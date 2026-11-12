# =============================================================================
# 13_load_holdings.R
# Read the library holdings xlsx files, parse call numbers into bare RVK
# notations, validate thoroughly, and store as a `holdings` table in rvk.db.
#
# Inputs:  RVK_data/HoldingsB500.xlsx, RVK_data/HoldingsB589.xlsx
#          RVK_data/rvk.db
# Outputs: table `holdings` (+ `holdings_fts`) in rvk.db
#          RVK_data/holdings_parse_problems.csv  (rows needing a look)
#
# CHECK THE VALIDATION OUTPUT BEFORE RUNNING 14_embed_holdings.R.
# =============================================================================

library(here)
library(readxl)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)
library(DBI)
library(RSQLite)
library(tidyr)

source(here("RVK_data", "lib_profiles.R"))

db_path <- here("RVK_data", "rvk.db")
stopifnot(file.exists(db_path))
con <- dbConnect(SQLite(), db_path)


# -----------------------------------------------------------------------------
# 1. Reference sets for validation
# -----------------------------------------------------------------------------

rvk_notations <- dbGetQuery(
  con, "SELECT notation FROM rvk WHERE has_range = 0")$notation

local_additions <- if ("local_rules" %in% dbListTables(con)) {
  dbGetQuery(con, "SELECT raw_notation FROM local_rules WHERE is_local_addition = 1")$raw_notation |>
    str_trim()
} else character(0)

valid_notations <- union(rvk_notations, local_additions)
cat(sprintf("Reference: %d RVK notations + %d local additions.\n",
            length(rvk_notations), length(local_additions)))


# -----------------------------------------------------------------------------
# 2. Read and parse one holdings file
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# REPLACEMENT for load_one() in 13_load_holdings.R
# Handles banner rows above the real header, and reads everything as text
# to avoid readxl type-guessing warnings.
# ---------------------------------------------------------------------------

find_col <- function(nms, pattern) {
  hit <- which(str_detect(nms, regex(pattern, ignore_case = TRUE)))
  if (length(hit) == 0) NA_integer_ else hit[1]
}

# Look through the first `max_scan` rows for the one that contains the
# expected column headers. Returns the number of rows to skip.
detect_header_row <- function(path, max_scan = 15L) {
  probe <- suppressWarnings(read_excel(
    path, col_names = FALSE, n_max = max_scan, col_types = "text",
    .name_repair = "minimal"
  ))
  for (i in seq_len(nrow(probe))) {
    vals <- as.character(unlist(probe[i, ]))
    vals <- vals[!is.na(vals)]
    if (length(vals) == 0) next
    has_call  <- any(str_detect(vals, regex("Permanent\\s*Call\\s*Number", ignore_case = TRUE)))
    has_title <- any(str_detect(vals, regex("^\\s*Title\\s*$", ignore_case = TRUE)))
    if (has_call && has_title) return(i - 1L)   # skip everything above
  }
  NA_integer_
}

load_one <- function(profile_id, spec) {
  path <- here("RVK_data", spec$file)
  if (!file.exists(path)) {
    warning(sprintf("File not found, skipping: %s", path))
    return(NULL)
  }
  cat(sprintf("\n=== %s (%s) ===\n", profile_id, spec$file))
  
  skip_n <- detect_header_row(path)
  if (is.na(skip_n)) {
    probe <- suppressWarnings(read_excel(path, col_names = FALSE, n_max = 15,
                                         col_types = "text",
                                         .name_repair = "minimal"))
    cat("  First 15 rows, first 8 columns, for diagnosis:\n")
    print(as.data.frame(probe[, seq_len(min(8, ncol(probe)))]))
    stop(sprintf("Could not locate a header row in %s.", spec$file))
  }
  cat(sprintf("  header row detected: skipping %d row(s) above it\n", skip_n))
  
  raw <- suppressWarnings(read_excel(
    path, skip = skip_n, col_types = "text", .name_repair = "minimal"
  ))
  nms <- names(raw)
  cat(sprintf("  columns: %d | rows read: %d\n", length(nms), nrow(raw)))
  
  ci_call  <- find_col(nms, "^\\s*Permanent\\s*Call\\s*Number")
  ci_title <- find_col(nms, "^\\s*Title\\s*$")
  ci_mms   <- find_col(nms, "MMS\\s*Id")
  ci_date  <- find_col(nms, "Publication\\s*Date")
  
  if (is.na(ci_call) || is.na(ci_title)) {
    stop(sprintf("Could not find required columns in %s. Names: %s",
                 spec$file, paste(nms, collapse = " | ")))
  }
  cat(sprintf("  call number col: %d | title col: %d | mms col: %s\n",
              ci_call, ci_title, ifelse(is.na(ci_mms), "none", ci_mms)))
  
  df <- tibble(
    profile     = profile_id,
    mms_id      = if (is.na(ci_mms))  NA_character_ else as.character(raw[[ci_mms]]),
    call_number = as.character(raw[[ci_call]]),
    title       = as.character(raw[[ci_title]]),
    pub_date    = if (is.na(ci_date)) NA_character_ else as.character(raw[[ci_date]])
  ) |>
    # drop trailing blank rows that Excel exports sometimes carry
    filter(!(is.na(call_number) & is.na(title)))
  
  cat(sprintf("  rows after dropping blanks: %d\n", nrow(df)))
  # Merged Excel cells leave the continuation rows blank. Journals and
  # multi-volume works produce the same pattern. Filling downward only within
  # runs of identical titles is safe: a blank can never inherit a call number
  # from a different book.
  
  n_blank_before <- sum(is.na(df$call_number) | !nzchar(trimws(df$call_number)))
  
  df <- df |>
    mutate(call_number = if_else(nzchar(trimws(coalesce(call_number, ""))),
                                 call_number, NA_character_),
           .title_key  = coalesce(title, "\u0001"),
           .title_run  = cumsum(.title_key != lag(.title_key, default = "\u0002"))) |>
    group_by(.title_run) |>
    tidyr::fill(call_number, .direction = "down") |>
    ungroup() |>
    select(-.title_key, -.title_run)
  
  n_blank_after <- sum(is.na(df$call_number))
  cat(sprintf("  blank call numbers: %d -> %d (filled %d from identical preceding title)\n",
              n_blank_before, n_blank_after, n_blank_before - n_blank_after))
  p <- parse_call_number(df$call_number)
  df$notation     <- p$notation
  df$parse_method <- p$method
  df$exclude_p    <- spec$exclude_p
  df
}


