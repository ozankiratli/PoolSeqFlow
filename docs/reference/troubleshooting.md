# Troubleshooting

## Installation and environment

| Problem | Cause and fix |
|---|---|
| Environment creation fails | `conda update -n base conda`, then retry `./PoolSeqFlow install` |
| Missing dependencies after install | Activate it: `conda activate PoolSeqFlow` |
| A tool is found but misbehaves | Check whether `params.software.*` points at a system binary rather than the environment's — version mismatches are not detected |

## The run will not start

### `null: command not found`

```text
.command.sh: line 17: null: command not found
```

Your `parameters.config` predates the installed version. An absent parameter interpolates as the literal string `null`, which is why the error names nothing useful and points at a generated script. Rebuild the file — see [Upgrading](../getting-started/upgrading.md).

### `Process requirement exceeds available CPUs`

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

`threads` is larger than the machine. Tasks reserve what they really use, so an oversized request fails at submission rather than quietly oversubscribing. Set `threads` to the cores you have. [Resources →](../configuration/resources.md)

### Step 0 reports a parameter or RGTags change

Working as designed. An analysis-affecting parameter, or `RGTags.csv`, differs from what produced your existing outputs. Because completed steps are skipped by looking for output files, continuing would mix results from two configurations in one folder.

The report names the folders to delete; deleting them clears the check. Or `./PoolSeqFlow reset` to discard everything. [Why →](../concepts/design-decisions.md#the-run-refuses-to-mix-settings)

### `RGTAGS UNIQUE ID CHECK` fails

An `ID` appears more than once. A row is looked up by `ID` and only the first match is read, so the duplicate would have silently given a sample the wrong read-group tags — producing a valid BAM that nothing downstream could flag.

### `Invalid tag 'PU'`, or `RGTAGS LINE ENDING CHECK: FIXED`

`RGTags.csv` was saved with Windows line endings, putting a carriage return in the last tag of every row. Step 0 repairs it in place and reports `FIXED`. If it cannot rewrite the file, it stops and prints the command to run.

## Failures during the run

### `no usable clip range`

```text
CLIPPING READS <sample>: ERROR: no usable clip range in <file>
CLIPPING READS <sample>: exit 3 = unexpected FastQC header; 4 = no cycle within at_gc_error (0.025)
```

Exit **4** means no read cycle had A/T and G/C ratios inside `at_gc_error`. On a GC-skewed genome this is expected, not a fault — raise `at_gc_error`.

Exit **3** means the FastQC per-base composition table did not have the expected `A`/`T`/`G`/`C` columns, which points at a FastQC version change or a corrupt report.

[Trimming & Clipping →](../configuration/trimming.md#when-it-refuses-to-run)

### Symbolic link errors

Confirm you are on Linux or macOS. Windows — including WSL under some filesystem configurations — is not supported. Also check that `projectDir` is still mounted and was not cleared while the run was in flight.

### A step fails and I cannot tell why

`.nextflow.log` names the failing process. Each step also mirrors its own `.command.log` and `.command.err` into `Logs/<step>/`, which is usually more readable.

For a reproducible failure, set `threads = 1`. That removes concurrency as a variable and makes the logs sequential.

## Results are not what I expected

### Fewer sample columns than samples

Rows in `RGTags.csv` sharing an `SM` are merged into one VCF column and their depths add together. Eight FASTQ pairs with four distinct `SM` values give four columns — usually intentional, occasionally not. [Read Groups →](../configuration/read-groups.md#sm-decides-what-counts-as-a-sample)

### Sample columns in an unexpected order

Column order follows `RGTags.csv` **row order**. Where rows share an `SM`, the merged column takes the position of the first of them. [Read Groups →](../configuration/read-groups.md#row-order-decides-column-order)

### `REF` does not match my reference genome

Correct. Step 7 re-encodes each site so the most-read allele across the whole cohort becomes `REF`, which is what makes frequencies comparable across samples and runs. If you need the assembly's base, take it from the assembly. [Why →](../concepts/filter-chain.md#4-major-allele-normalisation-step-7)

### A variant I know is real is missing

Work outward through the chain — a read lost at alignment cannot be recovered later.

| Check | Parameter |
|---|---|
| Was it filtered at alignment? | `samtools.mapq` (30 is strict), `samtools.filter` |
| Was the pileup truncated? | `bcftools.maxDepth` vs your coverage reports |
| Was it seen in too few pools? | `filterFalsePositives.sampleThreshold` — the default discards alleles found in one pool out of eight |
| Below the frequency floor? | `poolSize`, `diploidy` |
| Site removed on quality? | `vcffilter.minQUAL` |

[The Filter Chain →](../concepts/filter-chain.md#tuning-the-chain)

### Much less depth than I sequenced for

Two usual causes, in order of likelihood:

1. **MAPQ filtering.** At `samtools.mapq = 30`, repetitive genomes lose a lot. Compare read counts in `Output/Aligned/` and `Output/Ready/`.
2. **Duplicate removal.** The step 4 log carries `markdup -s` statistics; a high duplicate rate is a library-prep problem, not a pipeline one.

### Depth plateaus at a round number

`bcftools.maxDepth`, default 2000, caps reads considered per file per position. Deep pooled libraries exceed it, and the truncation biases every frequency at those positions. [maxDepth →](../configuration/variant-calling.md#maxdepth)

### Genotype-based tools find nothing in my VCFs

`FORMAT/GT` is set to `./.` throughout, deliberately — a pool has no genotype, and leaving bcftools' diploid call in place would invite tools to read it as one. Use `AD` and `DP`.

### Annotated VCF contains sites missing from my frequency tables

Step 8 runs on step **6**'s output, in parallel with the frequency branch, so it never sees the step 7 filters. Its allele encoding is also the original reference-based one, not the major-allele normalised one. Join on `CHROM`/`POS` and expect unmatched rows. [Details →](../concepts/interpreting-results.md#the-vcf-files)

## Resume behaviour

### A re-run skips too many steps

Steps skip themselves when their outputs exist in `projectDir`. Delete the stale outputs, or `./PoolSeqFlow reset` to start over.

### A re-run submits every job anyway

Expected. Step-skipping happens inside each task rather than before it, so a fully resumed run still submits roughly one short job per process per sample. [Resume Logic →](../pipeline/resume.md)

### `-resume` appears to do nothing

Correct — PoolSeqFlow does not use Nextflow's `-resume`, and the wrapper never passes it. `./PoolSeqFlow run` already resumes. [Resume Logic →](../pipeline/resume.md)

### A step reruns after an interrupted job

If the interruption hit a cross-filesystem move, the partial file was left as `.part` rather than under its final name, so the step correctly runs again. That is the atomic move working.

## Getting help

Include the failing step, the relevant `Logs/` excerpt and your `parameters.config` with paths redacted when opening an issue: [github.com/ozankiratli/PoolSeqFlow/issues](https://github.com/ozankiratli/PoolSeqFlow/issues)
