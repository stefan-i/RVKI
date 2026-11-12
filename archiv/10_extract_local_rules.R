# =============================================================================
# 10_extract_local_rules.R  (v2 — fixes list-cols + discontinuous cell IDs)
# Parse the Gesamtregister.docx into a structured CSV for manual review.
#
# v2 corrections:
#   (a) A single Word cell can contain multiple paragraphs. officer emits
#       one row per paragraph; we collapse those before pivoting.
#   (b) cell_id in officer's output may skip numbers when merged cells are
#       present (we saw values up to 37). We pivot by POSITIONAL index
#       (sorted within each row) instead of raw cell_id.
# =============================================================================

library(here)
library(officer)
library(dplyr)
library(stringr)
library(tibble)
library(tidyr)
library(readr)

doc_path <- here("RVK_data", "Gesamtregister.docx")
stopifnot(file.exists(doc_path))


# -----------------------------------------------------------------------------
# 1. Read document
# -----------------------------------------------------------------------------

doc <- read_docx(doc_path)
sm  <- docx_summary(doc) |> as_tibble()

cat("Content types in document:\n")
print(table(sm$content_type))

sm <- sm |>
  arrange(doc_index) |>
  mutate(is_cell = str_detect(content_type, "cell"))


# -----------------------------------------------------------------------------
# 2. Clean text
# -----------------------------------------------------------------------------

clean_text <- function(x) {
  x |>
    coalesce("") |>
    str_replace_all("\\*+", "") |>
    str_replace_all("[\\u00A0\\u202F]", " ") |>
    str_replace_all("\\s+", " ") |>
    str_trim() |>
    na_if("")
}

sm$text <- clean_text(sm$text)


# -----------------------------------------------------------------------------
# 3. Section header detection + forward-fill
# -----------------------------------------------------------------------------

section_re <- "^[A-Z]{1,3}(\\s*[–\\-]\\s*[A-Z]{1,4})?(\\s+\\d+ff?)?\\s+[A-ZÄÖÜ]"

sm <- sm |>
  mutate(
    is_section_para =
      !is_cell & !is.na(text) & str_detect(text, section_re),
    is_section_cell =
      is_cell & row_id == 1 & cell_id == 1 &
      !is.na(text) & str_detect(text, section_re)
  ) |>
  mutate(is_section    = is_section_para | is_section_cell,
         section_carry = if_else(is_section, text, NA_character_)) |>
  fill(section_carry, .direction = "down")


# -----------------------------------------------------------------------------
# 4. Identify tables (runs of consecutive cells)
# -----------------------------------------------------------------------------

sm <- sm |>
  mutate(table_start = is_cell & !lag(is_cell, default = FALSE),
         table_id    = cumsum(table_start) * as.integer(is_cell)) |>
  mutate(table_id    = if_else(table_id == 0L, NA_integer_, table_id))

cells <- sm |> filter(is_cell)

cat(sprintf("\nIdentified %d tables, %d total cell rows (paragraphs).\n",
            length(unique(cells$table_id)), nrow(cells)))
cat("Unique cell_id values seen in source:",
    paste(sort(unique(cells$cell_id)), collapse = ", "), "\n")


# -----------------------------------------------------------------------------
# 5. Collapse multi-paragraph cells, pivot by positional index
# -----------------------------------------------------------------------------

cells_collapsed <- cells |>
  group_by(table_id, row_id, cell_id) |>
  summarize(
    text    = paste(text[!is.na(text)], collapse = " "),
    section = first(section_carry),
    .groups = "drop"
  ) |>
  mutate(text = clean_text(text))

cells_positional <- cells_collapsed |>
  group_by(table_id, row_id) |>
  arrange(cell_id, .by_group = TRUE) |>
  mutate(pos = row_number()) |>
  ungroup()

cat("\nCells per row distribution (positional):\n")
print(cells_positional |> count(table_id, row_id) |> count(n, name = "n_rows"))

