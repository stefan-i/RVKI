# =============================================================================
# 09_diagnose_clusters.R
# Look directly at the failing notation clusters (MS 3600, DK 1010, DG 5000,
# MG 32xxx) to determine WHY retrieval misses them consistently.
#
# Three questions per cluster:
#   1. Is the failing notation's rich_text sparse or rich?
#   2. What notations ARE retrieved for queries targeting it?
#   3. Where does the failing notation actually rank (n_final = 200)?
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)
library(DBI)

source(here("RVK_data", "05_retrieve.R"))

if (!exists("state") || is.null(state$con) || !DBI::dbIsValid(state$con)) {
  state <- load_retrieval_state()
}

test <- read_delim(
  here("RVK_data", "RVK-Testdaten.csv"),
  delim = ";", col_names = c("title", "notation_truth"),
  show_col_types = FALSE, locale = locale(encoding = "UTF-8")
) |>
  filter(!is.na(title), nzchar(title), !is.na(notation_truth))

enriched <- read_csv(here("RVK_data", "retrieval_enriched_results.csv"),
                     show_col_types = FALSE)


# -----------------------------------------------------------------------------
# Helper: print full rich_text of a notation and its siblings
# -----------------------------------------------------------------------------

inspect_notation_neighborhood <- function(notation, n_siblings = 10) {
  cat(sprintf("\n>>> Notation: %s\n", notation))
  info <- dbGetQuery(state$con, sprintf(
    "SELECT notation, benennung, pfad, register, bemerkung
     FROM rvk WHERE notation = '%s'", notation
  ))
  if (nrow(info) == 0) { cat("  NOT FOUND in db\n"); return(invisible()) }
  cat(sprintf("  Benennung: %s\n",  info$benennung))
  cat(sprintf("  Pfad:      %s\n",  info$pfad))
  cat(sprintf("  Register:  %s\n",  ifelse(is.na(info$register),  "(none)", info$register)))
  cat(sprintf("  Bemerkung: %s\n",  ifelse(is.na(info$bemerkung), "(none)", info$bemerkung)))
  
  # Show parent and a few siblings to understand the local hierarchy.
  parent <- dbGetQuery(state$con, sprintf(
    "SELECT parent_notation FROM rvk WHERE notation = '%s'", notation
  ))$parent_notation
  if (!is.null(parent) && length(parent) > 0 && !is.na(parent)) {
    cat(sprintf("\n  Siblings (children of %s):\n", parent))
    siblings <- dbGetQuery(state$con, sprintf(
      "SELECT notation, benennung, register
       FROM rvk WHERE parent_notation = '%s' AND has_range = 0
       ORDER BY notation LIMIT %d", parent, n_siblings
    )) |> as_tibble()
    print(siblings, n = n_siblings)
  }
}


# -----------------------------------------------------------------------------
# Helper: find rank of a notation deep in the candidate list
# -----------------------------------------------------------------------------

deep_rank <- function(query_text, q_emb, target, n = 200) {
  hits <- retrieve_hybrid(state, query_text, q_emb,
                          n_fts = 100, n_vec = 200, n_final = n)
  list(
    rank   = match(target, hits$notation),
    top5   = hits |> head(5) |> select(notation, benennung),
    siblings_in_top_n = hits |> filter(str_starts(notation, str_sub(target, 1, 2))) |>
      head(10) |> select(notation, benennung)
  )
}


# -----------------------------------------------------------------------------
# 1. Inspect the cluster-failing notations themselves
# -----------------------------------------------------------------------------

cat("==============================================================\n")
cat("STEP 1: How are these notations represented in our index?\n")
cat("==============================================================\n")

for (n in c("MS 3600", "DK 1010", "DK 1020", "DF 3000", "DG 5000", "MG 32000")) {
  inspect_notation_neighborhood(n, n_siblings = 8)
}


# -----------------------------------------------------------------------------
# 2. Re-embed three migration queries and look deep (n=200)
# -----------------------------------------------------------------------------

cat("\n\n==============================================================\n")
cat("STEP 2: Migration cluster — what is actually being retrieved?\n")
cat("==============================================================\n")

# Re-build the enriched queries for the migration books (using saved data).
migration_books <- enriched |> filter(truth == "MS 3600")
cat(sprintf("\n%d migration books in test set.\n", nrow(migration_books)))

# We need fresh embeddings for the enriched queries; they aren't saved.
# Re-do for these specific books quickly.
mig_titles <- test$title[migration_books$i]
cat("Re-expanding and embedding 3 migration queries for deep look...\n")

source_path <- here("RVK_data", "08_query_enrichment.R")
# Reuse the expand_title function defined there.
# (If 08 hasn't been sourced yet, we need to redefine it.)
if (!exists("expand_title")) {
  source(source_path, local = TRUE, echo = FALSE,
         max.deparse.length = 1e6)
}

mig_sample <- head(migration_books, 3)
for (k in seq_len(nrow(mig_sample))) {
  ii <- mig_sample$i[k]
  title <- test$title[ii]
  cat(sprintf("\n--- Book %d: %s\n", ii, title))
  exp <- expand_title(title)
  enriched_q <- paste0(
    "Buchtitel: ", title, ". Fach: ", exp$fach, ". Hauptthema: ",
    exp$hauptthema, ". Schlagwörter: ",
    paste(exp$schlagwoerter, collapse = "; "), "."
  )
  q_emb <- embed_text(enriched_q)
  res <- deep_rank(enriched_q, q_emb, "MS 3600", n = 200)
  cat(sprintf("  Rank of MS 3600 (within top 200): %s\n",
              ifelse(is.na(res$rank), "NOT FOUND", res$rank)))
  cat("  Top 5 candidates:\n")
  print(res$top5)
  cat("  MS-branch notations in top 200:\n")
  print(res$siblings_in_top_n)
}


# -----------------------------------------------------------------------------
# 3. Same for education (DK 1010) and Switzerland (MG 32000) — one each
# -----------------------------------------------------------------------------

cat("\n\n==============================================================\n")
cat("STEP 3: Education and Switzerland clusters — one example each\n")
cat("==============================================================\n")

for (target in c("DK 1010", "MG 32000")) {
  one_book <- enriched |> filter(truth == target) |> head(1)
  if (nrow(one_book) == 0) next
  ii <- one_book$i[1]
  title <- test$title[ii]
  cat(sprintf("\n--- Truth %s, Book %d: %s\n", target, ii, title))
  exp <- expand_title(title)
  enriched_q <- paste0(
    "Buchtitel: ", title, ". Fach: ", exp$fach, ". Hauptthema: ",
    exp$hauptthema, ". Schlagwörter: ",
    paste(exp$schlagwoerter, collapse = "; "), "."
  )
  q_emb <- embed_text(enriched_q)
  res <- deep_rank(enriched_q, q_emb, target, n = 200)
  cat(sprintf("  Rank of %s (within top 200): %s\n",
              target,
              ifelse(is.na(res$rank), "NOT FOUND", res$rank)))
  cat("  Top 5:\n"); print(res$top5)
  cat(sprintf("  %s-branch notations in top 200:\n", str_sub(target, 1, 2)))
  print(res$siblings_in_top_n)
}