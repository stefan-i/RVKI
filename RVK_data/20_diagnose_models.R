# =============================================================================
# 20_diagnose_models.R
# Probe every configured judge model with a minimal request and print the raw
# response, so failures can be diagnosed from evidence instead of guesswork.
#
# For each model it reports:
#   - whether the API key is present
#   - the HTTP status and, on failure, the FULL error body (this is where
#     "model not found" and "parameter not supported" actually live)
#   - token usage, including reasoning tokens if the provider reports them
#   - the raw content, and whether it parses as JSON
#
# Costs a few cents. Run after adding a model or when one starts failing.
# =============================================================================

library(here)
library(httr2)
library(jsonlite)
library(stringr)

source(here("RVK_data", "lib_judge.R"))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# A deliberately tiny task with the same shape as the real one.
TEST_SYSTEM <- "Du bist ein Bibliothekar. Antworte AUSSCHLIESSLICH mit gültigem JSON im Format {\"notation\": \"...\", \"begruendung\": \"...\"} ohne Code-Block."
TEST_USER <- "BUCH:\nVerschwörungstheorien - eine Einführung\n\nKANDIDATEN:\n[1] MD 6250 — Intrige, Verschwörung, Verschwörungstheorie\n[2] MS 3600 — Emigranten, Immigranten\n\nWähle die beste Notation aus dieser Liste."


probe_model <- function(key, max_tokens = 4000L, json_mode = NULL) {
  spec <- JUDGE_MODELS[[key]]
  prov <- JUDGE_PROVIDERS[[spec$provider]]

  cat(sprintf("\n=========================================================\n"))
  cat(sprintf("%s\n  provider : %s\n  model id : %s\n  endpoint : %s\n",
              key, spec$provider, spec$model, prov$url))

  api_key <- Sys.getenv(prov$key_env)
  if (!nzchar(api_key)) {
    cat(sprintf("  KEY      : FEHLT (%s)\n", prov$key_env)); return(invisible())
  }
  cat(sprintf("  key      : vorhanden (%s, %d Zeichen)\n",
              prov$key_env, nchar(api_key)))

  jm_use <- if (is.null(json_mode)) isTRUE(spec$json_mode) else json_mode

  if (identical(prov$dialect, "anthropic")) {
    body <- list(model = spec$model, max_tokens = max_tokens,
                 system = TEST_SYSTEM,
                 messages = list(list(role = "user", content = TEST_USER)))
    req <- request(prov$url) |>
      req_headers("x-api-key" = api_key, "anthropic-version" = "2023-06-01",
                  "Content-Type" = "application/json")
  } else {
    body <- list(model = spec$model,
                 messages = list(list(role = "system", content = TEST_SYSTEM),
                                 list(role = "user",   content = TEST_USER)))
    body[[spec$token_param]] <- max_tokens
    if (!is.null(spec$temperature)) body$temperature <- spec$temperature
    if (jm_use) body$response_format <- list(type = "json_object")
    req <- request(prov$url) |>
      req_auth_bearer_token(api_key) |>
      req_headers("Content-Type" = "application/json")
  }

  cat(sprintf("  sende    : token_param=%s(%d) temperature=%s json_mode=%s\n",
              spec$token_param %||% "max_tokens", max_tokens,
              spec$temperature %||% "(nicht gesendet)", jm_use))

  # is_error = FALSE keeps the response object on 4xx so the body is readable.
  resp <- tryCatch(
    req |> req_body_json(body) |> req_timeout(180) |>
      req_error(is_error = function(r) FALSE) |> req_perform(),
    error = function(e) e)

  if (inherits(resp, "error")) {
    cat(sprintf("  ERGEBNIS : Verbindungsfehler — %s\n", conditionMessage(resp)))
    return(invisible())
  }

  st <- resp_status(resp)
  cat(sprintf("  HTTP     : %d\n", st))

  raw_txt <- tryCatch(resp_body_string(resp), error = function(e) "")
  if (st >= 400) {
    cat("  FEHLERTEXT:\n")
    cat(paste0("    ", str_trunc(raw_txt, 1500)), "\n")
    return(invisible())
  }

  parsed_env <- tryCatch(fromJSON(raw_txt, simplifyVector = FALSE),
                         error = function(e) NULL)
  if (is.null(parsed_env)) {
    cat("  Antwort war kein JSON-Envelope:\n")
    cat(paste0("    ", str_trunc(raw_txt, 800)), "\n"); return(invisible())
  }

  # usage, including reasoning tokens where reported
  u <- parsed_env$usage
  if (!is.null(u)) {
    det <- u$completion_tokens_details %||% list()
    cat(sprintf("  tokens   : prompt=%s completion=%s reasoning=%s\n",
                u$prompt_tokens %||% "?", u$completion_tokens %||% "?",
                det$reasoning_tokens %||% "-"))
  }

  content <- if (identical(prov$dialect, "anthropic")) {
    paste(vapply(parsed_env$content,
                 function(x) if (identical(x$type, "text")) x$text else "",
                 character(1)), collapse = "")
  } else {
    ch <- parsed_env$choices[[1]]
    cat(sprintf("  finish   : %s\n", ch$finish_reason %||% "?"))
    c1 <- ch$message$content
    if (is.null(c1) || !nzchar(c1)) {
      alt <- ch$message$reasoning_content %||% ch$message$reasoning %||% ""
      if (nzchar(alt)) cat("  Hinweis  : content leer, reasoning-Feld belegt\n")
      alt
    } else c1
  }

  cat(sprintf("  Länge    : %d Zeichen\n", nchar(content %||% "")))
  cat("  ROHTEXT  :\n")
  cat(paste0("    ", str_trunc(content %||% "(leer)", 900)), "\n")

  p <- parse_judge_json(content)
  if (is.null(p) || is.null(p$notation))
    cat("  PARSE    : FEHLGESCHLAGEN — kein verwertbares JSON\n")
  else
    cat(sprintf("  PARSE    : ok — notation = %s\n", p$notation))

  invisible()
}


# --- Run ---------------------------------------------------------------------

cat("Verfügbare Modelle laut Registry:\n")
print(available_judge_models(verified_only = FALSE))

for (k in names(JUDGE_MODELS)) probe_model(k)


# --- Follow-up experiments for the failures ----------------------------------
# If a model returned no content, it may have spent the whole budget on
# reasoning. If it returned prose, response_format may be unsupported.

cat("\n\n#########################################################\n")
cat("Nachtest: ohne json_mode, mehr Token\n")
cat("#########################################################\n")

for (k in c("uni_qwen", "uni_oss120")) {
  if (!is.null(JUDGE_MODELS[[k]])) probe_model(k, max_tokens = 8000L, json_mode = FALSE)
}
