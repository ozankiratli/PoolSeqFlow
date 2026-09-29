# A run that found nothing used to report success

**Written 2026-09-29, against the tree at `85eb380` plus uncommitted work.** The guard `mapq-downgrade.md` said should be built whatever happened to the default. Building it turned up a second finding that made the shipped documentation wrong, so both are here.

## The hole, measured end to end

A header-only VCF - exactly what `bcftools mpileup` emits when the pileup reaches it empty - walked through every stage of step 7 by hand:

| stage | exit | rows out |
|---|---|---|
| `MajorAlleleToRef.py` | 0 | 0 |
| `filterFalsePositives.sh` | 0 | 0 |
| `bcftools view -e` (depth) | 0 | 0 |
| `vcftools --minQ --recode` | **0** | 0 |
| `vcftools --remove-indels --recode` | **0** | 0 |
| `createDepthFile.sh` | 0 | header only |
| `depth2freq.awk` | 0 | header only |

**Every stage succeeds.** The two `vcftools` calls were the links nobody had checked and they exit 0 as well. What the user was left with was a frequency table holding one line of column names, from a run that reported success at every step.

Nothing in step 7 could have caught it: all seventeen of its conditionals are `[ -f ]`, and there is no `test -s`, no row count and no `exit 1` anywhere in the file. The two helpers that look like they might check only look at headers - `createDepthFile.sh` refuses when `#CHROM` carries no sample columns, `filterFalsePositives.sh` when `bcftools query -l` returns none - and an empty VCF satisfies both, because bcftools preserves the header.

## The trap a naive guard falls into

**Eleven `touch` statements in step 7 write deliberate zero-byte placeholders.** Every process checks whether anything LATER in the chain already exists and emits a stub if so, which is what makes a partially completed step 7 resumable. A guard written as "the file is empty, refuse" fires on every one of those skips.

So all three guards sit **inside the `else` branch only**, where real work happened. A skip cannot reach them.

## Three guards, one per door

Matching the `capBAM.histogramMax` refusal in `5_reports.nf`, which is the house shape: tagged stderr, the parameter named, whether it costs anything already produced, `exit 1`.

| where | catches | names |
|---|---|---|
| `6_variant_call.nf`, after `bcftools call` | the call set is empty | `variantCall.scaleMapQ`, and prints the composed `mpileupOptions` |
| `7_vcf2freq.nf`, after the cross-sample filter | every site filtered out | `filterFalsePositives.sampleThreshold`, `poolSize` |
| `7_vcf2freq.nf`, after depth and quality | every site filtered out | `minDP`, `minQUAL`, `dropZeroDepth` |

**`00_static`'s parameter-map check caught the first draft.** The step 6 message interpolated `variantCall.scaleMapQ` and `variantCall.varQualMin`, which step 6 had never read - it reads only the composed `mpileupOptions`. Declaring them in `stepParameterMap()` would have been the wrong fix: a project that pins `mpileupOptions` by hand makes both inert, and two runs would then be held apart by settings that did nothing, which is exactly the trap step 7's own comment warns about in the other direction. Printing the composed string, already declared, is correct AND more informative.

## The second finding: the destructive band is not a range

The template said *"Below 11 it does nothing; 11 to about 20 discards every read."* The second half is wrong.

`-C` caps each read's adjusted mapping quality near its own value, and `-q` (`variantCall.varQualMin`) then rejects anything below the minimum. **So the band is wherever `scaleMapQ` sits below `varQualMin`** - a relationship between two settings, not a fixed range. "11 to about 20" was an artifact of measuring only at the shipped `varQualMin = 30`.

Sites called, three pools, `2L:5000000-5050000`, cohort call with the release's options, against 695 with the adjustment off:

| `scaleMapQ` | `-q` 10 | 20 | 30 | 40 |
|---|---|---|---|---|
| off, 0, 5, 10 | 695 | 695 | 695 | 695 |
| 11 | 17 | **0** | **0** | **0** |
| 15 | 65 | **0** | **0** | **0** |
| 20 | 112 | 32 | **0** | **0** |
| 25 | 205 | 163 | **0** | **0** |
| 29 | 279 | 203 | **0** | **0** |
| 30 | 297 | 217 | 44 | **0** |
| 35 | 374 | 368 | 251 | **0** |
| 40 | 460 | 441 | 305 | 52 |
| 50 | 545 | 545 | 490 | 316 |
| 70 | 620 | 617 | 612 | 573 |
| 100 | 648 | 644 | 644 | 641 |

**The `-q 10` column is the proof: no dead band at all**, because 11 already clears the minimum. Then checked directly at six thresholds - `varQualMin` 12, 15, 20, 30, 40, 50. `scaleMapQ` one below returned zero every time; `scaleMapQ` equal to it returned sites every time.

**Clearing the minimum is not being safe.** At the default `-q 30`, `-C 30` returns 44 of 695 sites - 6%. That reproduces the whole-genome figure in `mapq-downgrade.md` (94,681 against `-C 100`'s 1,716,020, 5.5%), so the region is representative and the two measurements corroborate each other.

A synthetic grid pointed at the mechanism first, but its reads were identical clones at MAPQ 60, so it was all-or-nothing and put the boundary in the wrong place. **Every number above is from real pools.** The synthetic is recorded here only because it is what suggested looking at `-q` at all.

## The check before the run

`bin/check_project.sh` now reports the relationship, so a project is told before it spends an afternoon. It reads the **composed** `mpileupOptions` rather than the two settings, so a project that pinned the option string by hand is judged on what will actually run, and one that pinned it without a `-C` is reported as unjudged rather than guessed at.

Verdicts: `0` is off; at or below 10 is inert, with a note to write 0 if that was the intent; below `varQualMin` is a failure; below twice `varQualMin` is a warning carrying the measured 6%; above that passes.

## Coverage

- Three cases in `04_pipeline`, one per door, each a full run entering the empty state a different way. **Proven to bite**: with the guards reverted all three fail, and the assertion that fails alongside the exit status is `no frequency table should have been written` - the run completed and published the empty table.
- Seven cases in `02_launcher` for the `check_project.sh` verdicts, against a **stubbed `nextflow`** so they need no JVM. Proven to bite by deleting the check outright: all seven fail.
- The case that matters most for the future is `check project accepts a scale that clears a lower minimum`: the same `-C 15` that is fatal at `-q 30` is fine at `-q 5`. A check written against a constant would call it broken, which is the mistake the old template comment encoded.

## Still open

`0_verify_environment.nf` validates no parameters at all. The `scaleMapQ` relationship is caught by `check project`, which is optional, and by step 6, which is thirteen minutes in. Step 0 is where it would cost nothing - but step 0 has no parameter-validation section to add to, and building one is its own piece of work.
