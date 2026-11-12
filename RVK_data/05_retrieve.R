# =============================================================================
# 05_retrieve.R  (v5)
# Retrieval for the RVK classification pipeline.
#
# Four channels, merged with Reciprocal Rank Fusion:
#   F  FTS5 keyword search over RVK rich_text     (enriched query)
#   V  vector search over RVK embeddings          (enriched query)
#   L  local additions via their local Stichwoerter
#   H  holdings nearest-neighbour search          (RAW TITLE)
#
# v5 changes:
#   - ASSIGNABLE-NOTATION FILTER: bare hierarchy nodes such as "DI" or "MS"
#     are structural levels, not class numbers, and must never be suggested.
#     has_range = 0 did not exclude them (they contain no " - " range).
#     An assignable RVK notation always has letters followed by a number.
#   - branch preference boost (soft nudge for the library's core areas)
# =============================================================================

library(here)
library(DBI)
library(RSQLite)
library(dplyr)
library(tibble)
library(stringr)
library(httr2)
library(purrr)

source(here("RVK_data", "lib_local_rules.R"))
source(here("RVK_data", "lib_profiles.R"))
source(here("RVK_data", "lib_holdings.R"))


STOPWORDS <- c(
  "the","a","an","and","or","but","of","in","on","at","to","for","with",
  "by","from","as","is","are","was","were","be","been","being","this","that",
  "these","those","it","its","into","about","over","under","between","through",
  "der","die","das","den","dem","des","ein","eine","einen","einer","eines",
  "und","oder","auf","mit","von","zu","fur","bei","aus","um","durch","uber",
  "ist","sind","war","waren","sein","seine","ihre","ihr","wie","wo","wenn",
  "weil","aber","nicht","kein","keine","als","auch","noch","schon",
  "le","la","les","un","une","des","du","et","ou","au","aux","dans","sur",
  "avec","par","pour","ce","cette","ces",
  "buchtitel","fach","hauptthema","schlagworter","schlagwoerter"
)


# --- Assignable notations -----------------------------------------------------
# "DI" or "MS"  -> hierarchy level, NOT assignable
# "DI 3000"     -> assignable
# "PL 671.362"  -> assignable (decimals occur)

is_assignable_notation <- function(x) {
  !is.na(x) & str_detect(x, "^[A-Z]+\\s+[0-9]")
}


# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------

