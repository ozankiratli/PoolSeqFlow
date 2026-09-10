#!/usr/bin/env python3
"""Draw the manual's depth-cutoff figures from the corpus the detector is tested against.

Usage: plot_depth_cutoff.py [outdir]        (default: manual/assets)

One SVG per scenario, each showing the sample's depth histogram before capping, the same
histogram after, and where `bin/depth_cutoff.py` put the ceiling. The histograms come from
`test/tools/depth_corpus.py` and the ceilings from the detector itself, so nothing here is
drawn by hand.

The SVG is written directly, with no plotting library. Both axes are logarithmic.

Run it when the corpus or the detector changes; the output is committed and is not rebuilt by
the docs build.
"""

import math
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# The site's palette, from manual/stylesheets.
INK = "#aeaeae"
RULE = "#485266"
BEFORE = "#60c0ff"
AFTER = "#3cb371"
MARK = "#ffd166"

WIDTH, HEIGHT = 760, 300
LEFT, RIGHT, TOP, BOTTOM = 66, 18, 30, 46
BINS_PER_DECADE = 40

# The scenarios worth a figure, and the point each one makes.
FIGURES = [
    ("clean-200x", "An ordinary library",
     "One population, one rise and fall. Nothing is cut."),
    ("hill-small", "A collapsed repeat",
     "A second population at 4000x over 0.2% of the genome. The ceiling goes where "
     "coverage ran out."),
    ("mito", "Organelle contamination",
     "16 kb at 30000x, two orders of magnitude above the library."),
    ("bad-reference", "A poor reference",
     "Two thirds of the covered genome sits at depth 1-5. It is not coverage, and it is "
     "not an anomaly either."),
    ("heavy-tail", "An overdispersed library",
     "One population reaching 3000x. A long tail is not a second population."),
    ("hill-dominant", "A pile-up too large to judge",
     "The deep population outweighs the shallow one four to one. Which is the artefact "
     "cannot be read off the histogram, so nothing is cut."),
]


def read_histogram(path):
    counts = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            depth, positions = line.split("\t")
            counts[int(depth)] = int(positions)
    return counts


def cap_histogram(counts, cutoff):
    """What the histogram becomes once every position deeper than `cutoff` is truncated to it."""
    if cutoff <= 0:
        return dict(counts)
    out = {d: n for d, n in counts.items() if d < cutoff}
    above = sum(n for d, n in counts.items() if d >= cutoff)
    if above:
        out[cutoff] = out.get(cutoff, 0) + above
    return out


def bin_edges(max_depth):
    """Bin boundaries in depth, log-spaced but never narrower than one read.

    Below depth 17 a pure log bin is thinner than the gap between consecutive integers.
    """
    edges = [1]
    while edges[-1] <= max_depth:
        edges.append(max(edges[-1] + 1,
                         math.ceil(edges[-1] * 10 ** (1 / BINS_PER_DECADE))))
    return edges


def binned(counts, edges):
    mass = [0] * (len(edges) - 1)
    for depth, positions in counts.items():
        # bisect_right - 1: the last edge at or below this depth.
        low, high = 0, len(edges) - 1
        while low < high:
            mid = (low + high + 1) // 2
            if edges[mid] <= depth:
                low = mid
            else:
                high = mid - 1
        mass[min(low, len(mass) - 1)] += positions
    return mass


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Canvas:
    """A log-log frame, with depth across and covered positions up."""

    def __init__(self, max_depth, max_mass):
        self.decades = max(1, math.ceil(math.log10(max_depth)))
        self.top = max(1, math.ceil(math.log10(max(max_mass, 10))))
        self.plot_w = WIDTH - LEFT - RIGHT
        self.plot_h = HEIGHT - TOP - BOTTOM

    def x(self, depth):
        return LEFT + self.plot_w * math.log10(max(depth, 1)) / self.decades

    def y(self, mass):
        if mass <= 0:
            return TOP + self.plot_h
        return TOP + self.plot_h * (1 - math.log10(mass) / self.top)


def step_path(canvas, edges, mass, close):
    """A staircase across the bins; closed down to the baseline when it is to be filled."""
    base = TOP + canvas.plot_h
    parts = []
    for index, value in enumerate(mass):
        x0, x1 = canvas.x(edges[index]), canvas.x(edges[index + 1])
        y = canvas.y(value)
        parts.append(f"{'M' if not parts else 'L'}{x0:.1f},{y:.1f}")
        parts.append(f"L{x1:.1f},{y:.1f}")
    if not parts:
        return ""
    if close:
        parts.append(f"L{canvas.x(edges[-1]):.1f},{base:.1f}")
        parts.append(f"L{LEFT:.1f},{base:.1f}Z")
    return " ".join(parts)


