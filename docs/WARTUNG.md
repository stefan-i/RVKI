# Wartung des RVK-Klassifikationsassistenten

Kurzanleitung für die wiederkehrenden Aktualisierungen. Alle Skripte liegen in
`RVK_data/` und werden aus RStudio heraus ausgeführt.

---

## Wichtig vorab: was zerstört was

`rvk.db` enthält inzwischen **drei** Datenbestände:

| Tabelle | Quelle | Aufbau durch |
|---|---|---|
| `rvk`, `rvk_fts` | RVK-XML | `01`, danach `03` |
| `local_rules`, `local_rules_fts` | Local_rules_v2.csv | `11` |
| `holdings`, `holdings_fts` | HoldingsB*.xlsx | `13` |

`01_parse_rvk_xml.R` beginnt mit `file.remove(db_path)` und **löscht damit auch
die lokalen Regeln und den Bestand**. Nach einem RVK-Update müssen `11` und `13`
deshalb zwingend erneut laufen (siehe Reihenfolge unten).

`feedback.db` liegt separat und wird von keinem Skript angefasst. Sie ist der
**einzige nicht wiederherstellbare Bestandteil** des Systems — alles andere lässt
sich aus RVK-XML, Alma-Export und Regel-CSV neu erzeugen. Regelmässig sichern.

---

## 1. Bestand aktualisieren (jährlich)

Neuer Alma-Export als `HoldingsB500.xlsx` bzw. `HoldingsB589.xlsx` nach
`RVK_data/` legen, dann:

```r
source(here("RVK_data", "13_load_holdings.R"))   # Prüfausgabe kontrollieren!
source(here("RVK_data", "14_embed_holdings.R"))
source(here("RVK_data", "19_optimize_indexes.R"))
```

**Vor Schritt 14 die Checkpoints löschen**, sonst werden veraltete Embeddings
mit neuen Titeln vermischt:

```r
unlink(here("RVK_data", "holdings_partial_B500"), recursive = TRUE)
unlink(here("RVK_data", "holdings_partial_B589"), recursive = TRUE)
```

Kosten: rund 0.04 USD, Dauer 15–20 Minuten. Ein inkrementelles Verfahren (nur
neue Titel einbetten) wäre möglich, lohnt bei diesen Beträgen aber nicht.

In der Prüfausgabe von `13` besonders beachten: Zahl der nicht parsbaren
Signaturen, unbekannte Notationen, und die Abdeckung häufig genutzter Notationen.
Springt eine dieser Zahlen deutlich, hat sich vermutlich das Exportformat
geändert.

---

## 2. Lokale Regeln aktualisieren (bei Bedarf)

Vollständige neue `Local_rules_v2.csv` mit allen fünf Spalten (Notationen,
nicht belegt, lokale Notation, Stichwörter, Ergänzende Erklärungen), dann:

```r
source(here("RVK_data", "11_load_local_rules.R"))
```

Das Skript ersetzt die Regeln vollständig — Teillieferungen sind nicht
vorgesehen. Die Prüfausgabe meldet Tippfehler (Regeln ohne passende
RVK-Notation) und falsch markierte lokale Zusatznotationen.

Keine Neuberechnung von Embeddings nötig: die lokalen Stichwörter werden nur
über die Volltextsuche gefunden.

---

## 3. RVK aktualisieren (jährlich genügt)

Die RVK erscheint quartalsweise; jährlich ist für diesen Zweck ausreichend.
Neue `rvk.xml` nach `RVK_data/` legen, dann **in dieser Reihenfolge**:

```r
source(here("RVK_data", "01_parse_rvk_xml.R"))    # löscht rvk.db und baut neu
source(here("RVK_data", "03_fix_encoding.R"))     # HTML-Entities dekodieren
source(here("RVK_data", "11_load_local_rules.R")) # Regeln zurückspielen
source(here("RVK_data", "13_load_holdings.R"))    # Bestand zurückspielen
source(here("RVK_data", "04_embed_rvk.R"))        # ca. 90 Min, ca. 1.20 USD
source(here("RVK_data", "19_optimize_indexes.R"))
```

**Vor Schritt 04 die Checkpoints löschen:**

```r
unlink(here("RVK_data", "embeddings_partial"), recursive = TRUE)
```

Danach `02_validate_rvk_db.R` laufen lassen und mit den Werten des letzten
Aufbaus vergleichen (Knotenzahl, Tiefenverteilung, Anteil mit Register).
Anschliessend `21_evaluate_models.R` auf dem Testset — sinkt die Trefferquote
spürbar, hat die RVK etwas Relevantes umstrukturiert.

Wenn die Neuberechnung aller 675'000 Embeddings zu teuer oder zu langsam wird:
nur Knoten neu einbetten, deren `rich_text` sich geändert hat oder die neu sind.
Dazu den alten `rich_text` vor dem Neuaufbau sichern und vergleichen. Bei den
aktuellen Kosten lohnt der Aufwand nicht.

---

## 4. Rückmeldungen auswerten

```r
source(here("RVK_data", "24_feedback_analysis.R"))
```

Liefert Übernahmequote, Konfidenz-Kalibrierung, wiederkehrende
Abweichungspaare — und exportiert die Rückmeldungen als Testset im Format von
`RVK-Testdaten.csv`.

Wiederkehrende Abweichungspaare sind der interessanteste Teil: Wenn dieselbe
Ersetzung mehrfach auftritt, ist das meist eine hausinterne Konvention, die
bisher nirgends dokumentiert ist. Solche Fälle gehören ins Gesamtregister
(Abschnitt 2) — dann wendet das Werkzeug sie künftig selbst an.

---

## 5. Modelle ersetzen

Wird ein Modell abgekündigt oder erscheint ein besseres:

1. Eintrag in `JUDGE_MODELS` (`lib_judge.R`) ergänzen, zunächst ohne
   `verified = TRUE`.
2. `20_diagnose_models.R` — antwortet das Modell überhaupt, und mit gültigem JSON?
3. `21_evaluate_models.R` — Ausschlusskriterien zuerst: Fehler, JSON-Fehler,
   erfundene Notationen. Erst danach zählt die Trefferquote.
4. Besteht es beides, `verified = TRUE` setzen; es erscheint dann ohne den
   Zusatz „ungetestet“ in der Auswahl.

Ausgeschiedene Modelle als Kommentar mit Datum und Messwerten stehen lassen,
damit sie nicht ohne Grund erneut getestet werden.

---

## 6. Sicherung

Unbedingt sichern:

- `feedback.db` — nicht wiederherstellbar
- `Local_rules_v2.csv` — Handarbeit, nur mit Aufwand reproduzierbar
- `.Renviron` — API-Schlüssel

Bei Bedarf, spart aber nur Rechenzeit:

- `embeddings_norm.rds`, `holdings_emb_*_norm.rds` (aus den Quelldaten neu
  erzeugbar, kostet ca. 1.30 USD und zwei Stunden)

Nicht nötig: `rvk.db` (aus XML, CSV und Alma-Export vollständig reproduzierbar).
