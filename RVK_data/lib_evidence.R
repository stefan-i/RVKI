# =============================================================================
# lib_evidence.R  (v2)
# Show the librarian the evidence, not just a verdict.
#
# v2: the block now carries column headers and a short legend, so the
# similarity numbers are self-explanatory, and titles are truncated later.
#
# Nearest neighbours are returned REGARDLESS of notation, so disagreement in
# the collection stays visible instead of being filtered away.
# =============================================================================

library(dplyr)
library(tibble)
library(stringr)
library(DBI)


get_holdings_evidence <- function(state, mode, title_embedding,
                                  n = 8L, min_sim = 0.35,
                                  exclude_titles = NULL) {

  empty <- tibble(sim = numeric(0), notation = character(0),
                  title = character(0), benennung = character(0))

  prof <- get_profile(mode)
  if (is.null(prof$holdings)) return(empty)
  H <- state$holdings[[prof$holdings]]
  if (is.null(H)) return(empty)

  q <- as.numeric(title_embedding); q <- q / sqrt(sum(q^2))
  sims <- as.numeric(H$emb_norm %*% q)

  keep <- rep(TRUE, length(sims))
  if (!is.null(exclude_titles))
    keep <- keep & !(norm_title(H$title) %in% norm_title(exclude_titles))
  idx <- which(keep)
  if (!length(idx)) return(empty)

  idx <- head(idx[order(sims[idx], decreasing = TRUE)], n)
  idx <- idx[sims[idx] >= min_sim]
  if (!length(idx)) return(empty)

  ev <- tibble(sim = sims[idx], notation = H$notation[idx], title = H$title[idx])

  ben <- dbGetQuery(state$con, sprintf(
    "SELECT notation, benennung FROM rvk WHERE notation IN (%s)",
    paste0("'", unique(ev$notation), "'", collapse = ", "))) |> as_tibble()

  ev |> left_join(ben, by = "notation") |> arrange(desc(sim))
}


# --- German formatter --------------------------------------------------------

format_holdings_evidence <- function(ev, picked_notation = NULL,
                                     max_title_chars = 85L) {
  if (nrow(ev) == 0)
    return("Ähnliche Titel im Bestand: keine gefunden.")

  header <- sprintf("   %-11s %-11s %s", "Ähnlichkeit", "Notation", "Titel")

  lines <- vapply(seq_len(nrow(ev)), function(i) {
    marker <- if (!is.null(picked_notation) &&
                  identical(ev$notation[i], picked_notation)) "->" else "  "
    sprintf("%s %-11.2f %-11s %s", marker, ev$sim[i], ev$notation[i],
            str_trunc(ev$title[i], max_title_chars))
  }, character(1))

  legend <- paste0(
    "Ähnlichkeit: 1.00 = praktisch identischer Titel, ",
    "ab etwa 0.55 inhaltlich verwandt. -> = gleiche Notation wie der Vorschlag.")

  paste(c(header, lines, "", legend), collapse = "\n")
}


# --- Channel description (labels live in lib_confidence.R) -------------------

describe_channels <- function(found_in) {
  nms <- channel_names(found_in)
  if (!length(nms)) return("unbekannt")
  paste("gefunden über:", paste(nms, collapse = ", "))
}


# --- Descriptive caveat ------------------------------------------------------

thin_evidence_note <- function(candidates, picked_notation, ev) {
  i <- match(picked_notation, candidates$notation)
  if (is.na(i)) return(NULL)
  r <- candidates[i, ]

  no_holdings <- nrow(ev) == 0 || !any(ev$notation == picked_notation)
  one_channel <- !is.na(r$found_in) && nchar(r$found_in) <= 1

  notes <- character(0)
  if (no_holdings)
    notes <- c(notes, "kein ähnlicher Titel im Bestand unter dieser Notation")
  if (one_channel)
    notes <- c(notes, "nur von einem Suchkanal gefunden")

  if (!length(notes)) return(NULL)
  paste0("Wenig Anhaltspunkte: ", paste(notes, collapse = "; "), ".")
}


# --- Bundle for the UI -------------------------------------------------------

build_result_evidence <- function(state, mode, title_embedding,
                                  candidates, picked_notation,
                                  n_examples = 8L, exclude_titles = NULL) {

  ev <- get_holdings_evidence(state, mode, title_embedding,
                              n = n_examples, exclude_titles = exclude_titles)
  i <- match(picked_notation, candidates$notation)
  r <- if (is.na(i)) NULL else candidates[i, ]

  list(
    evidence_table = ev,
    evidence_text  = format_holdings_evidence(ev, picked_notation),
    channels_text  = if (is.null(r)) NA_character_ else describe_channels(r$found_in),
    local_rule     = if (is.null(r)) NA_character_ else r$local_erklaerung,
    in_core        = if (is.null(r)) NA else isTRUE(r$in_core),
    thin_note      = thin_evidence_note(candidates, picked_notation, ev),
    n_agree        = if (nrow(ev)) sum(ev$notation == picked_notation) else 0L,
    n_shown        = nrow(ev)
  )
}


# --- Console rendering -------------------------------------------------------

print_result <- function(title, judge_result, evidence) {
  cat(sprintf("\n%s\n%s\n", title, strrep("-", min(nchar(title), 80))))
  cat(sprintf("\nVorschlag:   %s — %s\n",
              judge_result$notation, judge_result$benennung))
  cat(sprintf("Begründung:  %s\n", judge_result$begruendung))
  if (!is.na(judge_result$alternative_notation))
    cat(sprintf("\nAlternative: %s — %s\n             %s\n",
                judge_result$alternative_notation,
                judge_result$alternative_benennung,
                judge_result$alternative_begruendung))
  cat(sprintf("\n%s\n", evidence$evidence_text))
  if (!is.null(evidence$local_rule) && !is.na(evidence$local_rule))
    cat(sprintf("\nLokale Regel: %s\n", evidence$local_rule))
  if (!is.null(evidence$thin_note)) cat(sprintf("\n%s\n", evidence$thin_note))
  if (!is.null(judge_result$disclaimer)) cat(sprintf("\n%s\n", judge_result$disclaimer))
  invisible(NULL)
}
