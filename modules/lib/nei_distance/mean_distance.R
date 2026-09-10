# A nei_distance() accumulation turned into the per-site mean each pair was taken over.
#
#     mean_distance(accumulated$corrected, accumulated$sites)
#
# Every pair is divided by its OWN site count, not by a count shared across the matrix. A pool
# with no reads at a site drops that site for its own pairs and leaves the others alone, so two
# pairs of one run can rest on different numbers of sites.
#
# A pair with no site in common gives NA rather than a division by zero. The diagonal is zero:
# a pool's distance from itself is not accumulated, and 0/0 would leave it NaN.
mean_distance <- function(total, sites) {
    out <- total / sites
    out[sites == 0] <- NA_real_
    diag(out) <- 0
    out
}
