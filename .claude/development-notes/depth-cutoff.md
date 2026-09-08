# The per-sample depth cutoff

**Written 2026-08-31, against the tree at `7d65893`.** The detector shipped in `c3a3191` before this was written and has not moved since: all five constants, the twenty corpus cases and the self-explaining `max()` are exactly as described. One open defect in the process that publishes its output is noted below.

How `bin/depth_cutoff.py` came to be shaped the way it is, and the three designs that were tried and measured before it. E2, 2026-08-30.

## What it is for

`bcftools.maxDepth` was **2000**, one hand-set number applied to every sample of every run. bcftools' own default is 250; 2000 was chosen because it was comfortably larger, and nothing in the output ever said whether it had bitten. Pool coverage is non-homogeneous by design, so the right ceiling is a property of the sample's own depth distribution, and the thing worth truncating is a collapsed repeat or a PCR hill — a *second population* at high depth, not a high mean. One global number either cuts legitimate coverage in a deep sample or lets a pile-up through in a shallow one.

## The method Z insisted on, and it is the reason this works

Z, 2026-08-30, after two candidate algorithms had been argued about in the abstract: *"before jumping into the math, how about we create ~20 distributions ~5 of them clean, rest of them odd distributions then look at the data to find the right mathematical approach."*

That is what `test/tools/depth_corpus.py` is. It killed two designs in about ten minutes that argument had not dented, and it is now a committed test rather than a scratch file, so the evidence stays executable. **The bounds are derived from how each case was built** — `lo` is the 99.9th percentile of that case's real coverage component, `hi` is the mean of its planted anomaly — so the suite measures the detector against the corpus's intent, never against its own previous output. They are written into an `expected.tsv` the script emits beside the histograms; nothing is committed but the generator, so there is no file to open and no expectation to quietly edit. Recording the detector's current answers as the expectation would have made the test a changelog.

## Three designs, and what the corpus did to them

**1. Linear-depth histogram, moving average, walk right from the argmax.** Rejected by Z on sight, and the corpus confirms why twice over.

The smoothing window was a fraction of the mode. Z: *"If we had a super deep file with depth reaching up to 20000 at times, window size would be 2000 which feels incorrect in a scenario where the cutoff was at ~500 then the peak at 20000."* A window of 2000 erases a trough at 500 completely.

The deeper fault is the anchor. **In linear depth a deep lobe is always spread thinner** — a lobe of mean `m` and dispersion `r` has width about `m/√r`, so its peak height falls as it gets deeper. The argmax is therefore biased towards shallow lobes: on `bad-reference` it lands on the depth-1 junk, and any walk rightward from there crosses the real coverage and cuts into it.

**2. Log-depth bins, anchored at the median covered position.** Fixed bins per decade fixes the window problem properly — coverage is multiplicative, so a hill at fifty times the mode is the same shape at 40x and at 4000x, and a constant number of log bins gives every part of the range the same relative resolution. That part survived into the shipped version.

The median anchor did not, and Z called it before it was measured: *"think about a scenario people used some system where the reference is not good enough, say ticks. There are a lot of sites with zero coverage."* `samtools stats` does not report depth 0 at all — verified — so uncovered sites are genuinely absent from the histogram, and the first instinct was that the objection did not apply. It does. A poor reference does not leave sites at depth 0; it leaves them at depth **1 to 5**, and those are in the histogram. On `bad-reference`, two thirds junk, the median covered position is **depth 3** against real coverage at 60x.

**3. Log-depth bins, anchored at the deeper of the position median and the base median.** Shipped.

The base median weights each position by its depth, so it counts reads rather than sites. Junk at depth 1-3 holds essentially no reads, so it cannot move the base median — `bad-reference` gives **63**, squarely in the 60x lobe. The two medians fail on opposite cases, and the measurement is the whole argument:

| case | position median | base median | the real coverage |
|---|---|---|---|
| `bad-reference` | **3** ✗ | 63 ✓ | 60x |
| `hill-large` | 128 ✓ | **4117** ✗ | 120x |
| `hill-dominant` | **17428** ✗ | **21316** ✗ | 200x |

Taking the deeper of the two is not a compromise, it is the safe direction: **an anchor that is too deep can only miss an anomaly and report the sample uncapped, while an anchor that is too shallow cuts into real coverage.** Every other test in the detector is oriented the same way. This is why the `max()` of two medians has a comment in the source explaining itself — it is exactly the kind of line a later reader "simplifies" to one median.

## The one-character fix that mattered most

The trough walk originally advanced on `height <= trough_height`. In a wide empty trough every height is zero, so the trough kept advancing to the *last* empty bin — the far side. The caps that produced were arithmetically correct and useless:

| case | cap with `<=` | cap with `<` | the anomaly |
|---|---|---|---|
| `mito` | 15849 | **502** | 16 kb of organelle at 30000x |
| `spike-far` | 35482 | **708** | 4000 positions at 50000x |
| `hill-small` | 892 | **447** | collapsed repeat at 4000x |

Truncating a 30000x organelle to 15849 does nothing. The cap belongs where coverage *ran out*, not where it came back, and `<` freezes the trough at the first empty bin because nothing is ever strictly less than zero.

## Two cases that are deliberately left uncapped

