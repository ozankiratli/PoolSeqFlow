# Pipeline Steps

Each step is an independent module under `scripts/`. This page covers what each one does, what it writes, and what makes it skip itself.

---

## Step 0: Verify Environment {: #step-0-verify-environment }

`scripts/0_verify_environment.nf`

The gate for everything else. It runs sixteen checks and writes `Output/Reports/0_verify_environment.txt`.

### What it checks

| Check | Fails when |
|---|---|
| `SOFTWARE CHECK` | A tool named in `params.software` is not on `PATH` |
| `DATA SOURCE CHECK` | `dataSource` is not set or does not resolve |
| `DATA FOLDER CHECK` | The data directory does not exist |
| `DATA FILES CHECK` | No files match `readPattern` |
| `REFERENCE FILE CHECK` | The gzipped reference is missing |
| `GFF FILE CHECK` | The GFF is missing while `annotate = true` |
| `RGTAGS FILE CHECK` | `RGTags.csv` is missing |
| `RGTAGS LINE ENDING CHECK` | CRLF endings — **repaired in place**, reported as `FIXED` |
| `RGTAGS ID COLUMN CHECK` | No `ID` column in the header |
| `RGTAGS VALID TAGS CHECK` | A column is not a recognised SAM read-group tag |
| `RGTAGS UNIQUE ID CHECK` | An `ID` appears more than once |
| `RGTAGS EMPTY VALUES CHECK` | A required value is blank |
| `RGTAGS SAMPLE MATCH CHECK` | A FASTQ sample has no matching `RGTags.csv` row |
| `RGTAGS CHANGE CHECK` | The file differs from the copy recorded when it was consumed |
| `RUN PARAMETER CHECK` | An analysis-affecting parameter differs from what produced existing outputs |
| `TRIM PARAMETER CHECK` | `autodetect = false` with `adapter1` or `adapter2` unset |

### The two guardrails

`RUN PARAMETER CHECK` and `RGTAGS CHANGE CHECK` are not validation — they are consistency guards, and they exist because of how resume works. Completed steps are skipped by looking for output files, not by checking what produced them, so a changed `poolSize` would leave one `Frequencies/` folder holding tables computed under two different thresholds, invisibly.

| Record | Contents |
|---|---|
| `.poolseqflow_params` | Analysis-affecting parameters, mirrored read-only to `Output/run_parameters.txt` |
| `.poolseqflow_rgtags` | The `RGTags.csv` as consumed; line endings and trailing whitespace ignored |
| `.poolseqflow_versions` | Every pipeline version that has run in this project, with the date. **Recorded, never enforced** |

Path, resource and software parameters are excluded — they change where and how fast work happens, not what the answer is.

