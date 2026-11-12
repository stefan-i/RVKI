# RVKI – Klassifikationsassistent

Schlägt für Buchtitel eine Notation der Regensburger Verbundklassifikation
(RVK) vor, unter Berücksichtigung des eigenen Bestands und hausinterner
Regeln. Entwickelt 2026 an der Universitätsbibliothek Bern für die
sozialwissenschaftliche und die wirtschaftswissenschaftliche Bibliothek.

Das Werkzeug rät nicht, es sucht: Vier Suchwege (Stichwörter, Bedeutung,
ähnliche Titel im Bestand, lokale Zusatznotationen) stellen rund 50
Kandidaten zusammen, ein Sprachmodell wählt ausschliesslich daraus und
begründet die Wahl. Bei einem Test mit 51 Titeln stand die richtige Notation
in 92 % der Fälle in der Kandidatenliste; rund 90 % der Vorschläge waren
fachlich vertretbar.

## Dokumentation

| Datei | Für wen |
|---|---|
| [`docs/ANWENDUNG.md`](docs/ANWENDUNG.md) | Nutzende: Bedienung, Ergebnisse lesen, Grenzen |
| [`docs/TECHNIK_UND_UEBERTRAGUNG.md`](docs/TECHNIK_UND_UEBERTRAGUNG.md) | Technischer Aufbau, Messergebnisse, Anpassung an andere Systematiken |
| [`docs/ANPASSUNG_MIT_CLAUDE_CODE.md`](docs/ANPASSUNG_MIT_CLAUDE_CODE.md) | Leitfaden für Teams, die das Werkzeug für ihre Systematik umbauen |
| [`docs/WARTUNG.md`](docs/WARTUNG.md) | Aktualisierung von Bestand, RVK, Regeln; Modellwechsel |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Betrieb im Docker-Container |
| [`CLAUDE.md`](CLAUDE.md) | Projektanweisungen für Claude Code |

## Schnellstart (lokal)

Voraussetzungen: R ≥ 4.5, OpenAI-API-Schlüssel, die Quelldaten (RVK-XML,
Bestandsexport aus Alma, optional Regel-CSV). Daten und Schlüssel sind
**nicht** im Repository.

1. `.Renviron.example` nach `.Renviron` kopieren, Schlüssel eintragen,
   R neu starten.
2. Quelldaten nach `RVK_data/` legen.
3. Datenbasis aufbauen – Reihenfolge in `docs/WARTUNG.md`, Abschnitt 3.
4. `shiny::runApp()`

Pakete: `shiny bslib DT here DBI RSQLite dplyr tibble tidyr stringr purrr
readr readxl httr2 jsonlite digest xml2`.

## Status

Prototyp im Testbetrieb. Keine Verfügbarkeitszusage.

## Lizenz

MIT, siehe `LICENSE`.
