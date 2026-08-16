# The Filter Chain

A read that makes it into a frequency table has passed eight separate filters spread across four steps. This page walks the whole chain in order: what each filter removes, which parameter controls it, and what you are trading when you move that parameter.

If you are trying to work out why a variant you expected is missing, read this page top to bottom — the answer is usually earlier in the chain than people look.

## The chain at a glance

| # | Stage | Operates on | Removes | Parameter |
|---|---|---|---|---|
| 1 | Alignment filter | Reads | Unmapped, non-paired, duplicate, secondary, supplementary, low-MAPQ reads | `samtools.filter`, `samtools.required`, `samtools.mapq` |
| 2 | Pileup filter | Reads at a position | Low mapping quality, low base quality; caps depth | `bcftools.baseQualMin`, `bcftools.varQualMin`, `bcftools.maxDepth` |
| 3 | Variant calling | Sites | Non-variant sites | `bcftools.callOptions` |
| 4 | Major-allele normalisation | Allele order | Nothing — it rewrites | — |
| 5 | False-positive filter | Alternate alleles | Alleles without cross-sample support | `poolSize`, `diploidy`, `filterFalsePositives.sampleThreshold` |
| 6 | Depth & quality filter | Sites | Sites where any sample is under-covered, and low-QUAL sites | `vcffilter.minDP`, `vcffilter.minQUAL` |
| 7 | SNP/INDEL split | Sites | Splits into two files; nothing is lost | — |
| 8 | Frequency conversion | — | Nothing | — |

Stages 1–3 happen in [steps 4 and 6](../pipeline/steps.md); stages 4–8 are the five sub-steps of step 7.

---

## 1. Alignment filter (step 4)

The last stage of BAM cleanup is a `samtools view` with three conditions:

```bash
samtools view -F 0xF0C -f 0x2 -q 30 -b
```

| Flag | Source | Effect |
|---|---|---|
| `-F 0xF0C` | `samtools.filter` | **Excludes** unmapped, mate-unmapped, secondary, QC-fail, duplicate and supplementary reads |
| `-f 0x2` | `samtools.required` | **Requires** the read to be properly paired |
| `-q 30` | `samtools.mapq` | **Excludes** reads with mapping quality below 30 |

The MAPQ floor is easy to miss because it is not part of either flag word. At `30` it is a strict filter — it discards reads that map ambiguously, which in a repetitive genome can be a substantial fraction. That is usually the right call for Pool-seq, because an ambiguously placed read contributes a read count to the wrong position and frequencies are read counts. But if your coverage reports from step 5 show much less depth than you sequenced for, this is the first place to look.

Duplicate removal happens just upstream (`samtools markdup -r`) and matters more here than in individual sequencing: a PCR duplicate is a second vote from a molecule that should only vote once, and in a frequency estimate every vote counts directly.

Full flag reference: [Alignment Filters](../configuration/filters.md).

## 2. Pileup filter (step 6)

```bash
bcftools mpileup -B -C 50 -q 30 -Q 30 -d 2000 -a AD,DP,SP,INFO/AD -Ou
```

| Flag | Parameter | Effect |
|---|---|---|
| `-q 30` | `bcftools.varQualMin` | Minimum **mapping** quality for a read to be counted |
| `-Q 30` | `bcftools.baseQualMin` | Minimum **base** quality for a base to be counted |
| `-C 50` | `bcftools.scaleMapQ` | Downgrades mapping quality for reads with excessive mismatches |
| `-d 2000` | `bcftools.maxDepth` | Caps reads considered per file per position |
| `-B` | fixed | Disables BAQ (base alignment quality) recalculation |
| `-a AD,DP,SP,INFO/AD` | fixed | Emits the allelic-depth fields everything downstream depends on |