load_retrieval_state <- function(
  db_path       = here("RVK_data", "rvk.db"),
  emb_path      = here("RVK_data", "embeddings.rds"),
  load_holdings = TRUE
) {
  stopifnot(file.exists(db_path))
  norm_path <- sub("\\.rds$", "_norm.rds", emb_path)
  if (!file.exists(norm_path) && !file.exists(emb_path))
    stop("Keine Embedding-Datei gefunden. Erwartet: ", basename(norm_path),
         " oder ", basename(emb_path), " im Ordner ", dirname(emb_path))
  con <- dbConnect(SQLite(), db_path)
  # Auf langsamen Platten dominieren die Zugriffszeiten: der FTS-Index wird
  # bei jeder Suche seitenweise gelesen. Grosser Seitencache und
  # Memory-Mapping halten ihn nach der ersten Abfrage im RAM.
  dbExecute(con, "PRAGMA cache_size = -1048576")    # 1 GB (negativ = KiB)
  dbExecute(con, "PRAGMA mmap_size  = 4294967296")  # 4 GB
  dbExecute(con, "PRAGMA temp_store = MEMORY")
  
  # Index einmal vorwärmen, damit nicht die erste Nutzerin die Wartezeit trägt
  invisible(tryCatch(
    dbGetQuery(con, "SELECT count(*) FROM rvk_fts
                     WHERE rvk_fts MATCH 'politik OR gesellschaft OR bildung
                                          OR soziologie OR geschichte'"),
    error = function(e) NULL))
       norm_path <- sub("\\.rds$", "_norm.rds", emb_path)
       if (file.exists(norm_path)) {
        emb_norm <- readRDS(norm_path)          # already unit length
       } else {
         embeddings <- readRDS(emb_path)
         emb_norm   <- embeddings / sqrt(rowSums(embeddings^2))
         rm(embeddings); invisible(gc())
       }
       notations <- rownames(emb_norm)

  # Drop non-assignable rows from the vector index once, at load time.
  keep <- is_assignable_notation(notations)
  if (any(!keep)) {
    cat(sprintf("  excluding %d non-assignable notations from the vector index\n",
                sum(!keep)))
    emb_norm  <- emb_norm[keep, , drop = FALSE]
    notations <- notations[keep]
  }

  local_rules <- if ("local_rules" %in% dbListTables(con)) {
    dbGetQuery(con, "SELECT * FROM local_rules") |>
      as_tibble() |>
      mutate(nicht_belegt      = as.logical(nicht_belegt),
             is_local_addition = as.logical(is_local_addition))
  } else {
    warning("No local_rules table found."); tibble()
  }

  holdings <- list()
  if (load_holdings) {
    ids <- unique(compact(map(PROFILES, "holdings")))
    for (hid in ids) {
      cat(sprintf("  loading holdings index '%s'...\n", hid))
      holdings[[hid]] <- load_holdings_index(hid)
    }
  }

  list(con = con, emb_norm = emb_norm, notations = notations,
       notation_to_idx = setNames(seq_along(notations), notations),
       local_rules = local_rules, holdings = holdings)
}

close_retrieval_state <- function(state) {
  dbDisconnect(state$con); invisible(NULL)
}


# -----------------------------------------------------------------------------
# Embedding API
# -----------------------------------------------------------------------------

embed_texts_batch <- function(texts, dimensions = 768L,
                              model = "text-embedding-3-small",
                              api_key = Sys.getenv("OPENAI_API_KEY"),
                              max_retries = 5L) {
  stopifnot(nzchar(api_key))
  req <- request("https://api.openai.com/v1/embeddings") |>
    req_auth_bearer_token(api_key) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(list(model = model, input = as.list(texts),
                       dimensions = dimensions, encoding_format = "float")) |>
    req_retry(max_tries = max_retries, backoff = ~ min(60, 2 ^ .x),
              is_transient = function(r) {
                s <- resp_status(r); s == 429 || s >= 500
              }) |>
    req_timeout(120)
  body <- resp_body_json(req_perform(req))
  t(vapply(body$data, function(x) as.numeric(x$embedding),
           FUN.VALUE = numeric(dimensions)))
}

embed_text <- function(text, ...) as.numeric(embed_texts_batch(text, ...))


# -----------------------------------------------------------------------------
# Channels
# -----------------------------------------------------------------------------

build_fts_query <- function(text) {
  if (is.na(text) || !nzchar(text)) return(NULL)
  tokens <- text |> str_to_lower() |>
    str_replace_all("[^\\w\\s]", " ") |> str_split("\\s+") |> unlist()
  tokens <- tokens[nchar(tokens) >= 3]
  tokens <- setdiff(tokens, STOPWORDS)
  tokens <- unique(str_replace_all(tokens, '"', ""))
  if (length(tokens) == 0) return(NULL)
  paste(paste0('"', tokens, '"'), collapse = " OR ")
}

retrieve_fts <- function(state, query_text, n = 50) {
  empty <- tibble(notation = character(0), fts_rank = integer(0))
  q <- build_fts_query(query_text)
  if (is.null(q)) return(empty)
  # GLOB '*[0-9]*' keeps only notations containing a digit, i.e. assignable
  # class numbers; bare hierarchy nodes such as "DI" are excluded.
  sql <- sprintf("
    SELECT r.notation FROM rvk_fts f JOIN rvk r ON r.rowid = f.rowid
    WHERE rvk_fts MATCH %s AND r.has_range = 0 AND r.notation GLOB '*[0-9]*'
    ORDER BY bm25(rvk_fts) LIMIT %d", dbQuoteString(state$con, q), n)
  res <- tryCatch(dbGetQuery(state$con, sql), error = function(e) NULL)
  if (is.null(res) || nrow(res) == 0) return(empty)
  as_tibble(res) |> mutate(fts_rank = row_number())
}

retrieve_vec <- function(state, query_embedding, n = 50) {
  q <- as.numeric(query_embedding); q <- q / sqrt(sum(q^2))
  sims <- as.numeric(state$emb_norm %*% q)
  top_idx <- order(sims, decreasing = TRUE)[seq_len(min(n, length(sims)))]
  tibble(notation = state$notations[top_idx],
         vec_rank = seq_along(top_idx),
         vec_sim  = sims[top_idx])
}

retrieve_local_additions <- function(state, query_text, n = 10) {
  empty <- tibble(notation = character(0), loc_rank = integer(0))
  if (nrow(state$local_rules) == 0) return(empty)
  q <- build_fts_query(query_text)
  if (is.null(q)) return(empty)
  sql <- sprintf("
    SELECT rule_id FROM local_rules_fts WHERE local_rules_fts MATCH %s
    ORDER BY bm25(local_rules_fts) LIMIT %d", dbQuoteString(state$con, q), n * 5)
  res <- tryCatch(dbGetQuery(state$con, sql), error = function(e) NULL)
  if (is.null(res) || nrow(res) == 0) return(empty)
  as_tibble(res) |>
    inner_join(state$local_rules |> filter(is_local_addition) |>
                 select(rule_id, notation = raw_notation), by = "rule_id") |>
    mutate(notation = str_trim(notation)) |>
    filter(is_assignable_notation(notation)) |>
    distinct(notation, .keep_all = TRUE) |>
    head(n) |> mutate(loc_rank = row_number()) |> select(notation, loc_rank)
}


# -----------------------------------------------------------------------------
# Local-rule context
# -----------------------------------------------------------------------------

attach_rule_context <- function(state, notations) {
  n <- length(notations)
  empty <- tibble(notation = notations, blocked = rep(FALSE, n),
                  local_stichwoerter = rep(NA_character_, n),
                  local_erklaerung   = rep(NA_character_, n))
  if (nrow(state$local_rules) == 0 || n == 0) return(empty)
  m <- match_notations_to_rules(notations, state$local_rules)
  if (nrow(m) == 0) return(empty)

  blocked_tbl <- m |> group_by(notation) |>
    slice_max(specificity, n = 1, with_ties = FALSE) |> ungroup() |>
    select(notation, blocked = nicht_belegt)

  ctx_tbl <- m |> group_by(notation) |>
    summarise(
      local_stichwoerter = { v <- stichwoerter[!is.na(stichwoerter) & nzchar(stichwoerter)]
                             if (!length(v)) NA_character_ else paste(unique(v), collapse = "; ") },
      local_erklaerung   = { v <- erklaerung[!is.na(erklaerung) & nzchar(erklaerung)]
                             if (!length(v)) NA_character_ else paste(unique(v), collapse = " | ") },
      .groups = "drop")

  tibble(notation = notations) |>
    left_join(blocked_tbl, by = "notation") |>
    left_join(ctx_tbl, by = "notation") |>
    mutate(blocked = coalesce(blocked, FALSE))
}


# -----------------------------------------------------------------------------
# Clone de-duplication
# -----------------------------------------------------------------------------

dedupe_candidates <- function(cand, max_per_benennung = 3L, max_listed = 8L) {
  if (nrow(cand) == 0) return(cand)
  cand <- cand |>
    mutate(ben_key = str_squish(str_to_lower(coalesce(benennung, "")))) |>
    arrange(desc(rrf)) |>
    group_by(ben_key) |> mutate(ben_pos = row_number()) |> ungroup()

  others <- cand |> filter(ben_pos > max_per_benennung) |>
    group_by(ben_key) |>
    summarise(n_parallel = n(),
              parallel_notations = paste0(
                paste(head(notation, max_listed), collapse = ", "),
                if_else(n() > max_listed, ", …", "")),
              .groups = "drop")

  cand |> filter(ben_pos <= max_per_benennung) |>
    left_join(others, by = "ben_key") |>
    mutate(n_parallel = coalesce(n_parallel, 0L)) |>
    arrange(desc(rrf)) |> select(-ben_key, -ben_pos)
}


# -----------------------------------------------------------------------------
# Main entry point
# -----------------------------------------------------------------------------

retrieve_candidates <- function(state, query_text,
                                query_embedding   = NULL,
                                title_text        = NULL,
                                title_embedding   = NULL,
                                mode              = "vanilla",
                                n_fts             = 150,
                                n_vec             = 150,
                                n_final           = 50,
                                rrf_k             = 60,
                                n_local           = 10,
                                max_per_benennung = 3L,
                                n_force_local     = 2L,
                                use_holdings      = TRUE,
                                k_neighbors       = 50L,
                                min_sim           = 0.40,
                                branch_boost      = 0.10,
                                exclude_titles    = NULL,
                                max_sim_holdings  = NULL) {

  prof <- get_profile(mode)
  if (is.null(query_embedding)) query_embedding <- embed_text(query_text)
  if (is.null(title_text)) title_text <- query_text
  if (is.null(title_embedding)) {
    title_embedding <- if (identical(title_text, query_text)) query_embedding
                       else embed_text(title_text)
  }

  fts_hits <- retrieve_fts(state, query_text, n = n_fts)
  vec_hits <- retrieve_vec(state, query_embedding, n = n_vec)

  loc_hits <- if (!is.null(prof$rule_set)) {
    retrieve_local_additions(state, query_text, n = n_local)
  } else tibble(notation = character(0), loc_rank = integer(0))

  hold_hits <- if (use_holdings && !is.null(prof$holdings)) {
    retrieve_holdings(state$holdings[[prof$holdings]], title_embedding,
                      k_neighbors = k_neighbors, min_sim = min_sim,
                      exclude_titles = exclude_titles,
                      max_sim = max_sim_holdings)
  } else tibble(notation = character(0), hold_rank = integer(0))

  all_n <- unique(c(fts_hits$notation, vec_hits$notation,
                    loc_hits$notation, hold_hits$notation))
  all_n <- all_n[is_assignable_notation(all_n)]      # safety net
  if (length(all_n) == 0) return(tibble())

  cand <- tibble(notation = all_n) |>
    left_join(fts_hits,  by = "notation") |>
    left_join(vec_hits,  by = "notation") |>
    left_join(loc_hits,  by = "notation") |>
    left_join(hold_hits, by = "notation") |>
    mutate(
      rrf = coalesce(1 / (rrf_k + fts_rank),  0) +
            coalesce(1 / (rrf_k + vec_rank),  0) +
            coalesce(1 / (rrf_k + loc_rank),  0) +
            coalesce(1 / (rrf_k + hold_rank), 0),
      found_in = paste0(if_else(!is.na(fts_rank),  "F", ""),
                        if_else(!is.na(vec_rank),  "V", ""),
                        if_else(!is.na(loc_rank),  "L", ""),
                        if_else(!is.na(hold_rank), "H", ""))
    )

  # Soft preference for the library's core collecting areas: a proportional
  # nudge that only reorders candidates already close together.
  if (branch_boost != 0 && length(prof$branch_specs) > 0) {
    cand <- cand |>
      mutate(in_core  = in_preferred_branches(notation, prof$branch_specs),
             rrf_base = rrf,
             rrf      = if_else(in_core, rrf * (1 + branch_boost), rrf))
  } else {
    cand <- cand |> mutate(in_core = FALSE, rrf_base = rrf)
  }

  info <- dbGetQuery(state$con, sprintf(
    "SELECT notation, benennung, pfad, register, bemerkung
     FROM rvk WHERE notation IN (%s)",
    paste0("'", cand$notation, "'", collapse = ", "))) |> as_tibble()

  cand <- cand |> left_join(info, by = "notation") |>
    mutate(rvk_benennung = benennung)

  # Local additions: the local meaning wins, the RVK reading is preserved.
  if (!is.null(prof$rule_set) && nrow(state$local_rules) > 0) {
    la <- state$local_rules |> filter(is_local_addition) |>
      transmute(notation = str_trim(raw_notation),
                la_benennung = stichwoerter, la_erklaerung = erklaerung)
    cand <- cand |> left_join(la, by = "notation") |>
      mutate(
        is_local_addition = !is.na(la_benennung),
        benennung = if_else(is_local_addition, la_benennung, benennung),
        bemerkung = case_when(
          is_local_addition & !is.na(rvk_benennung) ~ str_squish(paste0(
            "Lokale Zusatznotation. RVK-Benennung wäre: ", rvk_benennung,
            if_else(is.na(la_erklaerung), "", paste0(" | ", la_erklaerung)))),
          is_local_addition ~ str_squish(paste0(
            "Lokale Zusatznotation (nicht in der RVK).",
            if_else(is.na(la_erklaerung), "", paste0(" ", la_erklaerung)))),
          TRUE ~ bemerkung),
        pfad = if_else(is_local_addition & is.na(pfad),
                       "(lokale Zusatznotation, nicht in der RVK)", pfad)) |>
      select(-la_benennung, -la_erklaerung)
  } else {
    cand <- cand |> mutate(is_local_addition = FALSE)
  }

  n_blocked <- 0L
  if (!is.null(prof$rule_set)) {
    cand <- cand |> left_join(attach_rule_context(state, cand$notation), by = "notation")
    n_blocked <- sum(cand$blocked, na.rm = TRUE)
    cand <- cand |> filter(!blocked)
  } else {
    cand <- cand |> mutate(blocked = FALSE, local_stichwoerter = NA_character_,
                           local_erklaerung = NA_character_)
  }

  cand <- cand |> filter(!is.na(benennung), nzchar(benennung))
  if (nrow(cand) == 0) return(tibble())

  n_before <- nrow(cand)
  cand <- dedupe_candidates(cand, max_per_benennung = max_per_benennung)
  n_collapsed <- n_before - nrow(cand)

  forced <- tibble()
  if (!is.null(prof$rule_set) && n_force_local > 0) {
    top_slice <- head(cand, n_final)
    forced <- cand |> filter(is_local_addition, !notation %in% top_slice$notation) |>
      arrange(coalesce(loc_rank, .Machine$integer.max)) |> head(n_force_local)
  }

  out <- if (nrow(forced) > 0) {
    bind_rows(head(cand, max(1L, n_final - nrow(forced))), forced) |>
      distinct(notation, .keep_all = TRUE) |> arrange(desc(rrf))
  } else head(cand, n_final)

  for (cc in c("hold_rank","hold_score","hold_max_sim","hold_n","hold_examples")) {
    if (!cc %in% names(out)) out[[cc]] <- NA
  }

  out <- out |> mutate(rank = row_number()) |>
    select(rank, notation, benennung, pfad, register, bemerkung,
           local_stichwoerter, local_erklaerung, is_local_addition, rvk_benennung,
           n_parallel, parallel_notations,
           hold_n, hold_max_sim, hold_examples,
           in_core, found_in, rrf, rrf_base,
           fts_rank, vec_rank, loc_rank, hold_rank)

  attr(out, "mode")               <- mode
  attr(out, "profile")            <- prof
  attr(out, "preferred_branches") <- prof$branch_specs
  attr(out, "n_blocked_removed")  <- n_blocked
  attr(out, "n_clones_collapsed") <- n_collapsed
  attr(out, "law_disclaimer")     <- prof$law_disclaimer && any(str_starts(out$notation, "P"))
  out
}
