# =============================================================================
# lib_local_rules.R
# Pure functions for parsing local-rule notations and matching them against
# RVK notations. Safe to source (no side effects).
#
# A rule's notation field is one of:
#   single        "DN 1000"            -> letters DN, number 1000
#   numeric_range "AE 70210-70218"     -> letters AE, 70210..70218
#   letter_prefix "DM"                 -> any notation whose letters start DM
#   letter_range  "MN-MW"              -> any notation whose letters are
#                                          alphabetically within [MN, MW]
# =============================================================================

library(dplyr)
library(stringr)
library(tibble)
library(purrr)


# Specificity ranking for resolving overlapping matches (higher = wins).
RULE_SPECIFICITY <- c(single = 4L, numeric_range = 3L,
                      letter_range = 2L, letter_prefix = 1L)


# --- Parse a single rule notation string into structured fields ---------------

parse_rule_notation <- function(x) {
  raw <- x
  t <- x |>
    str_trim() |>
    str_replace_all("[\u2013\u2014]", "-") |>   # en/em dash -> hyphen
    str_replace_all("\\s*-\\s*", "-") |>
    str_replace_all("\\s+", " ") |>
    str_trim()

  if (str_detect(t, "^[A-Z]+ [0-9]+-[0-9]+$")) {
    m <- str_match(t, "^([A-Z]+) ([0-9]+)-([0-9]+)$")
    return(tibble(type = "numeric_range", letters = m[2],
                  num_start = as.numeric(m[3]), num_end = as.numeric(m[4]),
                  letter_start = NA_character_, letter_end = NA_character_,
                  raw = raw))
  }
  if (str_detect(t, "^[A-Z]+ [0-9]+$")) {
    m <- str_match(t, "^([A-Z]+) ([0-9]+)$")
    return(tibble(type = "single", letters = m[2],
                  num_start = as.numeric(m[3]), num_end = as.numeric(m[3]),
                  letter_start = NA_character_, letter_end = NA_character_,
                  raw = raw))
  }
  if (str_detect(t, "^[A-Z]+-[A-Z]+$")) {
    m <- str_match(t, "^([A-Z]+)-([A-Z]+)$")
    return(tibble(type = "letter_range", letters = NA_character_,
                  num_start = NA_real_, num_end = NA_real_,
                  letter_start = m[2], letter_end = m[3], raw = raw))
  }
  if (str_detect(t, "^[A-Z]+$")) {
    return(tibble(type = "letter_prefix", letters = t,
                  num_start = NA_real_, num_end = NA_real_,
                  letter_start = NA_character_, letter_end = NA_character_,
                  raw = raw))
  }
  tibble(type = "UNPARSEABLE", letters = NA_character_,
         num_start = NA_real_, num_end = NA_real_,
         letter_start = NA_character_, letter_end = NA_character_, raw = raw)
}


# --- Parse a vector of RVK notations into (letters, number) -------------------

parse_rvk_notation <- function(notations) {
  tibble(
    notation = notations,
    n_letters = str_match(notations, "^([A-Z]+)")[, 2],
    n_number  = suppressWarnings(as.numeric(str_match(notations, "\\s([0-9]+)")[, 2]))
  )
}


# --- Match candidate notations against a parsed rules table -------------------
# `rules` must have columns: rule_id, type, letters, num_start, num_end,
# letter_start, letter_end, nicht_belegt, stichwoerter, erklaerung,
# specificity. Returns one row per (candidate, matching rule).

match_notations_to_rules <- function(candidate_notations, rules) {
  cand <- parse_rvk_notation(candidate_notations)
  if (nrow(cand) == 0) return(tibble())

  out <- vector("list", nrow(rules))
  for (i in seq_len(nrow(rules))) {
    r <- rules[i, ]
    matched <- switch(
      r$type,
      "single" =
        !is.na(cand$n_letters) & cand$n_letters == r$letters &
        !is.na(cand$n_number) & cand$n_number == r$num_start,
      "numeric_range" =
        !is.na(cand$n_letters) & cand$n_letters == r$letters &
        !is.na(cand$n_number) &
        cand$n_number >= r$num_start & cand$n_number <= r$num_end,
      "letter_prefix" =
        !is.na(cand$n_letters) & startsWith(cand$n_letters, r$letters),
      "letter_range" =
        !is.na(cand$n_letters) &
        cand$n_letters >= r$letter_start & cand$n_letters <= r$letter_end,
      rep(FALSE, nrow(cand))
    )
    if (any(matched)) {
      out[[i]] <- tibble(
        notation     = cand$notation[matched],
        rule_id      = r$rule_id,
        type         = r$type,
        specificity  = r$specificity,
        nicht_belegt = r$nicht_belegt,
        stichwoerter = r$stichwoerter,
        erklaerung   = r$erklaerung
      )
    }
  }
  bind_rows(out)
}


# --- Convenience: for each candidate, the single most-specific matching rule --
# Used for the nicht_belegt filter decision.

most_specific_rule_per_notation <- function(candidate_notations, rules) {
  m <- match_notations_to_rules(candidate_notations, rules)
  if (nrow(m) == 0) return(tibble(notation = character(0)))
  m |>
    group_by(notation) |>
    slice_max(specificity, n = 1, with_ties = FALSE) |>
    ungroup()
}
