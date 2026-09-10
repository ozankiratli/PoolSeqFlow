# Two nei_distance() accumulations added, for a table read in bins or across workers.
#
#     add_distance(NULL, first)          -> first
#     add_distance(first, second)        -> the two summed, field by field
#
# All three fields are sums over sites, so adding them is what reading the table in one pass
# would have given. A NULL left side is the empty accumulator a fold starts from.
#
# The two must hold the same pools in the same order; a mismatch is R's own error on matrices of
# different shape.
add_distance <- function(left, right) {
    if (is.null(left)) return(right)
    if (is.null(right)) return(left)
    list(raw = left$raw + right$raw,
         corrected = left$corrected + right$corrected,
         sites = left$sites + right$sites)
}
