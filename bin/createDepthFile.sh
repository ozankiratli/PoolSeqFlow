#!/bin/bash

# Initialize variables
VCF=""
BCFTOOLS="bcftools"

# Usage help function
usage() {
  echo "Usage: $0 -v <vcf-file> -t <threshold> -s <sensitivity> [-b <bcftools-path>]"
  echo "Options:"
  echo "  -v <vcf-file>       Input VCF File (required)"
  echo "  -b <bcftools-path>  The path for bcftools. Default: 'bcftools'"
  exit 1
}

# Parse flags with getopts
while getopts "v:b:" opt; do
  case $opt in
    v) VCF="$OPTARG" ;;
    b) BCFTOOLS="$OPTARG" ;;
    \?) echo "Error: Unknown flag -$OPTARG" >&2; usage ;;
    :) echo "Error: Flag -$OPTARG requires an argument" >&2; usage ;;
  esac
done

# Validate required flags
if [ -z "$VCF" ]; then
  echo "Error: -v <vcf-file>, is required" >&2
  usage
fi

SAMPLENAMES=`${BCFTOOLS} view -h ${VCF} | grep '^#CHROM' | cut -f10-`
echo -e "CHROM\tPOS\tREF\tALT\tTOTAL_AD\t$SAMPLENAMES"
${BCFTOOLS} query -f '%CHROM\t%POS\t%REF\t%ALT\t%INFO/AD[\t%AD]\n' ${VCF}
