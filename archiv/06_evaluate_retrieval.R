# =============================================================================
# 06_evaluate_retrieval.R
# Run all three retrieval methods on a labeled test set and compare quality.
#
# Inputs:  RVK_data/RVK-Testdaten.csv  (title;notation, no header)
# Outputs: console summary table + worst-case inspection
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)
library(tidyr)

source(here("RVK_data", "05_retrieve.R"))


# -----------------------------------------------------------------------------
# 1. Load test data
# -----------------------------------------------------------------------------

test_path <- here("RVK_data", "RVK-Testdaten.csv")
test <- read_delim(
  test_path, delim = ";",
  col_names = c("title", "notation_truth"),
  show_col_types = FALSE,
  locale = locale(encoding = "UTF-8")
) |>
  filter(!is.na(title), nzchar(title),
         !is.na(notation_truth), nzchar(notation_truth))
cat(sprintf("Loaded %d test books.\n", nrow(test)))


# -----------------------------------------------------------------------------
# 2. Load retrieval state
# -----------------------------------------------------------------------------

cat("Loading retrieval state (DB + 1.2 GB embedding matrix)...\n")
t0 <- Sys.time()
state <- load_retrieval_state()
cat(sprintf("  loaded in %.1fs\n", as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 3. Pre-embed all queries in one batched API call
# -----------------------------------------------------------------------------

cat("Embedding test queries (one batched API call)...\n")
t0 <- Sys.time()
query_embs <- embed_texts_batch(test$title)
cat(sprintf("  %d queries embedded in %.1fs\n",
            nrow(query_embs),
            as.numeric(Sys.time() - t0, units = "secs")))
stopifnot(nrow(query_embs) == nrow(test))


# -----------------------------------------------------------------------------
# 4. Run all three retrieval methods for each query
# -----------------------------------------------------------------------------

cat("Running retrieval...\n")
N <- 50L  # top-K to evaluate

t0 <- Sys.time()
results <- map_dfr(seq_len(nrow(test)), function(i) {
  title <- test$title[i]
  truth <- test$notation_truth[i]
  q_emb <- query_embs[i, ]
  
  fts <- retrieve_fts(state, title, n = N)
  vec <- retrieve_vec(state, q_emb, n = N)
  hyb <- retrieve_hybrid(state, title, q_emb,
                         n_fts = N, n_vec = N, n_final = N)
  
  tibble(
    i        = i,
    title    = title,
    truth    = truth,
    fts_rank = match(truth, fts$notation),
    vec_rank = match(truth, vec$notation),
    hyb_rank = match(truth, hyb$notation)
  )
})
cat(sprintf("  %d queries retrieved in %.1fs\n",
            nrow(results),
            as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 5. Summary
# -----------------------------------------------------------------------------

summarise_method <- function(ranks, name) {
  capped <- ifelse(is.na(ranks), Inf, ranks)
  found_ranks <- ranks[!is.na(ranks)]
  tibble(
    method        = name,
    `top 5`       = sum(capped <= 5),
    `top 10`      = sum(capped <= 10),
    `top 20`      = sum(capped <= 20),
    `top 30`      = sum(capped <= 30),
    `top 50`      = sum(capped <= 50),
    `median rank (found)` = if (length(found_ranks) == 0) NA_real_
    else median(found_ranks),
    `not in top 50` = sum(is.na(ranks))
  )
}

summary <- bind_rows(
  summarise_method(results$fts_rank, "FTS only"),
  summarise_method(results$vec_rank, "Vector only"),
  summarise_method(results$hyb_rank, "Hybrid (RRF)")
)

cat(sprintf("\nResults over %d test books (counts are # of books):\n",
            nrow(results)))
print(summary)


# -----------------------------------------------------------------------------
# 6. Worst cases for hybrid retrieval
# -----------------------------------------------------------------------------
# Books where the known notation didn't reach the hybrid top 30 — these are
# the cases worth inspecting manually to understand failure modes.

cat("\n--- Books where hybrid did NOT find truth in top 30 ---\n")
bad <- results |>
  filter(is.na(hyb_rank) | hyb_rank > 30) |>
  arrange(desc(coalesce(hyb_rank, .Machine$integer.max)))

if (nrow(bad) == 0) {
  cat("  None! Every truth was within hybrid top 30.\n")
} else {
  print(bad |> select(i, title, truth, fts_rank, vec_rank, hyb_rank),
        n = nrow(bad))
}


# -----------------------------------------------------------------------------
# 7. Per-book detail (compact view)
# -----------------------------------------------------------------------------
# Save for later inspection.

results_path <- here("RVK_data", "retrieval_eval_results.csv")
write_csv(results, results_path)
cat(sprintf("\nPer-book results saved to %s\n", results_path))


close_retrieval_state(state)