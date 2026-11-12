# =============================================================================
# 04_embed_rvk.R
# Generate OpenAI embeddings for all non-range RVK nodes and store them
# as a matrix on disk for fast cosine similarity at query time.
#
# Inputs:  RVK_data/rvk.db    (built and cleaned by scripts 01–03)
# Outputs: RVK_data/embeddings.rds       — final matrix [n_nodes x 768]
#          RVK_data/embeddings_partial/  — per-batch checkpoints (resumable)
#
# Design:
#   - Skip range entries (has_range = TRUE).
#   - Send up to 256 rich_texts per API call (well under OpenAI's 2048 cap,
#     keeps per-call payload reasonable).
#   - Save a checkpoint .rds after every batch. Re-running the script picks
#     up from where the last checkpoint left off.
#   - Retry transient errors with exponential backoff.
#
# Model: text-embedding-3-small at 768 dimensions.
# Expected cost: ~$1.00 for ~675k nodes.
# Expected runtime: 20–45 minutes depending on network and API responsiveness.
# =============================================================================

library(here)
library(DBI)
library(RSQLite)
library(dplyr)
library(stringr)
library(tibble)
library(httr2)
library(purrr)


# -----------------------------------------------------------------------------
# 1. Configuration
# -----------------------------------------------------------------------------

db_path       <- here("RVK_data", "rvk.db")
out_path      <- here("RVK_data", "embeddings.rds")
checkpoint_dir <- here("RVK_data", "embeddings_partial")

model         <- "text-embedding-3-small"
dimensions    <- 768L     # tradeoff: 768 ≈ near-full quality, ~half the storage of 1536
batch_size    <- 256L     # texts per API call
max_retries   <- 6L       # per batch
api_key       <- Sys.getenv("OPENAI_API_KEY")

stopifnot(nzchar(api_key))  # fail fast if env var missing
dir.create(checkpoint_dir, showWarnings = FALSE, recursive = TRUE)


# -----------------------------------------------------------------------------
# 2. Load the nodes we want to embed
# -----------------------------------------------------------------------------

con <- dbConnect(SQLite(), db_path)
nodes <- dbGetQuery(con, "
  SELECT notation, rich_text
  FROM rvk
  WHERE has_range = 0
  ORDER BY rowid
") |> as_tibble()
dbDisconnect(con)

cat(sprintf("Loaded %d non-range nodes for embedding.\n", nrow(nodes)))

# Sanity: no empty rich_text rows.
empty <- which(is.na(nodes$rich_text) | !nzchar(nodes$rich_text))
if (length(empty) > 0) {
  cat(sprintf("WARNING: %d rows have empty rich_text. They will be skipped.\n",
              length(empty)))
  nodes <- nodes[-empty, ]
}


# -----------------------------------------------------------------------------
# 3. Batch plan + checkpoint discovery
# -----------------------------------------------------------------------------

n_batches <- ceiling(nrow(nodes) / batch_size)
batch_idx <- ceiling(seq_len(nrow(nodes)) / batch_size)
cat(sprintf("Plan: %d batches of up to %d rows each.\n", n_batches, batch_size))

# Find which batches are already done.
done_files <- list.files(checkpoint_dir, pattern = "^batch_\\d+\\.rds$", full.names = FALSE)
done_ids   <- as.integer(str_match(done_files, "batch_(\\d+)\\.rds")[, 2])
done_ids   <- done_ids[!is.na(done_ids)]
cat(sprintf("Found %d completed batch checkpoints. Resuming from batch %d.\n",
            length(done_ids),
            if (length(done_ids) == 0) 1L else max(done_ids) + 1L))


# -----------------------------------------------------------------------------
# 4. API call helper with retries
# -----------------------------------------------------------------------------
# Returns a matrix [length(texts) x dimensions] of float32 values.

call_embedding_api <- function(texts) {
  req <- request("https://api.openai.com/v1/embeddings") |>
    req_auth_bearer_token(api_key) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list(
      model      = model,
      input      = texts,
      dimensions = dimensions,
      encoding_format = "float"
    )) |>
    req_retry(
      max_tries     = max_retries,
      backoff       = ~ min(60, 2 ^ .x),
      is_transient  = function(resp) {
        s <- resp_status(resp)
        s == 429 || s >= 500
      }
    ) |>
    req_timeout(120)
  
  resp <- req_perform(req)
  body <- resp_body_json(resp)
  
  # body$data is a list with one entry per input, each with $embedding (list of doubles).
  embs <- vapply(body$data, function(x) as.numeric(x$embedding),
                 FUN.VALUE = numeric(dimensions))
  # vapply returns [dimensions x n_texts]; transpose to [n_texts x dimensions].
  t(embs)
}


