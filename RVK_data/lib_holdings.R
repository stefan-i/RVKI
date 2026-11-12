# =============================================================================
# lib_holdings.R
# Nearest-neighbour retrieval over library holdings (title-to-title matching).
#
# Loaded lazily by 05_retrieve.R. One embedding matrix per profile, built by
# 14_embed_holdings.R.
#
# Scoring: for each notation among the k nearest titles, sum the similarities
# of its best `top_m` supporting titles. This rewards a notation backed by
# several good matches over one backed by a single lucky match, while capping
# how much a very large notation (e.g. DF 3000 with 476 books) can accumulate
# purely through base rate.
# =============================================================================

library(dplyr)
library(tibble)
library(stringr)


     load_holdings_index <- function(profile_id, dir = here::here("RVK_data")) {
       npath <- file.path(dir, sprintf("holdings_emb_%s_norm.rds", profile_id))
       path  <- file.path(dir, sprintf("holdings_emb_%s.rds", profile_id))
       if (file.exists(npath)) return(readRDS(npath))   # emb_norm already present
       if (!file.exists(path)) {
         warning(sprintf("No holdings embeddings for profile '%s'", profile_id))
         return(NULL)
       }
       H <- readRDS(path)
       H$emb_norm <- H$emb / sqrt(rowSums(H$emb^2))
       H$emb <- NULL
       invisible(gc())
       H
     }


# --- Core neighbour search ---------------------------------------------------
# title_embedding: embedding of the RAW book title (symmetric with the index)
# Returns one row per notation with aggregated support and example titles.

#
# Adds two exclusion mechanisms, needed for honest evaluation:
#   exclude_titles  drop neighbours whose normalised title matches one of these
#                   (simulates "this book is not yet in the collection")
#   max_sim         drop neighbours at or above this similarity
#
# Both default to off, so production behaviour is unchanged: in real use a
# near-identical neighbour (a new edition of a held title) is legitimate and
# useful signal.
# ---------------------------------------------------------------------------

norm_title <- function(x) {
  x |> stringr::str_to_lower() |>
    stringr::str_replace_all("[^\\w\\s]", " ") |>
    stringr::str_squish()
}

retrieve_holdings <- function(H, title_embedding,
                              k_neighbors    = 50L,
                              min_sim        = 0.40,
                              top_m          = 3L,
                              n_notations    = 25L,
                              n_examples     = 3L,
                              exclude_titles = NULL,
                              max_sim        = NULL) {
  
  empty <- tibble(notation = character(0), hold_rank = integer(0),
                  hold_score = numeric(0), hold_max_sim = numeric(0),
                  hold_n = integer(0), hold_examples = character(0))
  if (is.null(H)) return(empty)
  
  q <- as.numeric(title_embedding)
  q <- q / sqrt(sum(q^2))
  sims <- as.numeric(H$emb_norm %*% q)
  
  keep <- rep(TRUE, length(sims))
  if (!is.null(max_sim))        keep <- keep & (sims < max_sim)
  if (!is.null(exclude_titles)) keep <- keep & !(norm_title(H$title) %in% norm_title(exclude_titles))
  if (!any(keep)) return(empty)
  
  cand_idx <- which(keep)
  ord <- cand_idx[order(sims[cand_idx], decreasing = TRUE)]
  idx <- head(ord, k_neighbors)
  idx <- idx[sims[idx] >= min_sim]
  if (length(idx) == 0) return(empty)
  
  tibble(notation = H$notation[idx],
         title    = H$title[idx],
         sim      = sims[idx]) |>
    group_by(notation) |>
    arrange(desc(sim), .by_group = TRUE) |>
    summarise(
      hold_score   = sum(head(sim, top_m)),
      hold_max_sim = max(sim),
      hold_n       = n(),
      hold_examples = paste0(
        sprintf("%s (%.2f)", stringr::str_trunc(head(title, n_examples), 70),
                head(sim, n_examples)), collapse = " | "),
      .groups = "drop") |>
    arrange(desc(hold_score)) |>
    head(n_notations) |>
    mutate(hold_rank = row_number()) |>
    select(notation, hold_rank, hold_score, hold_max_sim, hold_n, hold_examples)
}
