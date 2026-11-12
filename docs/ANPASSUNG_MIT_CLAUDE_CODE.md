# Anpassung an eine andere Systematik mit Claude Code

Leitfaden für Teams, die dieses Werkzeug für ihre eigene Systematik
umbauen wollen. Voraussetzungen: R-Kenntnisse, ein Claude-Abo (Pro genügt
für den Einstieg), keine Erfahrung mit Claude Code nötig.

Vorher lesen: `TECHNIK_UND_UEBERTRAGUNG.md` (Aufbau und Lehren) und
`ANWENDUNG.md` (was das Werkzeug aus Sicht der Nutzenden tut).

---

## 0. Die wichtigste Einsicht vorweg

**Die Arbeit liegt in den Daten, nicht im Code.** Claude Code schreibt einen
Importer für eure Systematik in einer Stunde – aber nur, wenn ihr ihm eine
saubere Datei und echte Beispiele gebt. Was es nicht kann: eine Systematik
aus einem PDF rekonstruieren, raten, wie eure Signaturen aufgebaut sind,
oder beurteilen, ob ein Vorschlag fachlich stimmt.

Deshalb zuerst `ANFORDERUNGEN_VORLAGE.md` ausfüllen und die drei
Datengrundlagen bereitstellen:

1. die Systematik als strukturierte Datei
2. den Bestandsexport mit Signaturen
3. ein Testset von 50–100 Titeln mit bekannter Notation

Ohne Testset lässt sich keine Änderung beurteilen – auch nicht von Claude.

---

## 1. Einrichtung

### Repository

Auf GitHub einen **Fork** von `stefan-i/RVKI` anlegen (oder ein eigenes
Repository mit diesem Code als Ausgangspunkt) und lokal klonen. Nicht im
Original-Repository arbeiten.

### Claude Code installieren

Windows, in PowerShell:

```powershell
irm https://claude.ai/install.ps1 | iex
```

