# One pool's detection limit: the frequency below which step 7's false-positive filter took a
# call to be error rather than a rare allele.
#
#     1 / (2 * ploidy * pool_size)
#
# Half the frequency of a single chromosome, so a true singleton clears it with margin. Mirrored
# by SENS[name] in bin/filterFalsePositives.sh, which is what actually filtered, and by
# poolSensitivity() in analysis/lib/nf/pools.nf, which is where a module reads it from without
# recomputing it.
pool_sensitivity <- function(ploidy, pool_size) {
    if (any(ploidy < 1, na.rm = TRUE)) stop("pool_sensitivity: ploidy is at least 1")
    if (any(pool_size < 1, na.rm = TRUE)) stop("pool_sensitivity: a pool holds at least one individual")
    1 / (2 * ploidy * pool_size)
}
