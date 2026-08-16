# Interpreting Results

The pipeline's product is a pair of tab-separated allele frequency tables. This page describes their format precisely, works through an example, and covers the mistakes that are easy to make when reading them.

## The frequency tables

Two files are written to `Output/Frequencies/`, named after `vcf.fileName`:

| File | Contents |
|---|---|
| `<name>_snp_freq.tsv` | Every surviving SNP site |
| `<name>_indel_freq.tsv` | Every surviving insertion or deletion site |

With the default `vcf.fileName = 'Test'` those are `Test_snp_freq.tsv` and `Test_indel_freq.tsv`.

### Columns

```text
CHROM   POS   REF   ALLELE   TOTAL_AD   <sample 1>   <sample 2>   …
```

| Column | Contents |
|---|---|
| `CHROM` | Reference sequence name |
| `POS` | 1-based position |
| `REF` | The reference allele **for the site**, repeated on every row of that site |
| `ALLELE` | The allele this row reports on |
| `TOTAL_AD` | Frequency of `ALLELE` across **all samples combined** |
| *sample columns* | Frequency of `ALLELE` in that sample |

Sample columns appear in `RGTags.csv` row order — see [Row order decides column order](../configuration/read-groups.md#row-order-decides-column-order).

### One row per allele

This is the part that surprises people. A site does not occupy one row; it occupies **one row per allele, including the reference allele.** A biallelic SNP produces two rows, a triallelic site three.

`REF` is constant within a site and `ALLELE` varies. The reference row is the one where the two are equal.

### The header says `TOTAL_AD`, the column holds a frequency

The fifth column is derived from `INFO/AD`, the cohort-wide allelic depth, and the conversion divides it by the row total exactly as it does for the sample columns. The header label is carried over from the intermediate depth file and was not renamed. Read it as *overall frequency*, not as a depth.

### Worked example

Take a triallelic site with two samples:

```text
CHROM  POS   REF  ALT    INFO/AD        sample1 AD    sample2 AD
chr1   1000  A    G,T    800,150,50     400,100,0     400,50,50
```

Cohort total is 800 + 150 + 50 = 1000. Sample 1 totals 500, sample 2 totals 500. The table contains:

```text
CHROM  POS   REF  ALLELE  TOTAL_AD  sample1  sample2
chr1   1000  A    A       0.8       0.8      0.8
chr1   1000  A    G       0.15      0.2      0.1
chr1   1000  A    T       0.05      0        0.1
```

Every column within one site sums to 1. A zero means the allele was not observed in that sample, not that the site was missing there.

## Reading the tables correctly

**`REF` is the major allele, not the reference genome's base.** Step 7 re-encodes each site so the most-read allele becomes `REF` ([why](filter-chain.md#4-major-allele-normalisation-step-7)). This makes rows comparable across samples and runs, but it means `REF` will often disagree with the FASTA you supplied. If you need the assembly's base, take it from the assembly.

**"Most-read" is decided across the whole cohort.** A sample where the cohort-minor allele dominates locally will show a `REF` frequency below 0.5. That is a real signal, not a defect.

**A missing row means the variant did not survive the chain, not that it is absent.** Sites are removed at eight points between the FASTQ and the table. Before concluding a variant is absent from your population, check it against [The Filter Chain](filter-chain.md#tuning-the-chain) — in particular the cross-sample requirement at stage 5, which discards alleles seen in too few pools regardless of how frequent they are in those pools.

**Frequencies are read proportions, not estimates with error bars.** The table reports the fraction of reads carrying each allele. Sampling error in that fraction depends on depth at the position and on the pool size, and the pipeline does not propagate it. If your analysis needs uncertainty, compute it from the depth — which is why the VCFs retain `AD` and `DP`.

**There is no genotype to read.** `FORMAT/GT` is `./.` throughout, deliberately. Genotype-based tools pointed at these VCFs will find nothing.

## The VCF files

`Output/VCF/` holds the call sets. After a complete run:

| File | What it is |
|---|---|
| `<name>.vcf` | Raw output of step 6 — every called site, no step 7 filtering, original reference encoding |
| `<name>_sort_fp_dq.vcf` | Fully filtered and major-allele normalised, before the SNP/INDEL split |
| `<name>_annotated.vcf` | SnpEff annotation of the **raw** call set, if `annotate = true` |

The per-stage intermediates (`_sort`, `_sort_fp`, and the split `_snp`/`_indel` files) are deleted once consumed — see [Steps delete their own inputs](design-decisions.md#steps-delete-their-own-inputs).

!!! note "Annotation is applied to the unfiltered call set"

    Step 8 runs on the output of step 6, in parallel with the frequency branch rather than after it. So `<name>_annotated.vcf` contains sites that the step 7 filters removed, and its allele encoding is the original reference-based one, not the major-allele normalised one. To attach annotations to your frequency tables, join on `CHROM`/`POS` and expect unmatched rows on the annotation side.

## The reports

`Output/Reports/` collects everything generated along the way.

| Path | Produced by | Useful for |
|---|---|---|
| `Alignment/<sample>_alignment_report.txt` | `bamtools stats` | Mapping rate, duplicate rate, paired-end statistics |
| `Coverage/<sample>_coverage_report.txt` | `samtools coverage` | Per-contig depth and breadth — **check this against `bcftools.maxDepth`** |
| `Fastqc/<sample>/` | FastQC | Raw, trimmed and clipped read quality |
| `Trimming/<sample>/` | Trim Galore | How much was removed, and which adapter was detected |
| `snpeff_summary.html` | SnpEff | Variant effect summary, if annotation ran |
| `PoolSeqFlow_pipeline_report.html` | Nextflow | Per-task resource usage |
| `PoolSeqFlow_pipeline_timeline.html` | Nextflow | Where wall-clock time went |
| `PoolSeqFlow_pipeline_trace.txt` | Nextflow | Machine-readable task trace |
| `PoolSeqFlow_pipeline_dag.html` | Nextflow | Workflow graph |
| `run_parameters.txt` | Step 0 | Read-only record of the analysis parameters these outputs were built from |

The two worth reading on every run are the coverage report and `run_parameters.txt` — the first tells you whether the depth cap bit, the second tells you exactly what settings produced the files sitting next to it.

## A quick sanity pass

After a run finishes, four checks catch most problems:

1. **Sample columns.** Does the table have the number of columns you expect, in the order you laid out in `RGTags.csv`? A count lower than expected means samples were merged by a shared `SM` ([why](../configuration/read-groups.md#sm-decides-what-counts-as-a-sample)).
2. **Coverage against the cap.** If `samtools coverage` reports mean depth near `bcftools.maxDepth` (default 2000), the pileup was truncated and frequencies are biased.
3. **Row counts.** Compare the site count in `<name>.vcf` with `<name>_sort_fp_dq.vcf`. A very large drop points at the cross-sample filter; check `sampleThreshold` against your sample count in [the table above](filter-chain.md#where-m-comes-from).
4. **Column sums.** Frequencies within a site should sum to 1 in every column.
