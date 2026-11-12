# =============================================================================
# lib_enrichment.R  (v2)
# Step 1: turn a book title into RVK-style categorical German.
#
# v2 changes:
#   - default model gpt-5.6-luna
#   - GPT-5 family compatibility: NO temperature (only default 1 is accepted),
#     and max_completion_tokens instead of max_tokens
#   - disk cache keyed on (model, title): identical input returns the identical
#     enrichment. Since temperature cannot be pinned to 0, the cache is the only
#     way to make evaluations reproducible and to stop paying twice for the
#     same title.
# =============================================================================

library(httr2)
library(jsonlite)
library(stringr)
library(digest)

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

ENRICH_MODEL_DEFAULT <- "gpt-5.6-luna"
ENRICH_CACHE_DIR     <- here::here("RVK_data", "cache_enrichment")


ENRICH_SYSTEM_PROMPT <- "Du bist ein erfahrener wissenschaftlicher Bibliothekar und Experte für die deutsche RVK-Klassifikation (Regensburger Verbundklassifikation). Du erhältst Buchtitel (mit oder ohne Untertitel, in beliebiger Sprache) und bereitest sie für die Klassifikation auf.

Antworte AUSSCHLIESSLICH mit gültigem JSON in genau diesem Format:
{\"fach\": \"...\", \"hauptthema\": \"...\", \"schlagwoerter\": [\"...\", \"...\"]}

Wichtig:
- Antworte IMMER auf Deutsch, auch wenn der Titel in einer anderen Sprache ist.
- Verwende formales, akademisches Bibliotheksvokabular (NICHT die Marketingsprache des Titels).
- Bei Komposita die in der RVK übliche Form (z.B. 'Verschwörungstheorie' statt 'Verschwörungsmythen').
- 6–10 Schlagwörter. Nenne dabei BEIDE Ebenen: das enge Spezialthema UND den übergeordneten Fachbegriff, unter dem eine Bibliothek das Buch einordnen würde.
- Nenne relevante Synonyme und die in der RVK gebräuchlichen Oberbegriffe mit (z.B. bei Migration auch 'Einwanderung', 'Auswanderung', 'Migrationssoziologie').
- Wenn das Buch einen Länder- oder Regionsbezug hat, Land/Region als Schlagwort ergänzen.

Beispiele:

Titel: 'Conspiracy theories a primer'
{\"fach\": \"Politikwissenschaft\", \"hauptthema\": \"Verschwörungstheorien als politisches Phänomen\", \"schlagwoerter\": [\"Verschwörungstheorie\", \"Verschwörung\", \"Politische Psychologie\", \"Politisches Verhalten\", \"Radikalisierung\", \"Politische Ideologie\"]}

Titel: 'Migration in Deutschland - soziologisch erklärt'
{\"fach\": \"Soziologie\", \"hauptthema\": \"Migration und Integration in Deutschland\", \"schlagwoerter\": [\"Migration\", \"Einwanderung\", \"Auswanderung\", \"Einwanderer\", \"Migrationssoziologie\", \"Integration\", \"Minderheit\", \"Deutschland\"]}

Titel: 'Transkription ein Leitfaden mit Aufgaben für Studenten, Forscher und Laien'
{\"fach\": \"Sozialwissenschaftliche Methoden\", \"hauptthema\": \"Transkription in der qualitativen Forschung\", \"schlagwoerter\": [\"Transkription\", \"Qualitative Forschung\", \"Forschungsmethode\", \"Sozialwissenschaftliche Methodologie\", \"Empirische Sozialforschung\", \"Datenerhebung\"]}

Titel: 'Putin Russia'
{\"fach\": \"Politikwissenschaft\", \"hauptthema\": \"Politisches System Russlands unter Putin\", \"schlagwoerter\": [\"Russland\", \"Politisches System\", \"Wladimir Putin\", \"Russische Föderation\", \"Politische Systeme einzelner Länder\", \"Osteuropa\"]}"

SYSTEM_PROMPT <- ENRICH_SYSTEM_PROMPT   # backwards compatibility


# --- Cache -------------------------------------------------------------------

enrich_cache_path <- function(title, model) {
  dir.create(ENRICH_CACHE_DIR, showWarnings = FALSE, recursive = TRUE)
  key <- digest::digest(paste(model, str_squish(title), sep = "||"), algo = "sha1")
  file.path(ENRICH_CACHE_DIR, paste0(key, ".rds"))
}

enrich_cache_clear <- function() {
  f <- list.files(ENRICH_CACHE_DIR, pattern = "\\.rds$", full.names = TRUE)
  unlink(f)
  cat(sprintf("Cleared %d cached enrichments.\n", length(f)))
}


# --- Main --------------------------------------------------------------------

expand_title <- function(title,
                         api_key   = Sys.getenv("OPENAI_API_KEY"),
                         model     = ENRICH_MODEL_DEFAULT,
                         use_cache = TRUE,
                         reasoning_effort = NULL) {

  cp <- enrich_cache_path(title, model)
  if (use_cache && file.exists(cp)) return(readRDS(cp))

  body <- list(
    model = model,
    messages = list(
      list(role = "system", content = ENRICH_SYSTEM_PROMPT),
      list(role = "user",   content = paste0("Titel: ", title))
    ),
    response_format = list(type = "json_object"),
    # GPT-5 family: max_completion_tokens, and NO temperature (only default 1).
    max_completion_tokens = 700
  )
  if (!is.null(reasoning_effort)) body$reasoning_effort <- reasoning_effort

  req <- request("https://api.openai.com/v1/chat/completions") |>
    req_auth_bearer_token(api_key) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(body) |>
    req_retry(max_tries = 3, backoff = ~ min(30, 2 ^ .x),
              is_transient = function(r) {
                s <- resp_status(r); s == 429 || s >= 500
              }) |>
    req_timeout(90)

  resp    <- resp_body_json(req_perform(req))
  content <- resp$choices[[1]]$message$content

  clean <- content |> str_replace_all("```json|```", "") |> str_trim()
  m <- str_match(clean, "(?s)\\{.*\\}")[, 1]
  if (!is.na(m)) clean <- m

  parsed <- tryCatch(jsonlite::fromJSON(clean, simplifyVector = TRUE),
                     error = function(e) NULL)

  out <- list(
    fach          = as.character(parsed$fach %||% NA),
    hauptthema    = as.character(parsed$hauptthema %||% NA),
    schlagwoerter = as.character(unlist(parsed$schlagwoerter %||% character(0))),
    model         = model
  )

  if (use_cache && !is.na(out$fach)) saveRDS(out, cp)
  out
}


build_enriched_query <- function(orig_title, exp) {
  parts <- c(
    paste0("Buchtitel: ", orig_title, "."),
    if (!is.na(exp$fach))       paste0("Fach: ", exp$fach, "."),
    if (!is.na(exp$hauptthema)) paste0("Hauptthema: ", exp$hauptthema, "."),
    if (length(exp$schlagwoerter) > 0)
      paste0("Schlagwörter: ", paste(exp$schlagwoerter, collapse = "; "), ".")
  )
  paste(parts, collapse = " ")
}
