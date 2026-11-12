# =============================================================================
# 03_fix_encoding.R
# Decode literal HTML numeric character entities (&#NNN; and &#xNNN;) that
# survived XML parsing because they were double-escaped in the source.
# Also decodes a handful of named entities (&amp;, &lt;, &gt;, &quot;, &apos;).
#
# Safe to re-run: idempotent.
# =============================================================================

library(here)
library(DBI)
library(RSQLite)
library(dplyr)
library(stringr)
library(tibble)
library(tidyr)

db_path <- here("RVK_data", "rvk.db")
stopifnot(file.exists(db_path))


# -----------------------------------------------------------------------------
# 1. Entity-decoding helper
# -----------------------------------------------------------------------------
# Vectorised over a character vector. Only processes rows that actually
# contain an entity pattern, so it's fast even on a 783k-row column.

decode_entities <- function(x) {
  result   <- x
  na_mask  <- is.na(x)
  to_fix   <- !na_mask & str_detect(replace_na(x, ""), "&(#|amp;|lt;|gt;|quot;|apos;)")
  for (i in which(to_fix)) {
    s <- x[i]
    
    # Decimal numeric entities: &#NNN;
    while (str_detect(s, "&#\\d+;")) {
      m    <- str_extract(s, "&#\\d+;")
      code <- as.integer(str_match(m, "&#(\\d+);")[, 2])
      s    <- str_replace(s, fixed(m), intToUtf8(code))
    }
    
    # Hex numeric entities: &#xNNN;
    while (str_detect(s, "&#x[0-9a-fA-F]+;")) {
      m    <- str_extract(s, "&#x[0-9a-fA-F]+;")
      hex  <- str_match(m, "&#x([0-9a-fA-F]+);")[, 2]
      code <- strtoi(hex, base = 16)
      s    <- str_replace(s, fixed(m), intToUtf8(code))
    }
    
    # Common named entities. &amp; must be done LAST.
    s <- str_replace_all(s, "&lt;",   "<")
    s <- str_replace_all(s, "&gt;",   ">")
    s <- str_replace_all(s, "&quot;", "\"")
    s <- str_replace_all(s, "&apos;", "'")
    s <- str_replace_all(s, "&amp;",  "&")
    
    result[i] <- s
  }
  result
}


# -----------------------------------------------------------------------------
# 2. Load, decode, and rebuild rich_text
# -----------------------------------------------------------------------------

con <- dbConnect(SQLite(), db_path)
rvk <- dbGetQuery(con, "SELECT * FROM rvk") |> as_tibble()
cat(sprintf("Loaded %d rows.\n", nrow(rvk)))

# Count affected rows in each column before fixing (for reporting).
needs <- function(x) sum(!is.na(x) & str_detect(replace_na(x, ""), "&(#|amp;|lt;|gt;|quot;|apos;)"))
cat(sprintf("  benennung needing fix: %d\n", needs(rvk$benennung)))
cat(sprintf("  register  needing fix: %d\n", needs(rvk$register)))
cat(sprintf("  bemerkung needing fix: %d\n", needs(rvk$bemerkung)))
cat(sprintf("  pfad      needing fix: %d\n", needs(rvk$pfad)))

cat("\nDecoding...\n")
t0 <- Sys.time()
rvk$benennung <- decode_entities(rvk$benennung)
rvk$register  <- decode_entities(rvk$register)
rvk$bemerkung <- decode_entities(rvk$bemerkung)
rvk$pfad      <- decode_entities(rvk$pfad)
cat(sprintf("Decoded in %.1fs.\n", as.numeric(Sys.time() - t0, units = "secs")))

# Rebuild rich_text from the cleaned fields.
rvk <- rvk |>
  mutate(
    rich_text = paste0(
      "Notation: ", notation, ". ",
      "Benennung: ", coalesce(benennung, ""), ". ",
      if_else(!is.na(pfad),      paste0("Pfad: ", pfad, ". "), ""),
      if_else(!is.na(register),  paste0("Register: ", register, ". "), ""),
      if_else(!is.na(bemerkung), paste0("Bemerkung: ", bemerkung, "."), "")
    ) |> str_squish()
  )


# -----------------------------------------------------------------------------
# 3. Write back to SQLite and rebuild FTS index
# -----------------------------------------------------------------------------

cat("Writing back to SQLite...\n")
dbExecute(con, "DROP TABLE IF EXISTS rvk_fts")
dbWriteTable(con, "rvk", rvk, overwrite = TRUE)

dbExecute(con, "CREATE UNIQUE INDEX idx_rvk_notation ON rvk(notation)")
dbExecute(con, "CREATE INDEX idx_rvk_parent ON rvk(parent_notation)")
dbExecute(con, "CREATE INDEX idx_rvk_depth ON rvk(depth)")

