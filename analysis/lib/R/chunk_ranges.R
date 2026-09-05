# `n` items split into consecutive chunks of at most `size`, as from/to index pairs.
#
#     chunk_ranges(7, 3) -> list(c(1, 3), c(4, 6), c(7, 7))
#
# What a parallel loop iterates over. The chunks partition 1..n in order and never overlap, so
# a result assembled from them in order is what the whole vector would have given - the site
# statistics are independent, and the chunk size changes only how the work is handed out.
#
# n = 0 gives an empty list, which a loop runs zero times over.
chunk_ranges <- function(n, size) {
    if (length(n) != 1 || is.na(n) || n < 0) stop("chunk_ranges: n is a count")
    if (length(size) != 1 || is.na(size) || size < 1) stop("chunk_ranges: size is at least 1")
    if (n == 0) return(list())
    starts <- seq.int(1, n, by = size)
    lapply(starts, function(from) c(from, min(from + size - 1, n)))
}
