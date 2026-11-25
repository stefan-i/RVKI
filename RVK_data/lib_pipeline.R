# =============================================================================
# lib_pipeline.R
# The shared classification pipeline: enrichment -> retrieval -> judge ->
# evidence. Contains NO Shiny code, so the same function serves the web app,
# a future plumber endpoint, and the Zotero integration.
#
# Also holds the feedback log (what the librarian actually chose), which over
# time turns undocumented in-house practice into data.
# =============================================================================

library(here)
library(dplyr)
library(tibble)
library(stringr)
library(DBI)
library(RSQLite)

source(here("RVK_data", "05_retrieve.R"))     # pulls in profiles, rules, holdings
source(here("RVK_data", "lib_enrichment.R"))
source(here("RVK_data", "lib_judge.R"))       # pulls in lib_confidence.R
source(here("RVK_data", "lib_evidence.R"))


# --- Defaults ----------------------------------------------------------------

PIPELINE_DEFAULTS <- list(
  model_key    = "luna",
  n_final      = 50L,
  branch_boost = 0.10,
  n_evidence   = 12L
)

# UI labels -> internal profile ids
MODE_LABELS <- c(
  "RVK Standard" = "vanilla",
  "RVK vonRoll"  = "social",
  "RVK BWW"      = "economics"
)


# --- Main entry point --------------------------------------------------------
# Returns a list with everything needed to render a result, or ok = FALSE plus
# a German error message. Never throws: callers get a result either way.

classify_title <- function(state, title,
                           mode         = "social",
                           model_key    = PIPELINE_DEFAULTS$model_key,
                           abstract     = NULL,
                           n_final      = PIPELINE_DEFAULTS$n_final,
                           branch_boost = PIPELINE_DEFAULTS$branch_boost,
                           n_evidence   = PIPELINE_DEFAULTS$n_evidence) {

  t0 <- Sys.time()
  title <- str_squish(title)
  fail <- function(msg, stage) list(
    ok = FALSE, title = title, mode = mode, stage = stage, error = msg,
    seconds = as.numeric(Sys.time() - t0, units = "secs"))

  if (!nzchar(title)) return(fail("Kein Titel angegeben.", "input"))
  if (nchar(title) < 4) return(fail("Titel ist zu kurz für eine Klassifikation.", "input"))

  # --- 1. Enrichment --------------------------------------------------------
  exp <- tryCatch(
    expand_title(if (is.null(abstract) || !nzchar(abstract)) title
                 else paste0(title, " — ", str_trunc(abstract, 1200))),
    error = function(e) e)
  if (inherits(exp, "error"))
    return(fail(paste0("Die Titelanalyse ist fehlgeschlagen: ",
                       conditionMessage(exp)), "enrichment"))
  if (is.na(exp$fach))
    return(fail("Die Titelanalyse lieferte kein verwertbares Ergebnis.", "enrichment"))

  enriched <- build_enriched_query(title, exp)

  # --- 2. Embeddings --------------------------------------------------------
  # Two vectors: the enriched query drives the RVK channels, the raw title
  # drives the holdings channel (title-to-title matching is symmetric).
  embs <- tryCatch(embed_texts_batch(c(enriched, title)),
                   error = function(e) e)
  if (inherits(embs, "error"))
    return(fail(paste0("Die Embedding-Abfrage ist fehlgeschlagen: ",
                       conditionMessage(embs)), "embedding"))

  emb_query <- embs[1, ]
  emb_title <- embs[2, ]

  # --- 3. Retrieval ---------------------------------------------------------
  cand <- tryCatch(
    retrieve_candidates(state, enriched, emb_query,
                        title_text = title, title_embedding = emb_title,
                        mode = mode, n_final = n_final,
                        branch_boost = branch_boost),
    error = function(e) e)
  if (inherits(cand, "error"))
    return(fail(paste0("Die Kandidatensuche ist fehlgeschlagen: ",
                       conditionMessage(cand)), "retrieval"))
  if (nrow(cand) == 0)
    return(fail("Es wurden keine passenden Notationen gefunden. Bitte den Titel präzisieren.",
                "retrieval"))

  # --- 4. Judge -------------------------------------------------------------
  jr <- tryCatch(
    judge_candidates(title, cand, mode = mode, model_key = model_key,
                     max_candidates = n_final, abstract = abstract),
    error = function(e) e)
  if (inherits(jr, "error"))
    return(fail(paste0("Die Auswahl durch das Sprachmodell ist fehlgeschlagen: ",
                       conditionMessage(jr)), "judge"))
  if (!isTRUE(jr$ok))
    return(fail(paste0("Das Sprachmodell lieferte kein verwertbares Ergebnis: ",
                       jr$error %||% "unbekannter Fehler"), "judge"))

  # --- 5. Evidence ----------------------------------------------------------
  ev <- tryCatch(
    build_result_evidence(state, mode, emb_title, cand, jr$notation,
                          n_examples = n_evidence),
    error = function(e) NULL)

  warn <- character(0)
  if (!isTRUE(jr$notation_in_candidates)) {
    warn <- c(warn, paste0(
      "Achtung: Die vorgeschlagene Notation stammt nicht aus der Kandidatenliste ",
      "und konnte nicht gegen die RVK geprüft werden."))
  }

  list(
    ok            = TRUE,
    title         = title,
    abstract      = abstract,
    mode          = mode,
    model         = jr$model,
    seconds       = as.numeric(Sys.time() - t0, units = "secs"),

    fach          = exp$fach,
    hauptthema    = exp$hauptthema,
    schlagwoerter = exp$schlagwoerter,

    notation      = jr$notation,
    benennung     = jr$benennung,
    begruendung   = jr$begruendung,
    alt_notation  = jr$alternative_notation,
    alt_benennung = jr$alternative_benennung,
    alt_begruendung = jr$alternative_begruendung,

    konfidenz     = jr$konfidenz,
    konf_score    = jr$konfidenz_score,
    konf_gruende  = jr$konfidenz_gruende,

    evidence      = ev,
    disclaimer    = jr$disclaimer,
    warnings      = warn,
    candidates    = cand
  )
}


