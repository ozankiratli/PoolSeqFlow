#!/usr/bin/awk -f
#
# Keep a site where enough of its cells were read to the depth floor, and write every other cell
# there as unread: the depth filter when vcffilter.keepLowDepthAsZero is on. A cell is one pool's
# reads at one site, one sample column of one record.
#
#   mask_depth.awk -v minDP=20 -v minSamples=2 < in.vcf > out.vcf
#
# A cell is READ when its FORMAT/DP is at least minDP and above zero. Any other cell is masked:
# its FORMAT/AD becomes one 0 per allele and its FORMAT/DP 0, which the depth table carries as
# zeros and the frequency table as NA. A site is kept when at least minSamples of its cells are
# read, and dropped otherwise.
#
# INFO/AD and INFO/DP are recomputed from the cells as written, the sums MajorAlleleToRef.py
# leaves them as, so the depth table's TOTAL_AD counts only the cells that measured the site.
# Every other INFO key, DP4 among them, still counts every read. A site with nothing masked is
# written exactly as it came. Header lines pass through.
BEGIN {
    FS = OFS = "\t"
    if (minDP !~ /^[0-9]+(\.[0-9]+)?$/ || minSamples !~ /^[0-9]+$/) {
        print "mask_depth.awk: -v minDP=<reads> and -v minSamples=<cells> are both required," \
              " minDP a number and minSamples a whole number; got minDP '" minDP "' and" \
              " minSamples '" minSamples "'" > "/dev/stderr"
        failed = 2
        exit failed
    }
    minDP += 0
    minSamples += 0
}

/^#/ { print; next }

{
    keys = split($9, format, ":")
    ad = 0
    dp = 0
    for (i = 1; i <= keys; i++) {
        if (format[i] == "AD") ad = i
        else if (format[i] == "DP") dp = i
    }
    if (!ad || !dp) {
        print "mask_depth.awk: " $1 ":" $2 " has FORMAT " $9 ", and both AD and DP are needed" \
              > "/dev/stderr"
        failed = 1
        exit failed
    }

    alleles = ($5 == ".") ? 1 : split($5, alts, ",") + 1
    zeros = "0"
    for (j = 2; j <= alleles; j++) zeros = zeros ",0"

    read = 0
    masked = 0
    for (j = 1; j <= alleles; j++) total[j] = 0
    for (s = 10; s <= NF; s++) {
        parts = split($s, cell, ":")
        depth = cell[dp] + 0
        if (depth >= minDP && depth > 0) {
            read++
        } else {
            cell[ad] = zeros
            cell[dp] = 0
            # A cell may stop short of the FORMAT keys; the missing ones are written as `.`.
            if (parts < ad) parts = ad
            if (parts < dp) parts = dp
            rebuilt = cell[1]
            for (k = 2; k <= parts; k++) rebuilt = rebuilt ":" ((k in cell) ? cell[k] : ".")
            $s = rebuilt
            masked++
        }
        split(cell[ad], counts, ",")
        for (j = 1; j <= alleles; j++) total[j] += counts[j]
    }

    if (read < minSamples) next

    if (masked) {
        cohort = total[1]
        sum = total[1]
        for (j = 2; j <= alleles; j++) {
            cohort = cohort "," total[j]
            sum += total[j]
        }
        fields = split($8, info, ";")
        rewritten = ""
        for (k = 1; k <= fields; k++) {
            key = info[k]
            sub(/=.*/, "", key)
            if (key == "AD") info[k] = "AD=" cohort
            else if (key == "DP") info[k] = "DP=" sum
            rewritten = (k == 1) ? info[k] : rewritten ";" info[k]
        }
        $8 = rewritten
    }
    print
}

END { if (failed) exit failed }
