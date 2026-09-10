# One cell of the depth table, as numbers.
#
# A cell is the read counts for one pool at one site, comma-separated, REF first and then each
# ALT in the order the ALT column gives them. `.` is bcftools' missing value and becomes NA.
#
# The depth table is where every count comes from, never the frequency table: depth2freq.awk
# prints through awk's default CONVFMT, so a published frequency is a six-significant-digit
# rendering of a ratio these integers give exactly.
split_counts <- function(cell) {
    parts <- strsplit(as.character(cell), ",", fixed = TRUE)[[1]]
    parts[parts == "."] <- NA_character_
    suppressWarnings(as.numeric(parts))
}
