# =============================================================================
# 02_validate_rvk_db.R
# Consistency and completeness checks for the RVK SQLite database.
# Read-only — safe to re-run as often as you like.
# =============================================================================

library(here)
library(DBI)
library(RSQLite)
library(dplyr)
library(stringr)
library(tibble)

db_path <- here("RVK_data", "rvk.db")
stopifnot(file.exists(db_path))
con <- dbConnect(SQLite(), db_path)

# Convenience: pull the full rvk table into memory once for fast checks.
rvk <- dbGetQuery(con, "SELECT * FROM rvk") |> as_tibble()
cat(sprintf("Loaded %d nodes from %s\n\n", nrow(rvk), db_path))


# -----------------------------------------------------------------------------
# Check 1: Basic counts and structural overview
# -----------------------------------------------------------------------------
cat("=== Check 1: Structural overview ===\n")

cat(sprintf("  Total nodes:        %d\n", nrow(rvk)))
cat(sprintf("  Range entries:      %d (%.1f%%)\n",
            sum(rvk$has_range), 100 * mean(rvk$has_range)))
cat(sprintf("  Leaf nodes:         %d (%.1f%%)\n",
            sum(rvk$is_leaf), 100 * mean(rvk$is_leaf)))
cat(sprintf("  Nodes with register:%d (%.1f%%)\n",
            sum(!is.na(rvk$register)), 100 * mean(!is.na(rvk$register))))
cat(sprintf("  Nodes with bemerkung:%d (%.1f%%)\n",
            sum(!is.na(rvk$bemerkung)), 100 * mean(!is.na(rvk$bemerkung))))
cat(sprintf("  Nodes missing benennung: %d\n", sum(is.na(rvk$benennung))))
cat(sprintf("  Top-level roots:    %d\n", sum(rvk$depth == 0)))
cat(sprintf("  Max depth:          %d\n", max(rvk$depth)))
cat("\n")


# -----------------------------------------------------------------------------
# Check 2: Notation uniqueness
# -----------------------------------------------------------------------------
cat("=== Check 2: Notation uniqueness ===\n")
dupes <- rvk |> count(notation, sort = TRUE) |> filter(n > 1)
if (nrow(dupes) == 0) {
  cat("  OK — all notations unique.\n")
} else {
  cat(sprintf("  WARNING: %d duplicated notations:\n", nrow(dupes)))
  print(head(dupes, 20))
}
cat("\n")


# -----------------------------------------------------------------------------
# Check 3: Parent integrity
# -----------------------------------------------------------------------------
cat("=== Check 3: Parent integrity ===\n")
all_notations <- rvk$notation
orphans <- rvk |>
  filter(depth > 0L, !parent_notation %in% all_notations)
if (nrow(orphans) == 0) {
  cat("  OK — every non-root node has a valid parent.\n")
} else {
  cat(sprintf("  WARNING: %d nodes have an unknown parent_notation:\n", nrow(orphans)))
  print(head(orphans |> select(notation, parent_notation, benennung), 10))
}
cat("\n")


# -----------------------------------------------------------------------------
# Check 4: Depth consistency
# -----------------------------------------------------------------------------
cat("=== Check 4: Depth consistency ===\n")
parent_depth_map <- setNames(rvk$depth, rvk$notation)
check <- rvk |>
  filter(depth > 0L) |>
  mutate(expected = parent_depth_map[parent_notation] + 1L) |>
  filter(depth != expected)
if (nrow(check) == 0) {
  cat("  OK — all depths consistent with parent.\n")
} else {
  cat(sprintf("  WARNING: %d nodes have inconsistent depth:\n", nrow(check)))
  print(head(check |> select(notation, depth, expected, parent_notation), 10))
}
cat("\n")


# -----------------------------------------------------------------------------
# Check 5: Path consistency
# -----------------------------------------------------------------------------
cat("=== Check 5: Path consistency ===\n")
parent_pfad_map      <- setNames(rvk$pfad, rvk$notation)
parent_benennung_map <- setNames(rvk$benennung, rvk$notation)

expected_pfad <- ifelse(
  is.na(parent_pfad_map[rvk$parent_notation]),
  parent_benennung_map[rvk$parent_notation],
  paste(parent_pfad_map[rvk$parent_notation],
        parent_benennung_map[rvk$parent_notation], sep = " > ")
)

check <- tibble(
  notation = rvk$notation,
  depth    = rvk$depth,
  actual   = rvk$pfad,
  expected = expected_pfad
) |>
  filter(depth > 0L,
         !((is.na(actual) & is.na(expected)) | (actual == expected)))

if (nrow(check) == 0) {
  cat("  OK — all pfad values consistent with parent.\n")
} else {
  cat(sprintf("  WARNING: %d nodes have inconsistent pfad:\n", nrow(check)))
  print(head(check, 10))
}
cat("\n")


