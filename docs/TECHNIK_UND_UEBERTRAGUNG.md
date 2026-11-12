# RVK-Klassifikationsassistent – Technischer Aufbau und Übertragung auf andere Systematiken

Diese Beschreibung richtet sich an Kolleginnen und Kollegen, die das Werkzeug
für eine eigene Systematik nachbauen oder anpassen möchten. Sie setzt die
allgemeine Beschreibung aus der Informationsmail voraus und geht von dort ins
Detail: welche Datei was tut, wo die Stellschrauben sitzen, und was bei einer
anderen Systematik anders sein dürfte.

Vorweg das Wichtigste: **Der Code ist an mehreren Stellen auf die RVK
zugeschnitten**, vor allem beim Notationsformat und in den Texten für das
Sprachmodell. Die Architektur dagegen ist allgemein. Wer übertragen will,
übernimmt also besser das Vorgehen und die Lehren als den Code eins zu eins.

---

## 1. Architektur in einem Satz

Suchen und Entscheiden sind getrennt: Vier Suchwege stellen eine Liste von
rund 50 Kandidaten zusammen, und ein Sprachmodell wählt ausschliesslich aus
dieser Liste. Dadurch kann es keine Notationen erfinden, und jeder Vorschlag
ist über die Kandidatenliste und die Bestandsbelege nachvollziehbar.

```
Titel
 └─ 1. Titelanalyse (Sprachmodell): Fach, Hauptthema, Schlagwörter
     └─ 2. Vier Suchwege
         ├─ Stichwortsuche im Systematiktext      (SQLite FTS5)
         ├─ Bedeutungssuche im Systematiktext     (Embeddings)
         ├─ Ähnliche Titel im eigenen Bestand     (Embeddings)
         └─ Lokale Zusatznotationen               (Stichwörter)
     └─ 3. Zusammenführen (Reciprocal Rank Fusion), lokale Regeln,
           Dubletten entfernen, Schwerpunkte leicht gewichten
     └─ 4. Auswahl aus 50 Kandidaten (Sprachmodell)
     └─ 5. Konfidenz aus beobachtbaren Signalen, Belege aus dem Bestand
```

Technik: R 4.5, Shiny-Oberfläche, SQLite mit FTS5-Volltextindex, Embeddings
als R-Matrix im Arbeitsspeicher. Embeddings und Standard-Sprachmodell kommen
von OpenAI; weitere Modelle über OpenRouter und das universitätseigene
GPUStack. Betrieb in einem Docker-Container.

---

## 2. Was wie viel gebracht hat

Die wichtigsten Erkenntnisse aus der Entwicklung, gemessen an einem Testset
von 51 Titeln mit bekannter Notation. „Treffer in der Liste" heisst: die
tatsächlich vergebene Notation war unter den Kandidaten.

| Schritt | Treffer in der Liste |
|---|---|
| Nur Systematiksuche mit dem rohen Titel | 31 % |
| + Titelanalyse durch Sprachmodell | 59 % |
| + Suche im eigenen Bestand | 92 % |

Die Auswahl durch das Sprachmodell trifft danach in etwa 77 % der Fälle, in
denen die richtige Notation in der Liste steht, genau die historisch
vergebene. Bei manueller Durchsicht waren rund 90 % aller Vorschläge
fachlich vertretbar.

Daraus folgen die Lehren, die sich vermutlich übertragen lassen:

