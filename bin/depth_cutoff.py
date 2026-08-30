#!/usr/bin/env python3
"""Choose a depth ceiling for one sample from its coverage histogram.

Usage: depth_cutoff.py <histogram-tsv>

The histogram is `depth<TAB>positions`, one line per depth that occurs, which is the COV
section of `samtools stats` with its labels dropped. Prints two lines to stdout: the chosen
cutoff, and one sentence saying how it was reached. A cutoff of 0 means do not cap.

The cutoff is the first depth above the main population at which coverage falls away and then
returns. Depths are counted in bins of a log axis throughout.

Exit 0 whether or not a cutoff was found. Exit 1 for a histogram that cannot be read, 2 for a
usage mistake.
"""

import math
import sys

# Resolution of the log axis: each bin is about 12% deeper than the one below it.
BINS_PER_DECADE = 20

# Width of the moving average, in bins.
SMOOTH_BINS = 3

# A trough counts only if coverage falls to at most this fraction of its height at the anchor.
TROUGH_FRACTION = 0.10

# A rise counts only if it reaches at least this multiple of the trough's height...
RISE_FACTOR = 2.0

# ...and holds at least this fraction of the covered genome.
RISE_MIN_FRACTION = 1e-5


def read_histogram(path):
    """`depth -> positions`, from a two-column TSV. Blank lines and `#` comments are skipped."""
    counts = {}
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2:
                raise ValueError(f"line {lineno}: '{line}' is not <depth>TAB<positions>")
            try:
                depth, positions = int(fields[0]), int(fields[1])
            except ValueError:
                raise ValueError(f"line {lineno}: '{line}' does not hold two whole numbers")
            if depth < 0 or positions < 0:
                raise ValueError(f"line {lineno}: '{line}' holds a negative number")
            # Depth 0 is absence of coverage. samtools omits it; a hand-written histogram may not.
            if depth > 0:
                counts[depth] = counts.get(depth, 0) + positions
    return counts


def bin_of(depth):
    return int(BINS_PER_DECADE * math.log10(depth))


def floor_of(index):
    """The shallowest depth that falls in this bin."""
    return max(1, math.ceil(10 ** (index / BINS_PER_DECADE)))


def profile(counts):
    """Positions per log-depth bin, indexed from bin 0, which is depth 1."""
    mass = [0] * (bin_of(max(counts)) + 1)
    for depth, positions in counts.items():
        mass[bin_of(depth)] += positions
    return mass


def smooth(mass, window):
    """A centred moving average, with the window truncated at both ends."""
    if window <= 1:
        return list(mass)
    half = window // 2
    out = []
    for i in range(len(mass)):
        low, high = max(0, i - half), min(len(mass), i + half + 1)
        out.append(sum(mass[low:high]) / (high - low))
    return out


def weighted_median(counts, weight):
    total = sum(weight(d, n) for d, n in counts.items())
    running = 0
    for depth in sorted(counts):
        running += weight(depth, counts[depth])
        if running >= total / 2.0:
            return depth
    return max(counts)


def anchor_depth(counts):
    """The depth the search starts from: the deeper of two medians.

    The first weights every covered position equally, the second weights each by its depth and
    so counts reads.
    """
    return max(weighted_median(counts, lambda _d, n: n),
               weighted_median(counts, lambda d, n: d * n))


def choose(counts):
    """The cutoff, and the sentence explaining it."""
    if not counts:
        return 0, "the histogram holds no covered positions, so there is nothing to cap"

    mass = profile(counts)
    total = sum(mass)
    anchor = bin_of(anchor_depth(counts))
    curve = smooth(mass, SMOOTH_BINS)
    reference = curve[anchor]
    floor_mass = max(1.0, total * RISE_MIN_FRACTION)

    # Walk up from the anchor holding the lowest point seen. Strictly lower, so a flat empty
    # stretch keeps its FIRST bin rather than its last.
    trough, trough_height = anchor, reference
    for index in range(anchor + 1, len(curve)):
        height = curve[index]
        if height < trough_height:
            trough, trough_height = index, height
            continue
        if trough_height > reference * TROUGH_FRACTION:
            continue
        if height < trough_height * RISE_FACTOR or height < floor_mass:
            continue
        return floor_of(trough), (
            f"coverage falls away above depth {floor_of(trough)} and rises again by depth "
            f"{floor_of(index)}, so the ceiling goes where it ran out"
        )

    return 0, (
        f"coverage centres on depth {anchor_depth(counts)} and falls away without rising "
        f"again, so there is nothing to cut and the sample is left uncapped"
    )


def main(argv):
    if len(argv) != 2:
        print(f"Usage: {argv[0].split('/')[-1]} <histogram-tsv>", file=sys.stderr)
        return 2

    try:
        counts = read_histogram(argv[1])
    except OSError as exc:
        print(f"{argv[1]}: {exc.strerror}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"{argv[1]}: {exc}", file=sys.stderr)
        return 1

    cutoff, reason = choose(counts)
    print(cutoff)
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