wide <- cells_positional |>
  filter(pos <= 8) |>     # allow up to 8 defensively; rule tables have 5
  pivot_wider(id_cols     = c(table_id, row_id, section),
              names_from  = pos,
              values_from = text,
              names_prefix = "c")

for (cc in c("c1","c2","c3","c4","c5")) {
  if (!cc %in% names(wide)) wide[[cc]] <- NA_character_
}

cat("\nColumns after positional pivot:",
    paste(names(wide)[str_detect(names(wide), "^c\\d+$")], collapse = ", "), "\n")


# -----------------------------------------------------------------------------
# 6. Filter to data rows, classify, flag for review
# -----------------------------------------------------------------------------

rules_raw <- wide |>
  filter(!(coalesce(c1, "") == "Obergruppe")) |>
  filter(!(is.na(c1) & is.na(c2) & is.na(c3) & is.na(c4) & is.na(c5))) |>
  filter(!(is.na(c2) & is.na(c3) & is.na(c4) & is.na(c5) &
             !is.na(c1) & str_detect(c1, section_re)))

rules <- rules_raw |>
  transmute(
    section,
    table_id,
    row_id,
    obergruppe       = c1,
    notation         = c2,
    nicht_belegt_raw = c3,
    stichwoerter     = c4,
    erklaerung       = c5,
    nicht_belegt = case_when(
      is.na(c3) | c3 == ""                ~ "",
      str_to_lower(str_trim(c3)) == "x"   ~ "TRUE",
      str_detect(c3, "\\(x\\)")           ~ "CONDITIONAL",
      TRUE                                ~ c3
    )
  ) |>
  mutate(
    row_kind = case_when(
      !is.na(obergruppe) & is.na(notation) &
        is.na(stichwoerter) & is.na(erklaerung)            ~ "subheader",
      !is.na(obergruppe) & is.na(notation) &
        (!is.na(stichwoerter) | !is.na(erklaerung))        ~ "range_rule",
      is.na(obergruppe)  & !is.na(notation)                ~ "notation_rule",
      !is.na(obergruppe) & !is.na(notation)                ~ "ambiguous_both",
      is.na(obergruppe)  & is.na(notation)                 ~ "no_notation",
      TRUE                                                 ~ "other"
    ),
    notes = case_when(
      row_kind == "ambiguous_both"  ~ "REVIEW_both_filled",
      row_kind == "no_notation"     ~ "REVIEW_no_notation",
      !nicht_belegt %in% c("","TRUE","CONDITIONAL") ~
        paste0("REVIEW_nichtbelegt:", nicht_belegt_raw),
      TRUE                          ~ ""
    )
  )


# -----------------------------------------------------------------------------
# 7. Reports + save
# -----------------------------------------------------------------------------

cat(sprintf("\nFinal data rows: %d\n", nrow(rules)))

cat("\nRow kind distribution:\n")
print(rules |> count(row_kind, sort = TRUE))

cat("\nNicht_belegt distribution:\n")
print(rules |> count(nicht_belegt, sort = TRUE))

cat("\nSections (top 15 by rule count):\n")
print(rules |> count(section, sort = TRUE) |> head(15))

cat(sprintf("\nRows flagged for manual review: %d\n",
            sum(rules$notes != "")))
if (any(rules$notes != "")) {
  cat("Sample flagged rows:\n")
  print(rules |> filter(notes != "") |> head(15) |>
          select(section, obergruppe, notation, nicht_belegt, notes))
}

cat("\nFirst 20 data rows:\n")
print(rules |> head(20) |>
        select(section, obergruppe, notation, nicht_belegt, stichwoerter, erklaerung))

out_path <- here("RVK_data", "local_rules_extracted.csv")
write_csv(
  rules |> select(section, obergruppe, notation, nicht_belegt,
                  stichwoerter, erklaerung, row_kind, notes,
                  table_id, row_id),
  out_path, na = ""
)
cat(sprintf("\nSaved to %s\n", out_path))
cat("Open in Excel/LibreOffice for manual review.\n")