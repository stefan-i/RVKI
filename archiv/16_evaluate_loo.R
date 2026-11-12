# =============================================================================
# 16_evaluate_loo.R
# Honest evaluation of the holdings channel: leave-one-out.
#
# The 51 test books are drawn from the collection, so the holdings index
# contains them. Script 15 therefore measured "can we look up a book we
# already have", not "can we classify a new acquisition". Here we exclude
# each test book from its own neighbour search.
#
# Three exclusion levels bracket the honest estimate:
#   none    what script 15 measured (leaky, upper bound)
#   exact   drop neighbours with an identical normalised title
#   strict  also drop any neighbour with similarity >= 0.90 (removes new
#           editions and near-identical variants; conservative lower bound)
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


# -----------------------------------------------------------------------------
# 1. How many test books are actually in the holdings index?
# -----------------------------------------------------------------------------

H <- state$holdings[["B500"]]
held <- norm_title(test$title) %in% norm_title(H$title)
cat(sprintf("\nTest books found verbatim in the B500 holdings index: %d / %d\n",
            sum(held), nrow(test)))

# For those that are held, does the index agree with the test label?
if (any(held)) {
  agree <- map_lgl(which(held), function(i) {
    j <- which(norm_title(H$title) == norm_title(test$title[i]))
    any(H$notation[j] == test$notation_truth[i])
  })
  cat(sprintf("  of those, index notation matches the test label: %d / %d\n",
              sum(agree), length(agree)))
}


# -----------------------------------------------------------------------------
# 2. Queries
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
# 3. Run all configurations
# -----------------------------------------------------------------------------

run_one <- function(i, use_holdings, excl_title, max_sim_h) {
  retrieve_candidates(
    state, enriched[i], emb_enriched[i, ],
    title_text = test$title[i], title_embedding = emb_title[i, ],
    mode = "social", n_final = 50,
    use_holdings     = use_holdings,
    exclude_titles   = excl_title,
    max_sim_holdings = max_sim_h
  )
}

cat("Retrieving...\n")
res <- map_dfr(seq_len(nrow(test)), function(i) {
  truth <- test$notation_truth[i]
  own   <- test$title[i]

  a    <- run_one(i, FALSE, NULL, NULL)                 # RVK only
  leak <- run_one(i, TRUE,  NULL, NULL)                 # as in script 15
  loo  <- run_one(i, TRUE,  own,  NULL)                 # exact-title excluded
  str_ <- run_one(i, TRUE,  own,  0.90)                 # strict

  h_loo <- retrieve_holdings(H, emb_title[i, ], k_neighbors = 50L,
                             min_sim = 0.40, n_notations = 50L,
                             exclude_titles = own)

  tibble(
    i = i, title = own, truth = truth,
    rank_rvk    = match(truth, a$notation),
    rank_leak   = match(truth, leak$notation),
    rank_loo    = match(truth, loo$notation),
    rank_strict = match(truth, str_$notation),
    rank_hold_loo = match(truth, h_loo$notation),
    was_held    = held[i],
    branch_loo  = str_sub(truth, 1, 2) %in% str_sub(head(loo$notation, 30), 1, 2)
  )
})


# -----------------------------------------------------------------------------
# 4. Summary
# -----------------------------------------------------------------------------

summarise_cfg <- function(r, name) {
  c_ <- ifelse(is.na(r), Inf, r)
  tibble(config = name,
         `top 1` = sum(c_ <= 1), `top 5` = sum(c_ <= 5),
         `top 10` = sum(c_ <= 10), `top 20` = sum(c_ <= 20),
         `top 30` = sum(c_ <= 30), `top 50` = sum(c_ <= 50),
         `median (found)` = median(r[!is.na(r)]))
}

cat(sprintf("\n===== %d books =====\n", nrow(res)))
print(bind_rows(
  summarise_cfg(res$rank_rvk,    "RVK channels only"),
  summarise_cfg(res$rank_leak,   "+ holdings (leaky, = script 15)"),
  summarise_cfg(res$rank_loo,    "+ holdings (own title excluded)"),
  summarise_cfg(res$rank_strict, "+ holdings (strict, sim < 0.90)"),
  summarise_cfg(res$rank_hold_loo, "holdings alone (own excluded)")
))

cat(sprintf("\nBranch in top 30 (LOO): %d / %d\n",
            sum(res$branch_loo), nrow(res)))

cat("\n--- Split by whether the book was in the index ---\n")
print(res |> group_by(was_held) |>
        summarise(n = n(),
                  loo_top10 = sum(coalesce(rank_loo, 999L) <= 10),
                  loo_top30 = sum(coalesce(rank_loo, 999L) <= 30),
                  rvk_top30 = sum(coalesce(rank_rvk, 999L) <= 30),
                  .groups = "drop"))

cat("\n--- Rescued by holdings under LOO ---\n")
resc <- res |> filter((is.na(rank_rvk) | rank_rvk > 30),
                      !is.na(rank_loo), rank_loo <= 30)
print(resc |> select(i, truth, rank_rvk, rank_hold_loo, rank_loo, title), n = 40)

cat("\n--- Hurt under LOO ---\n")
hurt <- res |> filter(!is.na(rank_rvk), rank_rvk <= 30,
                      is.na(rank_loo) | rank_loo > 30)
if (nrow(hurt) == 0) cat("  none\n") else
  print(hurt |> select(i, truth, rank_rvk, rank_loo, title), n = 40)

cat("\n--- Still missing under LOO ---\n")
still <- res |> filter(is.na(rank_loo) | rank_loo > 30) |>
  arrange(desc(coalesce(rank_loo, 9999L)))
if (nrow(still) == 0) cat("  none\n") else
  print(still |> select(i, truth, rank_rvk, rank_hold_loo, rank_loo, branch_loo, title),
        n = nrow(still))

write_csv(res, here("RVK_data", "eval_loo_results.csv"))
cat("\nSaved eval_loo_results.csv\n")
