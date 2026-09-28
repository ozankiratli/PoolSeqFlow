# What `-C 50` removes, and why a pool is the wrong place for it

**Written 2026-09-28, against the tree at `c5bacb4` plus uncommitted work. SHELVED: measured, not fixed.** Raised by a collaborator's run of an installed 3.2.0 on a cluster, 2026-09-27. Nothing in the pipeline changed as a result of this note; the decision it sets up belongs to Z, because it moves every number the tool publishes.

## The report, in the order it arrived

Three symptoms from one run:

- the depths in the VCF were far below the aligned BAM, by orders of magnitude rather than by a fraction
- the frequency tables came out **empty**
- *"the VCF was not what I intended to recover"*

## The measurement

`scaleMapQ` defaults to 50 and reaches every call as `-C 50`, composed at `scripts/resolve_parameters.nf:85`. Measured with the release's own bcftools, the release's own option string, and 2000 synthetic reads over one 50 bp window, every read at MAPQ 60 with flat Q40 bases:

| mismatches per 50 bp read | ours, `-C 50` | `-C 0` |
|---|---|---|
| 0 | 2000 | 2000 |
| 1 (2% divergence) | 2000 | 2000 |
| 2 (4%) | 2000 | 2000 |
| **3 (6%)** | **site absent** | 2000 |
| 5 (10%) | site absent | 2000 |
| 10 (20%) | site absent | 2000 |

**It does not reduce depth. Past the threshold the site leaves the VCF altogether.**

Isolated at 10% divergence, the same 2000 reads:

```
-C 50 -q 30  ->  site absent
-C 50 -q 0   ->  site absent     the mapping-quality floor plays no part
-C 0  -q 30  ->  DP 2000
-C 0  -q 0   ->  DP 2000
-C 20 -q 30  ->  site absent     any nonzero -C, not the value 50
```

So `scaleMapQ` alone decides it, and `variantCall.varQualMin` is not involved.

## The mechanism, and why a pool is different

`-C` downgrades a read's mapping quality in proportion to how many mismatches it carries, and 50 is what samtools recommends for BWA. That recommendation is for **single-sample resequencing against a matched reference**, where a read full of mismatches is probably in the wrong place, and downgrading it is how a caller avoids believing it.

A pool inverts the premise. Excess mismatches in a pooled library are **diversity**, which is the quantity being measured, and they concentrate in exactly the regions a study is about. Mapping a pool to a reference drawn from another population raises every read's mismatch count at once. The reads `-C` discards are therefore the informative ones, and what survives is the reference-like fraction: a pull toward the reference that is strongest where the data is most variable.

That accounts for all three symptoms without needing a second cause. Depth collapses; sites vanish, so the tables downstream have nothing to convert; and the call set that does survive is biased rather than merely thin.

## What this is not, each ruled out by measurement rather than by argument

- **Not the depth cap.** `capBAM.maxDepth` was 0 on that run, which routes every sample to the uncapped branch at `scripts/6_variant_call.nf:124-133`. No BAM was truncated.
- **Not mpileup's own ceiling.** `-d 0` is genuinely unlimited: 2000 reads gave DP 2000. The bcftools default and an explicit `-d 250` both truncate to 250, so the risk is real but the value we pass is right. This is worth keeping because a shallow fixture cannot tell unlimited from 250 from broken, and the suite's end-to-end case is shallow.
- **Not the mapping-quality floor.** Measured above.
- **Not base quality.** `-Q 30` costs something like 10-30% of bases on real Illumina data. It cannot produce two orders of magnitude.

## What was not shown, and would have to be

The reads are synthetic: one position, uniform MAPQ 60, flat Q40 bases, no pairs and no indels. `-C` weights mismatches by base quality, so the cliff on real 150 bp reads at real quality sits somewhere other than three-in-fifty. **The mechanism and its totality are established; the threshold is not**, and nothing here was reproduced on the collaborator's own data at this note's date.

The measurement that would settle it on real data needs no pipeline run: `bcftools mpileup` over one ready BAM and one region, `-C 50` against `-C 0`, comparing mean DP.

## The decision, which is deliberately not made here

`scaleMapQ` is a parameter, so no project is stuck: setting it to 0 today disables the downgrade. The open question is the **default**, and it is a scientific one rather than a mechanical one. Changing it changes every frequency the tool publishes, which moves the version and invalidates existing results directories. See [[false-positive-filter]] and [[depth-cutoff]] for the two other places a stage-3 decision reaches a published number.

The manual's filter chain currently describes stage 3 as removing "low mapping quality, low base quality". That is true and it is not enough: it gives no hint that the stage can delete a site outright at moderate divergence, which is the part a person interpreting an empty table needs.

## A gate that is missing whatever the answer turns out to be

**Nothing in step 7 refuses an empty VCF or an empty frequency table.** The run published empty tables and reported success. That is the failure family in [[gates-that-stopped-checking]] and the same shape as the missing-mate drop 3.2.0 fixed: silence where a refusal belongs. It should be built regardless of what happens to `scaleMapQ`, because it is what turns this class of problem from a wrong number into a stopped run.
