# One pool's effective sample size over many sites, from its harmonic mean depth.
#
#     1/n_eff = 1/n_chrom + (1 - 1/n_chrom) * 1/harmonic_depth
#
# The harmonic mean is what averages n_eff, because 1/n_eff is linear in 1/depth — so a pool
# collapses to two numbers rather than one per site, exactly.
#
# `harmonic_depth` is harmonic_mean() over whatever set of positions is being summarised: the
# depth histogram's genome-wide one, or the depths at called sites.
pool_n_eff <- function(n_chrom, harmonic_depth) {
    if (any(n_chrom < 1, na.rm = TRUE)) stop("pool_n_eff: a pool holds at least one chromosome")
    if (any(harmonic_depth < 0, na.rm = TRUE)) stop("pool_n_eff: negative depth")
    out <- 1 / (1 / n_chrom + (1 - 1 / n_chrom) / harmonic_depth)
    out[!is.na(harmonic_depth) & harmonic_depth == 0] <- NA_real_
    out
}
