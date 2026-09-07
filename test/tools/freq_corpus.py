#!/usr/bin/env python3
"""Build the published tables that the basicstats module is judged against.

Usage: freq_corpus.py <Output-directory> [<sidecar-directory>]

Writes, under the Output directory, exactly what a completed run publishes and nothing else:

    Frequencies/Test_snp_depth.tsv      the depth tables, exactly as step 7 publishes them
    Frequencies/Test_indel_depth.tsv
    Reports/Depth/<sample>_depth_histogram.tsv   the COV section of samtools stats

and under the sidecar directory, which defaults to the same place, what only the tests read:

    expected.tsv                        key<TAB>value, what a module must compute from them
    pools.json                          the pool sizes and ploidy the pipeline filtered with
    design.json                         the design as the frame resolves it, for calling a
                                        module directly. design_binary.json is the same pools
                                        under a binary phenotype and design_timed.json the same
                                        again with exp_time as a time axis, where the six pools
                                        become three units

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

And five more for the association module, each documented where it is defined:

  chr1:700   the signal, at depths from 40 to 400 - where a weighted fit and an unweighted one
             give different answers
  chr2:550   TRIALLELIC, and REF carries the strongest signal. The site that fails any
             implementation minimising over the alternates alone
  chr10:1500 an allele invariant to the last bit: every count is half its pool's depth
  chr10:1600 PERFECT SEPARATION under the binary phenotype, where the closed form gives p = 0
             and the permutation p is 0.1 however infinite t is
  chr10:1700 six alternate reads in the whole cohort, arranged in a straight line
  chr10:1800 the same infinite t as chr10:1600 out of THREE reads, which is what a p-value
             cannot tell you and a minimum-evidence gate can

THE INDEL TABLE is separate because the site counts report SNPs and indels separately, and
because diversity is computed over the SNP table alone - a gate the module states.

NO CELL IS ZERO-DEPTH. vcffilter.minDP removes a site where ANY sample falls below the depth,
so a published table cannot hold one; the NA path in n_eff() is exercised by the library's own
unit tests instead.
"""

import itertools
import json
import math
import os
import sys

# The six pools of test/data/base/metadata.csv, in the order the table's columns take.
POOLS = ["TestSample%d" % n for n in range(1, 7)]

# What the pipeline filtered with, from parameters.config.template. n_chrom = ploidy * poolSize.
POOL_SIZE = 100
PLOIDY = 2
N_CHROM = PLOIDY * POOL_SIZE
SENSITIVITY = 1.0 / (2 * PLOIDY * POOL_SIZE)

# The default of analysis.modules.basicstats.minReads: the alternate reads a pool needs before a site
# counts as segregating for it, whatever the depth.
MIN_READS = 2

# THE PHENOTYPE, one value per pool, in the order POOLS gives them.
#
# Unequally spaced on purpose. Evenly spaced values make the weighted and the unweighted fit
# agree far more closely than they should, and a corpus that cannot tell them apart cannot
# catch a module that forgot to weight.
#
# The values sum to 84 and the plain mean is exactly 14, so a fit that ignored the weights is
# recognisable by hand; the weighted mean is not 14 at any site, because the weights are that
# site's depths.
PHENOTYPE_COLUMN = "pt_wingspan"
PHENOTYPE = [12.4, 15.1, 9.8, 18.6, 11.2, 16.9]

