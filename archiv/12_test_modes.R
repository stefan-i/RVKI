# =============================================================================
# 12_test_modes.R  (v2)
# Test the mode-aware retrieval layer, focusing on the v3 fixes:
#   1. clone de-duplication (the "Aus-und Einwanderung" flood)
#   2. local additions showing the LOCAL meaning + guaranteed slots
#   3. modes behaving as configured
#   4. full re-evaluation on the 51-book test set with enriched queries
#
# Requires: 08_query_enrichment.R has been sourced at least once in the session
#           (for expand_title / SYSTEM_PROMPT), or it will be sourced here.
# =============================================================================

library(here)
library(dplyr)
library(stringr)
library(tibble)
library(readr)
library(purrr)

source(here("RVK_data", "05_retrieve.R"))

if (!exists("state") || is.null(state$con) || !DBI::dbIsValid(state$con)) {
  cat("Loading retrieval state (slow: 1.2 GB matrix)...\n")
  state <- load_retrieval_state()
}
cat(sprintf("Local rules: %d | local additions: %d | forbidden: %d\n",
            nrow(state$local_rules),
            sum(state$local_rules$is_local_addition),
            sum(state$local_rules$nicht_belegt)))


# -----------------------------------------------------------------------------
# TEST 1: the clone problem — before vs after de-duplication
# -----------------------------------------------------------------------------

cat("\n==============================================\n")
cat("TEST 1: clone de-duplication\n")
cat("==============================================\n")

q1 <- paste0("Buchtitel: Migration in Deutschland - soziologisch erklärt. ",
             "Fach: Soziologie. Hauptthema: Migration und Integration in Deutschland. ",
             "Schlagwörter: Migration; Integration; Migrationsforschung; ",
             "Einwanderung; Deutschland.")
emb1 <- embed_text(q1)

cat("\n--- WITHOUT dedup (max_per_benennung = 999): top 12\n")
r_nodedup <- retrieve_candidates(state, q1, emb1, mode = "social",
                                 n_final = 12, max_per_benennung = 999L)
print(r_nodedup |> select(rank, notation, benennung))

cat("\n--- WITH dedup (max_per_benennung = 3): top 20\n")
r_dedup <- retrieve_candidates(state, q1, emb1, mode = "social", n_final = 20)
cat(sprintf("  clones collapsed: %d | blocked removed: %d\n",
            attr(r_dedup, "n_clones_collapsed"),
            attr(r_dedup, "n_blocked_removed")))
print(r_dedup |> select(rank, notation, benennung, n_parallel))

cat("\n  Is MS 3600 (Emigranten, Immigranten, Geflüchtete) now present?\n")
deep <- retrieve_candidates(state, q1, emb1, mode = "social", n_final = 50)
cat(sprintf("  rank of MS 3600 in top 50: %s\n",
            ifelse(is.na(match("MS 3600", deep$notation)),
                   "not found", match("MS 3600", deep$notation))))


# -----------------------------------------------------------------------------
# TEST 2: local additions show the local meaning and get guaranteed slots
# -----------------------------------------------------------------------------

cat("\n==============================================\n")
cat("TEST 2: local additions (Bilderbuch)\n")
cat("==============================================\n")

q2 <- paste0("Buchtitel: Der Grüffelo - ein Bilderbuch über ein Ungeheuer im Wald. ",
             "Fach: Kinderliteratur. Hauptthema: Bilderbuch mit phantastischer Geschichte. ",
             "Schlagwörter: Bilderbuch; Phantastische Geschichten; Ungeheuer; ",
             "Märchen; Kinderbuch.")
emb2 <- embed_text(q2)

r2 <- retrieve_candidates(state, q2, emb2, mode = "social", n_final = 12)
cat("\nSocial mode, top 12 (note benennung for DX codes and is_local_addition):\n")
print(r2 |> select(rank, notation, benennung, is_local_addition, found_in))

cat("\nDetail for any local additions in the list:\n")
la_rows <- r2 |> filter(is_local_addition)
if (nrow(la_rows) == 0) {
  cat("  none in top 12\n")
} else {
  for (i in seq_len(nrow(la_rows))) {
    cat(sprintf("\n  %s\n    benennung:     %s\n    rvk_benennung: %s\n    bemerkung:     %s\n",
                la_rows$notation[i], la_rows$benennung[i],
                coalesce(la_rows$rvk_benennung[i], "(keine)"),
                coalesce(la_rows$bemerkung[i], "(keine)")))
  }
}

cat("\nVanilla mode for comparison (local additions should NOT appear as local):\n")
r2v <- retrieve_candidates(state, q2, emb2, mode = "vanilla", n_final = 8)
print(r2v |> select(rank, notation, benennung, is_local_addition))


# -----------------------------------------------------------------------------
# TEST 3: mode configuration sanity
# -----------------------------------------------------------------------------

