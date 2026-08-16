# Variant Calling

These are the parameters that decide which variants exist in your output and at what frequency. Every one of them is analysis-affecting: change one and step 0 will stop the next run rather than let old and new results share a folder.

For how these fit together end to end, read [The Filter Chain](../concepts/filter-chain.md).

## `poolSize` and `diploidy`

```groovy
poolSize = 50    // individuals in one pool
diploidy = 2     // ploidy of the organism
```

These two are the pipeline's most consequential settings. They are not used to model anything — they set the **minimum credible allele frequency**:

$$S = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}$$

An alternate allele must reach `S` in a sample for that sample to count as supporting it.

**`poolSize` is per pool, not per run.** With eight pools of 50 individuals each, it is `50`, not `400`.

**The factor of two is deliberate.** A pool of 50 diploids holds 100 chromosomes, so one chromosome is frequency 0.01. `S` comes out at 0.005 — half of that — so a genuine singleton clears the threshold with margin rather than sitting exactly on it. The observed fraction of a singleton is itself noisy, and a threshold placed exactly at the expected value would reject half of them.

| `poolSize` | `diploidy` | One chromosome is | `S` |
|---|---|---|---|
| 10 | 2 | 0.0500 | 0.0250 |
| 25 | 2 | 0.0200 | 0.0100 |
| 50 | 2 | 0.0100 | 0.0050 |
| 100 | 2 | 0.0050 | 0.0025 |
| 200 | 2 | 0.0025 | 0.00125 |
| 50 | 1 | 0.0200 | 0.0100 |
| 50 | 4 | 0.0050 | 0.0025 |

**If your pools differ in size**, set `poolSize` to the smallest. That makes `S` larger and the filter conservative everywhere — you lose real low-frequency variants in the bigger pools rather than admitting noise from the smaller ones. If that trade does not suit your question, run the pools as separate projects.

!!! note "A stale formula in the helper's usage text"

    `bin/filterFalsePositives.sh -h` prints `s = 1 / 2 * ([DIPLOIDY] / [POOLSIZE per SAMPLE])`, which is not the formula the pipeline uses. The value actually passed is computed in `parameters.config` as `1.0 / (2 * diploidy * poolSize)`. Trust the config, not the usage string.

## `sampleThreshold`

```groovy
filterFalsePositives {
    sampleThreshold = 0.2
}
```

The fraction of samples that must independently support an allele at frequency `S` or above for it to be kept. This is what makes the filter a **corroboration** test rather than a frequency cutoff, and it is what allows `S` to be set so low without drowning in sequencing error: errors do not recur at the same position across independent libraries.

The comparison is `count >= n_samples × sampleThreshold`, so the effective requirement is the next whole number up:

| Samples | `M` at 0.2 | Must support |
|---|---|---|
| 1 | 0.2 | 1 |
| 4 | 0.8 | 1 |
| 5 | 1.0 | 1 |
| 6 | 1.2 | 2 |
| 8 | 1.6 | 2 |
| 10 | 2.0 | 2 |
| 12 | 2.4 | 3 |
| 20 | 4.0 | 4 |

!!! danger "The default removes population-private alleles"

    With eight samples, an allele found in **one** pool is discarded regardless of how frequent it is there — one does not reach two. If private or population-specific variation is the subject of your study, this default is wrong for you.

| Value | Behaviour | Suits |
|---|---|---|
| `0.2` (default) | Needs roughly a fifth of samples | Shared, evolving variation across comparable pools |
| Low enough to require 1 sample | Any single pool can carry an allele | Private variants, small sample counts, discovery runs |
| Higher, e.g. `0.5` | Needs half the samples | Conservative core-variant sets; high-noise data |

