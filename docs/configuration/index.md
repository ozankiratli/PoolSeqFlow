# Configuration

Everything is set in `parameters.config`. There are no command-line overrides ([why](../concepts/design-decisions.md#configuration-is-a-file-never-a-flag)).

This page sorts the parameters by what they actually affect, which is the distinction that matters most: some change your numbers, some change only where files land or how fast the run goes, and some are computed for you and should not be edited at all.

## Three kinds of parameter

### Parameters that change your results

Change one of these and your output changes. Step 0 records them and **refuses to run** if they differ from what produced your existing outputs, so that one folder never holds results from two settings.

| Parameter | Effect | Page |
|---|---|---|
| `poolSize` | Individuals per pool; sets the minimum credible allele frequency | [Variant Calling](variant-calling.md#poolsize-and-diploidy) |
| `diploidy` | Ploidy; same threshold | [Variant Calling](variant-calling.md#poolsize-and-diploidy) |
| `filterFalsePositives.sampleThreshold` | Fraction of samples that must support an allele | [Variant Calling](variant-calling.md#samplethreshold) |
| `bcftools.*` | Pileup and calling behaviour, including the depth cap | [Variant Calling](variant-calling.md) |
| `vcffilter.minDP`, `vcffilter.minQUAL` | Post-call depth and quality filtering | [Variant Calling](variant-calling.md#depth-and-quality) |
| `samtools.filter`, `samtools.required`, `samtools.mapq` | Which alignments reach the pileup | [Alignment Filters](filters.md) |
| `cutadapt.at_gc_error` | Composition tolerance driving the clip points | [Trimming & Clipping](trimming.md) |
| `trim_galore.quality`, `.autodetect`, `.adapter1/2` | What is trimmed off the reads | [Trimming & Clipping](trimming.md) |
| `annotate`, `gffFile` | Whether step 8 runs and against what | [Pipeline Steps](../pipeline/steps.md#step-8-annotate-variants) |
| `RGTags.csv` | Which FASTQ pairs are one sample, and column order | [Read Groups](read-groups.md) |

### Parameters that change speed, not answers

Safe to tune between runs. Step 0 does not track them, precisely because they cannot change a result.

| Parameter | Effect | Page |
|---|---|---|
| `threads` | Cores a single task may use; drives every tool's thread count | [Resources](resources.md) |
| `memory` | Memory ceiling for a single task | [Resources](resources.md) |
| `java.heapSize` | JVM heap for FastQC and SnpEff | [Resources](resources.md#java) |
| `fastqc.memory` | FastQC's own memory setting, in megabytes | [Resources](resources.md#java) |
| `software.*` | Paths to executables, if not using the conda environment | [below](#using-system-tools) |

### Parameters that change where files go

| Parameter | Effect |
|---|---|
| `mainDir` | Working directory — scratch, `work/`, symlinks |
| `projectDir` | Permanent storage — all outputs, and where your input already lives |
| `dataSource` | Subdirectory of `projectDir` holding the FASTQs |
| `readPattern` | Glob matching paired FASTQs; needs a `{1,2}` group |
| `referenceFile`, `gffFile`, `rgTagsFile` | Input filenames within `projectDir` |
| `vcf.fileName` | Base name for the VCFs and frequency tables |

### Do not edit: derived values

A large part of `parameters.config` is computed. The `cores` block derives every tool's thread count from `threads`; the `dir` block builds every path from `mainDir` and `projectDir`; `filterFalsePositives.sensitivity` is computed from `poolSize` and `diploidy`; `snpEff.db` is derived from `gffFile`.

Editing these by hand breaks the invariant that makes the pipeline predictable — that one number sizes the run, and one pair of paths places everything. Change the input, not the derivation.

## What to decide before your first run

In rough order of how expensive it is to get wrong:

1. **`RGTags.csv`** — which FASTQ pairs share an `SM`. Wrong here means valid results that answer a different question, and fixing it invalidates every BAM. [→](read-groups.md#sm-decides-what-counts-as-a-sample)
2. **`poolSize` and `diploidy`** — these set the frequency floor for the whole run. [→](variant-calling.md#poolsize-and-diploidy)
3. **`filterFalsePositives.sampleThreshold`** — decides whether alleles seen in few pools survive. The default removes them. [→](variant-calling.md#samplethreshold)
4. **`bcftools.maxDepth`** — check it against the depth you sequenced for. [→](variant-calling.md#maxdepth)
5. **`threads`** — must fit the machine, or the run fails at submission. [→](resources.md)

Changing any of items 1–4 after outputs exist means deleting those outputs. That is enforced, not advisory.

## Using system tools

The `software` block maps each tool to a command:

```groovy
software {
    samtools = 'samtools'
    bcftools = 'bcftools'
    // …
}
```

Replacing a command with an absolute path makes the pipeline use a system installation instead of the conda environment. This is supported but not recommended: the environment pins exact builds because Pool-seq results depend on the precise behaviour of the pileup and filtering tools, and a version mismatch will not announce itself. Use it to work around a genuine packaging problem, not as a default.
