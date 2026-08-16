# When to use PoolSeqFlow

This page is about fit. It describes what pooled sequencing changes about an analysis, what PoolSeqFlow assumes your design looks like, and the cases where a different tool is the better answer. If you already know Pool-seq is what you want, skip to [Getting Started](../getting-started/index.md).

## What pooling buys and what it costs

In a pooled library, DNA from many individuals is combined before sequencing. Every read still comes from exactly one chromosome in one individual, but nothing in the data records which. What survives is the **proportion** of reads carrying each allele, which is an estimate of the allele frequency in the pool.

| You gain | You give up |
|---|---|
| Frequency estimates for many individuals at a fraction of the per-individual cost | Individual genotypes — and therefore heterozygosity, relatedness, and anything phased |
| Depth concentrated where it matters: on the frequency estimate, not on calling a genotype confidently | The ability to separate sampling noise from real low-frequency variation without care |
| A design that scales to large populations and many time points | Straightforward variant filtering — the usual genotype-based heuristics do not apply |

The second row is the one that shapes this pipeline. In individual sequencing, a variant seen on two reads out of a hundred is almost certainly an error. In a pool of 50 diploids, one chromosome out of 100 is a real allele at frequency 0.01, and it looks exactly the same. Distinguishing the two is not something a fixed cutoff can do, which is why PoolSeqFlow derives its threshold from your pool size and ploidy rather than hard-coding one. See [The Filter Chain](filter-chain.md).

## What PoolSeqFlow assumes

These are structural assumptions. If your data does not match, the pipeline will either refuse to start or produce something that is not what you meant.

| Assumption | Where it comes from | If you do not match |
|---|---|---|
| Paired-end Illumina reads | `readPattern` matches an `R1`/`R2` pair; step 4 requires properly-paired alignments (`0x2`) | Single-end data will not survive the pairing filter |
| One reference genome for every sample | Variant calling is a single joint `bcftools mpileup` over all BAMs | Samples on different references cannot be run together |
| Every pool has the same size and ploidy | `poolSize` and `diploidy` are single global values feeding one sensitivity threshold | Pools of different sizes share one threshold — see [below](#pools-of-different-sizes) |
| Several comparable pools per run | The false-positive filter keeps a variant only if a **fraction of samples** support it | A single-sample run needs `sampleThreshold` reconsidered — see [below](#single-sample-runs) |
| A gzipped reference FASTA, plus a gzipped GFF if annotating | `referenceFile`, `gffFile` | Uncompressed input must be gzipped first |
| Compute and storage reachable from one process | `mainDir` and `projectDir` may be different filesystems, but both must be mounted | Cloud object storage without a filesystem mount is not supported |

## Where PoolSeqFlow ends

PoolSeqFlow produces **allele frequency tables**. It deliberately stops there. It does not compute F~ST~, run CMH or other tests for allele frequency change, generate `sync`/`mpileup` formats for PoPoolation, call structural variants or copy number, or perform any population-genetic modelling.

That is a scope decision, not an omission: the statistics you want depend entirely on your design, and a per-site frequency table is the input nearly all of them take. Annotation via SnpEff is included because it operates per-variant and needs the same reference build the pipeline already indexed.

## Cases that need a second look

### Pools of different sizes

`poolSize` and `diploidy` are single values for the whole run. They feed one sensitivity threshold:

$$f_{\min} = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}$$

which is the frequency one chromosome would represent. If your pools genuinely differ in size, one threshold is applied to all of them, and it will be too permissive for the small pools or too strict for the large ones.

The safe choice is to set `poolSize` to your **smallest** pool. That makes $f_{\min}$ larger, so the filter is conservative everywhere — you lose real low-frequency variants in the larger pools rather than admitting noise from the smaller ones. If that trade is unacceptable for your question, run the pools in separate projects with their own `parameters.config`.

### Single-sample runs

The false-positive filter is a **cross-sample** consistency check: an allele is kept only if at least `sampleThreshold` (default `0.2`) of the samples show it at or above $f_{\min}$. With one sample, that fraction rounds to a requirement that the one sample support it, so the filter degrades to a plain per-site frequency cutoff. It still works, but it is doing much less than it does on a multi-sample run, and the cross-sample corroboration that justifies a permissive $f_{\min}$ is gone.

### Genuinely private variants

At the default `sampleThreshold = 0.2`, an allele present in only one pool out of eight (12.5% of samples) is **removed**, even at high frequency in that pool. This is the correct default for detecting shared, evolving variation; it is the wrong default if population-private alleles are the point of your study. Lower `sampleThreshold` accordingly, and see [Variant Calling](../configuration/variant-calling.md#samplethreshold) for what that costs you.

### Very high depth

`bcftools.maxDepth` defaults to `2000` and becomes `mpileup -d`, a per-file cap on reads considered at a position. Pooled libraries are often sequenced deeply on purpose, and a cap that bites truncates the read counts the frequencies are computed from. Check your coverage reports from step 5 against this value before trusting the output — details in [Variant Calling](../configuration/variant-calling.md#maxdepth).

## Choosing between run layouts

| If your samples are… | Do this |
|---|---|
| Independent pools you want compared | One run, one row per pool in `RGTags.csv`, distinct `SM` values |
| One pool split across lanes or runs to reach depth | One run, one row per FASTQ pair, **sharing** an `SM` so the reads are combined |
| Technical replicates you want treated as one observation | Share an `SM` |
| Technical replicates you want to compare against each other | Distinct `SM` values |
| Different reference genomes | Separate projects |
| Different pool sizes, and the difference matters | Separate projects |

The `SM` decision is the one most often got wrong by accident, because two FASTQ pairs from one pool look exactly like two ordinary samples. It is covered in full in [Read Groups](../configuration/read-groups.md#sm-decides-what-counts-as-a-sample).