`-d 2000` deserves attention on a pooled run. It is a per-file cap, and deep pooled libraries can exceed it. When they do, the read counts the frequencies are computed from are truncated, which biases estimates in a way nothing downstream will flag. Compare it against your step 5 coverage reports — see [maxDepth](../configuration/variant-calling.md#maxdepth).

`-B` is a deliberate choice for pooled data. BAQ downweights bases near indels to suppress false positives that arise from misalignment in a single diploid genome. In a pool, the same signal may be a genuine low-frequency indel, and BAQ's correction assumes a genotype model that does not apply. Disabling it keeps the raw evidence and leaves the decision to the cross-sample filter at stage 5.

## 3. Variant calling (step 6)

```bash
bcftools call -m -A -v -Ov
```

| Flag | Effect | Why it matters here |
|---|---|---|
| `-m` | Multiallelic caller | Handles sites with more than one alternate allele, which biallelic-only calling would collapse |
| `-A` | Keep **all** alternate alleles from the pileup | Without this, bcftools discards alternates it considers unlikely under a genotype model — exactly the low-frequency alleles a pool is meant to detect |
| `-v` | Variant sites only | Invariant sites are dropped |

`-A` is the flag that makes this a Pool-seq caller rather than a general one. The default behaviour prunes alternate alleles that no plausible genotype supports, which is sound for an individual and wrong for a pool, where a true allele at frequency 0.01 supports no genotype at all.

## 4. Major-allele normalisation (step 7)

`bin/MajorAlleleToRef.py` re-encodes the VCF so the **most-read allele is the reference**. It does not remove anything; it rewrites.

For each site it sorts the alleles by `INFO/AD` — the read count summed across every sample — and reorders `REF`, `ALT`, `INFO/AD`, `INFO/DP`, `FORMAT/AD` and `FORMAT/DP` to match. `DP` is recomputed as the sum of the reordered `AD`, so depth and allelic depth cannot disagree.

**Why do it at all.** The reference genome is one individual's assembly. There is no reason its allele should be the common one in your population, and when it is not, every frequency in that row is reported against a rare baseline. Two studies on the same species then report mirror-image frequencies for the same site. Normalising to the major allele makes rows comparable across samples, across runs and across projects.

**Two consequences worth knowing.**

The ordering is **cohort-wide**, not per-sample. `REF` is the allele most read across all samples combined. In an individual sample where the cohort-minor allele is locally dominant, that sample's frequency for `REF` will be below 0.5 — which is meaningful, not an error.

`FORMAT/GT` is set to `./.` on every genotype. A pool has no genotype, and leaving bcftools' diploid call in place would invite downstream tools to read it as one. Making it explicitly missing is the honest encoding. Keep it in mind if you point a genotype-based tool at these VCFs: it will find nothing, by design.

The script runs **twice** — once before the false-positive filter and again after it, because splitting and rejoining multiallelic records can change allele order.

## 5. False-positive filter (step 7)

This is the filter that makes the pipeline pool-aware, and the one most worth understanding before you change anything.

```bash
bcftools norm -m -  vcf                    # 1. split multiallelic sites into one line per ALT
| bcftools view -i "INFO/AD[1]>0 && COUNT(FORMAT/AD[:1]/FORMAT/DP[:] >= S) >= M"
| sed  '*' → 'X'                           # 2. mask the spanning-deletion allele
| bcftools norm -m+                        # 3. rejoin into multiallelic records
| sed  'X' → '*'
```

### What the expression says

An alternate allele is kept only if **both** hold:

`INFO/AD[1] > 0`
: The allele has at least one supporting read somewhere in the cohort.

`COUNT(FORMAT/AD[:1] / FORMAT/DP[:] >= S) >= M`
: At least `M` samples show that allele at a frequency of `S` or more.

where

$$S = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}
\qquad
M = n_{\text{samples}} \times \text{sampleThreshold}$$

This is a **cross-sample corroboration** filter, not a frequency cutoff. A site is not kept because it is frequent; it is kept because several independent pools saw it. That distinction is what allows `S` to be set very low without drowning in sequencing error: errors are random and do not recur in the same place across libraries, whereas real low-frequency variants do.

### Where S comes from

A pool of `poolSize` individuals at ploidy `diploidy` contains $\text{diploidy} \times \text{poolSize}$ chromosomes, so a single chromosome carries a frequency of $1 / (\text{diploidy} \times \text{poolSize})$. The extra factor of two puts `S` at **half** that — a true singleton clears the threshold with margin rather than sitting exactly on it, which matters because the observed fraction of a singleton is itself noisy.

| `poolSize` | `diploidy` | One chromosome is | `S` (threshold) |
|---|---|---|---|
| 10 | 2 | 0.0500 | 0.0250 |
| 25 | 2 | 0.0200 | 0.0100 |
| 50 | 2 | 0.0100 | 0.0050 |
| 100 | 2 | 0.0050 | 0.0025 |
| 200 | 2 | 0.0025 | 0.00125 |