all_raw <- imap(HOLDINGS_SOURCES, ~ load_one(.y, .x)) |> compact() |> bind_rows()
cat(sprintf("\nTotal rows across all files: %d\n", nrow(all_raw)))


# -----------------------------------------------------------------------------
# 3. Validation
# -----------------------------------------------------------------------------

cat("\n==================== VALIDATION ====================\n")

cat("\n--- Parse method distribution ---\n")
print(all_raw |> count(profile, parse_method))

cat("\n--- Unparseable call numbers ---\n")
unparsed <- all_raw |> filter(is.na(notation))
cat(sprintf("  %d rows (%.2f%%)\n", nrow(unparsed),
            100 * nrow(unparsed) / nrow(all_raw)))
if (nrow(unparsed) > 0) {
  print(unparsed |> count(profile, call_number, sort = TRUE) |> head(25))
}

cat("\n--- Library prefixes seen ---\n")
print(all_raw |>
        mutate(prefix = str_extract(call_number, "^[A-Za-z]+")) |>
        count(profile, prefix, sort = TRUE) |> head(15))

cat("\n--- Parsed notations not found in RVK or local additions ---\n")
unknown <- all_raw |>
  filter(!is.na(notation), !notation %in% valid_notations)
cat(sprintf("  %d rows, %d distinct notations\n",
            nrow(unknown), n_distinct(unknown$notation)))
if (nrow(unknown) > 0) {
  print(unknown |> count(profile, notation, sort = TRUE) |> head(30))
}

cat("\n--- Empty or very short titles ---\n")
bad_title <- all_raw |>
  filter(is.na(title) | nchar(str_trim(title)) < 5)
cat(sprintf("  %d rows\n", nrow(bad_title)))
if (nrow(bad_title) > 0) print(bad_title |> select(profile, call_number, title) |> head(10))

cat("\n--- P-branch (law) records ---\n")
print(all_raw |>
        filter(!is.na(notation), str_starts(notation, "P")) |>
        count(profile, name = "p_records"))

cat("\n--- Title length distribution (chars) ---\n")
print(all_raw |>
        filter(!is.na(title)) |>
        group_by(profile) |>
        summarise(min = min(nchar(title)), median = median(nchar(title)),
                  mean = round(mean(nchar(title))), max = max(nchar(title)),
                  .groups = "drop"))

cat("\n--- Duplicate MMS Ids ---\n")
if (all(is.na(all_raw$mms_id))) {
  cat("  no MMS Id column\n")
} else {
  dup <- all_raw |> filter(!is.na(mms_id)) |> count(mms_id, sort = TRUE) |> filter(n > 1)
  cat(sprintf("  %d duplicated MMS Ids (%d extra rows)\n",
              nrow(dup), sum(dup$n) - nrow(dup)))
  if (nrow(dup) > 0) print(head(dup, 10))
}


# -----------------------------------------------------------------------------
# 4. Build the clean holdings set
# -----------------------------------------------------------------------------

# One MMS Id = one bibliographic record = one notation. Copies, volumes and
# item records must collapse to a single row, otherwise a heavily-held title
# would dominate its own k-NN neighbourhood and drown out other candidates.
# Rows without an MMS Id get a synthetic unique key so they are never merged.