def render(name, title, caption, counts, cutoff, reason):
    after = cap_histogram(counts, cutoff)
    edges = bin_edges(max(counts))
    before_mass = binned(counts, edges)
    after_mass = binned(after, edges)
    canvas = Canvas(max(counts), max(max(before_mass), max(after_mass)))
    base = TOP + canvas.plot_h

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {HEIGHT}" '
        f'width="{WIDTH}" height="{HEIGHT}" role="img" '
        f'aria-label="{esc(title)}: {esc(caption)}">',
        f"<title>{esc(title)}</title>",
        "<style>"
        f".ink{{fill:{INK};font:13px system-ui,sans-serif}}"
        f".sm{{fill:{INK};font:11px system-ui,sans-serif;opacity:.75}}"
        f".hd{{fill:{INK};font:600 14px system-ui,sans-serif}}"
        f".rule{{stroke:{RULE};stroke-width:1;fill:none}}"
        "@media (prefers-color-scheme: light){"
        ".ink,.sm,.hd{fill:#3b4252}.rule{stroke:#c4ccda}}"
        "</style>",
        f'<text class="hd" x="{LEFT}" y="18">{esc(title)}</text>',
    ]

    # Decade gridlines and the depth axis.
    for decade in range(canvas.decades + 1):
        x = LEFT + canvas.plot_w * decade / canvas.decades
        out.append(f'<line class="rule" x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{base}" '
                   f'opacity="0.35"/>')
        out.append(f'<text class="sm" x="{x:.1f}" y="{base + 16}" text-anchor="middle">'
                   f"{10 ** decade:,}</text>")
    for power in range(canvas.top + 1):
        y = canvas.y(10 ** power)
        out.append(f'<line class="rule" x1="{LEFT}" y1="{y:.1f}" x2="{WIDTH - RIGHT}" '
                   f'y2="{y:.1f}" opacity="0.25"/>')
        out.append(f'<text class="sm" x="{LEFT - 8}" y="{y + 4:.1f}" text-anchor="end">'
                   f"10<tspan baseline-shift=\"super\" font-size=\"8\">{power}</tspan></text>")

    # Before, filled; after, drawn over it.
    out.append(f'<path d="{step_path(canvas, edges, before_mass, True)}" fill="{BEFORE}" '
               f'opacity="0.22"/>')
    out.append(f'<path d="{step_path(canvas, edges, before_mass, False)}" fill="none" '
               f'stroke="{BEFORE}" stroke-width="1.4" opacity="0.9"/>')
    if cutoff > 0:
        out.append(f'<path d="{step_path(canvas, edges, after_mass, False)}" fill="none" '
                   f'stroke="{AFTER}" stroke-width="1.8"/>')
        x = canvas.x(cutoff)
        out.append(f'<line x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{base}" stroke="{MARK}" '
                   f'stroke-width="1.4" stroke-dasharray="5 4"/>')
        anchor = "end" if x > WIDTH * 0.7 else "start"
        dx = -6 if anchor == "end" else 6
        out.append(f'<text class="sm" x="{x + dx:.1f}" y="{TOP + 12}" text-anchor="{anchor}" '
                   f'fill="{MARK}">cap = {cutoff:,}</text>')

    # Legend and axis names.
    # dx, not spaces: SVG collapses whitespace between tspans.
    out.append(f'<text class="sm" x="{LEFT}" y="{HEIGHT - 8}">'
               f'<tspan fill="{BEFORE}">— before</tspan>'
               + (f'<tspan fill="{AFTER}" dx="20">— after capping</tspan>' if cutoff > 0
                  else '<tspan dx="20">nothing is capped</tspan>')
               + "</text>")
    out.append(f'<text class="sm" x="{WIDTH - RIGHT}" y="{HEIGHT - 8}" text-anchor="end">'
               f"depth →</text>")
    out.append(f'<text class="sm" transform="translate(14,{TOP + canvas.plot_h / 2}) '
               f'rotate(-90)" text-anchor="middle">covered positions</text>')
    out.append("</svg>")
    return "\n".join(out), reason


def main(argv):
    outdir = argv[1] if len(argv) > 1 else os.path.join(ROOT, "manual", "assets")
    os.makedirs(outdir, exist_ok=True)

    with tempfile.TemporaryDirectory() as work:
        subprocess.run([sys.executable, os.path.join(ROOT, "test/tools/depth_corpus.py"), work],
                       check=True, stdout=subprocess.DEVNULL)
        for name, title, caption in FIGURES:
            path = os.path.join(work, f"{name}.tsv")
            decision = subprocess.run(
                [sys.executable, os.path.join(ROOT, "bin/depth_cutoff.py"), path],
                check=True, capture_output=True, text=True).stdout.splitlines()
            cutoff, reason = int(decision[0]), decision[1]
            svg, _ = render(name, title, caption, read_histogram(path), cutoff, reason)
            target = os.path.join(outdir, f"depth-{name}.svg")
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(svg + "\n")
            print(f"depth-{name}.svg   cap={cutoff}   {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