# The same six pools under a binary phenotype: presence and absence, three each. Deliberately
# NOT aligned with exp_time, which alternates T1/T2 down the file, nor with exp_population,
# which pairs them - a fixture where the phenotype is a copy of an experimental variable cannot
# show that the module read the right column.
BINARY_COLUMN = "pt_resistant"
BINARY_LEVELS = ["absent", "present"]
BINARY = ["absent", "absent", "present", "absent", "present", "present"]

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

    # THE SITES BELOW ARE THE ASSOCIATION MODULE'S, and every one of them is a case the fit
    # gets wrong in a specific way if something is dropped. They are ordinary sites to every
    # other module, which is why they sit in the same table.

    # THE SIGNAL, AND THE ONE THAT SEPARATES A WEIGHTED FIT FROM AN UNWEIGHTED ONE. The
    # alternate rises with the phenotype, and the depths run from 40 to 400 - so the two deepest
    # pools, which carry a third of the weight between them, are also the two whose frequencies
    # are furthest below the unweighted line. Weighted the fit gives b1 = 0.0587 and t = 5.35;
    # unweighted it gives 0.0536 and 4.74, so the two disagree in the second significant figure
    # of the slope and by a tenth of the statistic - which is a p of 0.0059 against 0.0091.
    ("chr1", 700, "A", ["T"], [
        [60, 40], [30, 50], [340, 60], [24, 36], [210, 90], [15, 25]]),

    # TRIALLELIC, AND THE REFERENCE ALLELE CARRIES THE STRONGEST SIGNAL. Both alternates rise
    # with the phenotype and neither is impressive alone; REF falls by the sum of them and has
    # the largest |t| at the site. A site statistic taken over the alternates only - dropping
    # REF because MajorAlleleToRef.py made it the cohort's major allele - misses this site,
    # which is the whole case for maximising over every allele. Equal depths, so the weights
    # are equal here and the arithmetic can be checked by hand.
    ("chr2", 550, "G", ["A", "T"], [
        [140, 30, 30], [100, 60, 40], [160, 20, 20],
        [60, 70, 70], [150, 20, 30], [80, 70, 50]]),

    # AN INVARIANT ALLELE, exactly. Every count is half its pool's depth, so every frequency is
    # 0.5 in floating point as well as in arithmetic, the residual variance is zero and t is
    # 0/0. The row is flagged and takes no p-value - not a p of 1, which would inflate the
    # denominator of every other site's correction.
    ("chr10", 1500, "T", ["C"], [
        [50, 50], [40, 40], [200, 200], [30, 30], [150, 150], [20, 20]]),

    # PERFECT SEPARATION, under the binary phenotype and only under it: the three `absent` pools
    # carry no alternate read and the three `present` pools carry nothing else. The residual
    # variance is zero, so the closed form gives t = Inf and a parametric p of exactly 0, and
    # after any FDR correction that row sits at the top of the table.
    #
    # AND THE TWO ALLELES OF SUCH A SITE CAN DISAGREE ENORMOUSLY, which is the reason a site is
    # keyed on its position and never on comparing its alleles' p-values. They are algebraically
    # one test - the reference frequency is one minus the alternate - but the residual sum comes
    # out as exactly zero on one row and as 1e-18 on the other, which is t = Inf against t =
    # 8e15 and p = 0 against p = 1e-63. Neither is wrong; there is no zero to divide by that a
    # float can be trusted to find twice, and which row gets which moves when any pool's depth
    # changes. Both sites carry `separated` for that reason.
    #
    # Its permutation p is 2/20 = 0.1. An infinite t, three pools against three, and a tenth is
    # the smallest p the design can produce - the complementary labelling always ties.
    ("chr10", 1600, "A", ["G"], [
        [100, 0], [80, 0], [0, 400], [60, 0], [0, 300], [0, 40]]),

    # SIX READS OF EVIDENCE, ARRANGED IN A STRAIGHT LINE. Ordered by phenotype the alternate
    # counts are 0, 0, 0, 1, 2, 3 - a monotone rise built out of six reads in the whole cohort.
    # It clears step 7's filter honestly: three pools carry an alternate frequency above their
    # own detection limit.
    #
    # The weighting is what keeps t down to 4.45 here, because the three pools with no alternate
    # read at all are the three deepest and carry most of the weight - which is the weighting
    # working. THE PERMUTATION P IS 4/720 REGARDLESS, the fourth smallest the design can give.
    # A permutation null is built from the same six reads, so it does not notice that six is not
    # many; only a minimum-evidence gate does.
    ("chr10", 1700, "C", ["T"], [
        [100, 0], [80, 1], [400, 0], [57, 3], [300, 0], [40, 2]]),

    # THE SAME ABSURDITY, OUT OF THREE READS. Perfectly separated under the binary phenotype
    # like chr10:1600, from three alternate reads rather than seven hundred and forty, and the
    # closed form cannot tell the two apart - both give an effectively infinite t and a p at or
    # indistinguishable from zero, and both are capped at a permutation p of 0.1. That is the
    # argument for gating on evidence before the fit rather than on significance after it.
    #
    # THE THREE PRESENT POOLS ARE AT ONE DEPTH ON PURPOSE. Separation means no variance WITHIN
    # a group, and one read at three different depths is three different frequencies: at 400,
    # 300 and 40 deep this site gives t = 0.94 and nothing to see. It is 0.01 in each of them
    # here, four times the detection limit and the same number three times.
    ("chr10", 1800, "G", ["C"], [
        [120, 0], [90, 0], [99, 1], [60, 0], [99, 1], [99, 1]]),
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


