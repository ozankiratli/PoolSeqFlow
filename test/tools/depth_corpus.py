#!/usr/bin/env python3
"""Build the corpus of depth histograms that `bin/depth_cutoff.py` is judged against.

Usage: depth_corpus.py <outdir>

Writes <outdir>/<name>.tsv, each `depth<TAB>positions` as the COV section of `samtools stats`
reports it, and <outdir>/expected.tsv holding what the detector must decide for each:

    name    verdict   lo    hi    description

`verdict` is `none` (leave the sample uncapped) or `cap`, in which case the cutoff has to land
between `lo` and `hi`. The bounds are not the detector's own output recorded back: `lo` is the
top of the case's real coverage, so a cutoff below it truncates legitimate reads, and `hi` is
where the planted anomaly begins, so a cutoff above it truncates nothing worth truncating.

ANALYTIC, NOT SAMPLED. Each component is a negative binomial evaluated over the depth axis and
scaled to a number of positions, so the shapes are exactly what they claim to be and the corpus
is identical on every machine without a seed.

THE TWO CASES THAT ARE DELIBERATELY `none` DESPITE HOLDING A HILL are hill-large and
hill-dominant, where the pile-up holds a fifth and four fifths of the covered genome. Neither
is distinguishable from a library that simply ran deep, and capping either would truncate a
large fraction of a real genome on a guess. Reporting them uncapped is the intended answer, and
the per-sample param_capMaxDepth column is how a user overrules it.
"""

import math
import os
import sys

MAX_DEPTH = 100000
GENOME = 20_000_000


def nb(mean, r, positions):
    """A negative-binomial lobe: mean `mean`, variance mean + mean^2/r, `positions` positions.

    Large r is nearly Poisson; small r is heavily overdispersed, which is what PCR does.
    """
    top = min(MAX_DEPTH, int(mean * 30) + 50)
    p = r / (r + mean)
    weights = {}
    for k in range(top + 1):
        logpmf = (math.lgamma(k + r) - math.lgamma(r) - math.lgamma(k + 1)
                  + r * math.log(p) + k * math.log1p(-p))
        weight = math.exp(logpmf)
        if weight > 0:
            weights[k] = weight
    total = sum(weights.values())
    return {k: v / total * positions for k, v in weights.items()}


def geometric(scale, positions, top=40):
    """The near-zero junk a poor reference produces: many positions at depth 1, few at 10."""
    weights = {k: math.exp(-k / scale) for k in range(1, top + 1)}
    total = sum(weights.values())
    return {k: v / total * positions for k, v in weights.items()}


def spike(depth, positions):
    return {depth: float(positions)}


def uniform(low, high, positions):
    return {k: positions / (high - low + 1) for k in range(low, high + 1)}


def merge(*parts):
    out = {}
    for part in parts:
        for depth, positions in part.items():
            out[depth] = out.get(depth, 0.0) + positions
    return out


def quantile_of(hist, q):
    """The depth below which `q` of the positions lie. The `lo` bounds are read off this."""
    total = sum(hist.values())
    running = 0.0
    for depth in sorted(hist):
        running += hist[depth]
        if running >= total * q:
            return depth
    return max(hist)


