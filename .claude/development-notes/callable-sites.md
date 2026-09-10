# The callable-sites track — built, measured, and reverted

**Written 2026-08-31, against the tree at `7d65893`.** Nothing of the reverted work has come back, and the replacement it argues for is still not built. The three lessons at the end all still hold.

A per-window callable-sites track was added to step 5 on 2026-08-30 and taken back out the same day. Nothing of it remains in the tree. This note exists because the **measurements** behind the decision are what size the E4 analysis layer's working set, and because the reasoning is worth not repeating.

The removed work is in `callable-sites-reverted.patch`, beside this note, if any of it is ever wanted.

## What it was

`CallableSites` in `scripts/5_reports.nf`: one `samtools depth` pass per sample through `bin/callable_bins.awk`, gzipped to `Output/Reports/Callable/<sample>_callable.tsv.gz`. Per 1 kb window it recorded how many positions reached each of several depth thresholds, so anything measured per window would have a denominator. Thresholds were several rather than one because "callable" is a question about the analysis, not the alignment — a diversity estimate might want 10x, a presence/absence question 1x.

## Why it went

Z: *"all of this needs to be wired to the analysis layer, because we don't know which analysis is needed by the user."*

The main pipeline was producing an artifact on the guess that someone would want it. Of the fifteen tools in the E4 roster, exactly two would have read it — π/θ_W/Tajima's D, and the SFS sweep scan — and only for windows that are a multiple of the bin size. Z's sharper objection: it is a **derivable** table. A full per-position depth file yields it at any resolution, and yields it at analysis time rather than freezing the resolution at run time.

So the analysis layer derives it on demand into `Analysis/Main`, and the pipeline publishes only what a person reading results actually wants.

**That derivation is still not built.** `Analysis/Main` exists as a path and nothing writes per-position depth into it; the modules built since read the published depth table instead. But planning the third of them sharpened the rule this revert produced, and the sharper form is the one to keep: **promote a derivation when it costs more to recompute than to store, not merely when more than one module wants it.** A per-allele frequency matrix is wanted by two modules and is still cheaper to recompute than to keep. The callable-sites count is the thing that clears the bar, which is why `Analysis/Main` was warned to grow to tens of gigabytes.

## The measurements, which is the part worth keeping

Realistic depth data, 6 samples, overdispersed around 50x:

| artifact | size per Mb of covered genome |
|---|---|
| full per-position depth, `gzip -9` | **9.16 MB** |
| full per-position depth, `bgzip` | 9.04 MB + ~1 kB tabix index |
| binned at 1 kb, gzipped | **0.025 MB** |

A 360x ratio. Extrapolated, bgzipped:

| genome | 6 samples | 24 samples |
|---|---|---|
| 300 Mb insect | 2.4 GB | 7.5 GB |
| 1 Gb plant | 8.1 GB | 25 GB |
| 3 Gb vertebrate | 24.4 GB | 75 GB |

Sample count scales sub-linearly — 4x the samples is ~3x the size, because the `chrom`/`pos` columns amortise.

**`bgzip` + `tabix` is the finding that makes the full file usable.** Same size as plain gzip, and an arbitrary 10 kb region comes back in ~6 ms, so a module never reads the file whole. Any per-position artifact the analysis layer builds should be bgzipped and tabix-indexed for this reason.

For scale: those figures are roughly **5% of the ready BAMs** the project already keeps, which is what made Z judge the size acceptable.

## Two things learned that outlived the revert

**`samtools depth` takes multiple BAMs in one pass** and emits one column per BAM — `chrom pos d1 d2 ...` — with `-H` writing a header naming each file. So a joint cohort depth file is ONE process, not one per sample. The per-sample design that was reverted was more expensive than the alternative.

**The flags are inverted between the two tools.** `samtools depth -q` is BASE quality and `-Q` is MAPPING quality; `bcftools mpileup -q` is MAPPING quality and `-Q` is BASE quality. Same two letters, swapped. This project has already shipped a bug from exactly that confusion — in 2.2.0 `baseQualMin` and `varQualMin` were supplying each other's mpileup flags, and because both default to 30 nothing looked wrong. Whatever builds a depth track in the analysis layer must swap the flags, not the values.

**And a design error worth not repeating:** the reverted `CallableSites` read the **ready** BAM in step 5, while `VariantCall` piles up the **capped** BAM in step 6. Denominator and numerator would have described different read sets, diverging precisely at the anomalous pile-ups — the regions anyone would scrutinise. Any depth artifact must be built from the same BAMs the calls came from.
