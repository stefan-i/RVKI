# RVKI – Projektanweisungen für Claude Code

Werkzeug, das für Buchtitel eine Notation einer Bibliothekssystematik
vorschlägt (ursprünglich RVK, UB Bern). Suchen und Entscheiden sind getrennt:
vier Suchwege liefern ~50 Kandidaten, ein Sprachmodell wählt ausschliesslich
daraus. R 4.5, Shiny, SQLite/FTS5, Embedding-Matrizen im Arbeitsspeicher.

Hintergrund, Messergebnisse und Anpassungspunkte stehen in
`docs/TECHNIK_UND_UEBERTRAGUNG.md`. Lies diese Datei, bevor du Änderungen an
Suche, Prompts oder Datenimport vorschlägst. Wenn `docs/ANFORDERUNGEN.md`
existiert, ist das die verbindliche Aufgabenbeschreibung für die aktuelle
Anpassung – zuerst lesen.

## Struktur

- `app.R` – Shiny-Oberfläche (Projektstamm)
- `RVK_data/` – gesamter Code **und** die erzeugten Daten (Daten per
  `.gitignore` ausgeschlossen)
  - `01`–`04`: Systematik importieren, prüfen, einbetten
  - `11`: lokale Regeln laden · `13`/`14`: Bestand laden und einbetten
  - `19`: Embeddings vorab normalisieren
  - `05_retrieve.R`: die vier Suchwege und ihre Zusammenführung (Kern)
  - `lib_pipeline.R`: `classify_title()` – einziger Einstiegspunkt, ohne
    Shiny-Code; App und künftige Schnittstellen rufen nur das auf
  - `lib_profiles.R`: Profile (Bestand, Regeln, Schwerpunkte) und
    Signatur-Parser · `lib_judge.R`: Modellverzeichnis und Auswahl-Prompt
  - `20`/`21`: Modelle prüfen und vergleichen · `24`: Rückmeldungen auswerten
- `archiv/` – **toter Code** aus der Entwicklung. Läuft nicht mehr. Nicht
  lesen, nicht als Vorlage verwenden.
- `docs/` – Dokumentation · `beispiele/` – Formatbeispiele für Eingabedateien

## Befehle

```r
shiny::runApp()                                   # App lokal starten
source(here::here("RVK_data", "21_evaluate_models.R"))   # Bewertung
source(here::here("RVK_data", "20_diagnose_models.R"))   # Modelle anpingen
```

Reihenfolge beim Neuaufbau der Daten: siehe `docs/WARTUNG.md`.
`01_parse_rvk_xml.R` löscht `rvk.db` komplett – danach müssen `11` und `13`
erneut laufen.

## Regeln

**Geheimnisse und Daten.** Schlüssel stehen in `.Renviron` (Vorlage
`.Renviron.example`), nie im Code, nie in Commits. Datenbanken, `.rds`,
Exporte und `feedback.db` werden nie eingecheckt. Vor jedem Commit
`git status` prüfen.

**Kosten und Laufzeit.** `04_embed_rvk.R` (~90 min, ~1 USD) und
`14_embed_holdings.R` kosten Geld und Zeit: vorher fragen, nie
eigenmächtig starten. Checkpoint-Ordner `*_partial*` nicht ohne Rückfrage
löschen. Die Datenbank nie von Hand ändern – nur über die Skripte.

**Messen statt vermuten.** Jede Änderung an Suche, Prompts, Gewichten oder
Modellen wird mit `21_evaluate_models.R` vorher und nachher gemessen.
Reihenfolge der Kriterien: (1) keine Fehler, kein ungültiges JSON, keine
erfundenen Notationen, (2) erst dann Trefferquote, (3) dann Tempo.
Bestandskanal immer mit Leave-one-out (`exclude_titles = <Testtitel>`),
sonst findet er das Testbuch selbst und die Zahlen sind wertlos.
Unterschiede von 1–2 Titeln bei ~50 Testtiteln sind Rauschen.

**Titelanalyse-Cache.** `lib_enrichment.R` speichert Ergebnisse pro
Titel. Nach Änderung des Enrichment-Prompts `enrich_cache_clear()`
aufrufen, sonst wirkt die Änderung nicht.

**Modelle.** Neue Modelle nur über `JUDGE_MODELS` in `lib_judge.R`, mit
`verified = FALSE`, bis sie `21` bestanden haben. GPT-5-Familie: kein
`temperature`, `max_completion_tokens` statt `max_tokens`. Reasoning wo
möglich über `extra_body` abschalten. Embedding-Modell und Dimension (768)
nicht ändern, ohne alles neu einzubetten.

**R-Fallstricke.** Kein Komma nach dem letzten Element in `list(...)`
(Fehler „Argument N ist leer"). Pfade immer über
`here::here("RVK_data", ...)`; der Projektstamm ist durch `.here` markiert
(nötig im Container).

**Oberfläche.** Alle Texte für Nutzende auf Deutsch, Schweizer
Schreibweise (ss statt ß). Code-Kommentare dürfen englisch sein.

**Betrieb.** Code und Daten sind in den Container eingebunden: Code-
Änderung = Container-Neustart, kein Neubau. Neubau nur bei neuen Paketen
oder Systembibliotheken (Ubuntu 24.04: Paketnamen mit `t64`, z. B.
`libuv1t64`). Details: `docs/DEPLOYMENT.md`.

## Systematik-spezifische Stellen

Das RVK-Notationsformat („Buchstaben Leerzeichen Zahl", z. B. `MS 3600`)
ist an sechs Stellen fest eingebaut. Bei einer anderen Systematik alle
prüfen; Fehler äussern sich nicht als Fehlermeldung, sondern als Suche, die
still nichts findet:

1. `05_retrieve.R` – `is_assignable_notation()`
2. `05_retrieve.R` – `retrieve_fts()`, Bedingung `GLOB '*[0-9]*'`
3. `01_parse_rvk_xml.R` – Erkennung von Bereichsknoten (`has_range`)
4. `lib_local_rules.R` – `parse_rule_notation()`, `parse_rvk_notation()`
5. `lib_profiles.R` – `notation_letters()`, `in_preferred_branches()`
6. `lib_profiles.R` – `parse_call_number()`

Ausserdem RVK-spezifisch: beide Prompts (`ENRICH_SYSTEM_PROMPT`,
`build_judge_system_prompt()`), der Rechtshinweis für `P` in
`lib_judge.R`, `MODE_LABELS` in `lib_pipeline.R`.