dbExecute(con, "
  CREATE VIRTUAL TABLE rvk_fts USING fts5(
    notation, benennung, pfad, register, bemerkung, rich_text,
    content='rvk', content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
  )
")
dbExecute(con, "
  INSERT INTO rvk_fts(rowid, notation, benennung, pfad, register, bemerkung, rich_text)
  SELECT rowid, notation, benennung, pfad, register, bemerkung, rich_text FROM rvk
")

dbExecute(con, "DELETE FROM rvk_meta WHERE key = 'last_fixed'")
dbExecute(con, sprintf(
  "INSERT INTO rvk_meta (key, value) VALUES ('last_fixed', '%s')",
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
))


# -----------------------------------------------------------------------------
# 4. Verify the fix on the rows we knew were bad
# -----------------------------------------------------------------------------

cat("\n=== Verification: previously-broken rows ===\n")
print(dbGetQuery(con, "
  SELECT notation, benennung, register
  FROM rvk
  WHERE notation IN ('AP 51146','AP 51173','AP 51180','BD 4100 - BD 4101','BD 4282 - BD 4283')
"))

cat("\n=== Remaining entity-like strings (should be near zero) ===\n")
remaining <- dbGetQuery(con, "
  SELECT notation, register FROM rvk
  WHERE register LIKE '%&#%' OR register LIKE '%&amp;%'
  LIMIT 20
")
cat(sprintf("Rows with remaining entity patterns: %d\n", nrow(remaining)))
if (nrow(remaining) > 0) print(remaining)


# -----------------------------------------------------------------------------
# 5. Better FTS diagnostic
# -----------------------------------------------------------------------------
# Two complementary tests:
#   A) Rare-term test: searching for an uncommon register term should return
#      a small result set including the source node.
#   B) Top-K test: ordered by FTS5 bm25 ranking, does the source node appear
#      in the top K results for its own register term?

cat("\n=== FTS diagnostic A: rare-term lookups ===\n")
rare_terms <- c("Verschwörungstheorie", "Klientelismus", "Ethnomethodologie",
                "Europagedanke", "Radikalisierung", "Zivilcourage")
for (term in rare_terms) {
  hits <- dbGetQuery(con, sprintf(
    "SELECT r.notation, r.benennung FROM rvk_fts f JOIN rvk r ON r.rowid = f.rowid
     WHERE rvk_fts MATCH '%s' LIMIT 5", term
  ))
  cat(sprintf("  '%s' -> %d hits, top: %s\n",
              term, nrow(hits),
              if (nrow(hits) > 0) paste(head(hits$notation, 3), collapse=", ") else "(none)"))
}

cat("\n=== FTS diagnostic B: source-node recall in top-K ===\n")
# Sample register nodes, search for first register term ordered by bm25,
# check how often the source node lands in top 5/20/50.
set.seed(123)
sample_nodes <- rvk |> filter(!is.na(register)) |> slice_sample(n = 100)
ranks <- integer(nrow(sample_nodes))
for (i in seq_len(nrow(sample_nodes))) {
  term <- str_split(sample_nodes$register[i], ";\\s*")[[1]][1]
  if (!str_detect(term, "[\\w]")) { ranks[i] <- NA; next }
  # bm25 (lower = better match). Negate for descending order.
  hits <- tryCatch(dbGetQuery(con, sprintf(
    "SELECT r.notation FROM rvk_fts f JOIN rvk r ON r.rowid = f.rowid
     WHERE rvk_fts MATCH %s
     ORDER BY bm25(rvk_fts) LIMIT 100",
    dbQuoteString(con, paste0("\"", str_replace_all(term, "\"", "\"\""), "\""))
  )), error = function(e) data.frame(notation = character(0)))
  pos <- match(sample_nodes$notation[i], hits$notation)
  ranks[i] <- if (is.na(pos)) NA_integer_ else pos
}
cat(sprintf("  Source node found in top 5:   %d / %d\n", sum(ranks <= 5, na.rm=TRUE),  length(ranks)))
cat(sprintf("  Source node found in top 20:  %d / %d\n", sum(ranks <= 20, na.rm=TRUE), length(ranks)))
cat(sprintf("  Source node found in top 50:  %d / %d\n", sum(ranks <= 50, na.rm=TRUE), length(ranks)))
cat(sprintf("  Source node found in top 100: %d / %d\n", sum(ranks <= 100, na.rm=TRUE),length(ranks)))
cat(sprintf("  Source node not found at all: %d\n", sum(is.na(ranks))))

dbDisconnect(con)
cat("\nDone.\n")