holdings <- all_raw |>
  filter(!is.na(notation),
         notation %in% valid_notations,
         !is.na(title), nchar(str_trim(title)) >= 5) |>
  filter(!(exclude_p & str_starts(notation, "P"))) |>
  mutate(title = str_squish(title)) |>
  mutate(dedup_key = if_else(is.na(mms_id) | !nzchar(mms_id),
                             paste0("__norow", row_number()),
                             mms_id))

n_before_dedup <- nrow(holdings)

holdings <- holdings |>
  distinct(profile, dedup_key, .keep_all = TRUE) |>
  # residual safety net: identical title+notation from different bib records
  distinct(profile, notation, title, .keep_all = TRUE) |>
  mutate(holding_id = row_number()) |>
  select(holding_id, profile, mms_id, notation, title, pub_date, call_number)

cat(sprintf("\nDeduplication: %d -> %d records (%d duplicates removed)\n",
            n_before_dedup, nrow(holdings), n_before_dedup - nrow(holdings)))

# How concentrated is the collection? Useful for tuning k later.
cat("\n--- Records per notation ---\n")
print(holdings |>
        count(profile, notation) |>
        group_by(profile) |>
        summarise(notations = n(),
                  median_records = median(n),
                  p90_records    = quantile(n, 0.9),
                  max_records    = max(n),
                  singletons     = sum(n == 1),
                  .groups = "drop"))

cat("\n==================== CLEAN SET ====================\n")
print(holdings |> count(profile, name = "records"))

cat("\n--- Distinct notations used per profile ---\n")
print(holdings |> group_by(profile) |>
        summarise(distinct_notations = n_distinct(notation),
                  records = n(),
                  median_per_notation = median(table(notation)),
                  .groups = "drop"))

cat("\n--- Top 20 notations by record count (all profiles) ---\n")
top_n_tbl <- holdings |> count(notation, sort = TRUE) |> head(20)
info <- dbGetQuery(con, sprintf(
  "SELECT notation, benennung FROM rvk WHERE notation IN (%s)",
  paste0("'", top_n_tbl$notation, "'", collapse = ", ")))
print(top_n_tbl |> left_join(as_tibble(info), by = "notation"))

cat("\n--- Coverage of the five problem notations from the eval ---\n")
probe <- c("MS 3600", "DK 1010", "DK 1020", "DF 3000", "DG 5000", "MG 32000",
           "MD 6250", "MR 2600", "CQ 5100", "CU 3400")
print(holdings |> filter(notation %in% probe) |>
        count(profile, notation) |>
        arrange(notation, profile))


# -----------------------------------------------------------------------------
# 5. Write to SQLite
# -----------------------------------------------------------------------------

dbWriteTable(con, "holdings", holdings, overwrite = TRUE)
dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_hold_profile ON holdings(profile)")
dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_hold_notation ON holdings(notation)")

# FTS over titles (keyword channel over holdings; optional at query time).
dbExecute(con, "DROP TABLE IF EXISTS holdings_fts")
dbExecute(con, "
  CREATE VIRTUAL TABLE holdings_fts USING fts5(
    holding_id UNINDEXED, profile UNINDEXED, title,
    tokenize='unicode61 remove_diacritics 2'
  )
")
dbExecute(con, "
  INSERT INTO holdings_fts(holding_id, profile, title)
  SELECT holding_id, profile, title FROM holdings
")

# Add a rule_set column to local_rules so multiple libraries can coexist.
lr_cols <- dbListFields(con, "local_rules")
if (!"rule_set" %in% lr_cols) {
  dbExecute(con, "ALTER TABLE local_rules ADD COLUMN rule_set TEXT")
  dbExecute(con, "UPDATE local_rules SET rule_set = 'social'")
  cat("\nAdded rule_set column to local_rules (all rows = 'social').\n")
}

dbExecute(con, "DELETE FROM rvk_meta WHERE key IN ('holdings_loaded_at','holdings_n')")
dbExecute(con, sprintf(
  "INSERT INTO rvk_meta (key, value) VALUES ('holdings_loaded_at','%s'), ('holdings_n','%d')",
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), nrow(holdings)))


# -----------------------------------------------------------------------------
# 6. Save problem rows for review
# -----------------------------------------------------------------------------

problems <- bind_rows(
  unparsed |> mutate(problem = "call number unparseable"),
  unknown  |> mutate(problem = "notation not in RVK or local additions"),
  bad_title |> mutate(problem = "title missing or too short")
) |>
  select(profile, call_number, notation, title, problem)

if (nrow(problems) > 0) {
  write_csv(problems, here("RVK_data", "holdings_parse_problems.csv"))
  cat(sprintf("\n%d problem rows written to holdings_parse_problems.csv\n",
              nrow(problems)))
} else {
  cat("\nNo problem rows.\n")
}

dbDisconnect(con)
cat(sprintf("\nWrote %d holdings records to rvk.db.\n", nrow(holdings)))
cat("Review the validation output above before running 14_embed_holdings.R.\n")
