# =============================================================================
# lib_judge.R  (v3.3)
# Step 3: pick the best notation from the retrieved candidates.
#
# v3.3:
#   - `extra_body`: arbitrary provider-specific parameters merged into the
#     request, so reasoning can be turned down without special-casing each
#     provider in the calling code.
#   - reasoning controls configured per model (see registry comments).
#   - google/gemma-4-31b-it added as a candidate.
#   - judge_candidates() now returns elapsed seconds and token counts, so the
#     evaluation can compare cost and latency, not just accuracy.
# =============================================================================

library(httr2)
library(jsonlite)
library(dplyr)
library(stringr)
library(tibble)

source(here::here("RVK_data", "lib_confidence.R"))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a


# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

JUDGE_PROVIDERS <- list(
  openai = list(
    url     = "https://api.openai.com/v1/chat/completions",
    key_env = "OPENAI_API_KEY", dialect = "openai"),
  openrouter = list(
    url     = "https://openrouter.ai/api/v1/chat/completions",
    key_env = "OPENROUTER_API_KEY", dialect = "openai"),
  gpustack = list(
    url     = Sys.getenv("GPUSTACK_BASE_URL",
                         "https://gpustack.unibe.ch/v1-openai/chat/completions"),
    key_env = "GPUSTACK_API_KEY", dialect = "openai"),
  anthropic = list(
    url     = "https://api.anthropic.com/v1/messages",
    key_env = "ANTHROPIC_API_KEY", dialect = "anthropic")
)


# -----------------------------------------------------------------------------
# Model registry
# -----------------------------------------------------------------------------
# extra_body: provider-specific parameters, merged verbatim into the request.
#   OpenRouter          reasoning = list(enabled = FALSE) or list(effort = "low")
#   Qwen3 on vLLM       chat_template_kwargs = list(enable_thinking = FALSE)
#   gpt-oss on vLLM     reasoning_effort = "low"
# If a provider rejects a parameter it returns HTTP 400 with a message naming
# it, which 20_diagnose_models.R will show.

jm <- function(provider, model, label, verified = FALSE,
               token_param = "max_tokens", temperature = 0, json_mode = TRUE,
               max_tokens = 4000L, extra_body = NULL) {
  list(provider = provider, model = model, label = label, verified = verified,
       token_param = token_param, temperature = temperature,
       json_mode = json_mode, max_tokens = max_tokens, extra_body = extra_body)
}

JUDGE_MODELS <- list(
  # --- verified on the 51-title test set ------------------------------------
  luna  = jm("openai", "gpt-5.6-luna",  "GPT-5.6 Luna (Standard)", TRUE,
             token_param = "max_completion_tokens", temperature = NULL),
  terra = jm("openai", "gpt-5.6-terra", "GPT-5.6 Terra", TRUE,
             token_param = "max_completion_tokens", temperature = NULL),
  or_gemma = jm("openrouter", "google/gemma-4-31b-it",
                "OpenRouter: Gemma 4 31B", TRUE),
  or_minimax = jm("openrouter", "minimax/minimax-m3",
                  "OpenRouter: MiniMax M3", TRUE, max_tokens = 6000L,
                  extra_body = list(reasoning = list(enabled = FALSE))),
  # nur im Uni-Netz erreichbar (FortiClient VPN)
  uni_qwen = jm("gpustack", "qwen3.8-27b", "GPUStack: Qwen3.8 27B", TRUE,
                max_tokens = 8000L,
                extra_body = list(
                  chat_template_kwargs = list(enable_thinking = FALSE)))
  
  # --- ausgeschieden (Test vom <Datum>, 51 Titel) ---------------------------
  # google/gemini-3.5-flash-lite : 57% top-1, 2 JSON-Fehler
  # ~deepseek/deepseek-v4-flash- : 64% top-1, 30 s Median (60 s max)
  # gpt-oss-120b                 : 55% top-1 (schnell, aber deutlich schwächer)
)

