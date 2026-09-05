# The harmonic mean of `x`, optionally weighted by `w`.
#
# Weighted because a depth histogram is one row per depth and a count of the positions at it:
# sum(w) / sum(w/x) over those rows is the harmonic mean over positions, without expanding the
# histogram back into one entry per position.
#
# NA in either vector drops that pair. A value of zero gives zero, which is the harmonic mean's
# own answer and the one effective size wants: a position carrying no reads carries no
# information. A negative value is not a depth and stops here.
harmonic_mean <- function(x, w = NULL) {
    if (is.null(w)) w <- rep(1, length(x))
    if (length(w) != length(x)) {
        stop("harmonic_mean: ", length(x), " values and ", length(w), " weights")
    }
    keep <- !is.na(x) & !is.na(w)
    x <- x[keep]
    w <- w[keep]
    if (length(x) == 0) return(NA_real_)
    if (any(x < 0)) stop("harmonic_mean: negative values are not depths")
    if (any(w < 0)) stop("harmonic_mean: negative weights")
    if (sum(w) == 0) return(NA_real_)
    if (any(x == 0)) return(0)
    sum(w) / sum(w / x)
}
