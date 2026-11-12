# =============================================================================
# 24_feedback_analysis.R
# Read and analyse the feedback log written by the app.
#
# The log is the only irreplaceable data in the system: everything else can be
# rebuilt from the RVK XML, the Alma exports and the rules CSV. Back it up.
#
# Its real value is the corrections: (Titel, vorgeschlagen, tatsächlich
# gewählt) is exactly the shape of RVK-Testdaten.csv, so disagreements turn
# into a growing, real-world test set — and the in-house conventions that
# currently live only in people's heads start becoming data.
# =============================================================================

library(here)
library(dplyr)
library(stringr)
library(tibble)
library(readr)
library(DBI)
library(RSQLite)

source(here("RVK_data", "lib_pipeline.R"))   # for FEEDBACK_DB, read_feedback()


fb <- read_feedback()

if (!nrow(fb)) {
  cat("Noch keine Rückmeldungen erfasst.\n")
} else {

  fb <- fb |> mutate(ts = as.POSIXct(ts, format = "%Y-%m-%dT%H:%M:%S"))

  cat(sprintf("=== %d Rückmeldungen, %s bis %s ===\n\n", nrow(fb),
              format(min(fb$ts), "%d.%m.%Y"), format(max(fb$ts), "%d.%m.%Y")))

  # --- Acceptance rate ------------------------------------------------------
  cat("--- Übernahmequote ---\n")
  print(fb |> group_by(mode) |>
          summarise(n = n(), übernommen = sum(accepted == 1),
                    Quote = round(100 * mean(accepted == 1)), .groups = "drop"))

  cat("\n--- nach Modell ---\n")
  print(fb |> group_by(model) |>
          summarise(n = n(), Quote = round(100 * mean(accepted == 1)),
                    .groups = "drop") |> arrange(desc(n)))

  # --- Does the displayed confidence predict acceptance? --------------------
  # This is the calibration check we could not run on 51 books. Once a few
  # hundred rows have accrued, it says whether "hoch" is worth trusting.
  cat("\n--- Konfidenz vs. Übernahme ---\n")
  print(fb |> filter(!is.na(konfidenz)) |> group_by(konfidenz) |>
          summarise(n = n(), Quote = round(100 * mean(accepted == 1)),
                    .groups = "drop") |>
          arrange(factor(konfidenz, levels = c("hoch", "mittel", "niedrig"))))
  cat("Aussagekräftig ab etwa 100 Rückmeldungen pro Stufe.\n")

  # --- Corrections ----------------------------------------------------------
  corr <- fb |> filter(accepted == 0, !is.na(chosen), nzchar(chosen))

  cat(sprintf("\n--- %d Korrekturen ---\n", nrow(corr)))
  if (nrow(corr)) {
    print(corr |> select(ts, mode, title, suggested, chosen) |>
            mutate(title = str_trunc(title, 55)) |> head(30))

    # Where do suggestion and choice diverge systematically? A recurring pair
    # is usually an undocumented house convention, not a model failure.
    cat("\n--- häufigste Abweichungspaare (vorgeschlagen -> gewählt) ---\n")
    print(corr |> count(suggested, chosen, sort = TRUE) |> head(20))

    cat("\n--- Abweichungen nach RVK-Zweig ---\n")
    print(corr |>
            mutate(von = str_sub(suggested, 1, 2), nach = str_sub(chosen, 1, 2)) |>
            count(von, nach, sort = TRUE) |> head(20))

    # Same branch, different number = fine tuning within an area.
    # Different branch = the tool is looking in the wrong place.
    cat("\n--- Art der Abweichung ---\n")
    print(corr |>
            mutate(art = if_else(str_sub(suggested, 1, 2) == str_sub(chosen, 1, 2),
                                 "gleicher Zweig", "anderer Zweig")) |>
            count(art))
  }

  # --- Export as a test set -------------------------------------------------
  # Same format as RVK-Testdaten.csv: title;notation. Accepted suggestions and
  # corrections are both usable — the chosen notation is the ground truth in
  # either case.
  testset <- fb |>
    mutate(notation = if_else(accepted == 1, suggested, chosen)) |>
    filter(!is.na(title), nzchar(title), !is.na(notation), nzchar(notation)) |>
    distinct(title, notation)

  if (nrow(testset)) {
    out <- here("RVK_data", "RVK-Testdaten-aus-Feedback.csv")
    write_delim(testset, out, delim = ";", col_names = FALSE)
    cat(sprintf("\n%d Titel als Testset gespeichert: %s\n", nrow(testset), out))
    cat("Kann in 21_evaluate_models.R anstelle von RVK-Testdaten.csv verwendet werden.\n")
  }

  # --- Full export for manual inspection ------------------------------------
  out_all <- here("RVK_data", "feedback_export.csv")
  write_excel_csv2(fb, out_all)
  cat(sprintf("Vollständiger Export: %s\n", out_all))
}
