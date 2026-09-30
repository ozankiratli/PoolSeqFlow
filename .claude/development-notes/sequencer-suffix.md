# The sequencer suffix, and why nothing strips it

**Written 2026-09-29, against the tree at `6746280` plus uncommitted work.** Raised by Z from a collaborator's run: *"If sample name is A08781 but then they were submitted as A08781_S58 the metadata check cannot distinguish."* Shelved at the time with a manual section; picked up here and resolved as documentation, by Z's decision.

## What the problem actually was

`readPairChannel` uses `fromFilePairs`, so the sample identifier is **derived from the file name** -- whatever is left after `readPattern` is stripped. Illumina's `bcl2fastq` and BCL Convert append `_S<n>`, the sample's row number in the sample sheet, so `A08781` is delivered as `A08781_S58_R1.fq.gz` and the identifier is `A08781_S58`. Nothing in the pipeline chose that and nothing removes it.

**The join failing is not the defect. The defect was that the failure is reported as two unrelated problems**, in two directions checked asymmetrically:

| direction | verdict | message |
|---|---|---|
| reads with no row | hard FAIL | `Sample 'A08781_S58' has reads but no row in metadata.csv` |
| row with no reads | NOTE only | `NOTE: metadata.csv has a row for 'A08781', which has no reads in Data/` |

A user who wrote the short name gets both and nothing connects them. At sixty samples that is a hundred and twenty lines, none of which names the cause. Step 0 has both halves of the answer in hand and never puts them together -- which is exactly what "cannot distinguish" meant.

**And there is a second half that is worse, because it does not fail.** `RG_Sample` defaults to `SampleID` (`parse_metadata.py`, `pool = row.get("RG_Sample") or row.get(SAMPLE_ID, "")`). Fix the join by writing `SampleID = A08781_S58`, leave `RG_Sample` blank, and the run **succeeds** with the sample sheet's row number in every VCF column, every frequency table header and every analysis result. Worse, a sample split across lanes stays two separate pools rather than one, so each carries half its depth and the false-positive filter sees twice as many pools as exist.

## Why stripping the suffix is the wrong fix

The obvious fix -- strip a trailing `_S<n>` from `SampleID` -- is actively wrong, and the reason is the mechanism that makes lanes work. A sample split across two lanes arrives as `A08781_S58_L001` and `A08781_S58_L002`: two rows, one `RG_Sample`, merged into one pool. Stripping would give both rows the same identifier, and a repeated `SampleID` is refused, so one of the pairs would be lost.

The suffix is load-bearing in `SampleID` and meaningless in `RG_Sample`. That asymmetry is the whole design and it is correct.

## What was decided, and what was not

**Z, 2026-09-29: documentation, not code.** *"First we tell explicitly to the user to use the full name for SampleID... RG_Sample will need to be entered too explicitly. And we will ask the user to put what they want the pipeline to output as sample names in the outputs."* Then, on the defaulting: *"If we haven't changed automatic filling of RG_Sample, it's fine. We can add a note... It's good documentation practice."*

So the defaulting is unchanged, and is now stated plainly rather than presented as a fine choice:

- `SampleID` is defined in both places the manual defines it as **the whole name before the read tag, as delivered**, naming `_S<n>` and `_L00<n>`.
- The read-group section carries a two-row table separating the questions the two columns answer -- `SampleID`: which files is this row, from your sequencer; `RG_Sample`: what name do I want in my results, from you.
- A new subsection gives **both failure modes with the real messages quoted verbatim**, checked against `0_verify_environment.nf`: the two unconnected lines when `SampleID` is short, and the `METADATA CHECK: ... is one column, pooling ...` line that catches a blank `RG_Sample` before any compute is spent.
- `metadata.csv.template`'s eight example rows became `Sample1T1_S1_L001 -> Sample1T1`. Same eight rows and four pools, verified through the parser -- but the example now demonstrates the two columns doing different jobs, where before they looked redundant.

**NOT built, and not asked for:** step 0 connecting the two messages when an unmatched read id equals an unmatched row id plus a recognizable suffix, and a warning when `RG_Sample` was defaulted. Both are still the right shape if anyone wants them.

There is a practical obstacle to the second that is worth recording: **the parser fills `RG_Sample` before anything downstream sees it**, and emits a plain list of rows, so nothing after the parse can tell a written value from a defaulted one. A runtime warning has to come from `parse_metadata.py` itself, which has a notes channel -- but those notes reach `PoolSeqFlow check project` and NOT a run's step 0, because `resolve_parameters.nf` keeps a parser's stderr only when it fails.

## One thing measured, because it decides whether the advice is safe

**Filling `RG_Sample` with the value it was already defaulting to does not trip the metadata change guard.** The parser fills a blank cell, so the guard's projection -- `metadataGuardLines()`, which records each RG column of the resolved row -- is byte-identical whether the column is absent or written out with the same value. Verified by parsing both shapes.

That is what makes "always fill it in" safe to tell every existing project: no guard trip, no results invalidated. A project that *should* have been pooling and was not will trip when it fixes the column, which is correct -- those results really were produced under the wrong pooling. The manual says so, so nobody hesitates to add the column.