**Der Bestand ist der stärkste Kanal.** Er kennt die gelebte Einordnungspraxis,
die in keiner Systematik steht. Gerade Stellen mit nichtssagender Benennung
(„Allgemeines") sind über den Systematiktext kaum, über ähnliche Titel im
Bestand dagegen sofort auffindbar.

**Ohne Titelanalyse geht es nicht.** Buchtitel sind Marketingsprache,
Systematiken sind Bibliothekssprache. Der direkte Vergleich scheitert oft an
einem einzigen fehlenden Begriff.

**Die Wahl des Sprachmodells ist zweitrangig.** Fünf von sieben getesteten
Modellen lagen innerhalb eines Titels beieinander. Wichtiger sind die
Ausschlusskriterien: gültiges JSON und strikte Bindung an die Kandidatenliste.

**Die Selbsteinschätzung des Modells ist wertlos.** Bei „hoch" lag es nur in
etwa 55 % richtig. Die jetzt angezeigte Konfidenz beruht auf beobachtbaren
Signalen (vor allem: wie viele ähnliche Titel im Bestand unter der Notation
stehen) und trennt deutlich besser: „hoch" rund 78 %, „mittel" rund 44 %.

**Vorsicht vor geschönten Tests.** 50 der 51 Testtitel standen selbst im
Bestandsindex, der Bestandskanal fand also das Buch selbst. Erst mit
Ausschluss des Testtitels („leave-one-out") wurden die Zahlen ehrlich.

**Reproduzierbarkeit braucht einen Cache.** Die neueren Modelle akzeptieren
keine Temperatur 0, die Titelanalyse fällt bei jedem Lauf leicht anders aus.
Ohne Zwischenspeicher sind zwei Testläufe nicht vergleichbar.

---

## 3. Die Dateien und ihre Aufgaben

Aufgeführt sind nur Dateien, die für Aufbau, Betrieb und Pflege nötig sind.
Alle liegen in `RVK_data/`, ausser `app.R` im Projektstamm. Experimentier-
und Diagnoseskripte aus der Entwicklung liegen in `archiv/` und laufen mit
der aktuellen Fassung nicht mehr.

### 3.1 Aufbau der Datengrundlage (einmalig, dann jährlich)

| Datei | Aufgabe |
|---|---|
| `01_parse_rvk_xml.R` | Liest das RVK-XML, berechnet für jeden Knoten Pfad, Tiefe und Elternknoten, schreibt die Tabelle `rvk` samt Volltextindex in `rvk.db` |
| `03_fix_encoding.R` | Dekodiert HTML-Entities, die im RVK-Export doppelt maskiert sind, und baut den Volltextindex neu |
| `02_validate_rvk_db.R` | Prüft die Datenbank: eindeutige Notationen, Elternbezüge, Tiefen, Pfade, Kodierung |
| `04_embed_rvk.R` | Berechnet die Embeddings aller zuweisbaren Notationen (rund 675 000), stapelweise und wiederaufnehmbar |
| `11_load_local_rules.R` | Liest das Gesamtregister als CSV, prüft jede Regel gegen die RVK, schreibt `local_rules` |
| `13_load_holdings.R` | Liest die Alma-Exporte, zieht aus der Signatur die Notation, bereinigt Dubletten, schreibt `holdings` |
| `14_embed_holdings.R` | Berechnet die Embeddings der Bestandstitel, je Bibliothek eine Datei |
| `19_optimize_indexes.R` | Normalisiert alle Embedding-Matrizen vorab, damit der Start schnell geht |

### 3.2 Betrieb (wird von der App geladen)

| Datei | Aufgabe |
|---|---|
| `lib_profiles.R` | Zentrale Konfiguration: welche Bibliothek welchen Bestand, welche Regeln und welche Schwerpunktbereiche hat; ausserdem das Lesen von Signaturen |
| `lib_local_rules.R` | Zerlegt Regel-Notationen (Einzelstelle, Bereich, Buchstabenpräfix) und gleicht Kandidaten dagegen ab |
| `lib_holdings.R` | Suche nach ähnlichen Titeln im Bestand, Verdichtung zu Notationen |
| `05_retrieve.R` | Die vier Suchwege, Zusammenführung, Regelfilter, Dublettenbehandlung. Kernstück der Suche |
| `lib_enrichment.R` | Titelanalyse durch das Sprachmodell, mit Zwischenspeicher |
| `lib_judge.R` | Auswahl durch das Sprachmodell; Verzeichnis aller Anbieter und Modelle |
| `lib_confidence.R` | Konfidenz aus beobachtbaren Signalen |
| `lib_evidence.R` | Aufbereitung der Bestandsbelege für die Anzeige |
| `lib_pipeline.R` | Fasst alles zur Funktion `classify_title()` zusammen; enthält keine Oberflächenlogik und kann daher auch von anderen Programmen aufgerufen werden. Ausserdem das Rückmeldeprotokoll |
| `app.R` | Shiny-Oberfläche |

### 3.3 Qualität und Pflege

| Datei | Aufgabe |
|---|---|
| `20_diagnose_models.R` | Schnelltest aller konfigurierten Modelle mit Rohantwort, Fehlertext und Tokenverbrauch |
| `21_evaluate_models.R` | Vollständiger Vergleich mehrerer Modelle auf dem Testset: Robustheit, Trefferquote, Tempo |
| `24_feedback_analysis.R` | Auswertung der Rückmeldungen; exportiert sie als neues Testset |
| `25_profile.R` | Zeitmessung der einzelnen Schritte, zur Fehlersuche bei Langsamkeit |

---

## 4. Wo man anpassen kann oder muss

Gegliedert nach Dringlichkeit. Die erste Gruppe muss bei jeder anderen
Systematik angepasst werden, sonst funktioniert nichts.

### 4.1 Muss angepasst werden

**Import der Systematik (`01`, `03`)**
Komplett ersetzen. Der Parser kennt nur die RVK-XML-Struktur (Elemente
`node`, `children`, `register`, Attribute `notation`, `benennung`,
`bemerkung`). Eine andere Systematik liegt vermutlich als Excel-Liste,
Datenbankexport oder Textdatei vor.

Entscheidend ist nicht das Eingabeformat, sondern die Zieltabelle. Der Rest
der Pipeline erwartet in `rvk.db` eine Tabelle mit diesen Spalten:

| Spalte | Inhalt |
|---|---|
| `notation` | eindeutige Kennung der Stelle |
| `benennung` | Bezeichnung |
| `pfad` | Bezeichnungen aller übergeordneten Stellen, mit „ > " verbunden |
| `register` | zusätzliche Schlagwörter, mit „; " verbunden (darf leer sein) |
| `bemerkung` | Hinweise zur Verwendung (darf leer sein) |
| `parent_notation`, `depth` | Hierarchie |
| `has_range` | `TRUE` für Gruppierungsknoten, die nicht vergeben werden |
| `rich_text` | der Text, der durchsucht und eingebettet wird |

Am wichtigsten ist `rich_text`. Er setzt sich aus Notation, Benennung, Pfad,
Register und Bemerkung zusammen und ist das, was die Bedeutungssuche
„versteht". Wenn die eigene Systematik nur knappe Benennungen hat, ist der
Pfad umso wichtiger.

`03_fix_encoding.R` ist RVK-spezifisch und entfällt, wenn der eigene Import
sauberen Text liefert.

**Notationsformat – an mehreren Stellen fest eingebaut**
Die RVK-Notation hat die Form „Buchstaben, Leerzeichen, Zahl" (`MS 3600`).
Davon gehen diese Stellen aus:

| Datei | Stelle | Wofür |
|---|---|---|
| `05_retrieve.R` | `is_assignable_notation()`, Muster `^[A-Z]+\s+[0-9]` | trennt vergebbare Stellen von Hierarchieknoten |
| `05_retrieve.R` | `retrieve_fts()`, Bedingung `GLOB '*[0-9]*'` | dasselbe in der Volltextsuche |
| `01_parse_rvk_xml.R` | `has_range`, Muster `\s-\s` | erkennt Bereichsknoten wie `MD 6000 - MD 6500` |
| `lib_local_rules.R` | `parse_rule_notation()`, `parse_rvk_notation()` | zerlegt Regeln in Buchstaben, Zahl, Bereich |
| `lib_profiles.R` | `notation_letters()`, `in_preferred_branches()` | Schwerpunktbereiche über Buchstabenpräfixe |
| `lib_profiles.R` | `parse_call_number()` | zieht die Notation aus der Signatur `VRF_AE_62100 1` |

Wer eine Systematik mit anderer Syntax hat (rein numerisch, mit Punkten,
mehrstufig wie `5.3.12`), muss alle sechs Stellen anpassen. Ein Test in
`02_validate_rvk_db.R` hilft, Fehler früh zu sehen.

**Texte für das Sprachmodell (`lib_enrichment.R`, `lib_judge.R`)**
Beide Prompts sprechen ausdrücklich von der RVK und enthalten RVK-spezifische
Regeln:

- `ENRICH_SYSTEM_PROMPT`: verlangt RVK-übliche Begriffsformen, vier Beispiele
  aus unserem Testset. Beispiele durch eigene ersetzen – sie prägen das
  Verhalten stärker als die Anweisungen.
- `build_judge_system_prompt()`: enthält die Regel zu „Allgemeines und
  Deutschland" und zu Parallelstellen. Beides gibt es in anderen Systematiken
  vermutlich nicht oder anders. Die Grundregeln (nur aus der Liste wählen,
  spezifischste Stelle, Bestand als stärkstes Signal) sind dagegen allgemein.

Sprache: Die Titelanalyse liefert deutsche Schlagwörter, weil die RVK deutsch
ist. Ist die eigene Systematik englisch, sollte auch die Titelanalyse
englisch arbeiten.

**Signaturen im Bestand (`13_load_holdings.R`, `lib_profiles.R`)**
Der Bestandskanal funktioniert nur, wenn sich aus der Signatur die
Systemstelle zuverlässig ablesen lässt. Bei uns steht sie nach einem
Bibliothekspräfix (`VRF_`, `BWW_`). Bei einer Aufstellungssystematik mit
eigenem Signaturschema muss `parse_call_number()` angepasst werden. Wenn die
Signatur die Systemstelle gar nicht enthält, fehlt der stärkste Kanal – dann
lohnt es sich, die Zuordnung auf anderem Weg zu beschaffen.

Die Spaltennamen des Exports werden über Muster gesucht
(`Permanent Call Number`, `Title`, `MMS Id`). Bei einem anderen
Alma-Bericht ggf. anpassen.

**Profile (`lib_profiles.R`)**
`HOLDINGS_SOURCES` (Dateiname, Bezeichnung, Ausschlüsse) und `PROFILES`
(Bestand, Regelsatz, Schwerpunkte, Hinweise). Ein neues Profil ist ein neuer
Eintrag; der restliche Code bleibt gleich.

### 4.2 Sollte überprüft werden

**Stoppwörter** (`05_retrieve.R`, `STOPWORDS`): deutsch, englisch,
französisch. Für theologische Literatur ggf. Lateinisch ergänzen.

**Dublettenbehandlung** (`05_retrieve.R`, `max_per_benennung = 3`): fasst
Stellen mit identischer Benennung zusammen. Bei der RVK nötig, weil sie
dasselbe Unterthema für jedes Land wiederholt. Gibt es das in der eigenen
Systematik nicht, schadet die Einstellung nicht, nützt aber auch nichts.

**Lokale Regeln** (`11`, `lib_local_rules.R`): optional. Das CSV-Format
(Notation, gesperrt, lokale Zusatzstelle, Stichwörter, Erläuterung) lässt
sich übernehmen; die Zerlegung der Notationsbereiche ist RVK-Syntax. Der
Ausschluss des Rechtsbereichs P ist bei uns lokal begründet.

**Schwerpunkte** (`lib_profiles.R`, `BRANCHES_*`;
`05_retrieve.R`, `branch_boost = 0.10`): bevorzugen bei Gleichstand die
Kernfächer einer Bibliothek. Sinnvoll vor allem bei Systematiken, die für
dasselbe Thema mehrere vertretbare Stellen anbieten.

**Konfidenz** (`lib_confidence.R`, `CONF_PARAMS`): Schwellen sind an unserem
Bestand grob eingestellt. Bei einem kleineren oder dichteren Bestand neu
kalibrieren; die Rückmeldungen liefern dafür die Daten.

**Hinweistexte** (`lib_judge.R`): der Rechtshinweis für Notationen mit `P`
ist RVK- und hausspezifisch.

### 4.3 Kann so bleiben

- Volltextsuche, Embedding-Verfahren, Zusammenführung (RRF, `rrf_k = 60`)
- Modellverzeichnis und Anbieteranbindung (`JUDGE_MODELS`, `JUDGE_PROVIDERS`)
- Bestandssuche (`k_neighbors = 50`, `min_sim = 0.40`, `top_m = 3`) –
  Werte allenfalls am eigenen Testset prüfen
- Oberfläche und Rückmeldefunktion, bis auf Titel und Modusnamen
  (`MODE_LABELS` in `lib_pipeline.R`)
- Bewertungsskripte `20`, `21`, `24`

---

## 5. Was bei anderen Systematiken anders sein dürfte

**Grösse.** Die RVK hat 783 000 Knoten. Ein grosser Teil des Aufwands – die
Embeddings über eine Stunde, 4 GB Arbeitsspeicher, langsamer Start, die
Leistungsprobleme auf schwacher Hardware – folgt allein daraus. Eine
Haussystematik mit einigen tausend Stellen lässt sich in Minuten einbetten,
braucht kaum Speicher und läuft auf jedem Rechner. Möglicherweise genügt
dann sogar ein einfacherer Aufbau, bei dem das Sprachmodell eine grössere
Kandidatenliste sieht.

**Beschreibungsqualität.** Die RVK hat Register und Bemerkungen, wenn auch
lückenhaft. Haussystematiken bestehen oft nur aus knappen Bezeichnungen. Dann
trägt der Systematiktext wenig, und der Bestandskanal wird umso wichtiger.
Eine Möglichkeit, die wir nicht genutzt haben: knappe Stellen einmalig mit
den Titeln ihres Bestands anreichern. Dabei aber nichts vom Sprachmodell
erfinden lassen, was dann als Beschreibung gilt.

**Mehrsprachigkeit.** Naturwissenschaftliche Titel sind überwiegend englisch,
theologische enthalten Latein, Griechisch, Hebräisch in Umschrift. Die
Embeddings kommen damit gut zurecht. Die Volltextsuche ignoriert
diakritische Zeichen (`remove_diacritics 2`), was bei Umschriften hilft.

**Feinheit der Unterscheidungen.** Je feiner eine Systematik zwischen
benachbarten Stellen unterscheidet, desto wichtiger werden Bemerkungen im
Systematiktext und lokale Regeln. Die Bedeutungssuche findet zuverlässig die
richtige Gegend, nicht immer die richtige Hausnummer.

**Testset zuerst.** Vor jeder Anpassung 50 bis 100 Titel mit bekannter
Notation zusammenstellen, quer über die Fächer, mit ein paar schwierigen
Fällen. Ohne Testset lassen sich Änderungen nicht beurteilen. Dabei an den
Ausschluss des Testtitels aus dem Bestandsindex denken.

---

## 6. R oder Python

Der Code ist R, die Bausteine sind es nicht. Wer in Python arbeitet, findet
für alles direkte Entsprechungen: SQLite mit FTS5 ist in der
Standardbibliothek enthalten, die Vektorsuche ist eine Matrixmultiplikation
mit NumPy, die API-Aufrufe sind gewöhnliche HTTP-Anfragen. Statt Shiny
kämen Streamlit oder Gradio in Frage.

Was sich unabhängig von der Sprache übernehmen lässt: die Datenstruktur aus
Abschnitt 4.1, die Prompts als Ausgangspunkt, das Vorgehen beim Testen und
die Liste der Dinge, die nicht funktioniert haben.

---

## 7. Betrieb und Pflege

Läuft zurzeit als Docker-Container auf einem privaten NAS, erreichbar über
Tailscale Funnel mit Zugangswort. Code und Daten liegen ausserhalb des
Containers und werden eingebunden; eine Code-Änderung braucht nur einen
Neustart. Details in `DEPLOYMENT.md`, Aktualisierungen von Bestand,
Systematik und Regeln in `WARTUNG.md`.

Kosten im Betrieb: rund 0,3 Rappen pro Titel. Einmalige Embeddings der RVK:
rund 1.20 Franken.