def betacf(a, b, x):
    """The continued fraction the incomplete beta is evaluated by, Lentz's method."""
    tiny = 1e-300
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    if abs(d) < tiny:
        d = tiny
    d = 1.0 / d
    h = d
    for m in range(1, 300):
        m2 = 2 * m
        for step in (m * (b - m) * x / ((qam + m2) * (a + m2)),
                     -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))):
            d = 1.0 + step * d
            if abs(d) < tiny:
                d = tiny
            c = 1.0 + step / c
            if abs(c) < tiny:
                c = tiny
            d = 1.0 / d
            h *= d * c
        if abs(d * c - 1.0) < 1e-15:
            break
    return h


def betai(a, b, x, omx):
    """The regularized incomplete beta I_x(a, b).

    `omx` is 1 - x and is passed rather than subtracted: the caller can compute it exactly and
    the subtraction cannot. At t = 1e-8 with 4 degrees of freedom, x is 1 - 2.5e-17 and rounds
    to 1, which would report a p-value of exactly 1 for a t that is not zero.
    """
    if x <= 0.0:
        return 0.0
    if omx <= 0.0:
        return 1.0
    front = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
                     + a * math.log(x) + b * math.log(omx))
    if x < (a + 1.0) / (a + b + 2.0):
        return front * betacf(a, b, x) / a
    return 1.0 - front * betacf(b, a, omx) / b


def t_two_sided(t, df):
    """P(|T| >= |t|) for Student's t on df degrees of freedom.

    Checked against R's pt() over 218 cases - t from 1e-12 to 500, df from 1 to 20 - and the
    worst relative difference is 2.7e-11, on a p of 2e-9. The easy region agrees to 1e-15; the
    error is the continued fraction's own, in the far tail, and it is nine orders of magnitude
    below anything a test here compares.
    """
    if df <= 0:
        return float("nan")
    if not math.isfinite(t):
        return 0.0
    denom = df + t * t
    return betai(df / 2.0, 0.5, df / denom, (t * t) / denom)


def wls(y, f, w):
    """Weighted least squares of frequency on phenotype, one allele.

    Returns b1, its standard error, t, the residual variance and the two-sided parametric p.
    `sxx` and the weighted mean of y depend only on the weights, which are a property of the
    SITE - every allele at one site shares them.

    A residual variance of exactly zero gives t = inf and p = 0, which is reported as it comes
    out. Refusing it is the module's job and the corpus is what says what the closed form does.

    An allele that does not vary at all is the OTHER zero and is not the same: b1 is zero too,
    so t is 0/0 rather than something/0. It comes back as nan, which is what a row with no test
    in it should carry - a t of inf there would put an invariant allele at the top of the table.
    """
    n = len(y)
    sw = sum(w)
    ybar = sum(wi * yi for wi, yi in zip(w, y)) / sw
    fbar = sum(wi * fi for wi, fi in zip(w, f)) / sw
    sxx = sum(wi * (yi - ybar) ** 2 for wi, yi in zip(w, y))
    sxy = sum(wi * (yi - ybar) * (fi - fbar) for wi, yi, fi in zip(w, y, f))
    b1 = sxy / sxx
    b0 = fbar - b1 * ybar
    rss = sum(wi * (fi - b0 - b1 * yi) ** 2 for wi, yi, fi in zip(w, y, f))
    df = n - 2
    sigma2 = rss / df
    se = math.sqrt(sigma2 / sxx)
    if se > 0.0:
        t = b1 / se
    else:
        t = math.nan if b1 == 0.0 else math.inf
    p = math.nan if math.isnan(t) else t_two_sided(t, df)
    return {"b1": b1, "b0": b0, "se": se, "t": t, "df": df, "sxx": sxx,
            "sigma2": sigma2, "p": p}