Remember that the denominator is the number of **VCF columns**, which is the number of distinct `SM` values — not the number of FASTQ pairs. Merging replicates via `SM` changes this threshold as a side effect ([see Read Groups](read-groups.md#sm-decides-what-counts-as-a-sample)).

## Pileup settings

```groovy
bcftools {
    scaleMapQ   = 50     // -C  downgrade coefficient for mismatch-heavy reads
    varQualMin  = 30     // -q  minimum mapping quality
    baseQualMin = 30     // -Q  minimum base quality
    maxDepth    = 2000   // -d  per-file depth cap
}
```

`-C 50` (`scaleMapQ`)
: Downgrades mapping quality for reads carrying excessive mismatches. Reads that align poorly are more likely to be misplaced, and a misplaced read contributes its bases to the wrong position — which in a frequency estimate is a direct error, not just noise.

`-B` (fixed, not configurable)
: Disables BAQ recalculation. BAQ downweights bases near indels to suppress misalignment artefacts under a single-genome model. In a pool, the same signal may be a genuine low-frequency indel, so the raw evidence is kept and the decision is left to the cross-sample filter.

### `maxDepth`

`-d 2000` caps the reads considered **per file per position**. This is the parameter most likely to bite a Pool-seq run without announcing itself.

Pooled libraries are often sequenced deeply on purpose — depth is what buys frequency resolution. When depth exceeds the cap, the pileup stops counting, and the read counts your frequencies are computed from are truncated. Nothing downstream flags this.

**Check it against your data.** After a run, look at `Output/Reports/Coverage/`:

```bash
grep -H . Output/Reports/Coverage/*_coverage_report.txt | head
```

If mean depth approaches or exceeds 2000 anywhere you care about, raise `maxDepth` above your highest expected per-sample depth. There is a memory and runtime cost to a higher cap, but a truncated pileup is a biased result.

## Calling

```groovy
callOptions = "-m -A -v -Ov"
```

| Flag | Effect |
|---|---|
| `-m` | Multiallelic caller — required for sites with more than one alternate allele |
| `-A` | Keep **all** alternate alleles from the pileup |
| `-v` | Output variant sites only |
| `-Ov` | Uncompressed VCF |

**`-A` is what makes this a Pool-seq caller.** Without it, bcftools prunes alternate alleles that no plausible genotype supports — sound for an individual, and wrong for a pool, where a true allele at frequency 0.01 supports no genotype at all. If you edit `callOptions`, keep `-A` and `-m`.

Variant calling is a **single joint task** over all BAMs, not one task per sample. That is what produces a multi-sample VCF with comparable columns, and it is why every sample must share a reference.

## Depth and quality

```groovy
vcffilter {
    minDP   = 20
    minQUAL = 30
}
```

Both are **site**-level filters, applied as two commands in sequence:

```bash
bcftools view -e "FMT/DP<20" -Ov -o <name>_dp.vcf <input>
vcftools --vcf <name>_dp.vcf --minQ 30 --recode --recode-INFO-all --out <name>_dq
```

`minDP` → `bcftools view -e "FMT/DP<N"`
: Removes a site if **any** sample falls below the depth. Read the negation carefully: the site survives only when *every* sample meets the floor.

`minQUAL` → `vcftools --minQ`
: Removes sites whose `QUAL` falls below the value.

!!! danger "The weakest library sets the threshold for every site"

    Because the test is "any sample below `minDP`", one under-sequenced pool removes sites for all of them. Three pools at depths 50/15/55, 60/12/28 and 10/12/20, with `minDP = 20`:

    ```text
    minDP = 20  ->  0 of 3 sites kept   (poolB is 15/12/12, so it fails everywhere)
    minDP = 12  ->  2 of 3 sites kept
    ```

    Check `Output/Reports/Coverage/` for your weakest sample before choosing a value, and compare site counts between `<name>.vcf` and `<name>_sort_fp_dq.vcf` after the first run. A near-total wipeout is this filter, not a broken pipeline.

If "every sample" is too strict for your design, the alternatives are one-line swaps in [`7_vcf2freq.nf`](https://github.com/ozankiratli/PoolSeqFlow/blob/main/scripts/7_vcf2freq.nf). Tested against the depths above at `minDP = 20`:

| Expression | Semantics | Sites kept |
|---|---|---|
| `-e "FMT/DP<20"` *(current)* | Every sample must pass | 0 of 3 |
| `-i "COUNT(FMT/DP>=20)>=2"` | At least 2 samples pass | 2 of 3 |
| `-i "MEAN(FMT/DP)>=20"` | Mean depth across samples | 2 of 3 |
| `-i "INFO/DP>=20"` | Cohort total depth | 3 of 3 |
| `-i "FMT/DP>=20"` | **Any one** sample passes — not a depth floor | 3 of 3 |

The last row is worth noting as a trap: `-i "FMT/DP>=20"` reads like the obvious inverse of the current expression and is not, because bcftools evaluates a `FORMAT` condition per sample and keeps the site if it holds for any of them.

!!! note "Genotype-level filtering is not available here"

    A per-sample depth floor — blanking one pool's frequency while keeping the row — cannot be done in the VCF, because vcftools and bcftools both express a genotype-level verdict by rewriting `GT`, and `GT` is set to `./.` throughout by major-allele normalisation ([why](../concepts/filter-chain.md#4-major-allele-normalisation-step-7)). Frequency conversion reads `AD`. If you need per-sample blanking rather than whole-site removal, it has to happen in `bin/depth2freq.awk`, which already computes each sample's depth as the denominator.

## Output naming

```groovy
vcf {
    fileName = 'Test'
}
```

Base name for every VCF and frequency table. With the default you get `Test.vcf`, `Test_sort_fp_dq.vcf`, `Test_snp_freq.tsv` and `Test_indel_freq.tsv`. Worth setting to something descriptive — it is the name your results carry from here on.

Changing it after a run does not rename anything; it makes the resume checks look for files that do not exist, and the whole VCF and frequency branch runs again alongside the old files.
