# =============================================================================
# 19_optimize_indexes.R
# One-off: pre-normalise the embedding matrices so the app starts fast.
#
# Why: load_retrieval_state() currently does
#         emb_norm <- embeddings / sqrt(rowSums(embeddings^2))
#      at startup. On a 674'739 x 768 matrix that is ~4.1 GB held twice for a
#      moment, and takes ~190 s. Doing it once here turns app startup into a
#      plain readRDS().
#
# Outputs: RVK_data/embeddings_norm.rds
#          RVK_data/holdings_emb_<profile>_norm.rds
#
# The originals are left untouched, so this is safe to re-run and easy to undo.
# Run again after any re-embedding.
# =============================================================================

library(here)
library(float)
source(here("RVK_data", "lib_profiles.R"))


normalise_and_save <- function(in_path, out_path, label) {
  if (!file.exists(in_path)) {
    cat(sprintf("  %s: source missing (%s), skipping\n", label, basename(in_path)))
    return(invisible(FALSE))
  }
  cat(sprintf("\n%s\n  reading %s ...\n", label, basename(in_path)))
  t0 <- Sys.time()
  obj <- readRDS(in_path)
  cat(sprintf("  read in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))

  t0 <- Sys.time()
  if (is.matrix(obj)) {
    # RVK index: a bare matrix with notations as rownames.
    nrm <- sqrt(rowSums(obj^2))
    bad <- !is.finite(nrm) | nrm == 0
    if (any(bad)) {
      cat(sprintf("  WARNING: %d rows with zero/non-finite norm, left unscaled\n",
                  sum(bad)))
      nrm[bad] <- 1
    }
    obj <- obj / nrm
    attr(obj, "normalised") <- TRUE
  } else if (is.list(obj) && !is.null(obj$emb)) {
    # Holdings index: a list with $emb plus metadata.
    nrm <- sqrt(rowSums(obj$emb^2))
    bad <- !is.finite(nrm) | nrm == 0
    if (any(bad)) {
      cat(sprintf("  WARNING: %d rows with zero/non-finite norm, left unscaled\n",
                  sum(bad)))
      nrm[bad] <- 1
    }
    obj$emb_norm <- obj$emb / nrm
    obj$emb <- NULL              # drop the unnormalised copy
    obj$normalised <- TRUE
  } else {
    cat("  unrecognised object shape, skipping\n")
    return(invisible(FALSE))
  }
  cat(sprintf("  normalised in %.0f s\n", as.numeric(Sys.time() - t0, units = "secs")))

  t0 <- Sys.time()
  saveRDS(obj, out_path)
  cat(sprintf("  saved %s (%.0f MB) in %.0f s\n",
              basename(out_path), file.info(out_path)$size / 1024^2,
              as.numeric(Sys.time() - t0, units = "secs")))

  rm(obj); invisible(gc())
  invisible(TRUE)
}


# --- RVK index ---------------------------------------------------------------

normalise_and_save(
  here("RVK_data", "embeddings.rds"),
  here("RVK_data", "embeddings_norm.rds"),
  "RVK embeddings"
)


# --- Holdings indexes, one per profile ---------------------------------------

for (pid in names(HOLDINGS_SOURCES)) {
  normalise_and_save(
    here("RVK_data", sprintf("holdings_emb_%s.rds", pid)),
    here("RVK_data", sprintf("holdings_emb_%s_norm.rds", pid)),
    sprintf("Holdings %s", pid)
  )
}

cat("\nDone. Apply the loader patch in 05_retrieve.R and lib_holdings.R\n")
cat("so the app prefers the *_norm.rds files.\n")


# =============================================================================
# LOADER PATCHES
# =============================================================================
#
# --- 05_retrieve.R: inside load_retrieval_state(), replace
#
#     embeddings <- readRDS(emb_path)
#     notations  <- rownames(embeddings)
#     emb_norm   <- embeddings / sqrt(rowSums(embeddings^2))
#     rm(embeddings); invisible(gc())
#
#     with:
#
#     norm_path <- sub("\\.rds$", "_norm.rds", emb_path)
#     if (file.exists(norm_path)) {
#       emb_norm <- readRDS(norm_path)          # already unit length
#     } else {
#       embeddings <- readRDS(emb_path)
#       emb_norm   <- embeddings / sqrt(rowSums(embeddings^2))
#       rm(embeddings); invisible(gc())
#     }
#     notations <- rownames(emb_norm)
#
#
# --- lib_holdings.R: replace the body of load_holdings_index() with
#
#     load_holdings_index <- function(profile_id, dir = here::here("RVK_data")) {
#       npath <- file.path(dir, sprintf("holdings_emb_%s_norm.rds", profile_id))
#       path  <- file.path(dir, sprintf("holdings_emb_%s.rds", profile_id))
#       if (file.exists(npath)) return(readRDS(npath))   # emb_norm already present
#       if (!file.exists(path)) {
#         warning(sprintf("No holdings embeddings for profile '%s'", profile_id))
#         return(NULL)
#       }
#       H <- readRDS(path)
#       H$emb_norm <- H$emb / sqrt(rowSums(H$emb^2))
#       H$emb <- NULL
#       invisible(gc())
#       H
#     }
#
# Both patches fall back to the old behaviour if the *_norm.rds files are
# absent, so nothing breaks if you skip this step.
# =============================================================================
