# =============================================================================
# 18_diagnose_recall.R
# Script 16 measured 47/51 truth-in-top-30 under leave-one-out.
# Script 17 measured 31/51 with what should be the same retrieval.
# This isolates the cause: same session, same queries, several configurations.
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)

source(here("RVK_data", "05_retrieve.R"))
source(here("RVK_data", "lib_enrichment.R"))

if (!exists("state") || is.null(state$con) || !DBI::dbIsValid(state$con)) {
  cat("Loading retrieval state...\n")
  state <- load_retrieval_state()
}

test <- read_delim(here("RVK_data", "RVK-Testdaten.csv"), delim = ";",
                   col_names = c("title", "notation_truth"),
                   show_col_types = FALSE, locale = locale(encoding = "UTF-8")) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))


# -----------------------------------------------------------------------------
# 1. Confirm the retrieval function actually accepts the exclusion arguments
# -----------------------------------------------------------------------------

fa <- names(formals(retrieve_candidates))
cat("retrieve_candidates() arguments:\n  ", paste(fa, collapse = ", "), "\n")
for (a in c("exclude_titles", "max_sim_holdings", "n_force_local")) {
  cat(sprintf("  %-18s %s\n", a, if (a %in% fa) "present" else "*** MISSING ***"))
}
fh <- names(formals(retrieve_holdings))
cat("retrieve_holdings() arguments:\n  ", paste(fh, collapse = ", "), "\n")


# -----------------------------------------------------------------------------
# 2. Queries — computed ONCE and reused for every configuration
# -----------------------------------------------------------------------------

cat("\nEnriching + embedding (once)...\n")
expanded <- map(test$title, function(t)
  tryCatch(expand_title(t),
           error = function(e) list(fach = NA, hauptthema = NA,
                                    schlagwoerter = character(0))))
enriched <- map_chr(seq_len(nrow(test)),
                    ~ build_enriched_query(test$title[.x], expanded[[.x]]))
emb_enriched <- embed_texts_batch(enriched)
emb_title    <- embed_texts_batch(test$title)


# -----------------------------------------------------------------------------
# 3. Same queries, several retrieval configurations
# -----------------------------------------------------------------------------

get_rank <- function(i, n_final, excl, force_local) {
  r <- retrieve_candidates(
    state, enriched[i], emb_enriched[i, ],
    title_text = test$title[i], title_embedding = emb_title[i, ],
    mode = "social", n_final = n_final,
    exclude_titles = excl, n_force_local = force_local)
  match(test$notation_truth[i], r$notation)
}

cat("Retrieving under 5 configurations...\n")
cmp <- map_dfr(seq_len(nrow(test)), function(i) {
  own <- test$title[i]
  h <- retrieve_holdings(state$holdings[["B500"]], emb_title[i, ],
                         k_neighbors = 50L, min_sim = 0.40,
                         n_notations = 50L, exclude_titles = own)
  tibble(
    i          = i,
    truth      = test$notation_truth[i],
    title      = test$title[i],
    r50_loo    = get_rank(i, 50L, own,  2L),   # as in script 16
    r30_loo    = get_rank(i, 30L, own,  2L),   # as in script 17
    r30_noforce= get_rank(i, 30L, own,  0L),   # forced-local slots off
    r30_noexcl = get_rank(i, 30L, NULL, 2L),   # leaky, for reference
    hold_rank  = match(test$notation_truth[i], h$notation)
  )
})

hit <- function(x, k = 30L) sum(!is.na(x) & x <= k)

cat("\n===== Truth found, by configuration =====\n")
print(tibble(
  config = c("n_final=50, LOO (script 16)", "n_final=30, LOO (script 17)",
             "n_final=30, LOO, no forced local", "n_final=30, leaky",
             "holdings channel alone (LOO)"),
  `in top 30` = c(hit(cmp$r50_loo), hit(cmp$r30_loo),
                  hit(cmp$r30_noforce), hit(cmp$r30_noexcl), hit(cmp$hold_rank)),
  `in top 50` = c(hit(cmp$r50_loo, 50), hit(cmp$r30_loo, 50),
                  hit(cmp$r30_noforce, 50), hit(cmp$r30_noexcl, 50),
                  hit(cmp$hold_rank, 50))
))

cat("\n--- Books where n_final=50 finds the truth in top 30 but n_final=30 does not ---\n")
lost <- cmp |> filter(!is.na(r50_loo), r50_loo <= 30,
                      is.na(r30_loo) | r30_loo > 30)
if (nrow(lost) == 0) {
  cat("  none — the two configurations agree, so the earlier gap came from\n")
  cat("  run-to-run variation in the enrichment step, not from n_final.\n")
} else {
  print(lost |> select(i, truth, r50_loo, r30_loo, r30_noforce, hold_rank, title),
        n = nrow(lost))
}

cat("\n--- Rank distribution comparison ---\n")
print(cmp |> summarise(
  median_r50 = median(r50_loo, na.rm = TRUE),
  median_r30 = median(r30_loo, na.rm = TRUE),
  na_r50 = sum(is.na(r50_loo)),
  na_r30 = sum(is.na(r30_loo))))

write_csv(cmp, here("RVK_data", "diag_recall.csv"))
cat("\nSaved diag_recall.csv\n")


# -----------------------------------------------------------------------------
# 4. Stability check: does the enrichment step vary between runs?
# -----------------------------------------------------------------------------
# If the two runs above agree, the 47 vs 31 gap must come from the LLM
# enrichment producing different Schlagwörter each time. Test that directly
# on a handful of books.

cat("\n===== Enrichment stability (5 books, 2 runs each) =====\n")
probe <- c(3, 22, 44, 46, 50)
for (i in probe) {
  e1 <- build_enriched_query(test$title[i], expand_title(test$title[i]))
  e2 <- build_enriched_query(test$title[i], expand_title(test$title[i]))
  same <- identical(e1, e2)
  r1 <- retrieve_candidates(state, e1, embed_text(e1),
                            title_text = test$title[i],
                            title_embedding = emb_title[i, ],
                            mode = "social", n_final = 30,
                            exclude_titles = test$title[i])
  r2 <- retrieve_candidates(state, e2, embed_text(e2),
                            title_text = test$title[i],
                            title_embedding = emb_title[i, ],
                            mode = "social", n_final = 30,
                            exclude_titles = test$title[i])
  cat(sprintf("\n[%d] truth %s | enrichment identical: %s | rank run1: %s run2: %s\n",
              i, test$notation_truth[i], same,
              coalesce(as.character(match(test$notation_truth[i], r1$notation)), "-"),
              coalesce(as.character(match(test$notation_truth[i], r2$notation)), "-")))
  if (!same) {
    cat("   run1: ", str_trunc(e1, 150), "\n")
    cat("   run2: ", str_trunc(e2, 150), "\n")
  }
}
