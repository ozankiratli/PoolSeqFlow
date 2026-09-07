# Per-site depth and per-allele frequency for every pool, from the depth table's own cells.
#
#     allele_frequencies(list(A = c("50,50", "40,40,20"), B = c("30,10", "10,10,10")))
#
#       $site     1 1 2 2 2      the site each allele row belongs to
#       $alleles  2 3            how many alleles each site holds
#       $depth    A 100 100      one row per SITE, one column per pool
#                 B  40  30
#       $freq     A 0.5 0.5 0.4 0.4 0.2       one row per ALLELE, one column per pool
#                 B 0.75 0.25 1/3 1/3 1/3
#
# `columns` is one column of the depth table per pool: one comma-separated count list per site,
# REF first and then each ALT. A site holds any number of alleles, so the frequencies are one
# long vector per pool rather than a rectangle, and `site` is the index that groups them —
# `rowsum(x, site)` is a per-site total and `depth[site, ]` is a per-allele depth.
#
# THE ALT COLUMN IS ONE LIST FOR THE WHOLE COHORT, so every pool's cell at a site holds one
# count per allele. A site where they differ is refused: the columns would be describing
# different alleles, and nothing downstream could tell which.
#
# A pool with no reads at a site gets depth 0 and no frequency — there is nothing observed there
# to be a frequency of. bcftools' missing value takes that pool's whole site with it, as it does
# in site_diversity().
allele_frequencies <- function(columns) {
    if (length(columns) == 0) stop("allele_frequencies: no pools to read")
    n_pool <- length(columns)
    n_site <- length(columns[[1]])
    sizes <- lengths(columns)
    if (any(sizes != n_site)) {
        stop("allele_frequencies: the pools hold ", paste(unique(sizes), collapse = ", "),
             " sites. Every column is the same table read down the same rows.")
    }

    named <- names(columns)
    label <- function(i) {
        if (!is.null(named) && nzchar(named[i])) named[i] else paste0("column ", i)
    }

    alleles <- NULL
    site <- NULL
    depth <- NULL
    freq <- NULL

    for (i in seq_len(n_pool)) {
        parts <- strsplit(as.character(columns[[i]]), ",", fixed = TRUE)
        here <- lengths(parts)

        # AN EMPTY CELL IS NOT A SITE WITH NO READS, IT IS A SITE WITH NO ALLELES, and it would
        # contribute no allele row at all: rowsum() then returns one total fewer than there are
        # sites, and every depth below it moves up a row without anything being said.
        blank <- which(here < 1)
        if (length(blank) > 0) {
            stop("allele_frequencies: ", label(i), " has no counts at site ", blank[1],
                 ". A cell holds one count per allele and a site holds at least one allele; ",
                 "an empty cell is a table that lost a field, not a pool that saw nothing.")
        }

        if (is.null(alleles)) {
            alleles <- here
            site <- rep.int(seq_len(n_site), alleles)
            # NULL and not list(NULL, NULL) for unnamed columns, which is the state a matrix
            # built without names is in and what the compiled form returns.
            columnNames <- if (is.null(named)) NULL else list(NULL, named)
            depth <- matrix(NA_real_, nrow = n_site, ncol = n_pool, dimnames = columnNames)
            freq <- matrix(NA_real_, nrow = length(site), ncol = n_pool,
                           dimnames = columnNames)
        } else {
            bad <- which(here != alleles)
            if (length(bad) > 0) {
                stop("allele_frequencies: ", label(i), " holds ", here[bad[1]],
                     " counts at site ", bad[1], " where ", label(1), " holds ",
                     alleles[bad[1]], ". One ALT list serves every pool, so a row where the ",
                     "cells differ in length is not the table this reads.")
            }
        }

        flat <- unlist(parts, use.names = FALSE)
        flat[flat == "."] <- NA_character_
        counts <- suppressWarnings(as.numeric(flat))

        total <- as.vector(rowsum(counts, site, reorder = FALSE))
        f <- counts / total[site]

        empty <- !is.na(total) & total <= 0
        total[empty] <- 0
        f[empty[site]] <- NA_real_

        depth[, i] <- total
        freq[, i] <- f
    }

    list(site = site, alleles = alleles, depth = depth, freq = freq)
}
