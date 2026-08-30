#!/bin/bash

# pipefail is load-bearing: the SAMPLENAMES pipeline below ends in `cut`, which succeeds
# whatever bcftools did.
set -euo pipefail

VCF=""
BCFTOOLS="bcftools"

usage() {
  echo "Usage: $0 -v <vcf-file> [-b <bcftools-path>]"
  echo "Options:"
  echo "  -v <vcf-file>       Input VCF File (required)"
  echo "  -b <bcftools-path>  The path for bcftools. Default: 'bcftools'"
  exit 1
}

while getopts "v:b:" opt; do
  case $opt in
    v) VCF="$OPTARG" ;;
    b) BCFTOOLS="$OPTARG" ;;
    \?) echo "Error: Unknown flag -$OPTARG" >&2; usage ;;
    :) echo "Error: Flag -$OPTARG requires an argument" >&2; usage ;;
  esac
done

if [ -z "$VCF" ]; then
  echo "Error: -v <vcf-file>, is required" >&2
  usage
fi

SAMPLENAMES=$(${BCFTOOLS} view -h ${VCF} | grep '^#CHROM' | cut -f10-)
if [ -z "$SAMPLENAMES" ]; then
  echo "Error: no sample columns found in the #CHROM header of ${VCF}" >&2
  exit 1
fi
echo -e "CHROM\tPOS\tREF\tALT\tTOTAL_AD\t$SAMPLENAMES"
${BCFTOOLS} query -f '%CHROM\t%POS\t%REF\t%ALT\t%INFO/AD[\t%AD]\n' ${VCF}
