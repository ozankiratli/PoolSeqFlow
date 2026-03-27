#!/usr/bin/env python3

import re
import sys
import argparse
from pathlib import Path


def reorder_to_make_most_read_ref(vcf_file, output_file):
    """
    Reorder VCF alleles to make the most frequently read allele the reference.

    Args:
        vcf_file (str): Input VCF file path
        output_file (str): Output VCF file path
    """
    with open(vcf_file, 'r') as infile, open(output_file, 'w') as outfile:
        format_fields = None
        ad_idx = None
        gt_idx = None

        for line in infile:
            if line.startswith("#"):
                # Write header lines as-is
                outfile.write(line)
                continue

            fields = line.strip().split('\t')
            chrom, pos, id_, ref, alts, qual, filter_, info, format_, *samples = fields

            # Parse INFO/AD (site-level)
            ad_info = [int(x) for x in info.split("AD=")[1].split(";")[0].split(",")]
            allele_counts = [ad_info[0]] + ad_info[1:]  # Include REF + ALT counts

            # Sort alleles by total read counts (most-read first)
            sorted_indices = sorted(range(len(allele_counts)), key=lambda i: -allele_counts[i])

            # Update REF and ALT
            new_ref = ref if sorted_indices[0] == 0 else alts.split(",")[sorted_indices[0] - 1]
            new_alts = [ref if i == 0 else alts.split(",")[i - 1] for i in sorted_indices if i != sorted_indices[0]]

            # Update INFO/AD
            new_ad_info = [allele_counts[i] for i in sorted_indices]
            info = info.replace("AD=" + ",".join(map(str, ad_info)), "AD=" + ",".join(map(str, new_ad_info)))

            # Update INFO/DP from AD sum
            new_dp = sum(new_ad_info)
            info = re.sub(r'DP=\d+', f'DP={new_dp}', info)

            if format_fields is None:
                format_fields = format_.split(":")
                if "AD" not in format_fields:
                    print("No FORMAT/AD field in VCF. Check variant calling steps! Quitting!")
                    sys.exit(1)
                ad_idx = format_fields.index("AD")
                dp_idx = format_fields.index("DP") if "DP" in format_fields else None
                gt_idx = format_fields.index("GT") if "GT" in format_fields else None

            # Parse sample-level FORMAT/AD fields
            ad_format = [sample.split(":")[ad_idx] for sample in samples]
            sample_alleles = [[int(x) for x in ad.split(",")] for ad in ad_format]

            new_samples = []
            for i, sample in enumerate(sample_alleles):
                reordered_sample = [sample[j] for j in sorted_indices]
                new_sample = samples[i].split(":")
                new_sample[ad_idx] = ",".join(map(str, reordered_sample))
                if dp_idx is not None:
                    new_sample[dp_idx] = str(sum(reordered_sample))
                if gt_idx is not None:
                    new_sample[gt_idx] = "./."
                new_samples.append(":".join(new_sample))

            # Write reordered line
            outfile.write("\t".join([
                chrom, pos, id_, new_ref, ",".join(new_alts), qual, filter_, info, format_
            ] + new_samples) + "\n")

def main():
    # Set up argument parser
    parser = argparse.ArgumentParser(
        description='Reorder VCF alleles to make most frequent allele the reference'
    )
    parser.add_argument(
        'input_vcf',
        type=str,
        help='Input VCF file'
    )
    parser.add_argument(
        'output_vcf',
        type=str,
        help='Output VCF file'
    )
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Print progress information'
    )

    # Parse arguments
    args = parser.parse_args()

    # Check input file exists
    if not Path(args.input_vcf).exists():
        sys.exit(f"Error: Input file {args.input_vcf} does not exist")

    # Check output directory exists
    output_dir = Path(args.output_vcf).parent
    if not output_dir.exists():
        sys.exit(f"Error: Output directory {output_dir} does not exist")

    if args.verbose:
        print(f"Processing {args.input_vcf}")
        print(f"Writing to {args.output_vcf}")

    try:
        reorder_to_make_most_read_ref(args.input_vcf, args.output_vcf)
        if args.verbose:
            print("Processing completed successfully")
    except Exception as e:
        sys.exit(f"Error during processing: {str(e)}")

if __name__ == "__main__":
    main()
