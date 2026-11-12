# =============================================================================
# 15_evaluate_holdings.R
# Does the holdings channel deliver? Compare, on the same 51-book test set:
#   A  RVK channels only (v3 behaviour)      -> baseline was 30/51 in top 30
#   B  holdings channel alone
#   C  all four channels
#
# Requires 08_query_enrichment.R sourced in the session (expand_title(),
# build_enriched_query()).
#
# Cost: ~$0.02.
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
cat(sprintf("%d test books.\n", nrow(test)))


# --- Queries: enriched (for F/V) and raw title (for H) -----------------------

cat("Enriching titles...\n")
expanded <- map(test$title, function(t)
  tryCatch(expand_title(t),
           error = function(e) list(fach = NA, hauptthema = NA,
                                    schlagwoerter = character(0))))
enriched <- map_chr(seq_len(nrow(test)),
                    ~ build_enriched_query(test$title[.x], expanded[[.x]]))

cat("Embedding enriched queries and raw titles...\n")
emb_enriched <- embed_texts_batch(enriched)
emb_title    <- embed_texts_batch(test$title)


# --- Run the three configurations -------------------------------------------

cat("Retrieving (3 configurations)...\n")
res <- map_dfr(seq_len(nrow(test)), function(i) {
  truth <- test$notation_truth[i]

  rvk_only <- retrieve_candidates(
    state, enriched[i], emb_enriched[i, ],
    title_text = test$title[i], title_embedding = emb_title[i, ],
    mode = "social", n_final = 50, use_holdings = FALSE)

  hold_only <- retrieve_holdings(
    state$holdings[["B500"]], emb_title[i, ],
    k_neighbors = 50L, min_sim = 0.40, n_notations = 50L)

  full <- retrieve_candidates(
    state, enriched[i], emb_enriched[i, ],
    title_text = test$title[i], title_embedding = emb_title[i, ],
    mode = "social", n_final = 50, use_holdings = TRUE)

  tibble(
    i          = i,
    title      = test$title[i],
    truth      = truth,
    rank_rvk   = match(truth, rvk_only$notation),
    rank_hold  = match(truth, hold_only$notation),
    rank_full  = match(truth, full$notation),
    hold_n_cand = nrow(hold_only),
    branch_full = str_sub(truth, 1, 2) %in% str_sub(head(full$notation, 30), 1, 2)
  )
})


# --- Summary ----------------------------------------------------------------

summarise_cfg <- function(r, name) {
  c_ <- ifelse(is.na(r), Inf, r)
  tibble(config = name,
         `top 1`  = sum(c_ <= 1),  `top 5`  = sum(c_ <= 5),
         `top 10` = sum(c_ <= 10), `top 20` = sum(c_ <= 20),
         `top 30` = sum(c_ <= 30), `top 50` = sum(c_ <= 50),
         `median (found)` = median(r[!is.na(r)]))
}

cat(sprintf("\n===== Results over %d books =====\n", nrow(res)))
print(bind_rows(
  summarise_cfg(res$rank_rvk,  "A: RVK channels only"),
  summarise_cfg(res$rank_hold, "B: holdings only"),
  summarise_cfg(res$rank_full, "C: all four channels")
))

cat(sprintf("\nBranch in top 30 (config C): %d / %d\n",
            sum(res$branch_full), nrow(res)))
cat(sprintf("Median holdings candidates per query: %.0f\n",
            median(res$hold_n_cand)))


# --- Where did holdings make the difference? --------------------------------

cat("\n--- Rescued by holdings (missing in A, present in C top 30) ---\n")
rescued <- res |> filter((is.na(rank_rvk) | rank_rvk > 30),
                         !is.na(rank_full), rank_full <= 30)
print(rescued |> select(i, truth, rank_rvk, rank_hold, rank_full, title), n = 40)

cat("\n--- Hurt by holdings (in A top 30, lost in C) ---\n")
hurt <- res |> filter(!is.na(rank_rvk), rank_rvk <= 30,
                      is.na(rank_full) | rank_full > 30)
if (nrow(hurt) == 0) cat("  none\n") else
  print(hurt |> select(i, truth, rank_rvk, rank_hold, rank_full, title), n = 40)

cat("\n--- Still missing in config C ---\n")
still <- res |> filter(is.na(rank_full) | rank_full > 30) |>
  arrange(desc(coalesce(rank_full, 9999L)))
if (nrow(still) == 0) cat("  none\n") else
  print(still |> select(i, truth, rank_rvk, rank_hold, rank_full, branch_full, title),
        n = nrow(still))

write_csv(res, here("RVK_data", "eval_holdings_results.csv"))
cat("\nSaved eval_holdings_results.csv\n")


# --- Inspect one rescued case in detail -------------------------------------

if (nrow(rescued) > 0) {
  i <- rescued$i[1]
  cat(sprintf("\n===== Detail: book %d =====\n%s\nTruth: %s\n",
              i, test$title[i], test$notation_truth[i]))
  full <- retrieve_candidates(
    state, enriched[i], emb_enriched[i, ],
    title_text = test$title[i], title_embedding = emb_title[i, ],
    mode = "social", n_final = 10, use_holdings = TRUE)
  print(full |> select(rank, notation, benennung, found_in, hold_n, hold_max_sim))
  cat("\nSupporting holdings for the top candidate:\n")
  cat(strwrap(coalesce(full$hold_examples[1], "(none)"), width = 100,
              prefix = "  "), sep = "\n")
}
