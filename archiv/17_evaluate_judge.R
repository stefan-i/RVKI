# =============================================================================
# 17_evaluate_judge.R
# End-to-end evaluation: enrichment -> retrieval -> judge.
# A/B several models on the same 51 books and the same candidate lists.
#
# Retrieval runs ONCE per book; every model then judges the identical
# candidate list, so differences are attributable to the model alone.
#
# Holdings run leave-one-out, so the numbers are honest.
#
# Cost: roughly $0.02 (enrichment+embeddings) + under $1 per model tested.
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

# --- Which models to compare -------------------------------------------------
# Comment out any you do not want to pay for on this run.
MODELS_TO_TEST <- c("luna", "terra")

MODE <- "social"
N_CANDIDATES <- 50L


if (!exists("state") || is.null(state$con) || !DBI::dbIsValid(state$con)) {
  cat("Loading retrieval state...\n")
  state <- load_retrieval_state()
}

test <- read_delim(here("RVK_data", "RVK-Testdaten.csv"), delim = ";",
                   col_names = c("title", "notation_truth"),
                   show_col_types = FALSE, locale = locale(encoding = "UTF-8")) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))
cat(sprintf("%d test books | models: %s\n",
            nrow(test), paste(MODELS_TO_TEST, collapse = ", ")))


# -----------------------------------------------------------------------------
# 1. Enrichment + embeddings (once)
# -----------------------------------------------------------------------------

cat("\nEnriching titles...\n")
expanded <- map(test$title, function(t)
  tryCatch(expand_title(t),
           error = function(e) list(fach = NA, hauptthema = NA,
                                    schlagwoerter = character(0))))
enriched <- map_chr(seq_len(nrow(test)),
                    ~ build_enriched_query(test$title[.x], expanded[[.x]]))

cat("Embedding...\n")
emb_enriched <- embed_texts_batch(enriched)
emb_title    <- embed_texts_batch(test$title)


# -----------------------------------------------------------------------------
# 2. Retrieval (once per book, leave-one-out)
# -----------------------------------------------------------------------------

cat("Retrieving candidates (leave-one-out)...\n")
cand_list <- map(seq_len(nrow(test)), function(i) {
  retrieve_candidates(
    state, enriched[i], emb_enriched[i, ],
    title_text = test$title[i], title_embedding = emb_title[i, ],
    mode = MODE, n_final = N_CANDIDATES,
    exclude_titles = test$title[i]        # honest evaluation
  )
})

recall <- map_lgl(seq_len(nrow(test)),
                  ~ test$notation_truth[.x] %in% cand_list[[.x]]$notation)
cat(sprintf("Truth present in the %d candidates: %d / %d (%.0f%%)\n",
            N_CANDIDATES, sum(recall), nrow(test), 100 * mean(recall)))
cat("  (this is the ceiling for judge top-1 accuracy)\n")


# -----------------------------------------------------------------------------
# 3. Judge with each model
# -----------------------------------------------------------------------------

judge_all <- function(model_key) {
  cat(sprintf("\n--- judging with '%s' ---\n", model_key))
  t0 <- Sys.time()
  out <- map_dfr(seq_len(nrow(test)), function(i) {
    cat(sprintf("\r  %d/%d", i, nrow(test)))
    r <- judge_candidates(test$title[i], cand_list[[i]],
                          mode = MODE, model_key = model_key,
                          max_candidates = N_CANDIDATES)
    tibble(
      model      = model_key,
      i          = i,
      title      = test$title[i],
      truth      = test$notation_truth[i],
      ok         = isTRUE(r$ok),
      pick       = if (isTRUE(r$ok)) r$notation else NA_character_,
      alt        = if (isTRUE(r$ok)) r$alternative_notation else NA_character_,
      konfidenz  = if (isTRUE(r$ok)) r$konfidenz else NA_character_,
      valid_pick = if (isTRUE(r$ok)) isTRUE(r$notation_in_candidates) else NA,
      begruendung = if (isTRUE(r$ok)) r$begruendung else NA_character_,
      error      = if (isTRUE(r$ok)) NA_character_ else (r$error %||% NA_character_)
    )
  })
  cat(sprintf("\n  done in %.0fs\n", as.numeric(Sys.time() - t0, units = "secs")))
  out
}

