# Depth and gene diversity for one pool over many sites, from the depth table's own cells.
#
#     site_diversity(c("50,50", "40,40,20")) -> list(depth = c(100, 100), h = c(0.5, 0.64))
#
# `cells` is one column of the depth table: one comma-separated count list per site, REF first
# and then each ALT. A site holds any number of alleles, so the counts are flattened into one
# vector and grouped, never held as a rectangle.
#
# THE GROUPING VECTOR IS THE SITE INDEX, REPEATED ONCE PER ALLELE. H sums p^2 over the ALLELES
# of a site; summing over sites instead is a different quantity entirely and would return one
# number where this returns one per site. rowsum() with that vector is what keeps them apart.
#
# A site with no reads gets NA, by one assignment here rather than a branch per site. The
# per-site form this replaced lives on in test/tools/r_lib_tests.R as the oracle it is
# checked against, over mixed-arity sites.
site_diversity <- function(cells) {
    parts <- strsplit(as.character(cells), ",", fixed = TRUE)
    alleles <- lengths(parts)
    flat <- unlist(parts, use.names = FALSE)
    flat[flat == "."] <- NA_character_
    counts <- suppressWarnings(as.numeric(flat))

    site <- rep.int(seq_along(parts), alleles)
    total <- as.vector(rowsum(counts, site, reorder = FALSE))
    p <- counts / total[site]
    h <- 1 - as.vector(rowsum(p * p, site, reorder = FALSE))

    empty <- !is.na(total) & total <= 0
    total[empty] <- 0
    h[empty] <- NA_real_
    list(depth = total, h = h)
}
