# =============================================================================
# app.R  (v3)
# RVK-Klassifikationsassistent
#
# v4: Stapel-Limit 50; CSV mit RVK-Pfad für Vorschlag und Alternative;
#     ähnliche Titel als Tabelle (12 statt 8), Vorschlag gelb markiert,
#     Alternative hellblau.
#
# v3: Feedback-Bestätigung wird pro Ergebnis zurückgesetzt (neues Ergebnis,
#     "Leeren", neuer Stapel) und trägt eine Uhrzeit, damit auch wiederholtes
#     Speichern sichtbar bestätigt wird. Eingabefeld wird nach dem Melden
#     einer Abweichung geleert.
#
# Enthält ausserdem die früheren Änderungen: Systemschrift statt Google Fonts,
# Modellauswahl aus available_judge_models().
# =============================================================================

library(shiny)
library(bslib)
library(dplyr)
library(stringr)
library(tibble)
library(DT)

source(here::here("RVK_data", "lib_pipeline.R"))


# -----------------------------------------------------------------------------
# Startup
# -----------------------------------------------------------------------------

STARTUP_ERROR <- NULL
STATE <- NULL

local({
  if (!nzchar(Sys.getenv("OPENAI_API_KEY"))) {
    STARTUP_ERROR <<- paste("OPENAI_API_KEY ist nicht gesetzt.",
                            "Bitte in .Renviron eintragen und R neu starten.")
    return(invisible())
  }
  msg <- tryCatch({
    cat("Lade Indizes ...\n"); t0 <- Sys.time()
    STATE <<- load_retrieval_state()
    cat(sprintf("Bereit nach %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))
    NULL
  }, error = function(e) paste0("Die Indizes konnten nicht geladen werden: ",
                                conditionMessage(e)))
  if (!is.null(msg)) STARTUP_ERROR <<- msg
})

init_feedback_db()

APP_PASSWORD  <- Sys.getenv("RVK_APP_PASSWORD")
MODEL_CHOICES <- available_judge_models()


# -----------------------------------------------------------------------------
# Theme (Systemschrift: keine Abhängigkeit von Google Fonts beim Start)
# -----------------------------------------------------------------------------

app_theme <- bs_theme(
  version = 5,
  primary = "#1F5673",
  "font-size-root" = "17px"
)

app_css <- HTML("
  .notation-big  { font-size: 2.1rem; font-weight: 700; letter-spacing:.5px;
                   color:#1F5673; line-height:1.15; }
  .benennung-big { font-size: 1.25rem; font-weight: 500; margin-bottom:.3rem; }
  .pfad-line     { color:#5a6a72; font-size:.9rem; }
  .evidence-line { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                   font-size:.86rem; white-space:pre; overflow-x:auto; }
  .result-card   { border-left:5px solid #1F5673; }
  .result-card.err { border-left-color:#b3261e; }
  .badge-konf    { font-size:.85rem; vertical-align:middle; }
  .small-muted   { color:#6c757d; font-size:.88rem; }
  .title-echo    { font-size:1.05rem; font-weight:600; }
  .alt-notation  { font-size:1.1rem; font-weight:600; color:#1F5673; }
  .ev-table      { font-size:.9rem; margin-bottom:.25rem; }
  .ev-table td, .ev-table th { padding:.2rem .5rem; vertical-align:top; }
  .ev-table .ev-sim { font-variant-numeric: tabular-nums; white-space:nowrap; }
  .ev-table .ev-not { white-space:nowrap; }
  .ev-table tr.ev-main > td { background-color:#fff1a8 !important; font-weight:700; }
  .ev-table tr.ev-alt  > td { background-color:#e2eef9 !important; }
  .ev-key        { display:inline-block; padding:0 .35rem; border-radius:3px; }
  .ev-key-main   { background:#fff1a8; font-weight:700; }
  .ev-key-alt    { background:#e2eef9; }
  .fb-row { display:flex; align-items:center; gap:.5rem; flex-wrap:wrap; }
  .fb-row .form-group,
  .fb-row .shiny-input-container { margin-bottom:0 !important; }
  .fb-row .form-control { height:calc(1.5em + .5rem + 2px); padding:.25rem .5rem;
                          font-size:.9rem; }
")


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

konf_badge <- function(k) {
  cls <- switch(k, hoch = "text-bg-success", mittel = "text-bg-warning",
                "text-bg-secondary")
  span(class = paste("badge badge-konf", cls), paste0("Konfidenz: ", k))
}

copy_button <- function(txt) {
  tags$button(
    class = "btn btn-sm btn-outline-secondary",
    onclick = sprintf("navigator.clipboard.writeText('%s');
                       this.innerText='kopiert';
                       setTimeout(()=>this.innerText='Notation kopieren',1200);",
                      gsub("'", "\\\\'", txt)),
    "Notation kopieren")
}

# Pfad (übergeordnete Stellen) einer Notation: zuerst aus der Kandidatenliste,
# sonst direkt aus der Datenbank.
notation_pfad <- function(res, notation) {
  if (is.null(notation) || length(notation) == 0 || is.na(notation) ||
      !nzchar(notation)) return(NA_character_)
  if (!is.null(res$candidates)) {
    i <- match(notation, res$candidates$notation)
    if (!is.na(i)) return(res$candidates$pfad[i])
  }
  if (is.null(STATE) || is.null(STATE$con)) return(NA_character_)
  p <- tryCatch(
    DBI::dbGetQuery(STATE$con, "SELECT pfad FROM rvk WHERE notation = ?",
                    params = list(notation))$pfad,
    error = function(e) character(0))
  if (length(p) && !is.na(p[1])) p[1] else NA_character_
}

# Vollständige Verortung für den Export: Pfad > Benennung
full_location <- function(res, notation, benennung) {
  p <- notation_pfad(res, notation)
  b <- if (is.null(benennung) || is.na(benennung)) "" else benennung
  if (is.na(p) || !nzchar(p)) b else if (nzchar(b)) paste(p, b, sep = " > ") else p
}

# Ähnliche Titel als Tabelle; Vorschlag gelb, Alternative hellblau.
evidence_table_ui <- function(ev_tbl, main, alt) {
  if (is.null(ev_tbl) || !nrow(ev_tbl))
    return(div(class = "small-muted", "Keine ähnlichen Titel im Bestand gefunden."))
  alt <- if (is.null(alt) || is.na(alt)) "" else alt
  n_main <- sum(ev_tbl$notation == main)
  n_alt  <- if (nzchar(alt)) sum(ev_tbl$notation == alt) else 0L

  rows <- lapply(seq_len(nrow(ev_tbl)), function(i) {
    n <- ev_tbl$notation[i]
    cls <- if (identical(n, main)) "ev-main"
           else if (nzchar(alt) && identical(n, alt)) "ev-alt" else NULL
    ben <- if ("benennung" %in% names(ev_tbl) && !is.na(ev_tbl$benennung[i]))
             ev_tbl$benennung[i] else NULL
    tags$tr(class = cls,
            tags$td(class = "ev-sim", sprintf("%.2f", ev_tbl$sim[i])),
            tags$td(class = "ev-not", title = ben, n),
            tags$td(ev_tbl$title[i]))
  })

  tagList(
    div(class = "small-muted mb-1",
        paste0(sprintf("%d von %d unter dem Vorschlag", n_main, nrow(ev_tbl)),
               if (nzchar(alt)) sprintf(", %d unter der Alternative", n_alt) else "",
               ".")),
    tags$table(class = "table table-sm ev-table",
      tags$thead(tags$tr(tags$th("Ähnlichkeit"), tags$th("Notation"),
                         tags$th("Titel"))),
      tags$tbody(rows)),
    div(class = "small-muted",
        span(class = "ev-key ev-key-main", "Vorschlag"), " ",
        if (nzchar(alt)) span(class = "ev-key ev-key-alt", "Alternative"),
        " · Ähnlichkeit: 1.00 = praktisch identischer Titel, ab etwa 0.55 inhaltlich verwandt.",
        " Benennung der Notation beim Darüberfahren."))
}


render_result <- function(res, idx = 1L, open = TRUE) {

  if (!isTRUE(res$ok)) {
    return(card(class = "result-card err mb-3", card_body(
      div(class = "title-echo", res$title),
      div(class = "text-danger mt-2", res$error),
      div(class = "small-muted mt-1", paste0("Schritt: ", res$stage %||% "?")))))
  }

  ev <- res$evidence

  body <- list(
    div(class = "title-echo mb-2", res$title),
    div(class = "d-flex align-items-center gap-3 flex-wrap",
        div(class = "notation-big", res$notation),
        konf_badge(res$konfidenz),
        copy_button(res$notation)),
    div(class = "benennung-big", res$benennung)
  )
  p_main <- notation_pfad(res, res$notation)
  if (!is.na(p_main)) body <- c(body, list(div(class = "pfad-line mb-3", p_main)))
  body <- c(body, list(div(tags$strong("Begründung: "), res$begruendung)))

  if (!is.na(res$alt_notation) && nzchar(res$alt_notation)) {
    p_alt <- notation_pfad(res, res$alt_notation)
    body <- c(body, list(
      hr(),
      div(class = "mb-1", tags$span(class = "small-muted", "Alternative")),
      div(tags$span(class = "alt-notation", res$alt_notation), " — ",
          tags$span(res$alt_benennung)),
      if (!is.na(p_alt)) div(class = "pfad-line", p_alt),
      div(class = "small-muted mt-1", res$alt_begruendung)))
  }

  ev_block <- if (!is.null(ev)) {
    tagList(
      evidence_table_ui(ev$evidence_table, res$notation, res$alt_notation),
      if (length(res$konf_gruende))
        div(class = "small-muted mt-2",
            paste0("Konfidenz beruht auf: ",
                   paste(res$konf_gruende, collapse = "; "), ".")),
      if (!is.null(ev$local_rule) && !is.na(ev$local_rule))
        div(class = "small-muted mt-1",
            tags$strong("Lokale Regel: "), ev$local_rule))
  } else NULL

  if (!is.null(ev_block)) {
    body <- c(body, list(hr(),
      if (open) tagList(div(class = "mb-2", tags$strong("Ähnliche Titel im Bestand")),
                        ev_block)
      else accordion(open = FALSE,
                     accordion_panel("Belege und ähnliche Titel", ev_block))))
  }

  if (!is.null(ev) && !is.null(ev$thin_note))
    body <- c(body, list(div(class = "alert alert-warning mt-3 mb-0", ev$thin_note)))
  if (length(res$warnings))
    body <- c(body, list(div(class = "alert alert-danger mt-3 mb-0",
                             paste(res$warnings, collapse = " "))))
  if (!is.null(res$disclaimer))
    body <- c(body, list(div(class = "alert alert-info mt-3 mb-0", res$disclaimer)))

  body <- c(body, list(
    hr(),
    div(class = "fb-row",
        span(class = "small-muted", "Rückmeldung:"),
        actionButton(paste0("fb_ok_", idx), "Übernommen",
                     class = "btn btn-sm btn-outline-success"),
        div(style = "width:170px;",
            textInput(paste0("fb_other_", idx), NULL, width = "100%",
                      placeholder = "andere Notation")),
        actionButton(paste0("fb_send_", idx), "Abweichung melden",
                     class = "btn btn-sm btn-outline-secondary"),
        uiOutput(paste0("fb_msg_", idx), inline = TRUE))))

  card(class = "result-card mb-3", card_body(!!!body))
}


# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------

ui <- page_fluid(
  theme = app_theme,
  tags$head(tags$style(app_css)),
  title = "RVK-Klassifikationsassistent",
  uiOutput("gate"),
  uiOutput("main_ui")
)


# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------

server <- function(input, output, session) {

  authed <- reactiveVal(!nzchar(APP_PASSWORD))

  output$gate <- renderUI({
    if (authed()) return(NULL)
    div(class = "container", style = "max-width:420px; margin-top:12vh;",
        card(card_body(
          h4("RVK-Klassifikationsassistent"),
          p(class = "small-muted", "Bitte Zugangswort eingeben."),
          passwordInput("pw", NULL, width = "100%"),
          actionButton("pw_go", "Anmelden", class = "btn btn-primary w-100"),
          uiOutput("pw_msg"))))
  })

  observeEvent(input$pw_go, {
    if (identical(input$pw, APP_PASSWORD)) authed(TRUE)
    else output$pw_msg <- renderUI(
      div(class = "text-danger mt-2", "Falsches Zugangswort."))
  })

  output$main_ui <- renderUI({
    if (!authed()) return(NULL)
    if (!is.null(STARTUP_ERROR))
      return(div(class = "container mt-5",
                 div(class = "alert alert-danger",
                     h5("Die Anwendung konnte nicht starten"), STARTUP_ERROR)))

    page_sidebar(
      title = "RVK-Klassifikationsassistent",
      sidebar = sidebar(
        width = 330, open = "open",
        radioButtons("mode", "Systematik", choices = MODE_LABELS,
                     selected = "social"),
        hr(),
        accordion(open = FALSE, accordion_panel(
          "Erweiterte Optionen",
          selectInput("model", "Sprachmodell", choices = MODEL_CHOICES,
                      selected = PIPELINE_DEFAULTS$model_key),
          sliderInput("n_final", "Kandidaten", min = 20, max = 80,
                      value = PIPELINE_DEFAULTS$n_final, step = 10),
          sliderInput("boost", "Schwerpunkt-Gewichtung", min = 0, max = 0.4,
                      value = PIPELINE_DEFAULTS$branch_boost, step = 0.05),
          numericInput("batch_limit", "Max. Titel pro Stapel",
                       value = 50, min = 1, max = 500, step = 5),
          div(class = "small-muted",
              "Änderungen wirken ab der nächsten Klassifikation.")))
      ),

      navset_tab(
        id = "tabs",

        nav_panel("Einzeltitel", div(class = "mt-3",
          textAreaInput("single_title", "Titel und Untertitel",
                        width = "100%", height = "80px",
                        placeholder = "z. B. Verschwörungsmythen – woher sie kommen, was sie anrichten"),
          accordion(open = FALSE, accordion_panel(
            "Klappentext ergänzen (optional)",
            textAreaInput("single_abstract", NULL, width = "100%", height = "120px",
                          placeholder = "Nur nötig, wenn der Titel zu unspezifisch ist."))),
          div(class = "d-flex gap-2 mt-2",
              actionButton("go_single", "Klassifizieren", class = "btn btn-primary"),
              actionButton("clear_single", "Leeren", class = "btn btn-outline-secondary")),
          div(class = "mt-4", uiOutput("single_out")))),

        nav_panel("Mehrere Titel", div(class = "mt-3",
          textAreaInput("batch_input", "Ein Titel pro Zeile",
                        width = "100%", height = "180px"),
          div(class = "small-muted", textOutput("batch_count", inline = TRUE)),
          div(class = "d-flex gap-2 mt-2",
              actionButton("go_batch", "Alle klassifizieren", class = "btn btn-primary"),
              actionButton("cancel_batch", "Abbrechen", class = "btn btn-outline-danger"),
              actionButton("clear_batch", "Leeren", class = "btn btn-outline-secondary"),
              downloadButton("dl_csv", "CSV", class = "btn btn-outline-secondary")),
          div(class = "mt-3", uiOutput("batch_progress")),
          div(class = "mt-3", navset_pill(
            nav_panel("Karten",  div(class = "mt-3", uiOutput("batch_cards"))),
            nav_panel("Tabelle", div(class = "mt-3", DTOutput("batch_table")))))))
      )
    )
  })

  opts <- reactive(list(
    mode      = input$mode  %||% "social",
    model_key = input$model %||% PIPELINE_DEFAULTS$model_key,
    n_final   = as.integer(input$n_final %||% PIPELINE_DEFAULTS$n_final),
    boost     = input$boost %||% PIPELINE_DEFAULTS$branch_boost))


  # --- Feedback-Bestätigungen: ein Zustand pro Ergebnis ----------------------
  # Schlüssel "s" = Einzeltitel, "1", "2", ... = Stapel. Wird bei jedem neuen
  # Ergebnis bzw. beim Leeren auf NULL gesetzt.

  fb_msgs <- reactiveValues()

  reset_fb <- function(keys) {
    for (k in keys) fb_msgs[[as.character(k)]] <- NULL
  }
  reset_batch_fb <- function() {
    keys <- setdiff(names(reactiveValuesToList(fb_msgs)), "s")
    reset_fb(keys)
  }


  # --- single ---------------------------------------------------------------

  single_res <- reactiveVal(NULL)

  observeEvent(input$clear_single, {
    updateTextAreaInput(session, "single_title", value = "")
    updateTextAreaInput(session, "single_abstract", value = "")
    single_res(NULL)
    reset_fb("s")
  })

  observeEvent(input$go_single, {
    ttl <- str_squish(input$single_title %||% "")
    if (!nzchar(ttl)) {
      showNotification("Bitte zuerst einen Titel eingeben.", type = "warning")
      return()
    }
    reset_fb("s")
    o <- opts()
    withProgress(message = "Klassifiziere ...", value = 0.3, {
      res <- classify_title(STATE, ttl, mode = o$mode, model_key = o$model_key,
                            abstract = input$single_abstract,
                            n_final = o$n_final, branch_boost = o$boost)
      incProgress(0.7)
      single_res(res)
    })
  })

  output$single_out <- renderUI({
    res <- single_res()
    if (is.null(res)) return(div(class = "small-muted", "Noch kein Ergebnis."))
    render_result(res, idx = "s", open = TRUE)
  })


  # --- batch ----------------------------------------------------------------

  batch <- reactiveValues(queue = character(0), done = list(),
                          running = FALSE, total = 0L, current = "")

  parse_titles <- function(txt) {
    v <- str_split(txt %||% "", "\n")[[1]] |> str_squish()
    v[nzchar(v)]
  }

  output$batch_count <- renderText({
    n <- length(parse_titles(input$batch_input))
    lim <- input$batch_limit %||% 50
    if (n == 0) "" else sprintf("%d Titel erkannt%s", n,
      if (n > lim) sprintf(" — Limit ist %d, überzählige werden ignoriert.", lim) else "")
  })

  observeEvent(input$clear_batch, {
    updateTextAreaInput(session, "batch_input", value = "")
    batch$done <- list(); batch$queue <- character(0)
    batch$running <- FALSE; batch$total <- 0L; batch$current <- ""
    reset_batch_fb()
  })

  observeEvent(input$cancel_batch, {
    if (isolate(batch$running)) {
      batch$queue <- character(0)
      batch$running <- FALSE
      batch$current <- ""
      showNotification("Stapelverarbeitung abgebrochen.", type = "message")
    }
  })

  observeEvent(input$go_batch, {
    v <- parse_titles(input$batch_input)
    lim <- as.integer(input$batch_limit %||% 50)
    if (!length(v)) {
      showNotification("Bitte zuerst Titel eingeben.", type = "warning"); return()
    }
    reset_batch_fb()
    v <- head(v, lim)
    batch$done <- list()
    batch$queue <- v
    batch$total <- length(v)
    batch$current <- v[1]
    batch$running <- TRUE
  })

  observe({
    invalidateLater(300, session)
    if (!isolate(batch$running)) return()
    q <- isolate(batch$queue)
    if (!length(q)) {
      batch$running <- FALSE
      batch$current <- ""
      return()
    }
    ttl <- q[1]
    batch$queue   <- q[-1]
    batch$current <- ttl
    o <- isolate(opts())
    res <- classify_title(STATE, ttl, mode = o$mode, model_key = o$model_key,
                          n_final = o$n_final, branch_boost = o$boost)
    batch$done <- c(isolate(batch$done), list(res))
  })

  output$batch_progress <- renderUI({
    if (batch$total == 0) return(NULL)
    n <- length(batch$done)
    pct <- round(100 * n / batch$total)
    tagList(
      div(class = "progress", style = "height:24px;",
          div(class = "progress-bar progress-bar-striped progress-bar-animated",
              role = "progressbar", style = sprintf("width:%d%%;", max(pct, 3)),
              sprintf("%d / %d", n, batch$total))),
      if (batch$running)
        div(class = "small-muted mt-1",
            sprintf("Verarbeitung läuft — aktuell: %s", str_trunc(batch$current, 70)))
      else div(class = "small-muted mt-1", "Fertig.")
    )
  })

  output$batch_cards <- renderUI({
    d <- batch$done
    if (!length(d)) return(div(class = "small-muted", "Noch keine Ergebnisse."))
    tagList(lapply(seq_along(d),
                   function(k) render_result(d[[k]], idx = k, open = FALSE)))
  })

  batch_tbl <- reactive({
    d <- batch$done
    if (!length(d)) return(tibble())
    g <- function(f, default = "") vapply(d, function(r) {
      v <- try(f(r), silent = TRUE)
      if (inherits(v, "try-error") || is.null(v) || is.na(v)) default else as.character(v)
    }, character(1))
    tibble(
      Titel                   = g(function(r) r$title),
      Notation                = g(function(r) if (isTRUE(r$ok)) r$notation else "—"),
      Benennung               = g(function(r) if (isTRUE(r$ok)) r$benennung else r$error),
      Konfidenz               = g(function(r) if (isTRUE(r$ok)) r$konfidenz else ""),
      Alternative             = g(function(r) if (isTRUE(r$ok)) r$alt_notation else ""),
      `Alternative Benennung` = g(function(r) if (isTRUE(r$ok)) r$alt_benennung else "")
    )
  })

  output$batch_table <- renderDT({
    df <- batch_tbl()
    if (!nrow(df)) return(NULL)
    datatable(df, rownames = FALSE, options = list(pageLength = 25, dom = "tip"))
  })

  # Export: wie die Tabelle, plus vollständige RVK-Verortung von Vorschlag und
  # Alternative (Pfad > Benennung), damit "Allgemeines" eindeutig wird.
  csv_tbl <- reactive({
    d <- batch$done
    df <- batch_tbl()
    if (!nrow(df)) return(df)
    loc <- function(r, alt = FALSE) {
      if (!isTRUE(r$ok)) return("")
      v <- tryCatch(
        if (alt) full_location(r, r$alt_notation, r$alt_benennung)
        else     full_location(r, r$notation, r$benennung),
        error = function(e) "")
      if (is.null(v) || is.na(v)) "" else v
    }
    df |>
      mutate(`RVK-Pfad` = vapply(d, loc, character(1)),
             .after = Benennung) |>
      mutate(`Alternative RVK-Pfad` = vapply(d, loc, character(1), alt = TRUE),
             .after = `Alternative Benennung`)
  })

  output$dl_csv <- downloadHandler(
    filename = function() sprintf("rvk_klassifikation_%s.csv",
                                  format(Sys.time(), "%Y%m%d_%H%M")),
    content  = function(file) readr::write_excel_csv2(csv_tbl(), file))


  # --- Feedback -------------------------------------------------------------

  registered <- reactiveVal(character(0))

  register_feedback <- function(idx, getter) {
    key <- as.character(idx)
    if (key %in% isolate(registered())) return(invisible())
    registered(c(isolate(registered()), key))

    output[[paste0("fb_msg_", key)]] <- renderUI({
      m <- fb_msgs[[key]]
      if (is.null(m)) return(NULL)
      span(class = "text-success small ms-2", m)
    })

    observeEvent(input[[paste0("fb_ok_", key)]], {
      res <- getter(); if (is.null(res) || !isTRUE(res$ok)) return()
      log_feedback(res, accepted = TRUE)
      fb_msgs[[key]] <- sprintf("Übernahme gespeichert · %s",
                                format(Sys.time(), "%H:%M:%S"))
    }, ignoreInit = TRUE)

    observeEvent(input[[paste0("fb_send_", key)]], {
      res <- getter(); if (is.null(res) || !isTRUE(res$ok)) return()
      chosen <- str_squish(input[[paste0("fb_other_", key)]] %||% "")
      if (!nzchar(chosen)) {
        showNotification("Bitte die tatsächlich gewählte Notation eintragen.",
                         type = "warning"); return()
      }
      log_feedback(res, accepted = FALSE, chosen = chosen)
      updateTextInput(session, paste0("fb_other_", key), value = "")
      fb_msgs[[key]] <- sprintf("Abweichung (%s) gespeichert · %s",
                                chosen, format(Sys.time(), "%H:%M:%S"))
    }, ignoreInit = TRUE)
  }

  register_feedback("s", function() single_res())

  observe({
    n <- length(batch$done)
    if (n == 0) return()
    lapply(seq_len(n), function(k) register_feedback(k, function() batch$done[[k]]))
  })
}

shinyApp(ui, server)