results <- map_dfr(MODELS_TO_TEST, judge_all)


# -----------------------------------------------------------------------------
# 4. Summary
# -----------------------------------------------------------------------------

results <- results |>
  mutate(
    truth_in_cand = recall[i],
    hit_top1      = !is.na(pick) & pick == truth,
    hit_alt       = !is.na(alt)  & alt  == truth,
    hit_either    = hit_top1 | hit_alt,
    branch_ok     = !is.na(pick) & str_sub(pick, 1, 2) == str_sub(truth, 1, 2)
  )

cat(sprintf("\n===== Judge comparison over %d books =====\n", nrow(test)))
print(results |> group_by(model) |>
        summarise(
          calls_ok      = sum(ok),
          invalid_picks = sum(!coalesce(valid_pick, TRUE)),
          top1          = sum(hit_top1),
          `top1 %`      = round(100 * mean(hit_top1)),
          `+alternative`= sum(hit_either),
          `either %`    = round(100 * mean(hit_either)),
          `branch ok`   = sum(branch_ok),
          .groups = "drop"))

cat("\n--- Accuracy when the truth WAS in the candidate list ---\n")
print(results |> filter(truth_in_cand) |> group_by(model) |>
        summarise(n = n(), top1 = sum(hit_top1),
                  `top1 %` = round(100 * mean(hit_top1)),
                  either = sum(hit_either), .groups = "drop"))

cat("\n--- Confidence calibration ---\n")
print(results |> group_by(model, konfidenz) |>
        summarise(n = n(), correct = sum(hit_top1),
                  accuracy = round(100 * mean(hit_top1)), .groups = "drop") |>
        arrange(model, desc(n)))


# -----------------------------------------------------------------------------
# 5. Disagreements — for manual review
# -----------------------------------------------------------------------------
# The test labels are one defensible answer, not the only one. These are the
# cases to read yourself and decide whether the pick is acceptable.

cat("\n--- Picks that differ from the test label (first model) ---\n")
m1 <- MODELS_TO_TEST[1]
misses <- results |> filter(model == m1, !hit_top1, truth_in_cand) |>
  select(i, truth, pick, alt, konfidenz, title, begruendung)
print(misses |> select(i, truth, pick, alt, konfidenz, title), n = 40)

cat("\n--- Where models disagree with each other ---\n")
if (length(MODELS_TO_TEST) > 1) {
  wide <- results |> select(i, model, pick) |>
    tidyr::pivot_wider(names_from = model, values_from = pick)
  disagree <- wide |>
    filter(!Reduce(`&`, lapply(MODELS_TO_TEST[-1],
                               function(m) wide[[m]] == wide[[MODELS_TO_TEST[1]]])))
  print(disagree |> left_join(test |> mutate(i = row_number()) |>
                                select(i, truth = notation_truth), by = "i"),
        n = 30)
}


# -----------------------------------------------------------------------------
# 6. Save, including reasoning text for manual review
# -----------------------------------------------------------------------------

write_csv(results, here("RVK_data", "eval_judge_results.csv"))
cat("\nSaved eval_judge_results.csv (includes Begründungen for manual review)\n")

cat("\n--- Sample output (first 3 books, first model) ---\n")
for (k in 1:3) {
  r <- results |> filter(model == m1, i == k)
  cat(sprintf("\n[%d] %s\n  Soll:   %s\n  Vorschlag: %s (%s)\n  Begründung: %s\n",
              k, str_trunc(r$title, 80), r$truth, r$pick, r$konfidenz,
              str_trunc(coalesce(r$begruendung, ""), 200)))
}