# --- Convenience: pfad of the chosen notation, for display -------------------

result_pfad <- function(res) {
  if (!isTRUE(res$ok) || is.null(res$candidates)) return(NA_character_)
  i <- match(res$notation, res$candidates$notation)
  if (is.na(i)) return(NA_character_)
  res$candidates$pfad[i]
}


# =============================================================================
# Feedback log
# =============================================================================
# Anonymous. One row per decision: what was suggested, what was chosen.

FEEDBACK_DB <- here("RVK_data", "feedback.db")

init_feedback_db <- function(path = FEEDBACK_DB) {
  con <- dbConnect(SQLite(), path)
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS feedback (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      ts            TEXT,
      mode          TEXT,
      model         TEXT,
      title         TEXT,
      suggested     TEXT,
      suggested_ben TEXT,
      alternative   TEXT,
      konfidenz     TEXT,
      accepted      INTEGER,
      chosen        TEXT,
      note          TEXT
    )")
  dbDisconnect(con)
  invisible(path)
}

log_feedback <- function(res, accepted, chosen = NA_character_,
                         note = NA_character_, path = FEEDBACK_DB) {
  init_feedback_db(path)
  con <- dbConnect(SQLite(), path)
  on.exit(dbDisconnect(con))
  dbExecute(con,
    "INSERT INTO feedback (ts, mode, model, title, suggested, suggested_ben,
                           alternative, konfidenz, accepted, chosen, note)
     VALUES (?,?,?,?,?,?,?,?,?,?,?)",
    params = list(
      format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
      res$mode %||% NA_character_,
      res$model %||% NA_character_,
      res$title %||% NA_character_,
      res$notation %||% NA_character_,
      res$benennung %||% NA_character_,
      res$alt_notation %||% NA_character_,
      res$konfidenz %||% NA_character_,
      as.integer(isTRUE(accepted)),
      chosen, note))
  invisible(TRUE)
}

read_feedback <- function(path = FEEDBACK_DB) {
  if (!file.exists(path)) return(tibble())
  con <- dbConnect(SQLite(), path); on.exit(dbDisconnect(con))
  dbGetQuery(con, "SELECT * FROM feedback ORDER BY id DESC") |> as_tibble()
}
