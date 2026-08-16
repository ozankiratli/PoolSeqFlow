# Pipeline Overview

PoolSeqFlow is nine Nextflow DSL2 modules, each an independent file under `scripts/` and each responsible for its own resume logic. This page is the map; the detail is in [Steps](steps.md).

```text
Raw FASTQ reads
      │
      ▼
[Step 0] Verify environment, parameters and folder structure
      │
      ▼
[Step 1] Build reference dictionaries (BWA, SAMtools, SnpEff)
      │
      ▼
[Step 2] QC & trimming (FastQC → Trim Galore → composition-aware clipping)
      │
      ▼
[Step 3] Alignment (BWA-MEM)
      │
      ▼
[Step 4] BAM cleanup (name-sort → fixmate → coord-sort → markdup → addRG → filter → index)
      │
      ├──────────────────────┐
      ▼                      ▼
[Step 5] Reports    [Step 6] Variant calling (BCFtools mpileup + call)
                             │
                             ├────────────────────────────────┐
                             ▼                                ▼
                    [Step 7] VCF → frequency tables   [Step 8] Annotation (optional)
```

## What runs per sample and what runs once

This distinction explains most of the pipeline's runtime behaviour.

| Step | Granularity | Notes |
|---|---|---|
| 0 Verify | Once | Gate for everything else |
| 1 Dictionaries | Once | Three parallel index builds |
| 2 Trim & clip | Per sample | Two sub-steps, the second depends on the first's FastQC output |
| 3 Align | Per sample | |
| 4 Cleanup | Per sample | |
| 5 Reports | Per sample | Two sub-steps, independent |
| 6 Variant call | **Once, jointly** | One `bcftools mpileup` over every BAM |
| 7 Frequencies | Once, five sub-steps | Serial chain; the last runs twice, on SNPs and on INDELs |
| 8 Annotation | Once | Optional; runs on step 6's output, not step 7's |

Step 6 is the pipeline's barrier: it needs every BAM before it can start, so a single slow sample delays the whole run from that point. It is also why samples must share a reference, and why the sample column order needs deciding ([in `RGTags.csv`](../configuration/read-groups.md#row-order-decides-column-order)).

## The two output branches

After variant calling the workflow forks, and the branches never rejoin:

**Step 7** takes the raw VCF through major-allele normalisation, the cross-sample false-positive filter, depth and quality filtering, a SNP/INDEL split, and conversion to frequency tables. This is the analytical path.

**Step 8** takes the *same raw VCF* — not step 7's output — splits multiallelic sites, and annotates with SnpEff. So the annotated VCF contains sites step 7 removed, in the original reference encoding rather than the major-allele one. Joining the two requires matching on `CHROM`/`POS` and expecting unmatched rows ([details](../concepts/interpreting-results.md#the-vcf-files)).

## Where the work happens

Every step follows the same pattern:

1. Check whether its output already exists in `projectDir`. If so, symlink it and exit.
2. Otherwise do the work in `mainDir/work/`.
3. Move the result to `projectDir` atomically.
4. Symlink it back into the working directory.
5. Copy `.command.log` and `.command.err` into `Logs/`.

That pattern is what makes the pipeline resumable without Nextflow's cache, keeps large files from being duplicated, and survives an interrupted move. The reasoning is in [Design Decisions](../concepts/design-decisions.md); the mechanics are in [Resume Logic](resume.md).

## Error handling

`nextflow.config` sets `errorStrategy = 'finish'`: on a failure, running tasks are allowed to complete and no new ones start. Nothing is left half-written, and a re-run picks up from whatever genuinely finished.

`ClipReads` is the exception, with `errorStrategy 'retry'` and `maxRetries 3` — it is the one step whose failures are commonly transient.

`cleanup = true` removes task working directories after a successful run, leaving only empty hash-prefix folders under `work/`. `./PoolSeqFlow clean` clears those.
