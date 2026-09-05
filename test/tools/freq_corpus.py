#!/usr/bin/env python3
"""Build the published tables that the basicstats module is judged against.

Usage: freq_corpus.py <Output-directory> [<sidecar-directory>]

Writes, under the Output directory, exactly what a completed run publishes and nothing else:

    Frequencies/Test_snp_depth.tsv      the depth tables, exactly as step 7 publishes them
    Frequencies/Test_indel_depth.tsv
    Reports/Depth/<sample>_depth_histogram.tsv   the COV section of samtools stats

and under the sidecar directory, which defaults to the same place, what only the tests read:

    expected.tsv                        key<TAB>value, what a module must compute from them
    design.json, pools.json             what the frame hands a module, for calling one directly

The frequency tables are NOT written here. `bin/depth2freq.awk` derives them from the depth
tables, and the fixture runs that same converter, so the pair cannot drift from the contract.

EXPLICIT, NOT SAMPLED. Every read count below is written out, and `expected.tsv` is computed
from them by the plain loops at the bottom of this file - no vectorisation, no library, nothing
shared with the R under test. The corpus is small enough to check by hand, and the docstring of
each expectation says how.

WHAT THE SITES ARE FOR

  chr1:100   biallelic, one pool fixed for REF, one at 30/70 - the ordinary case
  chr1:250   the same alleles at six different depths, so a depth read off the wrong column
             changes every weighted number
  chr1:400   nearly monomorphic. TestSample2 sits at 1 read in 100 and is NOT segregating,
             TestSample3 at 3 in 100 IS: the k/depth limb of the threshold, on both sides
  chr2:100   TRIALLELIC. 1 - sum(p^2) needs every allele; 2p(1-p) cannot reach this row
  chr2:250   TETRALLELIC, including one pool at 25/25/25/25 where H is exactly 0.75
  chr2:400   pools FIXED FOR THE ALTERNATE allele. TestSample1 and TestSample5 hold no
             reference read at all, so they are not segregating - and reading the majority off
             the reference column instead of each pool's own would say every one of them is
  chr10:500  chr10 comes THIRD in the file and must stay third. R sorts it second
  chr10:900  THE SITE WHERE THE TWO LIMBS OF max(sensitivity, k/depth) SWAP PLACES, and it
             holds one pool on each side of the swap. TestSample5 is 2000 deep with 6 alternate
             reads and IS segregating; TestSample6 is 4000 deep with 4 and is NOT, because at
             that depth 2 reads is below the pool's own detection limit and k/depth alone would
             admit it. Neither limb can be dropped without one of them changing

THE INDEL TABLE is separate because the site counts report SNPs and indels separately, and
because diversity is computed over the SNP table alone - a gate the module states.

NO CELL IS ZERO-DEPTH. vcffilter.minDP removes a site where ANY sample falls below the depth,
so a published table cannot hold one; the NA path in n_eff() is exercised by the library's own
unit tests instead.
"""

import json
import os
import sys

# The six pools of test/data/base/metadata.csv, in the order the table's columns take.
POOLS = ["TestSample%d" % n for n in range(1, 7)]

# What the pipeline filtered with, from parameters.config.template. n_chrom = ploidy * poolSize.
POOL_SIZE = 100
PLOIDY = 2
N_CHROM = PLOIDY * POOL_SIZE
SENSITIVITY = 1.0 / (2 * PLOIDY * POOL_SIZE)

# The default of analysis.basicstats.minReads: the alternate reads a pool needs before a site
# counts as segregating for it, whatever the depth.
MIN_READS = 2