# Each case is (name, histogram, verdict, lo, hi, description). `lo` is normally the 99.9th
# percentile of the case's REAL coverage alone, computed below rather than written by hand.
def cases():
    clean_40 = nb(40, 12, GENOME)
    clean_200 = nb(200, 15, GENOME)
    clean_120 = nb(120, 15, GENOME)
    clean_60 = nb(60, 10, GENOME)
    clean_150 = nb(150, 15, GENOME)
    clean_80 = nb(80, 15, GENOME)
    shallow_8 = nb(8, 6, GENOME)
    junk = geometric(2.0, GENOME * 2)

    def top_of(component):
        return quantile_of(component, 0.999)

    return [
        # --- five clean libraries: nothing to cut ---
        ("clean-40x", clean_40, "none", 0, 0,
         "an ordinary pool at 40x"),
        ("clean-200x", clean_200, "none", 0, 0,
         "an ordinary pool at 200x"),
        ("clean-800x", nb(800, 20, GENOME), "none", 0, 0,
         "a deep pool at 800x"),
        ("clean-4000x", nb(4000, 25, GENOME), "none", 0, 0,
         "a very deep pool at 4000x"),
        ("clean-8x", shallow_8, "none", 0, 0,
         "a shallow pool at 8x, where the lobe nearly touches zero"),

        # --- collapsed repeats and PCR hills: what the cap exists for ---
        ("hill-small", merge(clean_120, nb(4000, 8, GENOME // 500)),
         "cap", top_of(clean_120), 4000,
         "120x coverage with a collapsed repeat at 4000x over 0.2% of the genome"),
        ("hill-near", merge(clean_120, nb(500, 10, GENOME // 50)),
         "cap", top_of(clean_120), 500,
         "a hill only 4x above the mode, with little trough between them"),
        ("hill-shallow", merge(shallow_8, nb(300, 8, GENOME // 300)),
         "cap", top_of(shallow_8), 300,
         "a shallow library with a collapsed repeat"),
        ("spike-far", merge(clean_200, spike(50000, 4000)),
         "cap", top_of(clean_200), 50000,
         "200x coverage and 4000 positions stacked at exactly 50000x"),
        ("mito", merge(clean_150, nb(30000, 20, 16000)),
         "cap", top_of(clean_150), 30000,
         "organelle contamination: 16kb at 30000x"),
        ("three-lobes", merge(clean_80, nb(900, 12, GENOME // 20),
                              nb(12000, 10, GENOME // 400)),
         "cap", top_of(clean_80), 900,
         "two anomalous populations above the real one; the lower one sets the cap"),
        ("bad-reference-hill", merge(junk, clean_60, nb(2500, 8, GENOME // 200)),
         "cap", top_of(clean_60), 2500,
         "a poor reference AND a collapsed repeat: the junk must not become the anchor"),

        # --- awkward but legitimate shapes: leaving them alone is the answer ---
        ("bad-reference", merge(junk, clean_60), "none", 0, 0,
         "a poor reference: twice as many junk positions at depth 1-5 as real coverage at 60x"),
        ("two-chromosomes", merge(nb(100, 20, GENOME), nb(50, 20, GENOME // 3)), "none", 0, 0,
         "a hemizygous chromosome at half depth: two real lobes, neither an anomaly"),
        ("heavy-tail", nb(150, 2.0, GENOME), "none", 0, 0,
         "one lobe, badly overdispersed, reaching 3000x with no second population"),
        ("plateau", uniform(50, 400, GENOME), "none", 0, 0,
         "duplicate-heavy: a flat plateau rather than a peak"),
        ("amplicon", nb(3000, 30, GENOME // 1000), "none", 0, 0,
         "an amplicon panel: a narrow deep peak over a thousandth of the genome"),
        ("uniform-wide", uniform(1, 5000, GENOME), "none", 0, 0,
         "no structure at all"),

        # --- a pile-up too large to call an anomaly; see the module docstring ---
        ("hill-large", merge(clean_120, nb(4000, 8, GENOME // 4)), "none", 0, 0,
         "the collapsed repeat now holds a fifth of the genome, so capping it is a guess"),
        ("hill-dominant", merge(nb(200, 15, GENOME // 4), nb(20000, 10, GENOME)), "none", 0, 0,
         "the pile-up at 20000x outweighs the real coverage at 200x four to one"),
    ]


def quantise(hist):
    """Whole positions, dropping depth 0 and anything that rounds away, as samtools does."""
    return {d: int(round(n)) for d, n in sorted(hist.items())
            if 0 < d <= MAX_DEPTH and round(n) >= 1}


def main(argv):
    if len(argv) != 2:
        print(f"Usage: {argv[0].split('/')[-1]} <outdir>", file=sys.stderr)
        return 2
    outdir = argv[1]
    os.makedirs(outdir, exist_ok=True)

    built = cases()
    with open(os.path.join(outdir, "expected.tsv"), "w", encoding="utf-8") as expected:
        expected.write("name\tverdict\tlo\thi\tdescription\n")
        for name, hist, verdict, lo, hi, description in built:
            with open(os.path.join(outdir, f"{name}.tsv"), "w", encoding="utf-8") as handle:
                for depth, positions in sorted(quantise(hist).items()):
                    handle.write(f"{depth}\t{positions}\n")
            expected.write(f"{name}\t{verdict}\t{int(lo)}\t{int(hi)}\t{description}\n")
    print(f"{len(built)} histograms in {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
