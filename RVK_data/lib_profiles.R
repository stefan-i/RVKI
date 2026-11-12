# =============================================================================
# lib_profiles.R  (v2)
# Profile configuration: holdings set + local-rule set + preferred RVK groups.
#
# v2 changes: preferred branches are now precise RVK letter specs with human
# labels, matching the collection profile of each library, instead of coarse
# single letters.
#
# To add another library: add entries to HOLDINGS_SOURCES and PROFILES, then
# run 13_load_holdings.R and 14_embed_holdings.R. Nothing else changes.
# =============================================================================

HOLDINGS_SOURCES <- list(
  B500 = list(file = "HoldingsB500.xlsx",
              label = "Sozialwissenschaftliche Bibliothek",
              exclude_p = TRUE),      # St. Galler Rechtssystematik in use
  B589 = list(file = "HoldingsB589.xlsx",
              label = "Wirtschaftswissenschaftliche Bibliothek",
              exclude_p = FALSE)      # law classified with vanilla RVK
)


# --- Branch specs ------------------------------------------------------------
# "AP"     -> prefix match: every notation whose letters start with AP
# "CL-CZ"  -> range match: letters alphabetically within [CL, CZ]
# Labels are passed to the judge so it reasons about subjects, not codes.

BRANCHES_SOCIAL <- list(
  list(spec = "AP",    label = "AP Medien- und Kommunikationswissenschaften"),
  list(spec = "CL-CZ", label = "CL-CZ Psychologie"),
  list(spec = "D",     label = "D Pädagogik"),
  list(spec = "MA-ML", label = "MA-ML Politologie"),
  list(spec = "MN-MS", label = "MN-MS Soziologie")
)

BRANCHES_ECONOMICS <- list(
  list(spec = "Q",     label = "Q Wirtschaftswissenschaften")
)


PROFILES <- list(
  vanilla = list(
    label              = "Standard (reine RVK)",
    holdings           = NULL,
    rule_set           = NULL,
    branches           = list(),
    law_disclaimer     = FALSE
  ),
  social = list(
    label              = "Sozialwissenschaften",
    holdings           = "B500",
    rule_set           = "social",
    branches           = BRANCHES_SOCIAL,
    law_disclaimer     = TRUE
  ),
  economics = list(
    label              = "Wirtschaftswissenschaften",
    holdings           = "B589",
    rule_set           = NULL,
    branches           = BRANCHES_ECONOMICS,
    law_disclaimer     = FALSE
  )
)

get_profile <- function(profile) {
  profile <- match.arg(profile, names(PROFILES))
  p <- PROFILES[[profile]]
  # convenience: plain vectors alongside the structured list
  p$branch_specs  <- vapply(p$branches, function(b) b$spec,  character(1))
  p$branch_labels <- vapply(p$branches, function(b) b$label, character(1))
  # kept for older code that expected a plain letter vector
  p$preferred_branches <- p$branch_specs
  p
}


# --- Branch matching ---------------------------------------------------------
# Vectorised over notations; returns TRUE where a notation falls inside any
# of the given specs.

notation_letters <- function(notations) {
  m <- regmatches(notations, regexpr("^[A-Z]+", notations))
  out <- rep(NA_character_, length(notations))
  hit <- regexpr("^[A-Z]+", notations) > 0
  out[hit] <- m
  out
}

in_preferred_branches <- function(notations, specs) {
  if (length(specs) == 0 || length(notations) == 0)
    return(rep(FALSE, length(notations)))
  L <- notation_letters(notations)
  res <- rep(FALSE, length(notations))
  for (s in specs) {
    s <- trimws(s)
    if (grepl("-", s, fixed = TRUE)) {
      ends <- strsplit(s, "-", fixed = TRUE)[[1]]
      lo <- trimws(ends[1]); hi <- trimws(ends[2])
      res <- res | (!is.na(L) & L >= lo & L <= hi)
    } else {
      res <- res | (!is.na(L) & startsWith(L, s))
    }
  }
  res
}


# --- Call-number parsing (unchanged from v1 patch) ---------------------------

parse_call_number <- function(x) {
  s <- trimws(as.character(x)); s[is.na(s)] <- ""
  m1 <- regmatches(s, regexec("^[A-Za-z]+[_ ]+([A-Za-z]+)[_ ]+([0-9]+(?:\\.[0-9]+)?)", s))
  m2 <- regmatches(s, regexec("^([A-Za-z]+)_([0-9]+(?:\\.[0-9]+)?)", s))
  out <- rep(NA_character_, length(s)); method <- rep(NA_character_, length(s))
  for (i in seq_along(s)) {
    if (length(m1[[i]]) == 3) {
      out[i] <- paste(toupper(m1[[i]][2]), m1[[i]][3]); method[i] <- "prefixed"
    } else if (length(m2[[i]]) == 3) {
      out[i] <- paste(toupper(m2[[i]][2]), m2[[i]][3]); method[i] <- "unprefixed"
    }
  }
  list(notation = out, method = method)
}


# Backwards compatibility for v3 code paths.
MODE_CONFIG <- lapply(PROFILES, function(p) {
  list(use_local_rules    = !is.null(p$rule_set),
       preferred_branches = vapply(p$branches, function(b) b$spec, character(1)),
       law_disclaimer     = p$law_disclaimer)
})
get_mode_config <- function(mode) {
  mode <- match.arg(mode, names(MODE_CONFIG)); MODE_CONFIG[[mode]]
}
