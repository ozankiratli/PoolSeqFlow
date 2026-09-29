# A cell nobody measured, and how it is published

**Written 2026-09-29, against the tree at `eedf598` plus uncommitted work.** Raised by Z the moment `vcffilter.dropZeroDepth` landed: if the pipeline can now be told to keep a site some pool has no reads at, what does the frequency table say about that pool, and does the analysis layer need to change.

The first half is fixed here. The second half is measured and **one decision is left open**, named at the bottom.

## What a zero-depth cell actually looks like

Measured rather than assumed, because the fixture VCF this project unit-tests against has no such record and its README says so: *"no sample has `DP=0` -- a division-by-zero case has to be constructed, not found here."*

Constructed one: a 120 bp reference, twenty reads for `SampleA` over 11-50 carrying an alternate at position 30, twenty reads for `SampleB` over 71-110 and none anywhere near it. Through `bcftools mpileup` with the release's own option string, then `bcftools call -m -A -v`:

```
chrT  30  A  C  GT:PL:DP:SP:AD  1/1:214,60,0:20:0:0,20  ./.:0,0,0:0:0:0,0
```

**A sample with no reads gets `AD` as `0,0`, not as a missing value.** So the depth table cell reads `0,0` -- real zeros -- and nothing about it is missing in the VCF sense. That matters because `allele_frequencies()` and `site_diversity()` both carry a `flat[flat == "."] <- NA` line written for bcftools' missing value; that line is not what handles this case, `total <= 0` is.

## What the frequency table said before

`bin/depth2freq.awk` divided each count by the cell's total and had `(total > 0) ? counts[j] / total : 0`. Run over the record above:

```
CHROM  POS  REF  ALLELE  TOTAL_AD  SampleA  SampleB
chrT   30   A    A       0         0        0
chrT   30   A    C       1         1        0
```

**`SampleA`'s zero and `SampleB`'s zero are the same character and mean opposite things.** SampleA was read twenty times and carries no `A`; SampleB was not read at all. A reader has no way to tell them apart, and the one tell -- that SampleB's column sums to 0 across the site where every other column sums to 1 -- is not something any reader is going to compute.

This was unreachable before `dropZeroDepth`: `vcffilter.minDP` removes a site where any sample falls short, and the smallest minDP that means anything is 1. The branch existed and could not fire. `dropZeroDepth = false` with `minDP = 0` is what makes it reachable, which is two deliberate edits from any default.

## The change

`freqs[j] = (total > 0) ? counts[j] / total : "NA"`. Every allele of that site in that pool reads `NA`; every other pool at the same site is untouched, and the same pool at every other site is untouched. `TOTAL_AD` is converted by the same loop and takes the same rule.

`NA` rather than an empty field or a `.`: the table is read by R more than by anything else, and `read.table` takes `NA` natively. `pandas.read_table` gives `NaN` for it too.

**The depth table is not changed.** `0,0` there is unambiguous already -- zero reads supporting each allele, with no competing reading -- and it is what every module computes from.

`delete parsed_vals` went in at the same time. It had been sitting in the release triage as a one-liner to apply whenever something next touched this file, and this is that. `parsed_vals` is global, the write loop runs over the cell's counts and the print loop over the ALT column's alleles, so a cell holding fewer counts than its row declares alleles printed whatever an earlier row left at that index. Measured with the clear removed: a row at `chr1:200` published `0.25` for its third allele, carried from `chr1:100`. It cannot reach this from a run -- `AD` is `Number=R` and `MajorAlleleToRef.py` stops on a ragged cell first -- so the case in `03_helpers` is written against the converter's contract rather than against what feeds it.

## The analysis layer: per site it was already right

Nothing in the frame or in any module reads the frequency table's numbers. `basicstats` declares `frequencies` in `needs`, which requires the file to exist, and its `main.nf` passes only depth tables to R. Every module computes from the depth table, which is the standing rule and is what made this a publishing defect rather than a numerical one.

And the per-site arithmetic already treats an unmeasured cell as unmeasured, in four places, each with the behavior stated in its own comment:

