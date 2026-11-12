# =============================================================================
# 21_evaluate_models.R
# Benchmark judge models on the 51-title test set. Supersedes 17.
#
# Retrieval runs ONCE per book and every model judges the identical candidate
# list, so differences are attributable to the model alone. Holdings run
# leave-one-out, so the ceiling is honest.
#
# Reports, per model:
#   robustness  errors, parse failures, invalid picks   <- the gate
#   accuracy    top-1, top-1 or alternative, branch
#   cost        seconds per call, prompt/completion/reasoning tokens
#
# Set MODELS_TO_TEST to one model or several. Failures are per-call, so a
# broken model does not abort the run.
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)

source(here("RVK_data", "05_retrieve.R"))
source(here("RVK_data", "lib_enrichment.R"))
source(here("RVK_data", "lib_judge.R"))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a


# --- Configuration -----------------------------------------------------------
# Edit this line to test one model or many. Names come from JUDGE_MODELS.
MODELS_TO_TEST <- c("luna", "terra",
                    "or_gemini", "or_gemma", "or_minimax", "or_deepseek",
                    "uni_oss120", "uni_qwen")

MODE         <- "social"
N_CANDIDATES <- 50L
RESULT_CSV   <- here("RVK_data", "eval_models_results.csv")


cat("Zu testende Modelle:\n")
for (k in MODELS_TO_TEST) {
  s <- JUDGE_MODELS[[k]]
  if (is.null(s)) { cat(sprintf("  %-12s UNBEKANNT\n", k)); next }
  p <- JUDGE_PROVIDERS[[s$provider]]
  cat(sprintf("  %-12s %-38s key: %s\n", k, s$model,
              if (nzchar(Sys.getenv(p$key_env))) "ok" else "FEHLT"))
}

if (!exists("state") || is.null(state$con) || !DBI::dbIsValid(state$con)) {
  cat("\nLade Indizes ...\n")
  state <- load_retrieval_state()
}


# --- Test data ---------------------------------------------------------------

test <- read_delim(here("RVK_data", "RVK-Testdaten.csv"), delim = ";",
                   col_names = c("title", "notation_truth"),
                   show_col_types = FALSE, locale = locale(encoding = "UTF-8")) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))
cat(sprintf("\n%d Testtitel\n", nrow(test)))


# --- Enrichment (cached) + embeddings ---------------------------------------
# lib_enrichment caches by (model, title), so repeated runs reuse identical
# queries. That is what makes results comparable between runs.

cat("Titelanalyse (Cache wird genutzt) ...\n")
expanded <- map(test$title, function(t)
  tryCatch(expand_title(t),
           error = function(e) list(fach = NA, hauptthema = NA,
                                    schlagwoerter = character(0))))
enriched <- map_chr(seq_len(nrow(test)),
                    ~ build_enriched_query(test$title[.x], expanded[[.x]]))

cat("Embeddings ...\n")
emb_enriched <- embed_texts_batch(enriched)
emb_title    <- embed_texts_batch(test$title)


# --- Retrieval once, shared by all models ------------------------------------

cat("Kandidatensuche (leave-one-out) ...\n")
cand_list <- map(seq_len(nrow(test)), function(i)
  retrieve_candidates(state, enriched[i], emb_enriched[i, ],
                      title_text = test$title[i], title_embedding = emb_title[i, ],
                      mode = MODE, n_final = N_CANDIDATES,
                      exclude_titles = test$title[i]))

recall <- map_lgl(seq_len(nrow(test)),
                  ~ test$notation_truth[.x] %in% cand_list[[.x]]$notation)
cat(sprintf("Treffer in den %d Kandidaten: %d / %d (%.0f%%) — Obergrenze für top-1\n",
            N_CANDIDATES, sum(recall), nrow(test), 100 * mean(recall)))


# --- Judge with each model ---------------------------------------------------

