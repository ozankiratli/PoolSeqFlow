#!/usr/bin/awk -f
#
# The depth table's read counts as per-allele frequencies, one row per allele.
#
#   depth2freq.awk < <vcf>_snp_depth.tsv > <vcf>_snp_freq.tsv
#
# In:  CHROM POS REF ALT, then one column per sample holding a comma-separated count list, REF
#      first and then each ALT in the order the ALT column gives them.
# Out: the same leading columns with ALT replaced by ALLELE, and one row per allele of a site,
#      each carrying that allele's frequency in each sample.
#
# EVERY COLUMN FROM 5 ON IS CONVERTED THE SAME WAY, TOTAL_AD included.
#
# Frequencies print through awk's default CONVFMT, so each is a six-significant-digit rendering
# of a ratio the input holds exactly, and a sample with no reads at a site prints 0 rather than
# a blank. Anything computing from these numbers reads the DEPTH table instead.

BEGIN {
    FS = OFS = "\t";
}
NR == 1 {
    $4 = "ALLELE";
    print;
    next;
}
{
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

        for (j in freqs) {
            parsed_vals[i, j] = freqs[j];
        }
    }

    # REF joins the front of the ALT list, so every allele gets a row of its own.
    $4 = $3","$4;
    split($4, alleles, ",");

    for (j = 1; j <= length(alleles); j++) {
        printf "%s\t%s\t%s\t%s", chrom, pos, ref, alleles[j];

        for (i = 5; i <= NF; i++) {
            printf "\t%s", parsed_vals[i, j];
        }
        print "";
    }
}