available_judge_models <- function(verified_only = FALSE) {
  keep <- vapply(JUDGE_MODELS, function(m) {
    p <- JUDGE_PROVIDERS[[m$provider]]
    nzchar(Sys.getenv(p$key_env)) && (!verified_only || isTRUE(m$verified))
  }, logical(1))
  ids  <- names(JUDGE_MODELS)[keep]
  labs <- vapply(JUDGE_MODELS[ids], function(m)
    if (isTRUE(m$verified)) m$label else paste0(m$label, " — ungetestet"),
    character(1))
  ord <- order(!vapply(JUDGE_MODELS[ids],
                       function(m) isTRUE(m$verified), logical(1)))
  setNames(ids[ord], labs[ord])
}


list_openrouter_models <- function(pattern = "",
                                   api_key = Sys.getenv("OPENROUTER_API_KEY")) {
  req <- request("https://openrouter.ai/api/v1/models") |>
    req_timeout(60) |> req_error(is_error = function(r) FALSE)
  if (nzchar(api_key)) req <- req_auth_bearer_token(req, api_key)
  resp <- req_perform(req)
  if (resp_status(resp) >= 400) {
    message("HTTP ", resp_status(resp), ": ",
            substr(resp_body_string(resp), 1, 300))
    return(invisible(NULL))
  }
  dat <- resp_body_json(resp)$data
  if (is.null(dat) || !length(dat)) {
    message("Keine Modelldaten erhalten."); return(invisible(NULL))
  }
  get1 <- function(x, ...) {
    v <- x
    for (k in c(...)) { v <- if (is.list(v)) v[[k]] else NULL; if (is.null(v)) break }
    if (is.null(v) || length(v) != 1) NA_character_ else as.character(v)
  }
  out <- do.call(rbind, lapply(dat, function(x) data.frame(
    id = get1(x, "id"), name = get1(x, "name"),
    ctx = get1(x, "context_length"),
    prompt = get1(x, "pricing", "prompt"),
    output = get1(x, "pricing", "completion"),
    stringsAsFactors = FALSE)))
  out <- out[!is.na(out$id), ]
  if (nzchar(pattern)) out <- out[grepl(pattern, out$id, ignore.case = TRUE), ]
  out[order(out$id), ]
}


# -----------------------------------------------------------------------------
# System prompt
# -----------------------------------------------------------------------------