Danach ein neues Terminal öffnen und `claude --version` prüfen. Empfohlen
ist zusätzlich [Git for Windows](https://git-scm.com/downloads/win).
Anmeldung beim ersten Start mit dem Claude-Konto (Pro). Aktuelle Anleitung:
<https://code.claude.com/docs/en/quickstart>

**Verwaltete Uni-Rechner:** Installationen sind dort oft gesperrt. Vorher mit
der IT klären oder auf einem privaten Rechner arbeiten. Alternativen ohne
Terminal: Desktop-App, VS-Code-Erweiterung, oder Claude Code im Browser
unter claude.ai/code – Letzteres arbeitet in einer Cloud-Umgebung direkt auf
dem GitHub-Repository, hat dort aber eure (nicht eingecheckten) Daten nicht.

### Starten

Im Projektordner ein Terminal öffnen (in RStudio: Reiter *Terminal*) und
`claude` eingeben. Claude liest automatisch `CLAUDE.md` mit den
Projektregeln.

### Schlüssel

`.Renviron.example` nach `.Renviron` kopieren, eigenen OpenAI-Schlüssel
eintragen. **Nie committen** – die `.gitignore` schützt davor, aber vor
jedem Commit kurz `git status` ansehen.

---

## 2. Arbeitsweise

Ein paar Gewohnheiten, die den Unterschied machen:

**Erst planen lassen, dann bauen.** Mit `Shift+Tab` in den Planmodus
wechseln: Claude untersucht und schlägt vor, ändert aber nichts. Plan lesen,
korrigieren, dann umsetzen lassen.

**Kleine Schritte, jeder geprüft.** Eine Etappe pro Sitzung. Nach jedem
funktionierenden Schritt committen (`commit my changes` genügt). Läuft etwas
schief, ist der letzte gute Stand einen Befehl entfernt.

**Selbst ausführen und lesen.** Claude kann R-Skripte starten, aber die
Ausgaben beurteilt ihr. Bei Zahlen nachfragen, woher sie kommen.

**Konkret sein.** Nicht „pass den Import an", sondern „schreibe
`01_parse_<name>.R`, das `daten/systematik.xlsx` liest und die Tabelle `rvk`
mit den Spalten aus Abschnitt 4.1 von TECHNIK_UND_UEBERTRAGUNG.md erzeugt;
die ersten zehn Zeilen sollen so aussehen: …"

**Kontext frisch halten.** Bei Themenwechsel `/clear`. Lange Sitzungen
werden ungenauer und verbrauchen das Kontingent schneller.

**Pro-Kontingent.** Das Pro-Abo hat Nutzungsgrenzen pro Zeitfenster. Für
fokussierte Etappen reicht es; ganze Umbautage in einem Rutsch stossen an
die Grenze. Planung und kleine Schritte sparen auch hier.

**Nichts übernehmen, was ihr nicht versteht.** Wenn Claude eine Funktion
umbaut, erklären lassen, was sich ändert und warum. Ihr müsst das Werkzeug
später pflegen, nicht Claude.

---

## 3. Etappen

Jede Etappe mit einem Vorschlag für den ersten Auftrag und einem
Abschlusskriterium. Die Aufträge sind Ausgangspunkte – anpassen.

### Etappe 0 – Orientierung (keine Änderungen)

> Lies CLAUDE.md, docs/TECHNIK_UND_UEBERTRAGUNG.md und
> docs/ANFORDERUNGEN.md. Erkläre mir den Ablauf einer Klassifikation von
> der Eingabe bis zum Ergebnis anhand der Dateien. Dann: Welche Teile
> müssen für unsere Systematik geändert werden, welche können bleiben,
> und wo siehst du Risiken? Ändere noch nichts.

*Fertig, wenn* ihr die Pipeline in eigenen Worten erklären könnt und eine
Liste der Änderungen habt, der ihr zustimmt.

### Etappe 1 – Entscheiden: umbauen oder vereinfachen

Ist eure Systematik klein (einige tausend Stellen), braucht ihr vieles nicht:
keine Leistungsoptimierung, keine Dublettenbehandlung für Länderschlüssel,
möglicherweise nicht einmal die Bedeutungssuche über die Systematik.

> Unsere Systematik hat N Stellen. Welche Teile der Pipeline sind bei dieser
> Grösse unnötig? Schlage eine schlanke Variante vor und vergleiche sie mit
> einem vollständigen Umbau: Aufwand, Risiken, was wir verlieren.

*Fertig, wenn* entschieden ist, welche Variante.

### Etappe 2 – Systematik importieren

> Schreibe RVK_data/01_parse_<name>.R, das <Datei> liest und in rvk.db
> die Tabelle rvk mit den Spalten aus Abschnitt 4.1 erzeugt, inklusive
> Volltextindex. Passe 02_validate_rvk_db.R an unsere Notationssyntax an.

*Fertig, wenn* die Validierung ohne Warnungen durchläuft und ihr zehn
Stellen von Hand mit dem Original verglichen habt – insbesondere `pfad` und
`rich_text`.

### Etappe 3 – Notationsformat

> Unsere Notationen sehen so aus: <Beispiele>. Prüfe die sechs Stellen aus
> dem Abschnitt „Systematik-spezifische Stellen" in CLAUDE.md und passe sie
> an. Schreibe für jede Funktion einen kleinen Test mit unseren Beispielen,
> der vorher fehlschlägt und nachher besteht.

*Fertig, wenn* alle Tests bestehen. Diese Etappe nicht überspringen – hier
entstehen die Fehler, die man später nicht bemerkt.

### Etappe 4 – Systematik einbetten

> Wie viele Stellen werden eingebettet, was kostet das ungefähr, wie lange
> dauert es? Starte noch nichts.

Danach selbst `04_embed_rvk.R` starten, dann `19_optimize_indexes.R`.

*Fertig, wenn* der Nachbarschaftstest am Ende von 04 für eine bekannte
Stelle sinnvolle Nachbarn zeigt.

### Etappe 5 – Bestand

> Unsere Signaturen sehen so aus: <Tabelle aus ANFORDERUNGEN.md>. Passe
> parse_call_number() in lib_profiles.R und den Import in 13_load_holdings.R
> an. Lege in lib_profiles.R ein Profil für unsere Bibliothek an und entferne
> die RVK-Profile.

Dann `13` laufen lassen, Prüfausgabe lesen (wie viele Signaturen nicht
lesbar, wie viele Notationen unbekannt), dann `14` und `19`.

*Fertig, wenn* weniger als ~1 % der Signaturen unlesbar sind und die
häufigsten Notationen plausibel sind.

### Etappe 6 – Prompts

> Passe ENRICH_SYSTEM_PROMPT in lib_enrichment.R und
> build_judge_system_prompt() in lib_judge.R an unsere Systematik an.
> Entferne die RVK-spezifischen Regeln (Allgemeines und Deutschland,
> Parallelstellen, Rechtshinweis). Ersetze die Beispiele durch vier Titel
> aus unserem Testset – aber nicht solche, die wir zur Bewertung nutzen.

Danach `enrich_cache_clear()`.

*Fertig, wenn* `20_diagnose_models.R` für alle Modelle gültiges JSON zeigt.

### Etappe 7 – Bewerten

> Passe 21_evaluate_models.R an unser Testset an und lass es nur mit luna
> laufen.

*Fertig, wenn* die Zahlen vorliegen: Anteil Treffer in der Kandidatenliste,
Treffer an erster Stelle, null erfundene Notationen. Dann die Abweichungen
**selbst durchsehen** – bei uns waren 70 % exakte Treffer in Wahrheit 90 %
vertretbare Vorschläge.

### Etappe 8 – Oberfläche

> Passe MODE_LABELS in lib_pipeline.R und die Titel in app.R an unsere
> Bibliothek an.

*Fertig, wenn* `shiny::runApp()` läuft und einige Titel aus dem Alltag
sinnvolle Ergebnisse liefern.

---

## 4. Was bei uns schiefging

Damit es euch nicht auch passiert:

- **Leave-one-out vergessen.** Die Testtitel standen im Bestandsindex; der
  Bestandskanal fand die Bücher selbst. Ergebnis: 98 % statt ehrlicher 92 %.
- **Schwankende Testläufe.** Ohne Cache liefert die Titelanalyse bei jedem
  Lauf leicht andere Schlagwörter. Zwei Läufe sind sonst nicht vergleichbar.
- **Zwei Stellschrauben für dasselbe.** `n_final` in der Suche und
  `max_candidates` im Auswahlschritt müssen übereinstimmen, sonst liest das
  Modell weniger Kandidaten, als gefunden wurden.
- **Hierarchieknoten als Vorschläge.** Eine Stelle wie `DI` (ohne Zahl)
  wurde vorgeschlagen, weil sie nicht als Bereich markiert war.
- **Kopierte Zahlen aus kleinen Stichproben.** Bei 50 Testtiteln sind
  Unterschiede von ein, zwei Titeln Zufall.
- **Langsamer Server.** Auf einer NAS mit Festplatten dauerte die erste
  Volltextsuche 80 Sekunden, bis der SQLite-Cache vergrössert wurde
  (bereits in `05_retrieve.R`).

---

## 5. Zusammenarbeit

Euer Fork ist eure Version. Verbesserungen, die allen nützen (Fehler,
Verallgemeinerungen wie ein konfigurierbares Notationsformat), gerne als
Pull Request ans Original zurückgeben. Ziel ist, später einen gemeinsamen
Kern für mehrere Systematiken zu haben – dafür hilft es, wenn die
Schnittstellen (`classify_title()`, Tabellenstruktur, Testset-Format)
gleich bleiben.