def site_fit(counts, y):
    """Every allele of one site fitted against the phenotype, and the site statistic.

    `counts` is one count list per pool, in POOLS order. The weight is n_eff at that pool's
    depth here, so it is the same for every allele of the site and different at every site.

    The site statistic is max |t| over ALL alleles, the reference included: the frequencies of a
    site sum to 1, so the reference row carries the negated sum of the others and is where a
    signal spread across several alternates shows up.
    """
    depths = [float(sum(cell)) for cell in counts]
    w = [n_eff(N_CHROM, d) for d in depths]
    alleles = []
    for j in range(len(counts[0])):
        f = [cell[j] / depth for cell, depth in zip(counts, depths)]
        alleles.append(wls(y, f, w))
    # An allele with no test in it takes no part in the maximum. A site where none of them has
    # one has no statistic at all, which is not the same as a statistic of zero.
    tested = [abs(a["t"]) for a in alleles if not math.isnan(a["t"])]
    return {"alleles": alleles, "S": max(tested) if tested else math.nan, "weights": w}


def permutations_of(values):
    """Every distinct ordering of the phenotype, as the exhaustive permutation set.

    Distinct orderings and not all n!, so a phenotype with repeated values - every binary one -
    gives choose(n, n1) relabellings rather than n! copies of each. THE FLOOR IS THIS COUNT: the
    observed labelling is one of them, so no permutation p can be smaller than 1 / len(this),
    and at three pools against three that is 1/20.
    """
    return sorted(set(itertools.permutations(values)))


def permutation_p(counts, y, orderings):
    """The site's permutation p: the share of relabellings whose site statistic reaches the
    observed one.

    THE PHENOTYPE MOVES AND THE WEIGHT DOES NOT. A weight says how precisely that pool's
    frequency was measured, so it belongs to the frequency and stays with it; carrying it along
    with the phenotype would weight one pool's frequency by another pool's depth.

    The observed labelling is included in the count, which is what stops a p of zero.
    """
    observed = site_fit(counts, y)["S"]
    if math.isnan(observed):
        return float("nan")
    reached = sum(1 for order in orderings
                  if site_fit(counts, list(order))["S"] >= observed - 1e-12)
    return float(reached) / len(orderings)


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