# -----------------------------------------------------------------------------
# Check 6: Top-level roots
# -----------------------------------------------------------------------------
cat("=== Check 6: Top-level structure ===\n")
roots <- rvk |> filter(depth == 0L) |> arrange(notation)
print(roots |> select(notation, benennung))
cat("\n")


# -----------------------------------------------------------------------------
# Check 7: Spot-check well-known notations
# -----------------------------------------------------------------------------
cat("=== Check 7: Spot-checks ===\n")

spot_notations <- c(
  "MK 5000", "MK 5050", "AP 10000", "MD 6000", "MD 6250",
  "MG 10000", "MQ 1600", "MR 1100"
)

found <- rvk |> filter(notation %in% spot_notations) |>
  select(notation, benennung, depth, register) |>
  arrange(notation)
print(found)

missing_spots <- setdiff(spot_notations, found$notation)
if (length(missing_spots) > 0) {
  cat("  Not found:", paste(missing_spots, collapse = ", "), "\n")
}
cat("\n")


# -----------------------------------------------------------------------------
# Check 8: Register field shape
# -----------------------------------------------------------------------------
cat("=== Check 8: Register field shape ===\n")
with_reg <- rvk |> filter(!is.na(register))
reg_term_counts <- str_count(with_reg$register, ";") + 1L
cat(sprintf("  Nodes with register: %d\n", nrow(with_reg)))
cat(sprintf("  Register terms per node — min: %d, median: %.0f, mean: %.1f, max: %d\n",
            min(reg_term_counts), median(reg_term_counts),
            mean(reg_term_counts), max(reg_term_counts)))

suspect <- with_reg |>
  filter(str_detect(register, "(^|;\\s*);") | str_detect(register, ";\\s*$") |
           register == "")
if (nrow(suspect) == 0) {
  cat("  OK — no empty/malformed register entries.\n")
} else {
  cat(sprintf("  WARNING: %d suspicious register strings:\n", nrow(suspect)))
  print(head(suspect |> select(notation, register), 5))
}
cat("\n")


# -----------------------------------------------------------------------------
# Check 9: Encoding sanity
# -----------------------------------------------------------------------------
cat("=== Check 9: Encoding sanity (German umlauts) ===\n")
sample <- rvk |>
  filter(str_detect(benennung, "ö|ä|ü|ß")) |>
  slice_sample(n = 5)
print(sample |> select(notation, benennung))
cat("\n")


# -----------------------------------------------------------------------------
# Check 10: rich_text spot check
# -----------------------------------------------------------------------------
cat("=== Check 10: rich_text spot check ===\n")
rt <- rvk |> filter(notation %in% c("MD 6000", "MG 10000", "MD 6250"))
for (i in seq_len(nrow(rt))) {
  cat(sprintf("  %s:\n    %s\n\n", rt$notation[i], rt$rich_text[i]))
}


# -----------------------------------------------------------------------------
# Check 11: FTS index coverage sample
# -----------------------------------------------------------------------------
cat("=== Check 11: FTS coverage sample ===\n")
set.seed(42)
sample_nodes <- rvk |> filter(!is.na(register)) |> slice_sample(n = 20)
n_found <- 0L
for (i in seq_len(nrow(sample_nodes))) {
  first_term <- str_split(sample_nodes$register[i], ";\\s*")[[1]][1]
  safe_term <- paste0("\"", str_replace_all(first_term, "\"", "\"\""), "\"")
  q <- sprintf("SELECT notation FROM rvk_fts WHERE rvk_fts MATCH %s LIMIT 50",
               dbQuoteString(con, safe_term))
  hits <- tryCatch(dbGetQuery(con, q), error = function(e) data.frame(notation = character(0)))
  if (sample_nodes$notation[i] %in% hits$notation) n_found <- n_found + 1L
}
cat(sprintf("  %d of %d sampled nodes found via their own first register term.\n",
            n_found, nrow(sample_nodes)))
cat("\n")


# -----------------------------------------------------------------------------
# Check 12: rich_text length distribution (embedding planning)
# -----------------------------------------------------------------------------
cat("=== Check 12: rich_text length distribution ===\n")
char_lens <- nchar(rvk$rich_text)
cat(sprintf("  Chars: min %d, median %d, mean %.0f, 95%% %.0f, max %d\n",
            min(char_lens), median(char_lens), mean(char_lens),
            quantile(char_lens, 0.95), max(char_lens)))
cat(sprintf("  Approx tokens: median %.0f, mean %.0f, max %.0f\n",
            median(char_lens) / 4, mean(char_lens) / 4, max(char_lens) / 4))
cat(sprintf("  Estimated total tokens: %.1f million (cost ~$%.2f at $0.02/M)\n",
            sum(char_lens) / 4 / 1e6,
            sum(char_lens) / 4 / 1e6 * 0.02))
cat("\n")


dbDisconnect(con)
cat("All checks complete.\n")