build_judge_system_prompt <- function(mode = "vanilla",
                                      branch_labels = character(0),
                                      has_local_rules = FALSE) {

  base <- "Du bist ein erfahrener wissenschaftlicher Bibliothekar und Experte für die RVK (Regensburger Verbundklassifikation). Du erhältst einen Buchtitel und eine Liste von Kandidaten-Notationen. Wähle die am besten passende Notation aus.

GRUNDREGELN:
- Wähle AUSSCHLIESSLICH aus der vorgelegten Kandidatenliste. Erfinde niemals eine Notation, die nicht in der Liste steht.
- Wähle die spezifischste passende Notation, nicht eine allgemeine Oberklasse, wenn eine passende Unterklasse vorhanden ist.
- Achte auf den PFAD: er zeigt den hierarchischen Kontext. Eine Benennung wie 'Allgemeines' oder 'Allgemeines und Deutschland' bedeutet in der RVK 'allgemeine Literatur zu diesem Thema' und ist NICHT auf Deutschland beschränkt.
- Achte auf BEMERKUNG-Felder: sie enthalten oft Einschränkungen oder Ausschlüsse ('aber nicht ...').
- BESTAND-Hinweise zeigen ähnliche Bücher, die in dieser Bibliothek bereits unter der jeweiligen Notation stehen. Das ist das stärkste Signal für die tatsächliche Klassifikationspraxis dieser Bibliothek.
- PARALLELSTELLEN: Hat eine Notation Parallelstellen für andere Länder oder Regionen und das Buch einen klaren Länderbezug, wähle die passende Länder-Variante aus der Liste.

Antworte AUSSCHLIESSLICH mit einem einzigen gültigen JSON-Objekt, ohne einleitenden Text und ohne Code-Block. Es muss genau diese sechs Schlüssel enthalten:
notation, benennung, begruendung, alternative_notation, alternative_benennung, alternative_begruendung

Beispiel für die Form der Antwort:
{\"notation\": \"MD 6250\", \"benennung\": \"Intrige, Verschwörung, Verschwörungstheorie\", \"begruendung\": \"Das Buch behandelt ...\", \"alternative_notation\": \"MD 6000\", \"alternative_benennung\": \"Allgemeines\", \"alternative_begruendung\": \"Falls das Buch eher ...\"}

- begruendung: 2-3 Sätze auf Deutsch, mit Bezug auf Benennung, Pfad, Register, lokale Regeln oder Bestand.
- alternative: eine zweite plausible Notation aus der Liste, 1-2 Sätze Begründung."

  if (has_local_rules)
    base <- paste0(base, "

LOKALE REGELN:
Einige Kandidaten tragen LOKALE REGELN dieser Bibliothek. Diese haben Vorrang vor der allgemeinen RVK-Praxis. Notationen, die lokal nicht belegt werden, sind bereits aus der Liste entfernt.")

  if (length(branch_labels) > 0)
    base <- paste0(base, sprintf("

SAMMELSCHWERPUNKTE DIESER BIBLIOTHEK:
%s

Die RVK erlaubt für viele Themen mehrere sachlich vertretbare Notationen, weil sie von Bibliotheken mit sehr unterschiedlichem Spezialisierungsgrad genutzt wird. Diese Bibliothek ist auf die oben genannten Fächer spezialisiert.
REGEL: Wenn mehrere Kandidaten inhaltlich etwa gleich gut passen, wähle die Notation aus einem der oben genannten Schwerpunktbereiche. Passt das Buch thematisch eindeutig ausserhalb dieser Bereiche, wähle trotzdem die inhaltlich richtige Notation — die Schwerpunkte sind ein Entscheidungskriterium bei Gleichstand, kein Zwang.",
      paste0("- ", branch_labels, collapse = "\n")))

  base
}


# -----------------------------------------------------------------------------
# Candidate rendering
# -----------------------------------------------------------------------------

format_candidates <- function(cand, max_candidates = 50L) {
  cand <- head(cand, max_candidates)
  lines <- character(nrow(cand))
  has <- function(r, col) {
    col %in% names(r) && !is.na(r[[col]]) &&
      (!is.character(r[[col]]) || nzchar(r[[col]]))
  }
  for (i in seq_len(nrow(cand))) {
    r <- cand[i, ]
    parts <- sprintf("[%d] %s — %s", r$rank, r$notation, r$benennung)
    if (has(r, "pfad"))
      parts <- c(parts, sprintf("    Pfad: %s", r$pfad))
    if (has(r, "register"))
      parts <- c(parts, sprintf("    Register: %s", str_trunc(r$register, 250)))
    if (has(r, "bemerkung"))
      parts <- c(parts, sprintf("    Bemerkung: %s", str_trunc(r$bemerkung, 250)))
    if (has(r, "local_stichwoerter"))
      parts <- c(parts, sprintf("    LOKALE Stichwörter: %s",
                                str_trunc(r$local_stichwoerter, 200)))
    if (has(r, "local_erklaerung"))
      parts <- c(parts, sprintf("    LOKALE Regel: %s",
                                str_trunc(r$local_erklaerung, 300)))
    if (has(r, "hold_n") && r$hold_n > 0)
      parts <- c(parts, sprintf("    BESTAND: %d ähnliche Titel. Beispiele: %s",
                                r$hold_n, str_trunc(r$hold_examples %||% "", 280)))
    if (has(r, "n_parallel") && r$n_parallel > 0)
      parts <- c(parts, sprintf("    Parallelstellen (gleiche Benennung): %s",
                                str_trunc(r$parallel_notations %||% "", 200)))
    if ("in_core" %in% names(r) && isTRUE(r$in_core))
      parts <- c(parts, "    (Schwerpunktbereich dieser Bibliothek)")
    lines[i] <- paste(parts, collapse = "\n")
  }
  paste(lines, collapse = "\n\n")
}


# -----------------------------------------------------------------------------
# API calls
# -----------------------------------------------------------------------------

call_openai_compatible <- function(system_prompt, user_prompt, spec, provider) {
  api_key <- Sys.getenv(provider$key_env)
  if (!nzchar(api_key))
    stop(sprintf("Kein API-Key gefunden (%s).", provider$key_env))

  body <- list(
    model = spec$model,
    messages = list(
      list(role = "system", content = system_prompt),
      list(role = "user",   content = user_prompt)))
  body[[spec$token_param]] <- spec$max_tokens %||% 4000L
  if (!is.null(spec$temperature)) body$temperature     <- spec$temperature
  if (isTRUE(spec$json_mode))     body$response_format <- list(type = "json_object")
  # provider-specific parameters (reasoning switches etc.)
  if (!is.null(spec$extra_body))
    body <- utils::modifyList(body, spec$extra_body)

  resp <- request(provider$url) |>
    req_auth_bearer_token(api_key) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(body) |>
    req_retry(max_tries = 3, backoff = ~ min(30, 2 ^ .x),
              is_transient = function(r) {
                s <- resp_status(r); s == 429 || s >= 500
              }) |>
    req_error(is_error = function(r) FALSE) |>
    req_timeout(180) |>
    req_perform()

  st <- resp_status(resp)
  if (st >= 400) {
    detail <- tryCatch({
      j <- resp_body_json(resp)
      j$error$message %||% j$message %||% substr(resp_body_string(resp), 1, 300)
    }, error = function(e) substr(
      tryCatch(resp_body_string(resp), error = function(e2) ""), 1, 300))
    stop(sprintf("HTTP %d — %s", st, detail))
  }

  out <- resp_body_json(resp)
  if (!is.null(out$error)) stop(out$error$message %||% "Unbekannter API-Fehler")
  if (is.null(out$choices) || !length(out$choices))
    stop("Die Antwort enthielt kein Ergebnis.")

  ch  <- out$choices[[1]]
  txt <- ch$message$content
  if (is.null(txt) || !nzchar(txt))
    txt <- ch$message$reasoning_content %||% ch$message$reasoning %||% ""

  if (!nzchar(txt) && identical(ch$finish_reason, "length"))
    stop(paste("Das Token-Budget war erschöpft, bevor eine Antwort begann.",
               "max_tokens erhöhen oder Reasoning reduzieren."))

  list(text = txt, usage = out$usage, finish = ch$finish_reason %||% NA_character_)
}

call_anthropic <- function(system_prompt, user_prompt, spec, provider) {
  api_key <- Sys.getenv(provider$key_env)
  if (!nzchar(api_key))
    stop(sprintf("Kein API-Key gefunden (%s).", provider$key_env))
  resp <- request(provider$url) |>
    req_headers("x-api-key" = api_key, "anthropic-version" = "2023-06-01",
                "Content-Type" = "application/json") |>
    req_body_json(list(model = spec$model,
                       max_tokens = spec$max_tokens %||% 4000L,
                       system = system_prompt,
                       messages = list(list(role = "user", content = user_prompt)))) |>
    req_retry(max_tries = 3, backoff = ~ min(30, 2 ^ .x),
              is_transient = function(r) {
                s <- resp_status(r); s == 429 || s >= 500
              }) |>
    req_error(is_error = function(r) FALSE) |>
    req_timeout(180) |> req_perform()

  if (resp_status(resp) >= 400) {
    detail <- tryCatch(resp_body_json(resp)$error$message,
                       error = function(e) "unbekannt")
    stop(sprintf("HTTP %d — %s", resp_status(resp), detail))
  }
  body <- resp_body_json(resp)
  txt <- paste(vapply(body$content,
                      function(x) if (identical(x$type, "text")) x$text else "",
                      character(1)), collapse = "")
  list(text = txt, usage = body$usage, finish = body$stop_reason %||% NA_character_)
}


parse_judge_json <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NULL)
  clean <- txt |> str_replace_all("```json|```", "") |> str_trim()
  m <- str_match(clean, "(?s)\\{.*\\}")[, 1]
  if (!is.na(m)) clean <- m
  clean <- str_replace_all(clean, '"\\{([a-z_]+)\\}"\\s*:', '"\\1":')
  tryCatch(fromJSON(clean, simplifyVector = TRUE), error = function(e) NULL)
}


