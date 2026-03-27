#!/usr/bin/awk -f

BEGIN {
    FS = OFS = "\t";
}
NR == 1 {
    # Write modified header
    $4 = "ALLELE";
    print;
    next;
}
{
    # Store original values
    chrom = $1;
    pos = $2;
    ref = $3;

    # Process each sample column (from column 5 onwards)
    for (i = 5; i <= NF; i++) {
        split($i, counts, ",");
        total = 0;
        delete freqs;

        # Calculate total depth
        for (j in counts) {
            total += counts[j];
        }

        # Calculate frequencies
        for (j = 1; j <= length(counts); j++) {
            freqs[j] = (total > 0) ? counts[j] / total : 0;
        }

        # Store frequencies for later use
        for (j in freqs) {
            parsed_vals[i, j] = freqs[j];
        }
    }

    # Split alleles
    $4 = $3","$4;
    split($4, alleles, ",");

    # Print row for each allele
    for (j = 1; j <= length(alleles); j++) {
        printf "%s\t%s\t%s\t%s", chrom, pos, ref, alleles[j];

        # Print each samples frequency
        for (i = 5; i <= NF; i++) {
            printf "\t%s", parsed_vals[i, j];
        }
        print "";
    }
}