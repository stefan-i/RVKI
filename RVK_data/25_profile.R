# =============================================================================
# 25_profile.R
# Wo geht die Zeit hin? Misst die einzelnen Schritte einer Klassifikation.
#
# Im Container ausführen:
#   sudo docker exec -it rvk-app R -e "source('/srv/rvk/RVK_data/25_profile.R')"
#
# Zum Vergleich dieselbe Datei auf dem PC laufen lassen. Die Differenz zeigt,
# welcher Schritt auf der NAS langsam ist — API-Aufrufe hängen vom Netz ab,
# die Vektorsuche von CPU und BLAS.
# =============================================================================

library(here)
suppressMessages({
  source(here("RVK_data", "05_retrieve.R"))
  source(here("RVK_data", "lib_enrichment.R"))
  source(here("RVK_data", "lib_judge.R"))
})

TITEL <- "Verschwörungsmythen woher sie kommen, was sie anrichten"
MODE  <- "social"
MODELL <- "luna"

tim <- function(label, expr) {
  t0 <- Sys.time()
  val <- force(expr)
  cat(sprintf("  %-34s %6.2f s\n", label,
              as.numeric(Sys.time() - t0, units = "secs")))
  val
}

cat("\n=== Umgebung ===\n")
cat(sprintf("  R %s auf %s\n", getRversion(), R.version$platform))
cat(sprintf("  BLAS: %s\n", La_library()))
cat(sprintf("  Kerne: %d\n", parallel::detectCores()))

cat("\n=== Indizes laden ===\n")
state <- tim("load_retrieval_state()", load_retrieval_state())
cat(sprintf("  RVK-Vektoren: %d x %d\n",
            nrow(state$emb_norm), ncol(state$emb_norm)))

cat("\n=== Reine Rechenzeit (ohne Netz) ===\n")
q <- rnorm(ncol(state$emb_norm)); q <- q / sqrt(sum(q^2))
tim("Vektorsuche RVK (1x)", as.numeric(state$emb_norm %*% q))
tim("Vektorsuche RVK (5x)",
    for (i in 1:5) as.numeric(state$emb_norm %*% q))

H <- state$holdings[["B500"]]
if (!is.null(H)) tim("Vektorsuche Bestand (1x)", as.numeric(H$emb_norm %*% q))

tim("Volltextsuche (FTS5)", retrieve_fts(state, TITEL, n = 150))
tim("Regelabgleich (1014 Regeln)",
    attach_rule_context(state, head(state$notations, 200)))

cat("\n=== Netzaufrufe ===\n")
exp1 <- tim("Titelanalyse (LLM, evtl. Cache)",
            expand_title(TITEL, use_cache = FALSE))
enr  <- build_enriched_query(TITEL, exp1)
embs <- tim("Embeddings (1 Aufruf, 2 Texte)",
            embed_texts_batch(c(enr, TITEL)))

cat("\n=== Gesamter Abruf ===\n")
cand <- tim("retrieve_candidates()",
            retrieve_candidates(state, enr, embs[1, ],
                                title_text = TITEL, title_embedding = embs[2, ],
                                mode = MODE, n_final = 50))
cat(sprintf("  %d Kandidaten\n", nrow(cand)))

jr <- tim(sprintf("judge_candidates() [%s]", MODELL),
          judge_candidates(TITEL, cand, mode = MODE, model_key = MODELL))
cat(sprintf("  Ergebnis: %s\n", if (isTRUE(jr$ok)) jr$notation else jr$error))

cat("\nHinweis: Netzaufrufe hängen von Anbieter und Leitung ab,\n")
cat("Vektorsuche und Regelabgleich von CPU und BLAS.\n")

close_retrieval_state(state)
