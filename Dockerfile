# =============================================================================
# Dockerfile — RVK-Klassifikationsassistent
#
# Contains R and the packages only. Code and data are bind-mounted at
# /srv/rvk, so neither a code change nor an RVK update requires a rebuild —
# a container restart is enough. Rebuild only when the package list changes.
#
# R is pinned to 4.5.3 to match the development machine. rocker/r-ver also
# pins CRAN to a snapshot matching that release, so rebuilds install the same
# package versions rather than whatever is current.
# =============================================================================

FROM rocker/r-ver:4.5.3

# System libraries.
#
# libuv1t64 (Ubuntu 24.04 name for libuv1) is the one that bit us: the `fs` binary from Posit Package Manager
# links dynamically against it, and bslib pulls fs in via sass when it
# compiles the theme on the first HTTP request. Without it the app starts
# normally and then answers 500 on every page.
#
# The font/graphics group below is not needed today but is what the usual
# suspects (systemfonts, textshaping, ragg) link against — cheap insurance
# against another rebuild cycle.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        zlib1g-dev \
        libuv1t64 \
        libfontconfig1-dev \
        libfreetype6-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libpng-dev \
        libjpeg-dev \
        curl \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# R packages. rocker/r-ver points at Posit Package Manager, so these install
# as Linux binaries instead of compiling — minutes, not hours.
RUN install2.r --error --skipinstalled --ncpus -1 \
        shiny \
        bslib \
        DT \
        here \
        DBI \
        RSQLite \
        dplyr \
        tibble \
        tidyr \
        stringr \
        purrr \
        readr \
        httr2 \
        jsonlite \
        digest

# Fail the build rather than at runtime if a shared library is missing:
# loading these here exercises the same dynamic linking the app will need.
RUN R -e "library(bslib); library(sass); library(fs); \
          invisible(sass::sass('a{b:c}')); \
          cat('Paketprüfung bestanden\n')"

WORKDIR /srv/rvk

EXPOSE 3838

HEALTHCHECK --interval=60s --timeout=10s --start-period=10m --retries=3 \
    CMD curl -fsS http://localhost:3838/ >/dev/null || exit 1

# start-period is 10 minutes: loading ~4 GB of embeddings from disk on a
# Celeron takes a few minutes, and the app must not be killed meanwhile.

CMD ["R", "-e", "shiny::runApp('/srv/rvk', host = '0.0.0.0', port = 3838, launch.browser = FALSE)"]