# -----------------------------------------------------------------------------
# Main entry point
# -----------------------------------------------------------------------------

judge_candidates <- function(title, candidates,
                             mode           = "vanilla",
                             model_key      = "luna",
                             max_candidates = 50L,
                             abstract       = NULL) {

  t0 <- Sys.time()
  if (nrow(candidates) == 0) return(list(ok = FALSE, error = "keine Kandidaten"))

  spec <- JUDGE_MODELS[[model_key]]
  if (is.null(spec)) stop("Unbekanntes Modell: ", model_key)
  provider <- JUDGE_PROVIDERS[[spec$provider]]
  if (is.null(provider)) stop("Unbekannter Anbieter: ", spec$provider)

  prof <- attr(candidates, "profile")
  if (is.null(prof)) prof <- get_profile(mode)

  sys_prompt <- build_judge_system_prompt(
    mode            = mode,
    branch_labels   = prof$branch_labels %||% character(0),
    has_local_rules = !is.null(prof$rule_set))

  user_prompt <- paste0(
    "BUCH:\n", title,
    if (!is.null(abstract) && nzchar(abstract))
      paste0("\n\nKLAPPENTEXT:\n", abstract) else "",
    "\n\nKANDIDATEN:\n\n", format_candidates(candidates, max_candidates),
    "\n\nWähle die beste Notation aus dieser Liste.")

  resp <- tryCatch(
    if (identical(provider$dialect, "anthropic"))
      call_anthropic(sys_prompt, user_prompt, spec, provider)
    else
      call_openai_compatible(sys_prompt, user_prompt, spec, provider),
    error = function(e) list(text = NULL, error = conditionMessage(e)))

  secs <- as.numeric(Sys.time() - t0, units = "secs")
  u    <- resp$usage %||% list()
  det  <- u$completion_tokens_details %||% list()
  usage_flat <- list(
    prompt_tokens     = u$prompt_tokens %||% u$input_tokens %||% NA,
    completion_tokens = u$completion_tokens %||% u$output_tokens %||% NA,
    reasoning_tokens  = det$reasoning_tokens %||% NA)

  if (is.null(resp$text) || !nzchar(resp$text))
    return(list(ok = FALSE, seconds = secs, usage = usage_flat,
                error = paste0("Modell ", spec$model, ": ",
                               resp$error %||% "leere Antwort")))

  parsed <- parse_judge_json(resp$text)
  if (is.null(parsed) || is.null(parsed$notation))
    return(list(ok = FALSE, seconds = secs, usage = usage_flat,
                error = paste0("Modell ", spec$model,
                               " lieferte kein verwertbares JSON."),
                raw = str_trunc(resp$text, 500)))

  picked   <- as.character(parsed$notation)[1]
  alt_pick <- as.character(parsed$alternative_notation %||% "")[1]
  if (is.na(alt_pick)) alt_pick <- ""
  valid <- picked %in% candidates$notation
  conf  <- compute_confidence(candidates, picked)

  disclaimer <- NULL
  if (isTRUE(prof$law_disclaimer) &&
      (str_starts(picked, "P") ||
       (nzchar(alt_pick) && str_starts(alt_pick, "P")))) {
    disclaimer <- paste0(
      "Hinweis: Für Rechtswissenschaft (P) verwendet diese Bibliothek die ",
      "regionale St. Galler Anpassung der RVK, nicht die Standard-RVK. ",
      "Die vorgeschlagene Notation muss manuell mit der Sondersystematik ",
      "abgeglichen werden.")
  }

  list(
    ok = TRUE,
    notation                = picked,
    benennung               = as.character(parsed$benennung %||% NA)[1],
    begruendung             = as.character(parsed$begruendung %||% NA)[1],
    alternative_notation    = if (nzchar(alt_pick)) alt_pick else NA_character_,
    alternative_benennung   = as.character(parsed$alternative_benennung %||% NA)[1],
    alternative_begruendung = as.character(parsed$alternative_begruendung %||% NA)[1],
    konfidenz               = conf$level,
    konfidenz_score         = conf$score,
    konfidenz_gruende       = conf$reasons,
    notation_in_candidates  = valid,
    disclaimer              = disclaimer,
    model                   = spec$model,
    model_key               = model_key,
    seconds                 = secs,
    usage                   = usage_flat,
    finish                  = resp$finish %||% NA_character_)
}
