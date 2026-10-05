# What `CapBAM` costs, measured

**Written 2026-09-28, against the tree at `c5bacb4` plus uncommitted work. SHELVED: measured, not fixed.** Noticed by Z during the first end-to-end run of the early-development *Drosophila* project on 3.2.0. Nothing was changed as a result.

## The measurement

From that run's own trace, `Output/Reports/PoolSeqFlow_pipeline_trace.txt`, three pools of pooled *D. melanogaster* reads at roughly 300-400 MB of gzipped FASTQ per mate, `threads = 4`:

| process | realtime | %cpu |
|---|---|---|
| `AlignReads:Align` (Sample1) | 14.9 min | 401 |
| `AlignReads:Align` (Sample2) | 11.8 min | 383 |
| `AlignReads:Align` (Sample3) | 11.7 min | 384 |
| **`VariantCalling:CapBAM` (Sample2)** | **10.6 min** | **110** |
| **`VariantCalling:CapBAM` (Sample3)** | **10.3 min** | **111** |
| `SortCleanBams:SortCleanBam` (Sample3) | 6.7 min | 137 |
| `BuildDictionaries:BuildSnpEffDb` | 4.4 min | 106 |
| `TrimQcClip:TrimReads` (Sample1) | 3.6 min | 98 |

**Capping is the second most expensive step in the pipeline**, at about seventy percent of what alignment costs, and it is the only expensive one that does no biology. Alignment earns its fifteen minutes; this is bookkeeping.

**It runs on one core while the run is given four.** Alignment sits at 400% and capping at 110%, so on a four-core machine three cores idle for ten minutes per sample. The wall-clock cost is therefore close to the whole of its CPU cost, where alignment's is a quarter of its own.

The cap chosen for Sample1 on that run was 563, derived per sample by step 5 from its own depth histogram.

## Where the time goes, from `bin/cap_depth.awk` and its caller

`scripts/6_variant_call.nf` runs, per sample:

```sh
samtools view -h ready.bam | cap_depth.awk -v cap=N | samtools view -b -o capped.bam -
```

Three costs, none of them the algorithm:

- **A full BAM to SAM to BAM round trip.** The whole alignment is decompressed to text and recompressed, to decide which records to keep.
- **Neither `samtools view` is threaded.** No `-@`, so both the decompression and the recompression are serial. That alone accounts for much of the gap between 110% and 400%.
- **The awk walks every reference position of every read, twice.** A read is kept only if *every* position it covers is still under the cap, so the check pass has to finish before the increment pass begins. At 150 bp that is up to three hundred array operations per read, in an interpreter. `reflen()` additionally walks the CIGAR string one character at a time per read.

## The property that makes this parallelizable, which is already in the code

`cap_depth.awk` resets its state at every new reference sequence:

```awk
if ($3 != chrom) { delete depth; chrom = $3; low = $4 + 0 }
```

**So chromosomes are already independent.** Capping each one separately and merging gives a byte-identical read set, because no decision on one sequence can depend on another. A *Drosophila* assembly has a handful of arms carrying nearly all the reads, so the parallelism available is roughly the core count, and it needs no change to the capping rule at all. That is the obvious first thing to try and it costs no correctness argument.

## Why the cap is not simply handed to mpileup, which would cost nothing

`bcftools mpileup -d` caps depth at pileup time with no BAM rewritten, and `variantCall.maxDepth` already passes it. It cannot replace this, and the reason is worth recording so nobody spends the afternoon rediscovering it:

**The cap is per sample.** Step 5 measures a ceiling for each sample from that sample's own depth histogram, and `capBAM.maxDepth = -1` is what asks for it. `mpileup -d` applies one number to every input file in the cohort call, and step 6 pileups the whole cohort in a single invocation. One number cannot carry seven samples' ceilings.

Passing the maximum of the per-sample caps would leave every shallower sample uncapped, which is not the same filter and would change the frequencies.

## What is not measured

Only three samples, one organism, one machine, one cap value, and `%cpu` is the trace's own figure rather than an instrumented profile. **Nothing here separates the two `samtools view` ends from the awk in the middle**, so the split between "serial compression" and "interpreter" is inferred from the shape of the pipeline rather than timed. A run with `-@` added to both ends and nothing else changed would settle that in one measurement, and should be the first thing done if anyone picks this up.

See [[depth-cutoff.md]] for why the per-sample ceiling exists at all and what the alternatives were measured against.