| | |
|---|---|
| `allele_frequencies()` | `depth` 0, `freq` NA on every allele of that site |
| `site_diversity()` | `depth` 0, `h` NA |
| `n_eff()` | NA at depth 0, so the site carries no weight |
| `mean_distance()` | every pair divided by its own site count |

Run, not read: `allele_frequencies(list(A = c("0,20"), B = c("0,0")))` returns depth `20, 0` and freq `0, 1` against `NA, NA`.

`association` is safe by the same route -- the weight is `n_eff`, NA becomes 0, and a weight of 0 removes the pool from that site's fit. `mds` is safe and already says so in its gates: *"A pool with no reads at a site drops it for that pool's pairs and leaves the others intact."*

## The analysis layer: per pool it is not

`basicstats` aggregates each pool's per-site depths into summary columns, and those aggregates run over **every called site**, including the ones that pool never saw. One pool, four sites, `nChrom` 200, with and without a single zero-depth site among them:

| | `depth_mean` | `depth_harmonic` | `n_eff_harmonic` | `sites` | `pi_per_called_site` |
|---|---|---|---|---|---|
| four sites read | 100.00 | 100.00 | 66.89 | 4 | 0.43653 |
| one of them unmeasured | **75.00** | **0.00** | **NA** | 4 | 0.41284 |

Three different behaviors in one row:

- **`pi_per_called_site` is correct.** `h_sum` sums with `na.rm = TRUE` and the denominator is `sum(!is.na(corrected))`, so the unmeasured site leaves both. This is the column the manual already described as possibly smaller than `sites`.
- **`depth_harmonic` collapses to 0 and takes `n_eff_harmonic` to NA with it.** `harmonic_mean()` returns 0 if any value is 0, deliberately and with a comment saying so: *"a position carrying no reads carries no information."* Over one position that is right. Over a genome it says the pool has no information anywhere, out of one missed site in a million. It is at least **loud**: a depth_harmonic of exactly 0 beside a mean in the hundreds is not a number anyone reads past.
- **`depth_mean` is quietly wrong.** 75 where the pool was read at 100. It is a plausible number, it carries no marker, and `depth_median` behaves the same way. This is the one that would be believed.

`sites` in both tables stays the full count, so it no longer equals the number of sites any of the depth columns were taken over.

The step 5 depth histogram path is unaffected: `harmonic_mean(hist$depth, hist$positions)` reads the COV rows of `samtools stats`, which have no zero bin.

## Decided 2026-09-29, Z: aggregate over the sites the pool was read at

`read_at <- !is.na(stats$depth) & stats$depth > 0`, and `depth_mean`, `depth_median` and `depth_harmonic` are taken over that subset in both `depth.tsv` and `diversity.tsv`. A new `unmeasured` column in each publishes what was left out, so the denominator is readable rather than assumed. `sites` keeps its meaning and stays the full count.

`neff.tsv`'s called-site rows moved with it: `positions` is now `sites - unmeasured`, which is what that column has always meant -- how many positions the figure beside it was measured over -- and it would otherwise have named a count the depth was not taken over.

An all-unmeasured pool gives NA on all three rather than a mix. `mean(numeric(0))` is `NaN` while `median(numeric(0))` is `NA`, so the empty case is branched explicitly instead of being left to R's two answers.

`basicstats` goes to `20260929.001` and gains a gate stating the rule.

**What the case that guards it had to work around:** `awk -v n="NA" 'BEGIN { exit !(n > 0) }'` succeeds. `-v` assigns `NA` as a string, `"NA" > 0` compares it with `"0"` character by character, and `N` sorts above `0`. The first version of the `n_eff_harmonic` assertion passed on exactly the NA it existed to catch. It now tests the string first and forces the number with `n + 0`.

Reverting `basicstats.R` to `HEAD` fails all eight assertions of that case, including `depth_mean` at 60 where it should be 80 and `depth_harmonic` at 0.

## Still true afterwards

The dead zone and the destructive band of `scaleMapQ` are untouched by any of this, and **nothing in step 7 refuses an empty VCF or an empty frequency table**. `scaleMapQ = 15` still gives an empty run that reports success. See `mapq-downgrade.md`; the emptiness guard is still unbuilt.