judge_all <- function(model_key) {
  spec <- JUDGE_MODELS[[model_key]]
  if (is.null(spec)) return(tibble())
  cat(sprintf("\n--- %s (%s) ---\n", model_key, spec$model))
  t0 <- Sys.time()

  out <- map_dfr(seq_len(nrow(test)), function(i) {
    cat(sprintf("\r  %d/%d", i, nrow(test)))
    r <- tryCatch(
      judge_candidates(test$title[i], cand_list[[i]], mode = MODE,
                       model_key = model_key, max_candidates = N_CANDIDATES),
      error = function(e) list(ok = FALSE, error = conditionMessage(e)))

    err <- if (isTRUE(r$ok)) NA_character_ else (r$error %||% "unbekannt")
    tibble(
      model      = model_key,
      model_id   = spec$model,
      i          = i,
      title      = test$title[i],
      truth      = test$notation_truth[i],
      ok         = isTRUE(r$ok),
      pick       = if (isTRUE(r$ok)) r$notation else NA_character_,
      alt        = if (isTRUE(r$ok)) r$alternative_notation else NA_character_,
      konfidenz  = if (isTRUE(r$ok)) r$konfidenz else NA_character_,
      valid_pick = if (isTRUE(r$ok)) isTRUE(r$notation_in_candidates) else NA,
      begruendung= if (isTRUE(r$ok)) r$begruendung else NA_character_,
      seconds    = r$seconds %||% NA_real_,
      tok_prompt = as.numeric(r$usage$prompt_tokens %||% NA),
      tok_out    = as.numeric(r$usage$completion_tokens %||% NA),
      tok_reason = as.numeric(r$usage$reasoning_tokens %||% NA),
      parse_fail = !isTRUE(r$ok) && grepl("JSON", err %||% ""),
      error      = err)
  })

  cat(sprintf("\n  fertig in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
  out
}

results <- map_dfr(MODELS_TO_TEST, judge_all)


# --- Scoring -----------------------------------------------------------------

results <- results |>
  mutate(truth_in_cand = recall[i],
         hit_top1   = !is.na(pick) & pick == truth,
         hit_alt    = !is.na(alt)  & alt  == truth,
         hit_either = hit_top1 | hit_alt,
         branch_ok  = !is.na(pick) & str_sub(pick, 1, 2) == str_sub(truth, 1, 2))

cat("\n\n================ ROBUSTHEIT (Ausschlusskriterium) ================\n")
print(results |> group_by(model, model_id) |>
        summarise(n = n(),
                  Fehler        = sum(!ok),
                  `JSON-Fehler` = sum(parse_fail),
                  `Notation erfunden` = sum(!coalesce(valid_pick, TRUE)),
                  .groups = "drop") |>
        arrange(Fehler + `Notation erfunden`))

cat("\n================ TREFFERQUOTE ================\n")
print(results |> group_by(model) |>
        summarise(top1 = sum(hit_top1),
                  `top1 %` = round(100 * mean(hit_top1)),
                  `+Alternative` = sum(hit_either),
                  `Zweig ok` = sum(branch_ok),
                  .groups = "drop") |>
        arrange(desc(top1)))

cat("\n--- nur Fälle, in denen die Soll-Notation in der Liste stand ---\n")
print(results |> filter(truth_in_cand) |> group_by(model) |>
        summarise(n = n(), top1 = sum(hit_top1),
                  `top1 %` = round(100 * mean(hit_top1)),
                  .groups = "drop") |> arrange(desc(top1)))

cat("\n================ TEMPO UND TOKEN ================\n")
print(results |> filter(ok) |> group_by(model) |>
        summarise(`Sek. median` = round(median(seconds, na.rm = TRUE), 1),
                  `Sek. max`    = round(max(seconds, na.rm = TRUE), 1),
                  `Prompt-Tok`  = round(median(tok_prompt, na.rm = TRUE)),
                  `Antwort-Tok` = round(median(tok_out, na.rm = TRUE)),
                  `Reasoning-Tok` = round(median(tok_reason, na.rm = TRUE)),
                  .groups = "drop") |> arrange(`Sek. median`))

cat("\n================ KONFIDENZ ================\n")
print(results |> filter(ok) |> group_by(model, konfidenz) |>
        summarise(n = n(), richtig = sum(hit_top1),
                  Quote = round(100 * mean(hit_top1)), .groups = "drop") |>
        arrange(model, factor(konfidenz, levels = c("hoch", "mittel", "niedrig"))))

fails <- results |> filter(!ok)
if (nrow(fails)) {
  cat("\n================ FEHLERBEISPIELE ================\n")
  print(fails |> group_by(model) |> slice_head(n = 2) |>
          select(model, i, error), n = 30)
}

write_csv(results, RESULT_CSV)
cat(sprintf("\nGespeichert: %s\n", RESULT_CSV))
cat("\nHinweis: Modelle mit Fehlern oder erfundenen Notationen scheiden aus,\n")
cat("unabhängig von der Trefferquote. Erst danach zählt top-1.\n")
