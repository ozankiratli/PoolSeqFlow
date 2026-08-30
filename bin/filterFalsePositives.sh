#!/bin/bash

# pipefail is load-bearing: the pipeline below ends in awk, which succeeds on empty input.
set -euo pipefail

VCF=""
THRESHOLD=""
SENSITIVITY=""
POOLSIZES=""
DIPLOIDY=""
BCFTOOLS="bcftools"

usage() {
  echo "Usage: $0 -v <vcf-file> -t <threshold> -s <sensitivity> [-p <pool sizes> -d <diploidy>] [-b <bcftools-path>]"
  echo "Options:"
  echo "  -v <vcf-file>       Input VCF File (required)"
  echo "  -t <threshold>      Proportion of the samples to possess the rare allele (required)"
  echo "  -s <sensitivity>    The sensitivity level of the poolseq analysis, applied to every"
  echo "                      sample column. Used on its own when -p is not given."
  echo "                      s = 1 / (2 * [DIPLOIDY] * [POOLSIZE per SAMPLE])"
  echo "  -p <pool sizes>     Per-pool sizes as 'Name=count,Name=count', where Name is the"
  echo "                      VCF's own sample column name. Each column then gets its own"
  echo "                      sensitivity from the formula above instead of the flat -s."
  echo "                      Requires -d. EVERY column must be named: a pool this does not"
  echo "                      mention is refused rather than quietly given the -s value."
  echo "  -d <diploidy>       Ploidy of one individual, for the -p formula (required with -p)"
  echo "  -b <bcftools-path>  The path for bcftools. Default: 'bcftools'"
  exit 1
}

while getopts "v:t:s:p:d:b:" opt; do
  case $opt in
    v) VCF="$OPTARG" ;;
    t) THRESHOLD="$OPTARG" ;;
    s) SENSITIVITY="$OPTARG" ;;
    p) POOLSIZES="$OPTARG" ;;
    d) DIPLOIDY="$OPTARG" ;;
    b) BCFTOOLS="$OPTARG" ;;
    \?) echo "Error: Unknown flag -$OPTARG" >&2; usage ;;
    :) echo "Error: Flag -$OPTARG requires an argument" >&2; usage ;;
  esac
done

if [ -z "$VCF" ] || [ -z "$THRESHOLD" ] || [ -z "$SENSITIVITY" ]; then
  echo "Error: -v, -t and -s are required flags" >&2
  usage
fi

# -p carries sizes, not sensitivities, so it needs the ploidy to turn one into a threshold.
if [ -n "$POOLSIZES" ] && [ -z "$DIPLOIDY" ]; then
  echo "Error: -p needs -d, to turn a pool size into a sensitivity" >&2
  usage
fi

SAMPLENUMBER=$(${BCFTOOLS} query -l ${VCF} | wc -l)
# Zero samples would set MINSAMPLES to zero and disable the cross-sample filter, not fail.
if [ "$SAMPLENUMBER" -eq 0 ]; then
  echo "Error: no samples found in ${VCF}" >&2
  exit 1
fi
MINSAMPLES=$(awk "BEGIN {printf \"%f\", $SAMPLENUMBER * $THRESHOLD}")

# Each column gets its own threshold, matched on the VCF's sample NAME rather than its position.
# A column with no pool size is refused when -p was given, and takes -s when it was not.
${BCFTOOLS} norm -m - ${VCF} | \
${BCFTOOLS} view -i "INFO/AD[1]>0" | \
awk -v pools="${POOLSIZES}" -v diploidy="${DIPLOIDY}" -v fallback="${SENSITIVITY}" \
    -v minsamples="${MINSAMPLES}" '
BEGIN {
    FS = OFS = "\t"
    strict = (pools != "")
    n = split(pools, entries, ",")
    for (i = 1; i <= n; i++) {
        if (entries[i] == "") continue
        eq = index(entries[i], "=")
        if (eq == 0) {
            print "-p entry \"" entries[i] "\" is not Name=count" > "/dev/stderr"; exit 1
        }
        name = substr(entries[i], 1, eq - 1)
        size = substr(entries[i], eq + 1) + 0
        if (size <= 0) {
            print "-p gives pool \"" name "\" a size of " size > "/dev/stderr"; exit 1
        }
        SIZE[name] = size
        SENS[name] = 1 / (2 * diploidy * size)
    }
}
/^##/ { print; next }
/^#CHROM/ {
    for (c = 10; c <= NF; c++) {
        if (c in SENS_OF) continue
        if ($c in SENS) {
            SENS_OF[c] = SENS[$c]
            # Records the size and threshold used, in the VCF header.
            printf "##PoolSeqFlowPool=<ID=%s,PoolSize=%d,Sensitivity=%.10g>\n", \
                   $c, SIZE[$c], SENS[$c]
        } else if (strict) {
            print "the VCF has a sample column \"" $c "\" that -p gives no pool size for; " \
                  "refusing rather than filtering it at some other pool'"'"'s threshold" \
                  > "/dev/stderr"
            exit 1
        } else {
            SENS_OF[c] = fallback
        }
    }
    print; next
}
{
    # AD and DP are located per record: bcftools writes FORMAT in whatever order the fields were
    # produced.
    split($9, fmt, ":"); adi = 0; dpi = 0
    for (i in fmt) { if (fmt[i] == "AD") adi = i; else if (fmt[i] == "DP") dpi = i }
    if (!adi || !dpi) {
        print "record at " $1 ":" $2 " has no AD or DP in FORMAT" > "/dev/stderr"; exit 1
    }
    count = 0
    for (c = 10; c <= NF; c++) {
        split($c, f, ":")
        split(f[adi], ad, ",")
        dp = f[dpi] + 0
        # norm -m - has already made every record biallelic, so ad[2] is THE alternate depth.
        if (dp > 0 && ad[2] != "" && ad[2] != "." && (ad[2] + 0) / dp >= SENS_OF[c]) count++
    }
    if (count >= minsamples) print
}' | \
awk -v OFS="\t" 'BEGIN { FS=OFS="\t" } /^#/ { print; next } { gsub("\\*", "X", $5); print }' | \
${BCFTOOLS} norm -m+ | \
awk -v OFS="\t" 'BEGIN { FS=OFS="\t" } /^#/ { print; next } { gsub("X", "\\*", $5); print }'
