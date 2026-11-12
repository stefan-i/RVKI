# =============================================================================
# 08_query_enrichment.R
# Step 1 of the classification pipeline: use a cheap LLM to translate a
# book title from "marketing German/English" into RVK-style categorical
# vocabulary before retrieval.
#
# Compares baseline retrieval (raw titles) to enriched retrieval (LLM-
# expanded queries) on the same 50-book test set.
#
# Cost: ~$0.01 total. Runtime: ~5–7 minutes.
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)
library(httr2)
library(jsonlite)

source(here("RVK_data", "05_retrieve.R"))


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a


# -----------------------------------------------------------------------------
# 1. Title-expansion via GPT-4o-mini
# -----------------------------------------------------------------------------
# The LLM acts as a German subject librarian: it reads a title (in any
# language) and emits a structured German description using academic
# library vocabulary. The structured fields mirror our rich_text format
# (Fach ~ Pfad, Hauptthema ~ Benennung, Schlagwörter ~ Register), so the
# expanded query embeds in the same region of vector space as our docs.

SYSTEM_PROMPT <- "Du bist ein erfahrener wissenschaftlicher Bibliothekar und Experte für die deutsche RVK-Klassifikation (Regensburger Verbundklassifikation). Du erhältst Buchtitel (mit oder ohne Untertitel, in beliebiger Sprache) und bereitest sie für die Klassifikation auf.

