# =============================================================================
# 07_diagnose_retrieval.R
# Inspect failure cases to understand WHAT is being retrieved when the truth
# isn't, and test two cheap hypotheses for improving retrieval:
#
#   H1: "Parent-branch hit rate" — for failures, did we at least retrieve a
#       semantically adjacent notation? If yes, the LLM-judge can do useful
#       work even on the current retrieval.
#
#   H2: "Query enrichment" — does adding a short LLM-generated topic summary
#       to the query text dramatically improve retrieval?
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)

source(here("RVK_data", "05_retrieve.R"))

state <- load_retrieval_state()


# -----------------------------------------------------------------------------
# 1. Load test data and pre-embed queries
# -----------------------------------------------------------------------------

test <- read_delim(
  here("RVK_data", "RVK-Testdaten.csv"),
  delim = ";",
  col_names = c("title", "notation_truth"),
  show_col_types = FALSE,
  locale = locale(encoding = "UTF-8")
) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))

query_embs <- embed_texts_batch(test$title)


# -----------------------------------------------------------------------------
# 2. Inspect what's in top 10 for a few revealing failure cases
# -----------------------------------------------------------------------------

inspect_query <- function(i) {
  title <- test$title[i]
  truth <- test$notation_truth[i]
  q_emb <- query_embs[i, ]
  hits  <- retrieve_hybrid(state, title, q_emb,
                           n_fts = 50, n_vec = 50, n_final = 10)
  cat(sprintf("\n--- Query %d: %s\n--- Truth:    %s\n\n",
              i, title, truth))
  print(hits |> select(notation, benennung, rrf))
}

# Look at several failure cases that span different patterns.
inspect_indices <- c(33, 13, 42, 8, 34, 37, 39, 18, 22, 1)
for (i in inspect_indices) inspect_query(i)


# -----------------------------------------------------------------------------
# 3. Lenient metric: was a "neighboring" notation in top 30?
# -----------------------------------------------------------------------------
# "Neighboring" = shares the first 2 characters of the notation (= same
# RVK letter pair / sub-branch). This is the librarian's "right neighborhood"
# test. The LLM-judge can often refine a near-miss into the right answer
# if the candidate list contains sibling notations.

cat("\n\n=== LENIENT METRIC: same sub-branch in top 30 ===\n")

branch_of <- function(n) str_sub(n, 1, 2)

# Re-run hybrid retrieval at depth 30, full list.
neighborhood <- map_dfr(seq_len(nrow(test)), function(i) {
  hits <- retrieve_hybrid(state, test$title[i], query_embs[i, ],
                          n_fts = 50, n_vec = 50, n_final = 30)
  tibble(
    i           = i,
    truth       = test$notation_truth[i],
    branch      = branch_of(test$notation_truth[i]),
    has_truth   = test$notation_truth[i] %in% hits$notation,
    has_branch  = branch_of(test$notation_truth[i]) %in% branch_of(hits$notation)
  )
})

cat(sprintf("  Exact truth in top 30:    %d / %d (%.0f%%)\n",
            sum(neighborhood$has_truth), nrow(neighborhood),
            100 * mean(neighborhood$has_truth)))
cat(sprintf("  Same sub-branch in top 30:%d / %d (%.0f%%)\n",
            sum(neighborhood$has_branch), nrow(neighborhood),
            100 * mean(neighborhood$has_branch)))


# -----------------------------------------------------------------------------
# 4. Test H2: does query enrichment help?
# -----------------------------------------------------------------------------
# Hypothesis: prepending a brief categorical-style description to the title
# bridges the asymmetric-retrieval gap. We simulate the simplest possible
# enrichment by prepending the path-style label "Buch über das Thema:" to
# the query. (Real enrichment would use an LLM call to extract topics in
# German; this hand-crafted version is a lower bound.)

cat("\n\n=== H2: simple query prefix test ===\n")
# For a fair test we re-embed the prefixed queries.
prefixed <- paste0(
  "Klassifikation eines Buches mit folgendem Titel und Untertitel: ",
  test$title
)
prefixed_embs <- embed_texts_batch(prefixed)

results_prefix <- map_dfr(seq_len(nrow(test)), function(i) {
  hits <- retrieve_hybrid(state, prefixed[i], prefixed_embs[i, ],
                          n_fts = 50, n_vec = 50, n_final = 50)
  tibble(
    i        = i,
    truth    = test$notation_truth[i],
    rank_orig = match(test$notation_truth[i],
                      retrieve_hybrid(state, test$title[i], query_embs[i, ],
                                      n_fts = 50, n_vec = 50, n_final = 50)$notation),
    rank_prefix = match(test$notation_truth[i], hits$notation)
  )
})

cat(sprintf("  Original: top 30 = %d / %d, top 50 = %d / %d\n",
            sum(results_prefix$rank_orig <= 30, na.rm = TRUE), nrow(results_prefix),
            sum(results_prefix$rank_orig <= 50, na.rm = TRUE), nrow(results_prefix)))
cat(sprintf("  Prefixed: top 30 = %d / %d, top 50 = %d / %d\n",
            sum(results_prefix$rank_prefix <= 30, na.rm = TRUE), nrow(results_prefix),
            sum(results_prefix$rank_prefix <= 50, na.rm = TRUE), nrow(results_prefix)))


# -----------------------------------------------------------------------------
# 5. Compare a single failure case directly: title vs prefixed title
# -----------------------------------------------------------------------------
# Pick the Verschwörungsmythen case where vanilla retrieval failed completely.

cat("\n\n=== Single-case comparison: Verschwörungsmythen ===\n")
i33 <- 33

cat("\nRaw title query, top 10:\n")
print(retrieve_hybrid(state, test$title[i33], query_embs[i33, ],
                      n_fts = 50, n_vec = 50, n_final = 10) |>
        select(notation, benennung))

cat("\nPrefixed query, top 10:\n")
print(retrieve_hybrid(state, prefixed[i33], prefixed_embs[i33, ],
                      n_fts = 50, n_vec = 50, n_final = 10) |>
        select(notation, benennung))


close_retrieval_state(state)