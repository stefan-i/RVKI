# =============================================================================
# lib_confidence.R  (v2)
# Confidence for a chosen notation, from OBSERVABLE evidence.
#
# v2: the channel reason now names the channels inline, so the card can show a
# single sentence ("von 3 Suchkanälen (Stichwortsuche, ...) gefunden") instead
# of two lines that read as if the holdings titles came from those channels.
#
# Weighting, strongest signal first:
#   1. holdings support  — how many similar titles sit under this notation
#   2. channel agreement — how many independent channels found it
#   3. rank and margin
#
# Thresholds remain provisional; recalibrate once enough feedback has accrued.
# =============================================================================

library(dplyr)
library(stringr)
library(tibble)


CHANNEL_LABELS <- c(F = "Stichwortsuche", V = "Bedeutungsähnlichkeit",
                    L = "lokale Zusatznotation", H = "Bestand")

channel_names <- function(found_in) {
  if (is.na(found_in) || !nzchar(found_in)) return(character(0))
  lbl <- unname(CHANNEL_LABELS[strsplit(found_in, "")[[1]]])
  lbl[!is.na(lbl)]
}


CONF_WEIGHTS <- list(
  hold_strong = 3.0, hold_moderate = 1.5, hold_weak = 0.5,
  channels_3plus = 1.0, channels_2 = 0.5,
  is_rank1 = 0.5, clear_margin = 0.5
)

CONF_PARAMS <- list(
  hold_n_strong = 3L, sim_strong = 0.55,
  hold_n_moderate = 1L, sim_moderate = 0.48,
  margin_frac = 0.15,
  cut_high = 3.5, cut_medium = 1.5
)


compute_confidence <- function(candidates, picked_notation,
                               w = CONF_WEIGHTS, p = CONF_PARAMS) {

  out <- list(level = "niedrig", score = 0, reasons = character(0),
              hold_n = NA_integer_, hold_max_sim = NA_real_,
              channels = NA_integer_, rank = NA_integer_)
  if (nrow(candidates) == 0 || is.na(picked_notation)) return(out)

  i <- match(picked_notation, candidates$notation)
  if (is.na(i)) {
    out$reasons <- "Notation nicht in der Kandidatenliste"
    return(out)
  }
  r <- candidates[i, ]
  score <- 0; reasons <- character(0)

  # --- 1. holdings support --------------------------------------------------
  hn <- if (is.na(r$hold_n)) 0L else as.integer(r$hold_n)
  hs <- if (is.na(r$hold_max_sim)) 0 else as.numeric(r$hold_max_sim)

  if (hn >= p$hold_n_strong && hs >= p$sim_strong) {
    score <- score + w$hold_strong
    reasons <- c(reasons, sprintf(
      "%d ähnliche Titel im Bestand unter dieser Notation (höchste Ähnlichkeit %.2f)",
      hn, hs))
  } else if (hn >= p$hold_n_moderate && hs >= p$sim_moderate) {
    score <- score + w$hold_moderate
    reasons <- c(reasons, sprintf(
      "%d ähnliche%s Titel im Bestand (höchste Ähnlichkeit %.2f)",
      hn, if (hn == 1L) "r" else "", hs))
  } else if (hn > 0) {
    score <- score + w$hold_weak
    reasons <- c(reasons, sprintf(
      "nur schwache Bestandsähnlichkeit (%d Titel, max. %.2f)", hn, hs))
  } else {
    reasons <- c(reasons, "kein ähnlicher Titel im Bestand")
  }

  # --- 2. channel agreement, with the channels named ------------------------
  ch  <- if (is.na(r$found_in)) 0L else nchar(r$found_in)
  nms <- channel_names(r$found_in)
  ch_txt <- if (length(nms))
    sprintf("von %d Suchkanal%s (%s) gefunden", ch,
            if (ch == 1L) "" else "en", paste(nms, collapse = ", "))
  else NULL

  if (ch >= 3)      score <- score + w$channels_3plus
  else if (ch == 2) score <- score + w$channels_2
  if (!is.null(ch_txt)) reasons <- c(reasons, ch_txt)

  # --- 3. rank and margin ---------------------------------------------------
  if (!is.na(r$rank) && r$rank == 1L) {
    score <- score + w$is_rank1
    reasons <- c(reasons, "höchstplatzierter Kandidat")
  }
  if (nrow(candidates) >= 2 && !is.na(r$rrf)) {
    top2 <- sort(candidates$rrf, decreasing = TRUE)[1:2]
    if (top2[1] > 0) {
      margin <- (top2[1] - top2[2]) / top2[1]
      if (!is.na(r$rank) && r$rank == 1L && margin >= p$margin_frac) {
        score <- score + w$clear_margin
        reasons <- c(reasons, sprintf(
          "deutlicher Abstand zum zweiten Kandidaten (%.0f%%)", 100 * margin))
      }
    }
  }

  level <- if (score >= p$cut_high) "hoch"
           else if (score >= p$cut_medium) "mittel" else "niedrig"

  list(level = level, score = score, reasons = reasons,
       hold_n = hn, hold_max_sim = hs, channels = ch, rank = r$rank)
}


# --- Calibration helper ------------------------------------------------------

calibrate_confidence <- function(results, cand_list,
                                 pick_col = "pick", correct_col = "hit_top1",
                                 p = CONF_PARAMS) {
  conf <- vapply(seq_len(nrow(results)), function(k) {
    i <- results$i[k]
    compute_confidence(cand_list[[i]], results[[pick_col]][k], p = p)$level
  }, character(1))

  tibble(level = conf, correct = results[[correct_col]]) |>
    group_by(level) |>
    summarise(n = n(), correct = sum(correct, na.rm = TRUE),
              accuracy = round(100 * mean(correct, na.rm = TRUE)),
              .groups = "drop") |>
    arrange(factor(level, levels = c("hoch", "mittel", "niedrig")))
}
