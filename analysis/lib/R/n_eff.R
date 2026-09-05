# The effective sample size of one pool at one site: how many independent chromosomes a
# frequency read off `depth` reads from a pool of `n_chrom` is worth.
#
#     n_eff = n_chrom * depth / (n_chrom + depth - 1)
#
# `n_chrom` is the pool's HAPLOID size, ploidy * poolSize, which is the only place ploidy
# enters. Both limits hold: unlimited depth gives n_chrom, an unlimited pool gives depth.
#
# The -1 is not a slip. A second form, n*d/(n + d), is also in circulation and differs at low
# depth; the manual says which is which and what this one follows.
#
# Vectorised over either argument. A site a pool has no reads at gets NA rather than 0: there is
# no frequency there to weight, and a zero would average in as though there were.
n_eff <- function(n_chrom, depth) {
    if (any(n_chrom < 1, na.rm = TRUE)) stop("n_eff: a pool holds at least one chromosome")
    if (any(depth < 0, na.rm = TRUE)) stop("n_eff: negative depth")
    out <- n_chrom * depth / (n_chrom + depth - 1)
    out[!is.na(depth) & depth == 0] <- NA_real_
    out
}
