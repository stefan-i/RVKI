# Archiv

Experimentier- und Diagnoseskripte aus der Entwicklung (Sommer 2026). Sie
dokumentieren, wie die Entscheidungen in `docs/TECHNIK_UND_UEBERTRAGUNG.md`
zustande kamen.

**Sie laufen mit der aktuellen Fassung nicht mehr** – mehrere rufen
Funktionen auf, die es nicht mehr gibt (z. B. `retrieve_hybrid()`). Nicht als
Vorlage für neuen Code verwenden. Der aktuelle Stand der Bewertung ist
`RVK_data/21_evaluate_models.R`.

| Datei | Damals untersucht |
|---|---|
| `06_evaluate_retrieval.R` | Stichwort- vs. Bedeutungssuche vs. Kombination |
| `07_diagnose_retrieval.R` | Warum Treffer fehlen; erster Test der Titelanalyse |
| `08_query_enrichment.R` | Titelanalyse durch Sprachmodell (heute `lib_enrichment.R`) |
| `09_diagnose_clusters.R` | Problemfälle MS 3600, DK 1010, MG 32000 |
| `10_extract_local_rules.R` | Automatisches Auslesen des Word-Registers (verworfen, manuell ersetzt) |
| `12_test_modes.R` | Erste Fassung der drei Modi |
| `15_evaluate_holdings.R` | Bestandskanal, noch mit Datenleck |
| `16_evaluate_loo.R` | Bestandskanal mit Leave-one-out |
| `17_evaluate_judge.R` | Auswahl durch Sprachmodell, Vorläufer von 21 |
| `18_diagnose_recall.R` | Schwankungen zwischen Läufen (Ursache: Titelanalyse ohne Cache) |
