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
# THE INPUT MUST BE COORDINATE-SORTED.

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
}

/^@/ { print; next }

{
    # A new reference sequence shares no positions with the last one.
    if ($3 != chrom) { delete depth; chrom = $3; low = $4 + 0 }

    pos = $4 + 0
    span = reflen($6)
    # Unmapped, or a CIGAR that consumes no reference: nothing to count, and nothing to cap.
    if (pos == 0 || span <= 0) { kept++; print; next }

    while (low < pos) { delete depth[low]; low++ }

    end = pos + span - 1
    for (p = pos; p <= end; p++) {
        if (depth[p] + 0 >= cap) { dropped++; next }
    }
    for (p = pos; p <= end; p++) depth[p]++
    kept++
    print
}

END {
    if (cap + 0 > 0)
        printf "cap_depth.awk: kept %d, dropped %d at cap %d\n", kept, dropped, cap > "/dev/stderr"
}
