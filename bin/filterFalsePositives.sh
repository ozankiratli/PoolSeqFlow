#!/bin/bash

# pipefail is what matters here: this script's real work is one long pipeline whose last
# stage is awk, and awk succeeds on empty input. Without it every bcftools in the chain
# could fail and the script would still exit 0, emitting an empty VCF that the caller
# publishes to permanent storage - where the existence-based skip logic then reuses it on
# every later run, even after the underlying problem is fixed.
set -euo pipefail

# Initialize variables
VCF=""
THRESHOLD=""
SENSITIVITY=""
BCFTOOLS="bcftools"

# Usage help function
usage() {
  echo "Usage: $0 -v <vcf-file> -t <threshold> -s <sensitivity> [-b <bcftools-path>]"
  echo "Options:"
  echo "  -v <vcf-file>       Input VCF File (required)"
  echo "  -t <threshold>      Proportion of the samples to possess the rare allele (required)"
  echo "  -s <sensitivity>    The sensitivity level of the poolseq analysis."
  echo "                      Sensitivity can be calculated with the following formula."
  echo "                      s = 1 / (2 * [DIPLOIDY] * [POOLSIZE per SAMPLE])"
  echo "  -b <bcftools-path>  The path for bcftools. Default: 'bcftools'"
  exit 1
}

# Parse flags with getopts
while getopts "v:t:s:b:" opt; do
  case $opt in
    v) VCF="$OPTARG" ;;
    t) THRESHOLD="$OPTARG" ;;
    s) SENSITIVITY="$OPTARG" ;;
    b) BCFTOOLS="$OPTARG" ;;
    \?) echo "Error: Unknown flag -$OPTARG" >&2; usage ;;
    :) echo "Error: Flag -$OPTARG requires an argument" >&2; usage ;;
  esac
done
 
# Validate required flags
if [ -z "$VCF" ] || [ -z "$THRESHOLD" ] || [ -z "$SENSITIVITY" ]; then
  echo "Error: -v, -t and -s are required flags" >&2
  usage
fi

SAMPLENUMBER=$(${BCFTOOLS} query -l ${VCF} | wc -l)
# Checked rather than assumed: MINSAMPLES is the right-hand side of the COUNT(...) >= N
# clause below, so a sample count of zero does not fail - it quietly sets the threshold to
# zero and disables the cross-sample filter while the rest of the expression still runs.
if [ "$SAMPLENUMBER" -eq 0 ]; then
  echo "Error: no samples found in ${VCF}" >&2
  exit 1
fi
MINSAMPLES=$(awk "BEGIN {printf \"%f\", $SAMPLENUMBER * $THRESHOLD}")

${BCFTOOLS} norm -m - ${VCF} | \
${BCFTOOLS} view -i "INFO/AD[1]>0 && COUNT(FORMAT/AD[:1]/FORMAT/DP[:] >= ${SENSITIVITY}) >= ${MINSAMPLES}" | \
awk -v OFS="\t" 'BEGIN { FS=OFS="\t" } /^#/ { print; next } { gsub("\\*", "X", $5); print }' | \
${BCFTOOLS} norm -m+ | \
awk -v OFS="\t" 'BEGIN { FS=OFS="\t" } /^#/ { print; next } { gsub("X", "\\*", $5); print }'