def association_expectations():
    """What the association module must compute from the same tables, under both phenotypes.

    Both are fitted over the SNP sites, one key per allele and one per site. The keys carry the
    position rather than a row number, because the two tables are keyed differently and a site
    is what they have in common.

    NOTHING IS WRITTEN IN MERGED MODE. A phenotype is measured on a pool and there are six of
    them here; merged there are three, and pairing six values against three columns is not a
    smaller fixture but a different one. Merged mode exists for the effective-size bound, which
    has no phenotype in it.
    """
    if len(POOLS) != len(PHENOTYPE):
        return ""

    lines = []

    def put(key, value):
        if isinstance(value, float) and math.isnan(value):
            lines.append("%s\tNA" % key)
        elif value == math.inf:
            lines.append("%s\tInf" % key)
        else:
            lines.append("%s\t%.12g" % (key, value))

    quantitative = [float(v) for v in PHENOTYPE]
    # The binary phenotype as the module codes it: the position of each pool's level in
    # BINARY_LEVELS, so `present` is 1 and the sign of b1 is readable from the declaration.
    binary = [float(BINARY_LEVELS.index(level)) for level in BINARY]

    for prefix, y in (("assoc", quantitative), ("assocb", binary)):
        orderings = permutations_of(y)
        # THE FLOOR, AND IT IS THE POINT OF PUBLISHING A PERMUTATION P. The observed labelling
        # is one of the orderings, so nothing can come back below 1 / this however large t is.
        #
        # `smallest_p` is what the corpus ACTUALLY REACHED, which for a binary phenotype is
        # twice the arithmetic floor and not equal to it: swapping every label negates t and
        # leaves |t| alone, so the complementary labelling always ties with the observed one and
        # no site can score better than 2/20. That is the number a 3-against-3 design lives
        # with, and it is 0.1.
        put("%s.permutations" % prefix, len(orderings))
        put("%s.floor" % prefix, 1.0 / len(orderings))
        smallest = math.inf

        for chrom, pos, _ref, alts, cells in SNP_SITES:
            site = "%s.%s.%d" % (prefix, chrom, pos)
            fit = site_fit(cells, y)
            perm = permutation_p(cells, y, orderings)
            if not math.isnan(perm):
                smallest = min(smallest, perm)
            # WHERE THE RESIDUAL VARIANCE REACHES ZERO, t AND p ARE NOT COMPARABLE BETWEEN
            # IMPLEMENTATIONS and this flag says so. The two alleles of a separated biallelic
            # site are one test algebraically, and whether each lands on exactly 0 or on 1e-18
            # decides between t = Inf with p = 0 and t = 8e15 with p = 1e-63. Raising one pool's
            # depth from 20 to 60 moved which of the two sites below got which. Assert that a
            # module TRAPPED these rows, never that it reproduced their numbers.
            #
            # It catches both degeneracies and they are not the same one. An invariant allele
            # has a slope of zero as well, so its t is 0/0 and comes back NA; a separated one
            # has a slope and no residual, so its t runs off to infinity. The `t` beside this
            # tells them apart.
            put("%s.zero_variance" % site,
                1 if any(a["sigma2"] <= 0.0 or not math.isfinite(a["t"])
                         for a in fit["alleles"]) else 0)
            put("%s.k" % site, len(alts) + 1)
            put("%s.S" % site, fit["S"])
            put("%s.perm_p" % site, perm)
            for j, allele in enumerate(fit["alleles"]):
                put("%s.%d.b1" % (site, j), allele["b1"])
                put("%s.%d.se" % (site, j), allele["se"])
                put("%s.%d.t" % (site, j), allele["t"])
                put("%s.%d.p" % (site, j), allele["p"])

        put("%s.smallest_p" % prefix, smallest)

    return "\n".join(lines) + "\n"