Antworte AUSSCHLIESSLICH mit gültigem JSON in genau diesem Format:
{\"fach\": \"...\", \"hauptthema\": \"...\", \"schlagwoerter\": [\"...\", \"...\"]}

Wichtig:
- Antworte IMMER auf Deutsch, auch wenn der Titel in einer anderen Sprache ist.
- Verwende formale, akademische Bibliotheksvokabular (NICHT die Marketingsprache des Titels).
- Bei Komposita die in der RVK übliche Form (z.B. 'Verschwörungstheorie' statt 'Verschwörungsmythen').
- 5–8 möglichst spezifische Schlagwörter, einschliesslich relevanter Synonyme.
- Wenn das Buch einen länder- oder regionsspezifischen Fokus hat, das Land/die Region als Schlagwort hinzufügen.

Beispiele:

Titel: 'Conspiracy theories a primer'
{\"fach\": \"Politikwissenschaft\", \"hauptthema\": \"Verschwörungstheorien als politisches Phänomen\", \"schlagwoerter\": [\"Verschwörungstheorie\", \"Verschwörung\", \"Politische Psychologie\", \"Politisches Verhalten\", \"Radikalisierung\", \"Politische Ideologie\"]}

Titel: 'Transkription ein Leitfaden mit Aufgaben für Studenten, Forscher und Laien'
{\"fach\": \"Sozialwissenschaftliche Methoden\", \"hauptthema\": \"Transkription in der qualitativen Forschung\", \"schlagwoerter\": [\"Transkription\", \"Qualitative Forschung\", \"Forschungsmethode\", \"Sozialwissenschaftliche Methodologie\", \"Empirische Sozialforschung\"]}

Titel: 'Putin Russia'
{\"fach\": \"Politikwissenschaft\", \"hauptthema\": \"Politisches System Russlands unter Putin\", \"schlagwoerter\": [\"Russland\", \"Politisches System\", \"Wladimir Putin\", \"Russische Föderation\", \"Politische Systeme einzelner Länder\", \"Osteuropa\"]}

Titel: 'Innenwelten und Fremdkörper Abhängigkeitsbeziehungen bei Essstörungen und anderen seelischen Erkrankungen'
{\"fach\": \"Klinische Psychologie\", \"hauptthema\": \"Essstörungen und psychische Abhängigkeit\", \"schlagwoerter\": [\"Essstörung\", \"Klinische Psychologie\", \"Psychotherapie\", \"Anorexie\", \"Bulimie\", \"Abhängigkeit\", \"Psychische Erkrankung\"]}"


expand_title <- function(title,
                         api_key = Sys.getenv("OPENAI_API_KEY"),
                         model = "gpt-4o-mini") {
  req <- request("https://api.openai.com/v1/chat/completions") |>
    req_auth_bearer_token(api_key) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list(
      model = model,
      messages = list(
        list(role = "system", content = SYSTEM_PROMPT),
        list(role = "user",   content = paste0("Titel: ", title))
      ),
      response_format = list(type = "json_object"),
      temperature = 0.1,
      max_tokens  = 400
    )) |>
    req_retry(
      max_tries    = 3,
      backoff      = ~ min(30, 2 ^ .x),
      is_transient = function(r) resp_status(r) == 429 || resp_status(r) >= 500
    ) |>
    req_timeout(60)
  
  resp <- req_perform(req)
  body <- resp_body_json(resp)
  content <- body$choices[[1]]$message$content
  
  parsed <- tryCatch(
    jsonlite::fromJSON(content, simplifyVector = TRUE),
    error = function(e) list(fach = NA, hauptthema = NA, schlagwoerter = character(0))
  )
  list(
    fach          = as.character(parsed$fach %||% NA),
    hauptthema    = as.character(parsed$hauptthema %||% NA),
    schlagwoerter = unlist(parsed$schlagwoerter %||% character(0)) |> as.character()
  )
}


# Build the final enriched query string sent to retrieval.
# Includes the original title (so we never lose information) plus the
# librarian-style structured expansion.
build_enriched_query <- function(orig_title, exp) {
  parts <- c(
    paste0("Buchtitel: ", orig_title, "."),
    if (!is.na(exp$fach))       paste0("Fach: ", exp$fach, "."),
    if (!is.na(exp$hauptthema)) paste0("Hauptthema: ", exp$hauptthema, "."),
    if (length(exp$schlagwoerter) > 0)
      paste0("Schlagwörter: ", paste(exp$schlagwoerter, collapse = "; "), ".")
  )
  paste(parts, collapse = " ")
}


# -----------------------------------------------------------------------------
# 2. Load state (reuse if already loaded — state load is slow)
# -----------------------------------------------------------------------------

if (!exists("state") || is.null(state$con) || !DBI::dbIsValid(state$con)) {
  cat("Loading retrieval state...\n")
  state <- load_retrieval_state()
}


# -----------------------------------------------------------------------------
# 3. Load test data and original embeddings (re-use if loaded)
# -----------------------------------------------------------------------------

test <- read_delim(
  here("RVK_data", "RVK-Testdaten.csv"),
  delim = ";",
  col_names = c("title", "notation_truth"),
  show_col_types = FALSE,
  locale = locale(encoding = "UTF-8")
) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))

cat(sprintf("Loaded %d test books.\n", nrow(test)))

if (!exists("query_embs") || nrow(query_embs) != nrow(test)) {
  cat("Embedding original titles (one batched call)...\n")
  query_embs <- embed_texts_batch(test$title)
}


# -----------------------------------------------------------------------------
# 4. Expand all titles via LLM
# -----------------------------------------------------------------------------

cat(sprintf("Expanding %d titles via GPT-4o-mini...\n", nrow(test)))
t0 <- Sys.time()
expanded <- vector("list", nrow(test))
for (i in seq_len(nrow(test))) {
  cat(sprintf("\r  %d/%d", i, nrow(test)))
  expanded[[i]] <- tryCatch(
    expand_title(test$title[i]),
    error = function(e) {
      cat(sprintf("\n  WARNING: expansion failed for #%d: %s\n", i, conditionMessage(e)))
      list(fach = NA, hauptthema = NA, schlagwoerter = character(0))
    }
  )
}
cat(sprintf("\nDone in %.1fs.\n", as.numeric(Sys.time() - t0, units = "secs")))

enriched_queries <- map_chr(seq_len(nrow(test)),
                            ~ build_enriched_query(test$title[.x], expanded[[.x]]))


# -----------------------------------------------------------------------------
# 5. Embed enriched queries in one batch
# -----------------------------------------------------------------------------

cat("Embedding enriched queries...\n")
t0 <- Sys.time()
enriched_embs <- embed_texts_batch(enriched_queries)
cat(sprintf("Done in %.1fs.\n", as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 6. Run retrieval for both baseline and enriched, side by side
# -----------------------------------------------------------------------------

cat("Running retrieval for both query versions...\n")
t0 <- Sys.time()

results <- map_dfr(seq_len(nrow(test)), function(i) {
  truth <- test$notation_truth[i]
  branch_truth <- str_sub(truth, 1, 2)
  
  base <- retrieve_hybrid(state, test$title[i],     query_embs[i, ],
                          n_fts = 50, n_vec = 50, n_final = 50)
  enr  <- retrieve_hybrid(state, enriched_queries[i], enriched_embs[i, ],
                          n_fts = 50, n_vec = 50, n_final = 50)
  
  top30_base <- head(base$notation, 30)
  top30_enr  <- head(enr$notation,  30)
  
  tibble(
    i               = i,
    title           = test$title[i],
    truth           = truth,
    rank_baseline   = match(truth, base$notation),
    rank_enriched   = match(truth, enr$notation),
    branch_baseline = branch_truth %in% str_sub(top30_base, 1, 2),
    branch_enriched = branch_truth %in% str_sub(top30_enr,  1, 2)
  )
})
cat(sprintf("Done in %.1fs.\n", as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 7. Summary comparison
# -----------------------------------------------------------------------------

summarise_v <- function(ranks, branch, name) {
  capped <- ifelse(is.na(ranks), Inf, ranks)
  tibble(
    method   = name,
    `top 5`  = sum(capped <= 5),
    `top 10` = sum(capped <= 10),
    `top 20` = sum(capped <= 20),
    `top 30` = sum(capped <= 30),
    `top 50` = sum(capped <= 50),
    `branch in top 30` = sum(branch),
    `median rank (found)` = median(ranks[!is.na(ranks)])
  )
}

cat(sprintf("\n=== Comparison over %d books ===\n", nrow(results)))
print(bind_rows(
  summarise_v(results$rank_baseline, results$branch_baseline, "Baseline (raw title)"),
  summarise_v(results$rank_enriched, results$branch_enriched, "Enriched (LLM Step 1)")
))


# -----------------------------------------------------------------------------
# 8. Show several expansions + rank changes for sanity check
# -----------------------------------------------------------------------------

cat("\n=== Sample expansions (focus on baseline failures) ===\n")
inspect <- c(1, 4, 8, 13, 22, 33, 34, 39, 42, 44)
for (i in inspect) {
  cat(sprintf("\n[%2d] Truth: %s\n", i, test$notation_truth[i]))
  cat(sprintf("     Original: %s\n", test$title[i]))
  cat(sprintf("     Enriched: %s\n", enriched_queries[i]))
  cat(sprintf("     Rank baseline -> enriched: %s -> %s\n",
              ifelse(is.na(results$rank_baseline[i]), ">50", results$rank_baseline[i]),
              ifelse(is.na(results$rank_enriched[i]), ">50", results$rank_enriched[i])))
}


# -----------------------------------------------------------------------------
# 9. Worst remaining cases under enrichment
# -----------------------------------------------------------------------------

cat("\n=== Books still missing from enriched top 30 ===\n")
bad <- results |>
  filter(is.na(rank_enriched) | rank_enriched > 30) |>
  arrange(desc(coalesce(rank_enriched, .Machine$integer.max)))

if (nrow(bad) == 0) {
  cat("  None.\n")
} else {
  print(bad |> select(i, title, truth, rank_baseline, rank_enriched, branch_enriched),
        n = nrow(bad))
}


# -----------------------------------------------------------------------------
# 10. Save full results for review
# -----------------------------------------------------------------------------

# Add expansion data to saved CSV for offline inspection.
results_full <- results |>
  mutate(
    fach          = map_chr(expanded, ~ .x$fach %||% NA_character_),
    hauptthema    = map_chr(expanded, ~ .x$hauptthema %||% NA_character_),
    schlagwoerter = map_chr(expanded, ~ paste(.x$schlagwoerter, collapse = "; "))
  )

out_path <- here("RVK_data", "retrieval_enriched_results.csv")
write_csv(results_full, out_path)
cat(sprintf("\nFull results saved to %s\n", out_path))