# chrom, pos, REF, [ALT...], counts per pool in the order POOLS gives them. Each count list is
# REF first, then one per ALT - the depth table's own cell order.
SNP_SITES = [
    ("chr1", 100, "A", ["G"], [
        [50, 50], [75, 25], [90, 10], [100, 0], [30, 70], [20, 20]]),
    ("chr1", 250, "C", ["T"], [
        [30, 10], [60, 60], [160, 40], [24, 16], [25, 25], [45, 15]]),
    ("chr1", 400, "G", ["A"], [
        [100, 0], [99, 1], [97, 3], [100, 0], [100, 0], [396, 4]]),
    ("chr2", 100, "T", ["C", "A"], [
        [40, 40, 20], [50, 30, 20], [60, 20, 20], [80, 10, 10], [20, 20, 20], [100, 50, 50]]),
    ("chr2", 250, "A", ["G", "C", "T"], [
        [25, 25, 25, 25], [40, 20, 20, 20], [70, 10, 10, 10],
        [10, 10, 10, 10], [50, 30, 10, 10], [100, 60, 20, 20]]),
    ("chr2", 400, "T", ["G"], [
        [0, 100], [1, 99], [3, 97], [50, 50], [0, 200], [100, 0]]),
    ("chr10", 500, "G", ["T"], [
        [90, 10], [80, 20], [50, 50], [36, 4], [150, 50], [100, 100]]),
    ("chr10", 900, "C", ["A"], [
        [60, 40], [20, 20], [75, 25], [95, 5], [1994, 6], [3996, 4]]),
]

INDEL_SITES = [
    ("chr1", 600, "T", ["TA"], [
        [80, 20], [90, 10], [70, 30], [100, 0], [60, 40], [50, 50]]),
    ("chr2", 700, "CAG", ["C"], [
        [95, 5], [85, 15], [100, 0], [75, 25], [90, 10], [100, 0]]),
    ("chr10", 1200, "A", ["AT", "ATT"], [
        [60, 20, 20], [80, 10, 10], [50, 25, 25], [90, 5, 5], [70, 20, 10], [100, 0, 0]]),
]

# Genome-wide depth per library, as `samtools stats -c` reports it: depth, then the positions at
# that depth. Two bins each, chosen so the harmonic mean is exact: TestSample1 is
# 4000 / (2000/25 + 2000/100) = 4000/100 = 40.
HISTOGRAMS = {
    "TestSample1": [(25, 2000), (100, 2000)],    # H = 40
    "TestSample2": [(50, 3000), (150, 1000)],    # H = 60
    "TestSample3": [(40, 1000), (80, 3000)],     # H = 64
    "TestSample4": [(30, 2000), (60, 2000)],     # H = 40
    "TestSample5": [(100, 4000)],                # H = 100
    "TestSample6": [(20, 1000), (200, 3000)],    # H = 4000/65
}


def depth_table(sites):
    """The table step 7 publishes: TOTAL_AD is the cohort's per-allele sum, as bcftools writes."""
    lines = ["\t".join(["CHROM", "POS", "REF", "ALT", "TOTAL_AD"] + POOLS)]
    for chrom, pos, ref, alts, cells in sites:
        total = [sum(cell[i] for cell in cells) for i in range(len(alts) + 1)]
        row = [chrom, str(pos), ref, ",".join(alts), ",".join(str(c) for c in total)]
        row += [",".join(str(c) for c in cell) for cell in cells]
        lines.append("\t".join(row))
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------------------------
# The reference implementation. Plain loops over the lists above, sharing nothing with the R.


def gene_diversity(counts):
    """1 - sum(p^2) over every allele at the site. chr2:250 TestSample1 is 1 - 4*0.25^2 = 0.75."""
    total = sum(counts)
    return 1.0 - sum((c / total) ** 2 for c in counts)


def n_eff(n_chrom, depth):
    return n_chrom * depth / (n_chrom + depth - 1.0)


def harmonic(values, weights=None):
    if weights is None:
        weights = [1.0] * len(values)
    return sum(weights) / sum(w / v for v, w in zip(values, weights))