When a check trips, the run stops **before any work happens** and the report names the folders to delete. Deleting them is what clears the check. A reordered `RGTags.csv` invalidates less than a changed tag value, and the report distinguishes the two ([table](../configuration/read-groups.md#editing-rgtagscsv-after-a-run)).

Projects whose outputs predate these checks adopt their current state as the baseline.

---

## Step 1: Build Reference Dictionaries

`scripts/1_build_dictionaries.nf`

Decompresses the reference into `Reference/` and builds three index sets, in parallel:

| Sub-step | Produces |
|---|---|
| `CreateBwaIndex` | `Ref.fasta.{amb,ann,bwt,pac,sa}` |
| `CreateSamtoolsFaiIndex` | `Ref.fasta.fai` |
| `BuildSnpEffDb` | `Reference/snpEff/` and `snpEff.config` (only if `annotate = true`) |

The SnpEff database name is derived from the GFF filename — `reference.gff.gz` becomes database `reference.gff`. The build copies the reference and GFF into a SnpEff `data/` layout, generates a minimal config, and verifies that `.bin` files were produced before declaring success. Completion is marked by `.build_complete`, which is what the resume check looks for.

Build options are `-gff3 -noCheckCds -noCheckProtein -v`. The two `-noCheck` flags suppress SnpEff's protein and CDS consistency checks, which fail on many non-model GFFs for reasons that do not affect variant annotation.

---

## Step 2: Trim & QC

`scripts/2_trim_reads.nf`

Two sub-steps.

**`TrimReads`** runs Trim Galore with `--fastqc --paired --retain_unpaired -q 25`, which removes adapters and low-quality 3′ ends and produces a FastQC report on the result.

**`ClipReads`** parses that FastQC report and derives per-sample clip points from the per-base composition table, then applies them with cutadapt and re-runs FastQC on the output.

The clipping algorithm, its failure modes and the one parameter worth tuning are covered in [Trimming & Clipping](../configuration/trimming.md#composition-aware-clipping).

Trimmed reads are deleted once clipping has consumed them. `ClipReads` is the only step configured to retry on failure.

---

## Step 3: Align

`scripts/3_align.nf`

```bash
bwa mem -K 10000000 -T 30 -t <threads> reference R1_clipped R2_clipped \
  | samtools view -b -o <sample>.bam
```

| Option | Parameter | Effect |
|---|---|---|
| `-T 30` | `bwa.minScoreOutput` | Minimum alignment score to report |
| `-K 10000000` | `bwa.batchSize` | Fixed bases per batch — makes output **deterministic** regardless of thread count |

`-K` is worth knowing about. Without it, BWA processes a batch sized by thread count, so the same input aligned with different `threads` can produce slightly different output. Fixing the batch size makes a run reproducible across machines.

Output goes to `Output/Aligned/` as unsorted BAM.

---

## Step 4: Clean BAM Files

`scripts/4_clean.nf`

A single streamed pipeline of seven operations: name-sort, fixmate, coordinate-sort, mark and remove duplicates, add read groups, filter, index. The `@RG` string is assembled per sample from `RGTags.csv`, skipping empty fields.

Full detail, including why duplicates are removed rather than marked and what the MAPQ floor costs you: [Alignment Filters](../configuration/filters.md).

Output: `Output/Ready/<sample>_ready.bam` and `.bai`.

---

## Step 5: Generate Reports

`scripts/5_reports.nf`

Two independent sub-steps per sample:

| Sub-step | Command | Output |
|---|---|---|
| `AlignmentReport` | `bamtools stats` | `Output/Reports/Alignment/<sample>_alignment_report.txt` |
| `CoverageReport` | `samtools coverage` | `Output/Reports/Coverage/<sample>_coverage_report.txt` |

The coverage report is the one to read on every run: it is how you find out whether `bcftools.maxDepth` truncated your pileup ([why that matters](../configuration/variant-calling.md#maxdepth)).

---

## Step 6: Variant Calling

`scripts/6_variant_call.nf`

```bash
bcftools mpileup -B -C 50 -q 30 -Q 30 -d 2000 -a AD,DP,SP,INFO/AD -Ou -f reference <all BAMs> \
  | bcftools call -m -A -v -Ov -o <name>.vcf
```

One joint task over every BAM, producing a multi-sample VCF with `AD` and `DP` FORMAT fields. Every flag and its consequence: [Variant Calling](../configuration/variant-calling.md).

**The BAMs are sorted before being handed to bcftools**, in `RGTags.csv` row order. bcftools orders VCF columns by command-line order, so without this the column order would follow task-completion order — three consecutive runs on identical input gave three different orders.

A header fix is applied afterwards: `INFO/MQ` is declared `Integer` by bcftools but can carry a float, so the declaration is rewritten to `Float`. Without it, strict VCF parsers reject the file.

---

## Step 7: VCF → Allele Frequency Tables

`scripts/7_vcf2freq.nf`

Five sub-steps in a serial chain, each deleting its input once its output is safe:

| # | Sub-step | Does |
|---|---|---|
| 1 | `SortRefAltByFrequency` | Re-encodes so the most-read allele is `REF`; recomputes `DP` from `AD`; sets `GT` to `./.` |
| 2 | `FilterPotentialFalsePositives` | Splits multiallelics, applies the cross-sample support test, rejoins, re-normalises |
| 3 | `DepthAndQualityFilter` | `bcftools view -e "FMT/DP<20"` then `vcftools --minQ 30` |
| 4 | `SplitSNPsAndINDELs` | Two vcftools passes into a SNP VCF and an INDEL VCF |
| 5 | `CalculateFrequencies` | Extracts `AD` and divides to frequencies; runs once per split file |

Sub-step 2 is the pool-aware core of the pipeline and is documented in full in [The Filter Chain](../concepts/filter-chain.md#5-false-positive-filter-step-7). The minimum credible frequency it enforces is

$$f_{\min} = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}$$

but the test is not a plain cutoff — an allele must reach that frequency in a *fraction of samples*, which is what lets the threshold sit so low.

Output: `Output/Frequencies/<name>_snp_freq.tsv` and `<name>_indel_freq.tsv`. Format: [Interpreting Results](../concepts/interpreting-results.md#the-frequency-tables).

---

## Step 8: Annotate Variants {: #step-8-annotate-variants }

`scripts/8_annotate_variants.nf` — optional, controlled by `annotate`.

```bash
bcftools norm -m - <name>.vcf | snpEff -v -stats snpeff_summary.html <db>
```

Splits multiallelic sites onto separate lines — SnpEff annotates one alternate allele per record — and annotates against the database built in step 1.

!!! warning "This runs on the raw call set"

    Step 8 takes step **6**'s output, not step 7's. It runs in parallel with the frequency branch, so `<name>_annotated.vcf` contains sites the step 7 filters removed, encoded against the original reference rather than the major allele. To attach annotations to your frequency tables, join on `CHROM`/`POS` and expect unmatched rows on the annotation side.

Output: `Output/VCF/<name>_annotated.vcf` and `Output/Reports/snpeff_summary.html`.

Setting `annotate = false` skips this step and makes `gffFile` unnecessary — step 1 also stops building the SnpEff database.
