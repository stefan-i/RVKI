# =============================================================================
# 14_embed_holdings.R
# Embed holdings titles per profile for the nearest-neighbour retrieval channel.
#
# Inputs:  table `holdings` in RVK_data/rvk.db
# Outputs: RVK_data/holdings_emb_<profile>.rds        (one per profile)
#          RVK_data/holdings_partial_<profile>/       (resumable checkpoints)
#
# We embed the RAW TITLE, deliberately: the holdings channel is title-to-title
# matching, which is symmetric and avoids the format mismatch that hurts
# title-to-metadata retrieval. At query time this channel therefore uses an
# embedding of the raw book title, not the LLM-enriched query.
#
# Cost: ~80k titles x ~25 tokens x $0.02/M  ->  roughly $0.04.
# Runtime: 10-20 minutes for both profiles.
# =============================================================================

library(here)
library(DBI)
library(RSQLite)
library(dplyr)
library(tibble)
library(stringr)
library(httr2)

source(here("RVK_data", "lib_profiles.R"))

model      <- "text-embedding-3-small"
dimensions <- 768L
batch_size <- 256L
api_key    <- Sys.getenv("OPENAI_API_KEY")
stopifnot(nzchar(api_key))

con <- dbConnect(SQLite(), here("RVK_data", "rvk.db"))
stopifnot("holdings" %in% dbListTables(con))


call_embedding_api <- function(texts) {
  req <- request("https://api.openai.com/v1/embeddings") |>
    req_auth_bearer_token(api_key) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list(model = model, input = as.list(texts),
                       dimensions = dimensions, encoding_format = "float")) |>
    req_retry(max_tries = 6,
              backoff = ~ min(60, 2 ^ .x),
              is_transient = function(r) {
                s <- resp_status(r); s == 429 || s >= 500
              }) |>
    req_timeout(120)
  body <- resp_body_json(req_perform(req))
  t(vapply(body$data, function(x) as.numeric(x$embedding),
           FUN.VALUE = numeric(dimensions)))
}


embed_profile <- function(profile_id) {
  cat(sprintf("\n=========== profile: %s ===========\n", profile_id))

  h <- dbGetQuery(con, sprintf(
    "SELECT holding_id, mms_id, notation, title
     FROM holdings WHERE profile = '%s' ORDER BY holding_id", profile_id
  )) |> as_tibble()

  if (nrow(h) == 0) { cat("  no records, skipping\n"); return(invisible()) }
  cat(sprintf("  %d titles to embed\n", nrow(h)))

  out_path  <- here("RVK_data", sprintf("holdings_emb_%s.rds", profile_id))
  ckpt_dir  <- here("RVK_data", sprintf("holdings_partial_%s", profile_id))
  dir.create(ckpt_dir, showWarnings = FALSE, recursive = TRUE)

  n_batches <- ceiling(nrow(h) / batch_size)
  batch_idx <- ceiling(seq_len(nrow(h)) / batch_size)

  done <- list.files(ckpt_dir, pattern = "^batch_\\d+\\.rds$")
  cat(sprintf("  %d batches planned, %d checkpoints already present\n",
              n_batches, length(done)))

  run_t0 <- Sys.time(); done_this_run <- 0L

  for (b in seq_len(n_batches)) {
    ckpt <- file.path(ckpt_dir, sprintf("batch_%05d.rds", b))
    if (file.exists(ckpt)) next

    rows  <- which(batch_idx == b)
    emb   <- call_embedding_api(h$title[rows])
    stopifnot(nrow(emb) == length(rows), ncol(emb) == dimensions)
    rownames(emb) <- as.character(h$holding_id[rows])
    saveRDS(emb, ckpt)

    done_this_run <- done_this_run + length(rows)
    elapsed <- as.numeric(Sys.time() - run_t0, units = "secs")
    rate    <- done_this_run / max(elapsed, 0.1)
    remain  <- (nrow(h) - b * batch_size) / max(rate, 0.1)
    cat(sprintf("\r  batch %5d/%d  rate %.0f/s  ETA %.1f min      ",
                b, n_batches, rate, max(0, remain / 60)))
  }
  cat("\n  all batches done, stitching...\n")

  files <- sort(list.files(ckpt_dir, pattern = "^batch_\\d+\\.rds$",
                           full.names = TRUE))
  emb <- do.call(rbind, lapply(files, readRDS))

  stopifnot(nrow(emb) == nrow(h))
  stopifnot(all(rownames(emb) == as.character(h$holding_id)))

  # Store embeddings plus the metadata the retrieval channel needs, so the
  # channel can aggregate neighbours to notations and show example titles.
  saveRDS(list(
    profile    = profile_id,
    emb        = emb,
    holding_id = h$holding_id,
    notation   = h$notation,
    title      = h$title,
    mms_id     = h$mms_id,
    model      = model,
    dimensions = dimensions,
    built_at   = Sys.time()
  ), out_path)

  cat(sprintf("  saved %s (%.1f MB)\n", basename(out_path),
              file.info(out_path)$size / 1024^2))
}


for (pid in names(HOLDINGS_SOURCES)) embed_profile(pid)


# -----------------------------------------------------------------------------
# Sanity check: nearest neighbours of a few real titles
# -----------------------------------------------------------------------------

cat("\n=========== sanity check (B500) ===========\n")
p <- here("RVK_data", "holdings_emb_B500.rds")
if (file.exists(p)) {
  H <- readRDS(p)
  norms <- sqrt(rowSums(H$emb^2))
  Hn <- H$emb / norms

  # Pick a few titles that belong to notations we know were problematic.
  probe_notations <- c("MS 3600", "DK 1010", "DG 5000")
  for (pn in probe_notations) {
    idx <- which(H$notation == pn)
    if (length(idx) == 0) { cat(sprintf("\n%s: no holdings\n", pn)); next }
    i <- idx[1]
    sims <- as.numeric(Hn %*% Hn[i, ])
    top  <- order(sims, decreasing = TRUE)[2:6]   # skip self
    cat(sprintf("\n%s — query title: %s\n", pn, substr(H$title[i], 1, 70)))
    for (j in top) {
      cat(sprintf("   %.3f  %-9s %s\n", sims[j], H$notation[j],
                  substr(H$title[j], 1, 65)))
    }
  }
}

dbDisconnect(con)
cat("\nDone.\n")