`hill-large` (the pile-up holds a fifth of the covered genome) and `hill-dominant` (four fifths — Z's own scenario) are recorded in the corpus with verdict `none`, and that is a **policy decision, not a detector limitation**. Neither is distinguishable from a library that simply ran deep, and capping either truncates a large fraction of a real genome on a guess. They are reported uncapped, and `param_capMaxDepth` is how a user overrules that for one sample. This follows Z's standing rule: fail loudly or document, never automate away a decision.

The corresponding trap is that "uncapped" must be *visible*. A sample the detector declines to cut is the one case where the pipeline decided to do nothing, and the user cannot tell that from the output — which is why the sentence explaining the decision is published for every sample whether it was capped or not.

**The process publishing that sentence declares only one of the three files it writes.** `DepthProfile` produces `<sample>_depth_histogram.tsv`, `<sample>_depth_cap.txt` and `<sample>_depth_report.txt`, and its `output:` block names the decision file alone — so the report carrying the sentence above is outside Nextflow's tracking and outside the skip test, which asks about the decision file. A pipeline run cannot reach the bad state: the `atomic_mv` calls put the decision file last, so an interruption leaves the decision missing, the skip does not fire, and all three are rebuilt. Only deleting the histogram by hand gets there. Open as E6h and triaged low. Observed 2026-09-05.

## Everything is oriented towards not capping

Each of the detector's three tests — the trough fraction, the rise factor, the minimum rise mass — can only fail in the direction of leaving the sample alone, and the anchor rule is chosen the same way. An unrecognizable histogram therefore comes out reported rather than guessed at. This is deliberate and it is the property to preserve if the constants are ever retuned: a false cap silently truncates real coverage and the frequency tables that come out of it look perfectly ordinary, while a missed cap is visible in the published report.

## How the capping itself is done

`bin/cap_depth.awk`, a greedy one-pass truncator over a coordinate-sorted SAM stream: a read is kept only if every position it covers is still below the cap, so the depth afterwards can never exceed it. Coordinate order is what makes one pass enough — once the stream has moved past a position nothing can add to it again, so the running depth array is trimmed from behind and never holds more than one read's span. Measured on a synthetic BAM: 4000x → exactly 100x at `cap=100`, and **no position that was already under the cap changed**.

**There is no tool for this in the environment.** `samtools view` has `--subsample FLOAT` and nothing depth-aware; a first draft of `CapBAM` called a `--max-depth` flag that does not exist, with a `|| fallback` that would have silently done nothing. No pysam, no sambamba, no picard. Hence the awk.

**Reads are dropped, not pairs, and that is safe** — checked rather than assumed, because the opposite would have been a silent halving. `bcftools mpileup` excludes anomalous pairs by the PROPER_PAIR flag *in the record*; removing one mate from the file does not clear the survivor's flag, so the survivor is still counted. If a future change starts rewriting flags, this stops being true.

**The alternative was region exclusion** — a depth-derived BED plus `samtools view -L` — and it was not chosen. Excluding a region makes that sample depth-0 there, and `vcffilter.minDP` removes a site when *any* sample is under-covered, so one sample's collapsed repeat would delete those sites for the whole cohort. Truncation keeps the site and reduces one sample's weight in it.

## The figures in the manual

`dev/scripts/plot_depth_cutoff.py` writes SVG directly. matplotlib is not in the environment, and adding it would put a large dependency into `install/environment.yml` for something no run needs; hand-written SVG is text, so it diffs, scales, and carries the site's own palette. The figures are generated once and committed — the docs build copies `manual/assets/` wholesale and never runs this.

Both axes are logarithmic and both have to be. Depth is multiplicative, and the anomalous population holds a thousandth of the positions, so on a linear count axis it is simply invisible — which is the difficulty the figure exists to show. The bins are log-spaced but never narrower than one integer depth: below depth 17 a pure log bin is thinner than the gap between consecutive integers, and the first draft grew a comb of false zeros there.

`build_docs.py` gained an image-path rewrite for these. The manual is authored as a single file and read directly in the IDE, so images are written `assets/…` as the manual itself reads them; every generated page but the home page is emitted one directory down, so the path moves with it.

## Measurements worth not repeating

**`samtools stats -c 1,100000,1`, COV section** is a true per-position depth histogram in one streaming pass. Format confirmed on 1.24:

```
COV	[20-20]	20	2
COV	[100<]	100	128      <- the open top bin, present only when it is non-empty
```

Only non-zero bins are emitted, so the histogram is sparse; depth 0 is not reported at all. The default `-c` ceiling of **1000** collapses everything above it into that open bin — on the trial BAM it swallowed 25 positions silently — so the ceiling has to be raised and the open bin has to be a loud failure, not a warning.

`samtools depth` has no cap in 1.24 (`-d` is accepted and ignored) and is a usable but strictly more expensive fallback. `samtools coverage` is per-contig means, which is the wrong instrument.

**`bcftools mpileup -d 0` means no limit**, measured on 1.24 with a synthetic 600-read pile-up: default → 250, `-d 250` → 250, `-d 0` → **600**, `-d 100000` → 600, `-d 5` → 5. This is what makes `variantCall.maxDepth = 0` safe to ship as the default. It had been asserted from memory twice before anyone measured it; had `0` meant literally zero, the shipped configuration would have produced empty coverage everywhere, silently, at full pipeline cost.

## The constants, and what would move them

`BINS_PER_DECADE = 20`, `SMOOTH_BINS = 3`, `TROUGH_FRACTION = 0.10`, `RISE_FACTOR = 2.0`, `RISE_MIN_FRACTION = 1e-5`. All twenty corpus cases pass with margin, so none of these is currently at a boundary — but `RISE_MIN_FRACTION` is the one to watch. It is what stops a sparse upper tail being read as a second population (`heavy-tail` is the case that would break first), and it is a fraction of the covered genome, so a very small reference makes the absolute floor of one position bind instead. If a real dataset ever needs one of these moved, add it to the corpus first and change the number second.