def median(values):
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return float(ordered[mid])
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def segregating(counts):
    """Any allele but the pool's OWN major one reaching max(sensitivity, minReads/depth).

    The pool's major and not the cohort's: a pool fixed for an allele the cohort calls
    alternate is not segregating, and reading the majority off the REF column would say it is.
    chr1:400 is the pair that pins the k/depth limb - 1 read in 100 fails, 3 in 100 passes.
    """
    total = sum(counts)
    threshold = max(SENSITIVITY, MIN_READS / float(total))
    major = counts.index(max(counts))
    return any(c / float(total) >= threshold
               for i, c in enumerate(counts) if i != major)


def expectations():
    lines = []

    def put(key, value):
        lines.append("%s\t%.12g" % (key, value))

    # Site counts, per chromosome and per kind. Pool-invariant: they are properties of the
    # table. `alleles` counts the rows the frequency table holds, REF included.
    for kind, sites in (("snp", SNP_SITES), ("indel", INDEL_SITES)):
        for chrom in ordered_chroms(sites):
            here = [s for s in sites if s[0] == chrom]
            put("sites.%s.%s.sites" % (chrom, kind), len(here))
            put("sites.%s.%s.alleles" % (chrom, kind),
                sum(1 + len(alts) for _, _, _, alts, _ in here))

    # Depth, per pool per chromosome, over the SNP table.
    for index, pool in enumerate(POOLS):
        for chrom in ordered_chroms(SNP_SITES):
            depths = [float(sum(cells[index]))
                      for c, _, _, _, cells in SNP_SITES if c == chrom]
            put("depth.%s.%s.sites" % (pool, chrom), len(depths))
            put("depth.%s.%s.mean" % (pool, chrom), sum(depths) / len(depths))
            put("depth.%s.%s.median" % (pool, chrom), median(depths))
            put("depth.%s.%s.harmonic" % (pool, chrom), harmonic(depths))

    # Diversity and effective size, per pool, genome-wide over the SNP table.
    for index, pool in enumerate(POOLS):
        cells = [site[4][index] for site in SNP_SITES]
        depths = [float(sum(cell)) for cell in cells]
        corrected = []
        for cell, depth in zip(cells, depths):
            size = n_eff(N_CHROM, depth)
            corrected.append(gene_diversity(cell) * size / (size - 1.0))
        hd = harmonic(depths)
        put("pool.%s.sites" % pool, len(cells))
        put("pool.%s.segregating" % pool, sum(1 for cell in cells if segregating(cell)))
        put("pool.%s.depth_harmonic" % pool, hd)
        put("pool.%s.n_eff_harmonic" % pool,
            1.0 / (1.0 / N_CHROM + (1.0 - 1.0 / N_CHROM) / hd))
        put("pool.%s.h_sum" % pool, sum(corrected))
        put("pool.%s.pi" % pool, sum(corrected) / len(corrected))

    # The genome-wide harmonic depth of each library's own histogram, which is the OTHER
    # effective size: every position the library covered, not the sites that were called.
    for pool, bins in HISTOGRAMS.items():
        hd = harmonic([float(d) for d, _ in bins], [float(n) for _, n in bins])
        put("histogram.%s.harmonic" % pool, hd)
        put("histogram.%s.n_eff" % pool,
            1.0 / (1.0 / N_CHROM + (1.0 - 1.0 / N_CHROM) / hd))

    return "\n".join(lines) + "\n"


def ordered_chroms(sites):
    """File order, never sorted: chr10 is third here and R's sort() would make it second."""
    seen = []
    for site in sites:
        if site[0] not in seen:
            seen.append(site[0])
    return seen


# In merged mode the six columns become three pools of two libraries each. The depth table is
# named by RG_Sample and the histograms by SampleID, so this is the only shape in which the two
# levels are different things - and the only one where the pool figure is a bound rather than a
# measurement.
MERGED_POOLS = ["PoolA", "PoolB", "PoolC"]
MERGED_MEMBERS = {"PoolA": ["TestSample1", "TestSample2"],
                  "PoolB": ["TestSample3", "TestSample4"],
                  "PoolC": ["TestSample5", "TestSample6"]}


