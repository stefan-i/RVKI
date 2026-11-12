# =============================================================================
# 11_load_local_rules.R  (v2)
# Parse the cleaned local-rules CSV, validate against the RVK database, and
# store as a `local_rules` table inside rvk.db.
#
# v2 changes:
#   - reads the new "lokale Notation" column -> is_local_addition
#   - drops all P-branch rules (library uses the St. Gallen Swiss law
#     adaptation, which is out of scope; a disclaimer is added later in the
#     judge step instead)
#   - local additions are no longer flagged as typos; instead we flag the
#     inverse case (marked local but DOES exist in RVK)
#
# Inputs:  RVK_data/Local_rules_v2.csv  (semicolon, UTF-8, 5 columns)
#          RVK_data/rvk.db
# Output:  table `local_rules` + `local_rules_fts` in rvk.db
#          RVK_data/local_rules_validation.csv (problem rows, if any)
# =============================================================================

library(here)
library(readr)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)
library(DBI)
library(RSQLite)

source(here("RVK_data", "lib_local_rules.R"))


# -----------------------------------------------------------------------------
# 1. Load CSV and map columns by name
# -----------------------------------------------------------------------------

csv_path <- here("RVK_data", "Local_rules_v2.csv")
stopifnot(file.exists(csv_path))

raw <- read_delim(
  csv_path, delim = ";",
  locale = locale(encoding = "UTF-8"),
  show_col_types = FALSE,
  col_types = cols(.default = col_character()),
  name_repair = "unique_quiet"
)

# Match the five expected columns by leading keyword, so exact spelling of
# the long German headers (and any trailing empty column) doesn't matter.
find_col <- function(pattern) {
  hit <- which(str_detect(names(raw), regex(pattern, ignore_case = TRUE)))
  if (length(hit) == 0) NA_integer_ else hit[1]
}

col_map <- c(
  notation_raw     = find_col("^Notation"),
  nicht_belegt_raw = find_col("^nicht\\s*belegt"),
  lokal_raw        = find_col("^lokale\\s*Notation"),
  stichwoerter     = find_col("^Stichw"),
  erklaerung       = find_col("^Erg")
)

cat("Detected column mapping (name -> source column index):\n")
print(col_map)
if (any(is.na(col_map))) {
  stop("Could not find all expected columns. Actual names: ",
       paste(names(raw), collapse = " | "))
}

rules_in <- tibble(
  notation_raw     = raw[[col_map[["notation_raw"]]]],
  nicht_belegt_raw = raw[[col_map[["nicht_belegt_raw"]]]],
  lokal_raw        = raw[[col_map[["lokal_raw"]]]],
  stichwoerter     = raw[[col_map[["stichwoerter"]]]],
  erklaerung       = raw[[col_map[["erklaerung"]]]]
) |>
  filter(!is.na(notation_raw), nzchar(str_trim(notation_raw)))

cat(sprintf("\nLoaded %d rule rows.\n", nrow(rules_in)))


# -----------------------------------------------------------------------------
# 2. Parse notation field
# -----------------------------------------------------------------------------

parsed <- map_dfr(rules_in$notation_raw, parse_rule_notation)

is_x <- function(x) str_to_lower(str_trim(coalesce(x, ""))) == "x"

rules_all <- bind_cols(rules_in |> select(-notation_raw), parsed) |>
  mutate(
    nicht_belegt      = is_x(nicht_belegt_raw),
    is_local_addition = is_x(lokal_raw),
    specificity       = unname(RULE_SPECIFICITY[type]),
    specificity       = if_else(is.na(specificity), 0L, specificity)
  )

cat("\nRule types (before dropping P):\n")
print(rules_all |> count(type))
cat(sprintf("Marked as local addition: %d\n", sum(rules_all$is_local_addition)))


# -----------------------------------------------------------------------------
# 3. Drop P-branch rules (St. Gallen law adaptation is out of scope)
# -----------------------------------------------------------------------------
# The library classifies law using a regional Swiss adaptation that is not
# part of vanilla RVK, so these rules can reference notations that do not
# exist here. They are dropped entirely; the "consult the special edition"
# disclaimer is attached later, in the judge/output step, based purely on a
# notation starting with "P".

starts_with_P <- function(x) !is.na(x) & str_starts(x, "P")

rules_all <- rules_all |>
  mutate(
    is_p_rule = case_when(
      type == "letter_range" ~ starts_with_P(letter_start) | starts_with_P(letter_end),
      TRUE                   ~ starts_with_P(letters)
    )
  )

n_p <- sum(rules_all$is_p_rule)
cat(sprintf("\nDropping %d P-branch rules (law, out of scope).\n", n_p))
if (n_p > 0) {
  cat("  Examples: ",
      paste(head(rules_all$raw[rules_all$is_p_rule], 8), collapse = ", "), "\n")
}

rules <- rules_all |>
  filter(!is_p_rule) |>
  mutate(rule_id = row_number(), rule_set = "social") |>
  select(rule_id, rule_set, raw_notation = raw, type, letters, num_start, num_end,
         letter_start, letter_end, nicht_belegt, is_local_addition,
         stichwoerter, erklaerung, specificity)

cat(sprintf("Rules retained: %d\n", nrow(rules)))