# -----------------------------------------------------------------------------
# 5. Run batches
# -----------------------------------------------------------------------------

run_t0 <- Sys.time()
total_done_this_run <- 0L

for (b in seq_len(n_batches)) {
  ckpt_path <- file.path(checkpoint_dir, sprintf("batch_%05d.rds", b))
  if (file.exists(ckpt_path)) next  # already done in a previous run
  
  rows  <- which(batch_idx == b)
  texts <- nodes$rich_text[rows]
  nots  <- nodes$notation[rows]
  
  t_batch <- Sys.time()
  emb <- tryCatch(
    call_embedding_api(texts),
    error = function(e) {
      cat(sprintf("\nBatch %d failed after retries: %s\n", b, conditionMessage(e)))
      cat("You can re-run the script to retry this batch.\n")
      stop(e)
    }
  )
  stopifnot(nrow(emb) == length(rows), ncol(emb) == dimensions)
  
  # Save as float32 to halve disk usage (R stores as numeric/float64 in memory
  # but we can store as raw bytes; for simplicity here keep as numeric matrix
  # with row names = notations).
  rownames(emb) <- nots
  saveRDS(emb, ckpt_path)
  
  total_done_this_run <- total_done_this_run + length(rows)
  elapsed <- as.numeric(Sys.time() - run_t0, units = "secs")
  rate    <- total_done_this_run / elapsed
  remain  <- (nrow(nodes) - (b * batch_size)) / rate
  cat(sprintf("  batch %5d/%d  (%6d rows, %.1fs)  rate %.0f rows/s  ETA %.1f min\n",
              b, n_batches, length(rows),
              as.numeric(Sys.time() - t_batch, units = "secs"),
              rate, max(0, remain / 60)))
}

cat("\nAll batches complete.\n")


# -----------------------------------------------------------------------------
# 6. Stitch checkpoints into the final embeddings matrix
# -----------------------------------------------------------------------------

cat("Stitching checkpoints into final matrix...\n")
all_files <- list.files(checkpoint_dir, pattern = "^batch_\\d+\\.rds$", full.names = TRUE)
all_files <- all_files[order(all_files)]  # batch number order

mats <- lapply(all_files, readRDS)
embeddings <- do.call(rbind, mats)

cat(sprintf("Final matrix: %d rows x %d dims\n", nrow(embeddings), ncol(embeddings)))
stopifnot(nrow(embeddings) == nrow(nodes))
stopifnot(all(rownames(embeddings) == nodes$notation))

# Optional: convert to float32 storage to halve disk size.
# R doesn't have native float32, but we can store as raw via the float package.
# For now, keep as float64 — final file ~4 GB. If that's too large we can
# revisit (the float package or quantization are easy add-ons).

saveRDS(embeddings, out_path)
cat(sprintf("Saved %s (%.1f MB).\n",
            out_path, file.info(out_path)$size / 1024^2))


# -----------------------------------------------------------------------------
# 7. Quick sanity test: nearest neighbors of a known notation
# -----------------------------------------------------------------------------
# Take MD 6250 (Verschwörung) and find its 10 nearest neighbors. They should
# all be semantically related (other politische-Psychologie / -Verhalten codes).

cat("\n=== Sanity check: nearest neighbors of MD 6250 (Verschwörung) ===\n")

query_notation <- "MD 6250"
q_idx <- match(query_notation, rownames(embeddings))
stopifnot(!is.na(q_idx))

# Normalise embeddings to unit length for cosine similarity = dot product.
norms <- sqrt(rowSums(embeddings^2))
emb_norm <- embeddings / norms

q_vec <- emb_norm[q_idx, ]
sims  <- as.numeric(emb_norm %*% q_vec)
top10 <- order(sims, decreasing = TRUE)[1:10]

con <- dbConnect(SQLite(), db_path)
nbrs <- dbGetQuery(con, sprintf(
  "SELECT notation, benennung FROM rvk WHERE notation IN (%s)",
  paste0("'", rownames(embeddings)[top10], "'", collapse = ", ")
))
dbDisconnect(con)

print(tibble(
  rank      = seq_along(top10),
  notation  = rownames(embeddings)[top10],
  cosine    = round(sims[top10], 3)
) |>
  left_join(as_tibble(nbrs), by = "notation"))