Larger pools give a smaller `S`, so the filter admits rarer alleles — appropriately, since a larger pool really can contain rarer ones.

### Where M comes from

`M` is a count of samples, computed as a fraction of however many are in the VCF. It is compared with `>=` against a non-integer value, so the effective requirement is the next whole number up:

| Samples in run | `M` at `sampleThreshold = 0.2` | Samples that must support the allele |
|---|---|---|
| 1 | 0.2 | 1 |
| 4 | 0.8 | 1 |
| 5 | 1.0 | 1 |
| 6 | 1.2 | 2 |
| 8 | 1.6 | 2 |
| 10 | 2.0 | 2 |
| 12 | 2.4 | 3 |
| 20 | 4.0 | 4 |

!!! danger "This filter removes population-private alleles"

    At the default, an allele found in only one pool out of eight is discarded no matter how frequent it is in that pool — one sample does not reach the two the threshold requires. If private variation is what you are studying, lower `sampleThreshold` before your first run, not after. See [sampleThreshold](../configuration/variant-calling.md#samplethreshold).

### Why the splitting and rejoining

`FORMAT/AD[:1]` indexes the **first** alternate allele. On a multiallelic record, a rare third allele would never be tested — it would simply ride along on whatever the second allele did. Splitting to one line per alternate (`norm -m -`) makes each allele stand on its own evidence; `norm -m+` puts the survivors back together.

The `*` → `X` substitution around the rejoin masks the spanning-deletion allele, which `norm -m+` does not handle in this position. It is restored immediately afterwards.

## 6. Depth and quality filter (step 7)

Two commands, both operating on whole sites:

```bash
bcftools view -e "FMT/DP<20" -Ov -o <name>_dp.vcf <input>
vcftools --vcf <name>_dp.vcf --minQ 30 --recode --recode-INFO-all --out <name>_dq
```

`bcftools view -e "FMT/DP<20"` (`vcffilter.minDP`)
: Removes a site if **any** sample falls below the depth. A site survives only when every sample meets the floor, so **the weakest library sets the threshold for the whole cohort** — one under-sequenced pool removes sites for all of them.

`vcftools --minQ 30` (`vcffilter.minQUAL`)
: Removes sites whose `QUAL` falls below 30.

The depth test has to be site-level rather than per-sample. Both vcftools and bcftools express a genotype-level verdict by rewriting `FORMAT/GT` and nothing else — `AD` and `DP` survive untouched — and stage 8 reads `AD`. Stage 4 has already set every `GT` to `./.` besides, so a genotype filter would have nothing left to mark.

Alternative expressions, what each trades, and how to pick a value: [Depth and quality](../configuration/variant-calling.md#depth-and-quality).

## 7. SNP/INDEL split (step 7)

Two `vcftools` passes over the same input — `--remove-indels` and `--keep-only-indels` — produce a SNP VCF and an INDEL VCF. Nothing is discarded; every surviving site lands in exactly one of the two files, and each is converted to its own frequency table.

## 8. Frequency conversion (step 7)

No filtering. `bin/createDepthFile.sh` extracts `CHROM`, `POS`, `REF`, `ALT`, `INFO/AD` and per-sample `FORMAT/AD`, and `bin/depth2freq.awk` divides each allele's read count by the row's total to give a frequency. The output format is described in [Interpreting Results](interpreting-results.md).

---

## Tuning the chain

Work from the outside in. A variant lost at stage 1 cannot be recovered by loosening stage 5.

| Symptom | Most likely stage | Parameter to examine |
|---|---|---|
| Far less depth than sequenced | 1 | `samtools.mapq`, then duplicate rate in the step 5 reports |
| Depth plateaus at a round number | 2 | `bcftools.maxDepth` |
| Low-frequency alleles absent everywhere | 5 | `poolSize`, `diploidy` |
| Alleles present in one pool only, absent from output | 5 | `filterFalsePositives.sampleThreshold` |
| Whole sites missing despite good depth | 6 | `vcffilter.minQUAL` |
| Almost every site gone after filtering | 6 | `vcffilter.minDP` — one under-covered sample removes sites for all of them |
| Multiallelic sites reduced to two alleles | 3 | `bcftools.callOptions` — confirm `-A` is still present |

Changing any of these invalidates existing outputs, and step 0 will stop the next run rather than mix results. That is covered in [Design Decisions](design-decisions.md#the-run-refuses-to-mix-settings).
