# Nei's minimum distance between every pair of pools, accumulated over a set of sites.
#
# Per site, for pools A and B:
#
#     D = (J_A + J_B) / 2 - J_AB
#
# J_A is the probability that two chromosomes drawn from pool A carry the same allele, J_AB the
# probability that one drawn from each does. Expanded over a site's alleles that is
# 1/2 * sum_j (f_Aj - f_Bj)^2, so the sum runs over every allele including the reference and a
# site's frequencies sum to one.
#
# J_A read off a sample is biased upward by the sampling: two reads from one pool agree more
# often than two chromosomes do. The unbiased form subtracts that pool's own diversity at the
# site, scaled by its effective sample size there. J_AB takes no such term — the two pools are
# sequenced independently, so nothing correlates their draws.
#
#     nei_distance(freq, site, n_eff_site)
#
#       freq        one row per ALLELE, one column per pool
#       site        which site each allele row belongs to, non-decreasing
#       n_eff_site  one row per SITE in the order `site` first names them, one column per pool
#
# Returns `raw`, `corrected` and `sites`: two pool-by-pool sums and how many sites each was
# taken over. Sums rather than means, so a table read in bins accumulates with add_distance()
# and becomes a matrix with mean_distance().
#
# A site counts for a pair only where both pools have a frequency there and both have something
# to correct with, so `raw` and `corrected` always cover the same sites and their difference is
# the correction that was applied.
nei_distance <- function(freq, site, n_eff_site) {
    n_pool <- ncol(freq)
    if (ncol(n_eff_site) != n_pool) {
        stop("nei_distance: ", n_pool, " pools of frequencies against ", ncol(n_eff_site),
             " of effective sizes. Both are the same pools read in the same order.")
    }

    within <- rowsum(freq * freq, site, reorder = FALSE)
    if (nrow(within) != nrow(n_eff_site)) {
        stop("nei_distance: ", nrow(within), " sites in the frequencies against ",
             nrow(n_eff_site), " in the effective sizes. Both come from one parse of one table.")
    }

    # A pool worth one chromosome or fewer at a site has nothing left to divide by, and a site
    # read once is such a pool: n_eff is 1 at depth 1 whatever the pool holds.
    unbiased <- within - (1 - within) / (n_eff_site - 1)
    unbiased[!is.na(n_eff_site) & n_eff_site <= 1] <- NA_real_

    raw <- matrix(0, n_pool, n_pool)
    corrected <- matrix(0, n_pool, n_pool)
    sites <- matrix(0, n_pool, n_pool)

    for (a in seq_len(n_pool - 1)) {
        for (b in seq.int(a + 1, n_pool)) {
            between <- as.vector(rowsum(freq[, a] * freq[, b], site, reorder = FALSE))
            here_raw <- 0.5 * (within[, a] + within[, b]) - between
            here_adj <- 0.5 * (unbiased[, a] + unbiased[, b]) - between
            ok <- is.finite(here_raw) & is.finite(here_adj)
            raw[a, b] <- raw[b, a] <- sum(here_raw[ok])
            corrected[a, b] <- corrected[b, a] <- sum(here_adj[ok])
            sites[a, b] <- sites[b, a] <- sum(ok)
        }
    }

    list(raw = raw, corrected = corrected, sites = sites)
}