def merge(sites):
    """The same sites under three column names, taking one existing column per pool.

    The counts are not re-derived: a merged pool's cell is whatever the pipeline wrote for it,
    and what this fixture needs from it is only that the columns are named by RG_Sample.
    """
    return [(chrom, pos, ref, alts, cells[:len(MERGED_POOLS)])
            for chrom, pos, ref, alts, cells in sites]


def main():
    argv = [a for a in sys.argv[1:] if a != "--merged"]
    merged = "--merged" in sys.argv
    if len(argv) not in (1, 2):
        sys.exit("usage: freq_corpus.py <Output-directory> [<sidecar-directory>] [--merged]")
    out = argv[0]
    side = argv[1] if len(argv) == 2 else out

    if merged:
        global POOLS, SNP_SITES, INDEL_SITES
        POOLS = MERGED_POOLS
        SNP_SITES = merge(SNP_SITES)
        INDEL_SITES = merge(INDEL_SITES)

    freq = os.path.join(out, "Frequencies")
    depth = os.path.join(out, "Reports", "Depth")
    os.makedirs(freq, exist_ok=True)
    os.makedirs(depth, exist_ok=True)
    os.makedirs(side, exist_ok=True)

    with open(os.path.join(freq, "Test_snp_depth.tsv"), "w") as handle:
        handle.write(depth_table(SNP_SITES))
    with open(os.path.join(freq, "Test_indel_depth.tsv"), "w") as handle:
        handle.write(depth_table(INDEL_SITES))

    for pool, bins in HISTOGRAMS.items():
        with open(os.path.join(depth, "%s_depth_histogram.tsv" % pool), "w") as handle:
            for value, positions in bins:
                handle.write("%d\t%d\n" % (value, positions))

    members = MERGED_MEMBERS if merged else {pool: [pool] for pool in POOLS}

    extra = ""
    if merged:
        # THE BOUND. A merged pool's depth at a position is its libraries' depths added, and the
        # harmonic mean of that sum cannot be recovered from the two histograms - so the module
        # sums the parts' harmonic means, which is a lower bound on it. PoolA is 40 + 60.
        lines = []
        for pool, libraries in sorted(members.items()):
            summed = sum(harmonic([float(d) for d, _ in HISTOGRAMS[lib]],
                                  [float(n) for _, n in HISTOGRAMS[lib]]) for lib in libraries)
            lines.append("merged.%s.harmonic\t%.12g" % (pool, summed))
            lines.append("merged.%s.n_eff\t%.12g"
                         % (pool, 1.0 / (1.0 / N_CHROM + (1.0 - 1.0 / N_CHROM) / summed)))
        extra = "\n".join(lines) + "\n"

    with open(os.path.join(side, "expected.tsv"), "w") as handle:
        handle.write(expectations() + extra)

    # What the frame resolves and hands a module, for a case that calls the module's R without
    # a Nextflow run around it. The pools and the design are test/data/base/metadata.csv's.
    with open(os.path.join(side, "pools.json"), "w") as handle:
        json.dump([{"pool": pool, "size": POOL_SIZE, "ploidy": PLOIDY,
                    "nChrom": N_CHROM, "sensitivity": SENSITIVITY} for pool in POOLS], handle)
    with open(os.path.join(side, "design.json"), "w") as handle:
        json.dump({
            "variables": [{"name": "exp_population"}, {"name": "exp_time"}],
            "pools": [{"pool": pool, "libraries": members[pool],
                       "values": {"exp_population": "Pop%d" % ((n + 2) // 2),
                                  "exp_time": "T%d" % (2 - n % 2)}}
                      for n, pool in enumerate(POOLS, start=1)]}, handle)


if __name__ == "__main__":
    main()