def pool_values(merged):
    """The experimental variables each pool carries, as test/data/base/metadata.csv gives them:
    three populations of two samples each, every population sampled at both timepoints.

    Merged, the two rows of a population become one pool. The population survives that and the
    timepoint cannot - one sample at T1 and one at T2 have no single time, and checkTargetDesign
    refuses a pool whose rows disagree - so a merged pool carries one time here.
    """
    if merged:
        return [{"exp_population": "Pop%d" % (i + 1), "exp_time": "T1"}
                for i in range(len(POOLS))]
    return [{"exp_population": "Pop%d" % (i // 2 + 1), "exp_time": "T%d" % (i % 2 + 1)}
            for i in range(len(POOLS))]


def phenotype_block(column, kind, levels, raw):
    """One phenotype as resolvePhenotype() in analysis/lib/nf/design.nf returns it.

    `shown` is the cell as written and `value` is what the fit reads; a categorical scale also
    carries `group`, the position of its level in the declaration, which is what makes the sign
    of b1 readable - level 1 is the one coded 1.
    """
    values = []
    for pool, cell in zip(POOLS, raw):
        if kind == "quantitative":
            values.append({"pool": pool, "shown": "%g" % cell, "group": None,
                           "value": float(cell)})
        else:
            group = levels.index(cell)
            values.append({"pool": pool, "shown": cell, "group": group,
                           "value": float(group)})
    return {"column": column, "kind": kind,
            "levels": None if kind == "quantitative" else levels,
            "values": values, "warnings": []}


def design(merged, members, kind="quantitative", timed=False):
    """The design as the frame resolves it and hands it to a module.

    EVERY KEY designSummary() RETURNS IS HERE, including the ones this corpus has nothing to put
    in. A module reads `units` for its degrees of freedom and `phenotype` for its fit, and a
    fixture carrying only the two keys basicstats happens to read would let a module pass
    against a shape the frame never emits.

    Untimed, there is no series and every pool is its own unit: six pools are six independent
    observations, which is what an ordinary association study is. `timed` resolves exp_time as
    the time axis instead, and then the six pools are three series of two - THREE units, not
    six - which is the case rule 17c exists for and where degrees of freedom halve.
    """
    values = pool_values(merged)
    variables = [{"name": name, "levels": sorted({row[name] for row in values})}
                 for name in ("exp_population", "exp_time")]
    # Untimed, exp_time is an ordinary experimental variable and joins the key: nothing here is
    # declared a replicate, so no two pools are one material and each stands alone.
    key_columns = ["exp_population", "exp_time"]
    units = [{"label": " | ".join(row[column] for column in key_columns),
              "key": {column: row[column] for column in key_columns},
              "pools": [pool],
              "members": [pool]}
             for pool, row in zip(POOLS, values)]
    summary = {
        "variables": variables,
        "pools": [{"pool": pool, "libraries": members[pool], "values": row}
                  for pool, row in zip(POOLS, values)],
        "time": None,
        "keyColumns": key_columns,
        "roles": {"condition": key_columns, "biological": [], "technical": []},
        "series": [],
        "units": units,
        "conditions": [{"label": unit["label"], "key": unit["key"], "pools": unit["pools"],
                        "units": [unit["label"]]} for unit in units],
        "phenotype": (phenotype_block(PHENOTYPE_COLUMN, "quantitative", None, PHENOTYPE)
                      if kind == "quantitative"
                      else phenotype_block(BINARY_COLUMN, "binary", BINARY_LEVELS, BINARY)),
        "covariates": [],
        "warnings": [],
    }
    if not timed:
        return summary

    levels = [{"index": i, "value": value, "position": None}
              for i, value in enumerate(variables[1]["levels"])]
    summary["time"] = {"column": "exp_time", "kind": "categorical", "unit": None,
                       "format": None, "locale": None, "levels": levels,
                       "timeline": [level["index"] for level in levels]}
    summary["keyColumns"] = ["exp_population"]
    summary["roles"] = {"condition": ["exp_population"], "biological": [], "technical": []}
    summary["series"] = [
        {"label": population,
         "key": {"exp_population": population},
         "pools": [pool for pool, row in zip(POOLS, values)
                   if row["exp_population"] == population],
         "timeline": [level["index"] for level in levels]}
        for population in variables[0]["levels"]]
    # With no technicalRep declared nothing merges two series, so a unit is a series - a
    # population, and there are three of them where untimed there were six.
    summary["units"] = [{"label": entry["label"], "key": entry["key"],
                         "pools": entry["pools"], "members": [entry["label"]]}
                        for entry in summary["series"]]
    summary["conditions"] = [{"label": unit["label"], "key": unit["key"], "pools": unit["pools"],
                              "units": [unit["label"]]} for unit in summary["units"]]
    return summary


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
        handle.write(expectations() + association_expectations() + extra)

    # What the frame resolves and hands a module, for a case that calls the module's R without
    # a Nextflow run around it. The pools and the design are test/data/base/metadata.csv's.
    with open(os.path.join(side, "pools.json"), "w") as handle:
        json.dump([{"pool": pool, "size": POOL_SIZE, "ploidy": PLOIDY,
                    "nChrom": N_CHROM, "sensitivity": SENSITIVITY} for pool in POOLS], handle)
    # Three designs over one set of pools: the ordinary one, the same under a binary phenotype,
    # and the one where exp_time is a time axis so the six pools are three units. A module names
    # the one its case needs; nothing has to re-run this to get another.
    for name, block in (("design.json", design(merged, members)),
                        ("design_binary.json", design(merged, members, kind="binary")),
                        ("design_timed.json", design(merged, members, timed=True))):
        with open(os.path.join(side, name), "w") as handle:
            json.dump(block, handle)


if __name__ == "__main__":
    main()
