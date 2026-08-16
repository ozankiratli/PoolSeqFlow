# PoolSeqFlow

<p class="psf-lead">
A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data. It takes raw FASTQ files and a reference genome, and gives back allele frequency tables — quality control, adapter trimming, composition-aware clipping, alignment, BAM cleanup, variant calling and frequency conversion, in a single resumable run.
</p>

<p class="psf-badges">
<a href="https://www.nextflow.io/"><img src="https://img.shields.io/badge/nextflow-%E2%89%A526.04.0-3cb371.svg" alt="Nextflow ≥26.04.0"></a>
<a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/license-Apache--2.0-60c0ff.svg" alt="Apache 2.0"></a>
<a href="https://doi.org/10.5281/zenodo.19245611"><img src="https://zenodo.org/badge/DOI/10.5281/zenodo.19245611.svg" alt="DOI"></a>
</p>

[Install](getting-started/install.md){ .md-button .md-button--primary } [Quick Start](getting-started/quick-start.md){ .md-button }

!!! info "Platform support"

    PoolSeqFlow is developed and tested on **Linux and macOS**. Windows is not supported — the resume logic relies on symbolic links and Unix-style paths that do not behave correctly on native Windows filesystems.

---

## What it is for

Pool-seq sequences many individuals together in one library. You give up the ability to say which individual carried which allele, and in exchange you get an allele frequency estimate for the whole pool at a fraction of the cost of sequencing each individual separately. The unit of analysis stops being a genotype and becomes a **frequency**.

That difference runs through every stage of this pipeline. A variant caller built for individuals wants to assign one of three genotypes per site; here there is no genotype to assign, only a ratio of read counts that has to survive intact from the pileup to the final table. PoolSeqFlow is built around keeping that ratio honest:

- **No biallelic assumption.** Multiallelic sites are preserved through calling, filtering and conversion rather than being collapsed or dropped.
- **Major-allele normalisation.** VCFs are re-encoded so the most frequent allele is the reference, which makes frequencies comparable across samples and runs.
- **Pool-aware filtering.** The minimum credible frequency is derived from your pool size and ploidy, not from a fixed cutoff — see [The Filter Chain](concepts/filter-chain.md).

If you are weighing Pool-seq against individual sequencing, or checking whether your design fits what this pipeline assumes, start with [When to use PoolSeqFlow](concepts/index.md).

---

## The pipeline

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
      ▼
[Step 5] Alignment & coverage reports (BAMtools, SAMtools)
      │
      ▼
[Step 6] Variant calling (BCFtools mpileup + call)
      │
      ├────────────────────────────────────────────┐
      ▼                                            ▼
[Step 7] VCF → allele frequency tables   [Step 8] Annotation (SnpEff, optional)
```

Each step is an independent Nextflow DSL2 module. Full detail in [Pipeline Steps](pipeline/steps.md).

---

## Start here

<div class="grid cards" markdown>

-   **New to the pipeline**

    ---

    Install the conda environment, write a `parameters.config`, and get a first run going.

    [Getting Started →](getting-started/index.md)

-   **Deciding whether to use it**

    ---

    What Pool-seq buys you, what it costs, and the study designs this pipeline does and does not fit.

    [Concepts →](concepts/index.md)

-   **Choosing your settings**

    ---

    Every parameter that changes a result, what it trades off, and how to pick a value for your data.

    [Configuration →](configuration/index.md)

-   **Understanding your output**

    ---

    What each filter removes, what the frequency tables contain, and how to read a column.

    [Interpreting Results →](concepts/interpreting-results.md)

</div>

---

## What is different about it

**Configuration is a file, never a flag.** PoolSeqFlow rejects command-line parameter overrides. A run is therefore fully described by a file you can version, diff and publish. It also sidesteps a silent failure mode: Nextflow delivers `--param` values as strings, so `--annotate false` sets the *string* `"false"`, which Groovy evaluates as true and leaves annotation quietly switched on. [Why →](concepts/design-decisions.md#configuration-is-a-file-never-a-flag)

**Resume is filesystem-based, so there is no `-resume` to remember.** Every step checks whether its outputs already exist in permanent storage and skips itself if they do. That survives job timeouts, reboots and `work/` cleanups that would invalidate Nextflow's own cache. `./PoolSeqFlow run` is both "start" and "resume". [Why →](concepts/design-decisions.md#resume-is-filesystem-based)

**Large files exist once on disk.** Outputs are written to permanent storage and symlinked back into the working directory, so a 200 GB BAM is never duplicated into `work/`. [Why →](concepts/design-decisions.md#symbolic-links-instead-of-copies)

**Clipping thresholds are measured, not guessed.** Step 2 parses the FastQC per-base composition table and derives the clip points from where the A/T and G/C ratios actually settle, per sample. You set a tolerance, not a number of bases. [How →](configuration/trimming.md#composition-aware-clipping)

**Thread counts come from one number.** Set `threads` and every tool's core count follows a benchmarked ladder — including Trim Galore, which is costed on its real footprint of `N+4` threads rather than the `N` it advertises. [How →](configuration/resources.md)

**The run refuses to mix results from two settings.** Because steps skip on the existence of output files, a changed `poolSize` or a reordered `RGTags.csv` would otherwise leave one folder holding results from two different configurations. Step 0 detects both and stops before any work happens. [How →](pipeline/steps.md#step-0-verify-environment)

---

## Citing

If PoolSeqFlow contributes to published work, please cite it — the DOI and a formatted reference are on the [Citation](reference/citation.md) page.