# -----------------------------------------------------------------------------
# 4. Validate against the RVK database
# -----------------------------------------------------------------------------

con <- dbConnect(SQLite(), here("RVK_data", "rvk.db"))
rvk_notations <- dbGetQuery(con, "SELECT notation FROM rvk WHERE has_range = 0")$notation
cat(sprintf("\nLoaded %d assignable RVK notations for validation.\n",
            length(rvk_notations)))

cat("Counting matches per rule (this takes ~30-60s)...\n")
rvk_parsed <- parse_rvk_notation(rvk_notations)

count_matches <- function(r) {
  switch(
    r$type,
    "single" =
      sum(!is.na(rvk_parsed$n_letters) & rvk_parsed$n_letters == r$letters &
          !is.na(rvk_parsed$n_number)  & rvk_parsed$n_number == r$num_start),
    "numeric_range" =
      sum(!is.na(rvk_parsed$n_letters) & rvk_parsed$n_letters == r$letters &
          !is.na(rvk_parsed$n_number) &
          rvk_parsed$n_number >= r$num_start & rvk_parsed$n_number <= r$num_end),
    "letter_prefix" =
      sum(!is.na(rvk_parsed$n_letters) & startsWith(rvk_parsed$n_letters, r$letters)),
    "letter_range" =
      sum(!is.na(rvk_parsed$n_letters) &
          rvk_parsed$n_letters >= r$letter_start &
          rvk_parsed$n_letters <= r$letter_end),
    0L
  )
}

rules$n_rvk_matches <- map_int(seq_len(nrow(rules)), ~ count_matches(rules[.x, ]))


# -----------------------------------------------------------------------------
# 5. Flag problems
# -----------------------------------------------------------------------------
# A local addition matching 0 RVK notations is EXPECTED, not a problem.
# What is worth reviewing:
#   - unparseable notation strings
#   - 0 matches while NOT marked as a local addition (likely typo)
#   - marked as local addition but the notation DOES exist in RVK
#     (either mismarked, or RVK has since created that notation)

rules <- rules |>
  mutate(
    problem = case_when(
      type == "UNPARSEABLE" ~ "unparseable notation",
      n_rvk_matches == 0 & !is_local_addition ~
        "matches no RVK notation and not marked as local addition (likely typo)",
      n_rvk_matches > 0 & is_local_addition ~
        "marked as local addition but exists in RVK (check marking)",
      TRUE ~ ""
    )
  )

problems <- rules |> filter(problem != "")

cat(sprintf("\n%d rules flagged for review:\n", nrow(problems)))
if (nrow(problems) > 0) {
  print(problems |>
          select(rule_id, raw_notation, type, is_local_addition,
                 n_rvk_matches, problem),
        n = min(nrow(problems), 50))
  write_csv(
    problems |> select(rule_id, raw_notation, type, nicht_belegt,
                       is_local_addition, stichwoerter, erklaerung,
                       n_rvk_matches, problem),
    here("RVK_data", "local_rules_validation.csv")
  )
  cat("Problem rows written to local_rules_validation.csv\n")
} else {
  cat("  None. Rules validate cleanly.\n")
}

cat("\nLocal additions retained (should all show 0 RVK matches):\n")
print(rules |> filter(is_local_addition) |>
        select(rule_id, raw_notation, nicht_belegt, n_rvk_matches, stichwoerter),
      n = 40)

cat("\nForbidden (nicht_belegt) rules and how many RVK notations they block:\n")
print(rules |> filter(nicht_belegt) |>
        summarise(n_rules = n(), n_notations_blocked = sum(n_rvk_matches)))

cat("\nMatch-count distribution by type:\n")
print(rules |> group_by(type) |>
        summarise(rules = n(),
                  min_matches    = min(n_rvk_matches),
                  median_matches = median(n_rvk_matches),
                  max_matches    = max(n_rvk_matches),
                  .groups = "drop"))


# -----------------------------------------------------------------------------
# 6. Write to SQLite
# -----------------------------------------------------------------------------

dbWriteTable(con, "local_rules", rules, overwrite = TRUE)
dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_lr_type ON local_rules(type)")
dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_lr_letters ON local_rules(letters)")
dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_lr_local ON local_rules(is_local_addition)")

dbExecute(con, "DROP TABLE IF EXISTS local_rules_fts")
dbExecute(con, "
  CREATE VIRTUAL TABLE local_rules_fts USING fts5(
    rule_id UNINDEXED, raw_notation, stichwoerter, erklaerung,
    tokenize='unicode61 remove_diacritics 2'
  )
")
dbExecute(con, "
  INSERT INTO local_rules_fts(rule_id, raw_notation, stichwoerter, erklaerung)
  SELECT rule_id, raw_notation, coalesce(stichwoerter,''), coalesce(erklaerung,'')
  FROM local_rules
")

dbExecute(con, "DELETE FROM rvk_meta WHERE key IN ('local_rules_loaded_at','local_rules_n')")
dbExecute(con, sprintf(
  "INSERT INTO rvk_meta (key, value) VALUES ('local_rules_loaded_at','%s'), ('local_rules_n','%d')",
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), nrow(rules)
))

dbDisconnect(con)

cat(sprintf("\nWrote %d rules to local_rules table in rvk.db.\n", nrow(rules)))
cat("Done.\n")
