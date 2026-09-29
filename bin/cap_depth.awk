#!/usr/bin/awk -f
#
# Truncate a coordinate-sorted SAM stream so no reference position is covered more than `cap`
# times.
#
#   samtools view -h in.bam | cap_depth.awk -v cap=500 | samtools view -b -o out.bam -
#
# Reads a whole SAM on stdin, header included, and writes the records that were kept. Prints a
# kept/dropped tally to stderr. Exit 2 if `cap` is not a positive depth.
#
# A read is kept only if every position it covers is still below the cap. Reads are dropped
# individually, so a pair may lose one mate.
#
# THE INPUT MUST BE COORDINATE-SORTED. Every read already kept therefore starts at or before
# this one, so it covers a position only if its end reaches that far: the depth over this
# read's span is non-increasing and its first position carries the maximum. Coverage is held
# as a difference array and read off a running total at that one position.

function reflen(cigar,   i, c, num, len) {
    # Only M, D, N, = and X consume the reference; I, S, H and P do not.
    len = 0
    num = ""
    for (i = 1; i <= length(cigar); i++) {
        c = substr(cigar, i, 1)
        if (c >= "0" && c <= "9") { num = num c; continue }
        if (c == "M" || c == "D" || c == "N" || c == "=" || c == "X") len += num + 0
        num = ""
    }
    return len
}

BEGIN {
    FS = "\t"
    if (cap + 0 <= 0) {
        print "cap_depth.awk: cap must be a positive depth, not '" cap "'" > "/dev/stderr"
        exit 2
    }
    chrom = ""
    low = 0
    cur = 0
}

/^@/ { print; next }

{
    # A new reference sequence shares no positions with the last one.
    if ($3 != chrom) { delete diff; chrom = $3; low = $4 + 0; cur = 0 }

    pos = $4 + 0
    span = reflen($6)
    # Unmapped, or a CIGAR that consumes no reference: nothing to count, and nothing to cap.
    if (pos == 0 || span <= 0) { kept++; print; next }

    # Carry the running depth forward to this read's first position, consuming each entry as
    # it is passed. `in` rather than a plain read: referencing diff[low] would create it, and
    # most positions hold nothing.
    while (low < pos) { low++; if (low in diff) { cur += diff[low]; delete diff[low] } }

    # cur is the depth at pos, which is the largest over this read's span.
    if (cur >= cap) { dropped++; next }

    cur++                   # this read covers pos
    diff[pos + span]--      # and stops one past its last position
    kept++
    print
}

END {
    # A BEGIN that exits still runs END, so the tally is not printed after the usage error.
    if (cap + 0 > 0)
        printf "cap_depth.awk: kept %d, dropped %d at cap %d\n", kept, dropped, cap > "/dev/stderr"
}
