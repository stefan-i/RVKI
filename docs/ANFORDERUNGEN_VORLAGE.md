# Anforderungen für die Anpassung an [Name der Systematik]

*Vorlage. Kopieren nach `docs/ANFORDERUNGEN.md`, ausfüllen, einchecken.
Claude Code liest diese Datei zu Beginn jeder Sitzung (siehe `CLAUDE.md`).
Was hier nicht steht, muss Claude raten. Lieber zu konkret als zu knapp.
Unbekanntes mit „offen" markieren statt weglassen.*

---

## 1. Ziel

- Wofür soll das Werkzeug eingesetzt werden? (Erwerbung, Retrokatalogisierung,
  Aufstellung …)
- Wer nutzt es, wie oft, ungefähr wie viele Titel pro Jahr?
- Was ist für den ersten Prototyp **nicht** nötig? (z. B. Stapelverarbeitung,
  Docker, Rückmeldungen)

## 2. Systematik

- Name, Version, wer pflegt sie:
- Anzahl Stellen insgesamt / davon vergebbar:
- Liegt vor als: (Excel, CSV, Datenbankexport, Word, PDF …) – Datei und
  Spaltennamen nennen:
- Hierarchie: Wie ist erkennbar, welche Stelle unter welcher steht?
  (eigene Spalte, Einrückung, aus der Notation ableitbar …)
- Gibt es Gruppierungs- oder Bereichsknoten, die nie vergeben werden?
  Woran erkennbar?
- Beschreibende Felder pro Stelle (Benennung, Register, Hinweise, Beispiele):
- Sprache der Benennungen:

**Notationssyntax – mindestens zehn echte Beispiele**, quer durch die
Systematik, inklusive Sonderfälle:

| Notation | Benennung | vergebbar? |
|---|---|---|
| | | |

- Welche Zeichen kommen vor? (Buchstaben, Ziffern, Punkte, Leerzeichen,
  Bindestriche, Klammern)
- Wie werden Bereiche geschrieben?

## 3. Bestand

- Exportquelle (Alma-Bericht?) und Dateiname:
- Spaltennamen für Titel, Signatur, MMS-ID:
- Ungefähre Anzahl Titel:
- **Signaturschema – mindestens zehn echte Beispiele** mit der Notation, die
  daraus gelesen werden soll:

| Signatur im Export | gewünschte Notation |
|---|---|
| | |

- Gibt es Titel ohne Systemstelle in der Signatur? Was tun mit ihnen?
- Mehrere Exemplare / Bände pro Titel? (wird über die MMS-ID entdoppelt)
- Bereiche oder Bestände, die ausgeschlossen werden sollen:

## 4. Lokale Regeln (optional)

- Gibt es gesperrte Stellen, hausinterne Zusatzstellen, Abweichungen?
- Format: siehe `beispiele/Lokale_Regeln_BEISPIEL.csv`

## 5. Testset

- 50–100 Titel mit bekannter, als richtig angesehener Notation, quer durch
  die Fächer, mit einigen schwierigen und interdisziplinären Fällen.
- Format: siehe `beispiele/Testdaten_BEISPIEL.csv` (Titel;Notation, ohne
  Kopfzeile, UTF-8)
- Dateiname:
- Wer hat die Notationen geprüft?

## 6. Fachliche Präferenzen

- Kernbereiche, die bei gleichwertigen Alternativen bevorzugt werden sollen:
- Bereiche, für die das Werkzeug keine Vorschläge machen soll:
- Sprachen der Titel (Anteile grob):

## 7. Technik und Betrieb

- Wo wird entwickelt? (privater Rechner / verwalteter Uni-Rechner)
- Wo soll es laufen? (nur lokal / Server – welcher?)
- API: Wer stellt den Schlüssel, wer trägt die Kosten?
- GPUStack der Uni nutzbar (Entwicklung im Uni-Netz)?
- R oder Python?

## 8. Erfolgskriterium

- Wann ist der Prototyp gut genug für den Testbetrieb? (z. B. „richtige
  Notation in 85 % der Fälle unter den Kandidaten, kein einziger erfundener
  Vorschlag")
