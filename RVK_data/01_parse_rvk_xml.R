# =============================================================================
# 01_parse_rvk_xml.R  (v2 — fast bulk extraction)
# Parse the RVK XML classification into a SQLite database with FTS5 search.
#
# Inputs:  RVK_data/rvk.xml
# Outputs: RVK_data/rvk.db
#
# Strategy: instead of recursing node-by-node (slow because each xml2 XPath
# call traverses a subtree), we do a few bulk extractions across all <node>
# elements at once, then reconstruct hierarchy from the flat result.
#
# Expected runtime: 2–10 minutes total.
# =============================================================================

library(here)
library(xml2)
library(DBI)
library(RSQLite)
library(dplyr)
library(stringr)
library(tibble)
library(purrr)


# -----------------------------------------------------------------------------
# 1. Paths and setup
# -----------------------------------------------------------------------------

xml_path <- here("RVK_data", "rvk.xml")
db_path  <- here("RVK_data", "rvk.db")

stopifnot(file.exists(xml_path))
if (file.exists(db_path)) file.remove(db_path)


# -----------------------------------------------------------------------------
# 2. Read the XML
# -----------------------------------------------------------------------------

message("Reading XML...")
t0 <- Sys.time()
doc <- read_xml(xml_path)
message(sprintf("XML loaded in %.1f seconds.",
                as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 3. Bulk extraction of all <node> elements
# -----------------------------------------------------------------------------
# Instead of walking the tree, we grab every <node> in one query. The order
# of results from xml_find_all with "//node" is document order, which is
# exactly depth-first traversal order — so the parent of any node appears
# earlier in the list.

message("Extracting all <node> elements...")
t0 <- Sys.time()
all_nodes <- xml_find_all(doc, "//node")
message(sprintf("Found %d nodes in %.1f seconds.",
                length(all_nodes),
                as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 4. Extract attributes in bulk
# -----------------------------------------------------------------------------
# xml_attr() vectorised over a nodeset processes all nodes in a single
# C-level pass — dramatically faster than per-node XPath queries.

message("Extracting attributes...")
t0 <- Sys.time()

notations   <- xml_attr(all_nodes, "notation")
benennungen <- xml_attr(all_nodes, "benennung")

message(sprintf("Attributes extracted in %.1f seconds.",
                as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 5. Find parent notation for each node (via xml_path)
# -----------------------------------------------------------------------------
# xml_parent() on a nodeset deduplicates (XPath set semantics), so we'd lose
# the 1:1 mapping. Instead, get each node's absolute path, then strip the
# trailing "/children/node[N]" to get its parent's path. Look up the parent
# by path in a hash map.

message("Building parent map via xml_path...")
t0 <- Sys.time()

node_paths <- xml_path(all_nodes)

# Strip the trailing "/children/node" or "/children/node[N]" — that gives
# the path of the enclosing <node>. If nothing strips off, the node is
# top-level (its parent is <classification_scheme>, not another <node>).
parent_paths <- str_remove(node_paths, "/children/node(\\[\\d+\\])?$")
is_top_level <- parent_paths == node_paths

# Map every node's path to its row index, then look up parents.
path_to_idx <- setNames(seq_along(node_paths), node_paths)
parent_idx  <- path_to_idx[parent_paths]
parent_idx[is_top_level] <- NA_integer_

parent_notations <- rep(NA_character_, length(all_nodes))
has_parent <- !is.na(parent_idx)
parent_notations[has_parent] <- notations[parent_idx[has_parent]]

message(sprintf("Parent map built in %.1f seconds. %d nodes have parents.",
                as.numeric(Sys.time() - t0, units = "secs"),
                sum(has_parent)))

# -----------------------------------------------------------------------------
# 6. Extract Register, Bemerkung, and is_leaf in bulk
# -----------------------------------------------------------------------------
# xml_children() returns one flat nodeset of all children of all nodes
# concatenated. We use xml_length() to know how many children each node
# contributed, then build a parent-index vector to split results back.

message("Extracting children data...")
t0 <- Sys.time()

children_list <- xml_children(all_nodes)
n_children    <- xml_length(all_nodes)
child_parent  <- rep(seq_along(all_nodes), times = n_children)

child_names     <- xml_name(children_list)
child_text      <- xml_text(children_list)
child_bemerkung <- xml_attr(children_list, "bemerkung")

# --- Register entries (one per <register> child) ---
is_reg <- child_names == "register"
reg_text   <- str_trim(child_text[is_reg])
reg_parent <- child_parent[is_reg]
keep_reg   <- nzchar(reg_text)
reg_split  <- split(reg_text[keep_reg], reg_parent[keep_reg])
register_full <- rep(NA_character_, length(all_nodes))
register_full[as.integer(names(reg_split))] <-
  vapply(reg_split, paste, character(1), collapse = "; ")

# --- Bemerkung entries (from <content bemerkung="..."> children) ---
is_content   <- child_names == "content"
bem_text     <- child_bemerkung[is_content]
bem_parent   <- child_parent[is_content]
keep_bem     <- !is.na(bem_text) & nzchar(bem_text)
bem_split    <- split(bem_text[keep_bem], bem_parent[keep_bem])
bemerkung_full <- rep(NA_character_, length(all_nodes))
bemerkung_full[as.integer(names(bem_split))] <-
  vapply(bem_split, paste, character(1), collapse = " | ")

# --- is_leaf: TRUE if there's no <children> element ---
has_children_elem <- child_names == "children"
kids_split <- split(has_children_elem, child_parent)
is_leaf_full <- rep(TRUE, length(all_nodes))
nodes_with_any_child <- as.integer(names(kids_split))
is_leaf_full[nodes_with_any_child] <-
  !vapply(kids_split, any, logical(1))

message(sprintf("Children data extracted in %.1f seconds.",
                as.numeric(Sys.time() - t0, units = "secs")))


# -----------------------------------------------------------------------------
# 7. Assemble initial data frame
# -----------------------------------------------------------------------------

message("Assembling data frame...")
t0 <- Sys.time()

rvk_df <- tibble(
  notation        = notations,
  benennung       = benennungen,
  register        = register_full,
  bemerkung       = bemerkung_full,
  parent_notation = parent_notations,
  is_leaf         = is_leaf_full,
  has_range       = str_detect(notations, "\\s-\\s")
) |>
  filter(!is.na(notation))

message(sprintf("Data frame built in %.1f seconds. %d rows.",
                as.numeric(Sys.time() - t0, units = "secs"),
                nrow(rvk_df)))

# Free the XML — we have everything we need.
rm(doc, all_nodes, children_list)
invisible(gc())


# -----------------------------------------------------------------------------
# 8. Compute depth and pfad level-by-level (vectorised)
# -----------------------------------------------------------------------------
# Instead of looping over 783k rows, we process the tree level by level.
# At each level, every node's depth and pfad is derived from its parent's
# values in a single vectorised operation.

message("Computing depth and pfad...")
t0 <- Sys.time()

n <- nrow(rvk_df)
depth <- rep(NA_integer_, n)
pfad  <- rep(NA_character_, n)

# Build a fast lookup from notation -> row index (once).
notation_to_idx <- setNames(seq_len(n), rvk_df$notation)

# Level 0: nodes with no parent (or whose parent isn't in the table).
parent_idx_all <- notation_to_idx[rvk_df$parent_notation]
is_root <- is.na(parent_idx_all)
depth[is_root] <- 0L
pfad[is_root]  <- NA_character_

# Iterate level by level. At each step, find nodes whose parent has its
# depth already filled but the node itself doesn't.
current_level <- 0L
repeat {
  current_level <- current_level + 1L
  
  # Candidates: not yet assigned, parent exists and is at the previous level.
  pending <- which(is.na(depth) & !is.na(parent_idx_all))
  if (length(pending) == 0) break
  
  parent_depth <- depth[parent_idx_all[pending]]
  ready <- pending[!is.na(parent_depth) & parent_depth == current_level - 1L]
  if (length(ready) == 0) break
  
  pi <- parent_idx_all[ready]
  parent_pfad <- pfad[pi]
  parent_benennung <- rvk_df$benennung[pi]
  
  # Build new pfad: parent's pfad + " > " + parent's benennung.
  # Handle the case where parent has no pfad yet (its parent was root).
  new_pfad <- ifelse(
    is.na(parent_pfad),
    parent_benennung,
    ifelse(
      is.na(parent_benennung),
      parent_pfad,
      paste(parent_pfad, parent_benennung, sep = " > ")
    )
  )
  
  depth[ready] <- current_level
  pfad[ready]  <- new_pfad
}

# Any remaining NA depths are nodes whose parent_notation didn't resolve
# (shouldn't happen in clean data, but mark them as roots defensively).
orphan <- is.na(depth)
if (any(orphan)) {
  message(sprintf("  %d orphan nodes (parent not found), treating as roots.",
                  sum(orphan)))
  depth[orphan] <- 0L
}

rvk_df$depth <- depth
rvk_df$pfad  <- pfad
rvk_df$nicht_belegt <- FALSE  # placeholder

message(sprintf("Depth/pfad computed in %.1f seconds. Max depth: %d.",
                as.numeric(Sys.time() - t0, units = "secs"),
                max(depth)))


# -----------------------------------------------------------------------------
# 9. Build rich_text
# -----------------------------------------------------------------------------

rvk_df <- rvk_df |>
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
# 10. Quick sanity check before writing to disk
# -----------------------------------------------------------------------------

cat("\n--- Sample: MD 6000 ---\n")
print(rvk_df |> filter(notation == "MD 6000") |>
        select(notation, benennung, pfad, register))

cat("\n--- Sample: MG 10000 ---\n")
print(rvk_df |> filter(notation == "MG 10000") |>
        select(notation, benennung, pfad))


# -----------------------------------------------------------------------------
# 11. Write to SQLite
# -----------------------------------------------------------------------------

message("Writing to SQLite...")
con <- dbConnect(SQLite(), db_path)

dbWriteTable(con, "rvk", rvk_df, overwrite = TRUE)

dbExecute(con, "CREATE UNIQUE INDEX idx_rvk_notation ON rvk(notation)")
dbExecute(con, "CREATE INDEX idx_rvk_parent ON rvk(parent_notation)")
dbExecute(con, "CREATE INDEX idx_rvk_depth ON rvk(depth)")

dbExecute(con, "
  CREATE VIRTUAL TABLE rvk_fts USING fts5(
    notation,
    benennung,
    pfad,
    register,
    bemerkung,
    rich_text,
    content='rvk',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
  )
")

dbExecute(con, "
  INSERT INTO rvk_fts(rowid, notation, benennung, pfad, register, bemerkung, rich_text)
  SELECT rowid, notation, benennung, pfad, register, bemerkung, rich_text FROM rvk
")

dbExecute(con, "CREATE TABLE rvk_meta (key TEXT PRIMARY KEY, value TEXT)")
dbExecute(con, sprintf(
  "INSERT INTO rvk_meta (key, value) VALUES ('built_at', '%s'), ('n_nodes', '%d')",
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  nrow(rvk_df)
))

dbDisconnect(con)
message(sprintf("Done. Database written to %s (%.1f MB).",
                db_path,
                file.info(db_path)$size / 1024^2))


# -----------------------------------------------------------------------------
# 12. Verification queries
# -----------------------------------------------------------------------------

con <- dbConnect(SQLite(), db_path)

cat("\n--- Total nodes ---\n")
print(dbGetQuery(con, "SELECT COUNT(*) AS n FROM rvk"))

cat("\n--- Depth distribution ---\n")
print(dbGetQuery(con, "SELECT depth, COUNT(*) AS n FROM rvk GROUP BY depth ORDER BY depth"))

cat("\n--- MD 6000 ---\n")
print(dbGetQuery(con, "SELECT notation, benennung, register, pfad FROM rvk WHERE notation = 'MD 6000'"))

cat("\n--- MG 10000 ---\n")
print(dbGetQuery(con, "SELECT notation, benennung, pfad FROM rvk WHERE notation = 'MG 10000'"))

cat("\n--- FTS test: 'Verschwörung' ---\n")
print(dbGetQuery(con, "
  SELECT r.notation, r.benennung, r.register
  FROM rvk_fts f JOIN rvk r ON r.rowid = f.rowid
  WHERE rvk_fts MATCH 'Verschwörung'
  LIMIT 10
"))

cat("\n--- FTS test: 'Radikalisierung' ---\n")
print(dbGetQuery(con, "
  SELECT r.notation, r.benennung, r.register
  FROM rvk_fts f JOIN rvk r ON r.rowid = f.rowid
  WHERE rvk_fts MATCH 'Radikalisierung'
  LIMIT 10
"))

dbDisconnect(con)