cat("\n==============================================\n")
cat("TEST 3: mode configuration\n")
cat("==============================================\n")

for (m in names(MODE_CONFIG)) {
  cfg <- get_mode_config(m)
  cat(sprintf("  %-10s local_rules=%-5s branches=%-10s law_disclaimer=%s\n",
              m, cfg$use_local_rules,
              paste(cfg$preferred_branches, collapse = "/"),
              cfg$law_disclaimer))
}

q3 <- paste0("Buchtitel: Grundzüge des schweizerischen Staatsrechts. ",
             "Fach: Rechtswissenschaft. Hauptthema: Verfassungsrecht der Schweiz. ",
             "Schlagwörter: Staatsrecht; Verfassungsrecht; Schweiz; Bundesverfassung.")
emb3 <- embed_text(q3)
for (m in names(MODE_CONFIG)) {
  r <- retrieve_candidates(state, q3, emb3, mode = m, n_final = 5)
  cat(sprintf("\n  mode=%s law_disclaimer=%s -> %s\n",
              m, attr(r, "law_disclaimer"),
              paste(head(r$notation, 5), collapse = ", ")))
}


# -----------------------------------------------------------------------------
# TEST 4: full re-evaluation on the 51-book test set
# -----------------------------------------------------------------------------
# This is the number that matters. Uses the same LLM enrichment as script 08,
# then measures top-K recall with v3 retrieval in social mode.

cat("\n==============================================\n")
cat("TEST 4: full test-set re-evaluation (v3 retrieval)\n")
cat("==============================================\n")

test <- read_delim(
  here("RVK_data", "RVK-Testdaten.csv"),
  delim = ";", col_names = c("title", "notation_truth"),
  show_col_types = FALSE, locale = locale(encoding = "UTF-8")
) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))

# Reuse enrichment from script 08 if available; otherwise source it.
if (!exists("expand_title")) {
  cat("Sourcing enrichment helpers from 08_query_enrichment.R...\n")
  # Source only the function definitions by running the file in a temp env
  # would re-run its evaluation; instead we redefine minimally here.
  stop(paste0("Please run 08_query_enrichment.R first in this session so that ",
              "expand_title() and build_enriched_query() are defined, then re-run this script."))
}

cat(sprintf("Expanding %d titles...\n", nrow(test)))
expanded <- map(test$title, function(t) {
  tryCatch(expand_title(t),
           error = function(e) list(fach = NA, hauptthema = NA,
                                    schlagwoerter = character(0)))
})
enriched_queries <- map_chr(seq_len(nrow(test)),
                            ~ build_enriched_query(test$title[.x], expanded[[.x]]))

cat("Embedding enriched queries...\n")
enriched_embs <- embed_texts_batch(enriched_queries)

cat("Retrieving (social mode, v3)...\n")
res <- map_dfr(seq_len(nrow(test)), function(i) {
  hits <- retrieve_candidates(state, enriched_queries[i], enriched_embs[i, ],
                              mode = "social", n_final = 50)
  truth <- test$notation_truth[i]
  tibble(
    i          = i,
    title      = test$title[i],
    truth      = truth,
    rank       = match(truth, hits$notation),
    branch_hit = str_sub(truth, 1, 2) %in% str_sub(head(hits$notation, 30), 1, 2),
    collapsed  = attr(hits, "n_clones_collapsed"),
    blocked    = attr(hits, "n_blocked_removed")
  )
})

capped <- ifelse(is.na(res$rank), Inf, res$rank)
cat(sprintf("\nResults over %d books (v3 retrieval, social mode):\n", nrow(res)))
cat(sprintf("  top 5:  %2d / %d\n", sum(capped <= 5),  nrow(res)))
cat(sprintf("  top 10: %2d / %d\n", sum(capped <= 10), nrow(res)))
cat(sprintf("  top 20: %2d / %d\n", sum(capped <= 20), nrow(res)))
cat(sprintf("  top 30: %2d / %d\n", sum(capped <= 30), nrow(res)))
cat(sprintf("  top 50: %2d / %d\n", sum(capped <= 50), nrow(res)))
cat(sprintf("  branch in top 30: %2d / %d\n", sum(res$branch_hit), nrow(res)))
cat(sprintf("  median rank (found): %.1f\n", median(res$rank, na.rm = TRUE)))
cat(sprintf("  mean clones collapsed per query: %.1f\n", mean(res$collapsed)))
cat(sprintf("  mean blocked removed per query:  %.1f\n", mean(res$blocked)))

cat("\nStill missing from top 30:\n")
bad <- res |> filter(is.na(rank) | rank > 30) |> arrange(desc(coalesce(rank, 9999L)))
if (nrow(bad) == 0) cat("  none\n") else
  print(bad |> select(i, truth, rank, branch_hit, title), n = nrow(bad))

write_csv(res, here("RVK_data", "retrieval_v3_results.csv"))
cat("\nSaved to retrieval_v3_results.csv\n")
