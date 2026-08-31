<p align="center">
  <img src="https://ozankiratli.github.io/PoolSeqFlow/assets/logo-full.svg" width="88" alt="">
</p>

# PoolSeqFlow

**A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data**

[![Nextflow](https://img.shields.io/badge/nextflow-%E2%89%A526.04.0-brightgreen.svg)](https://www.nextflow.io/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.19245611.svg)](https://doi.org/10.5281/zenodo.19245611)

### 📖 [Read the documentation →](https://ozankiratli.github.io/PoolSeqFlow/)

> **Platform note:** PoolSeqFlow is developed and tested on **Linux and macOS**. Windows is not supported — the resume logic relies on symbolic links and Unix-style paths that are not compatible with native Windows filesystems.

---

## Overview

PoolSeqFlow takes raw FASTQ files and a reference genome and gives back allele frequency tables. It automates quality control, adapter trimming with composition-aware clipping, alignment, BAM post-processing, variant calling and VCF-to-frequency conversion, with optional annotation.

Pool-seq sequences many individuals together, so the unit of analysis is not a genotype but a **frequency** — and that difference runs through every stage. Multiallelic sites are preserved rather than collapsed, VCFs are re-encoded so the most-read allele is the reference, and the minimum credible frequency is derived from your pool size and ploidy instead of a fixed cutoff. See [When to use PoolSeqFlow](https://ozankiratli.github.io/PoolSeqFlow/concepts/) for what the design assumes about your data.

```
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

---

## Quick start

Requires Linux or macOS and [conda](https://docs.conda.io/en/miniconda.html). Every bioinformatics tool is installed for you into an isolated environment, pinned to an exact build.

```bash
# 1. Download the latest release
curl -LO https://github.com/ozankiratli/PoolSeqFlow/releases/latest/download/PoolSeqFlow.tar.gz
tar -xzf PoolSeqFlow.tar.gz
cd PoolSeqFlow-*/

# 2. Create your configuration
cp parameters.config.template parameters.config
#    then edit it: mainDir, projectDir, readPattern, referenceFile, poolSize, diploidy

# 3. Build and verify the environment
./PoolSeqFlow install

# 4. Run — this is also the resume command
./PoolSeqFlow run
```

Your project directory needs a `Data/` folder of FASTQs, a gzipped reference, and an `RGTags.csv`. Copy `RGTags.csv.template` and fill it in — it is not only metadata, it decides which FASTQ pairs count as one sample and the order your result columns come out in.

Full walkthrough: [Install](https://ozankiratli.github.io/PoolSeqFlow/getting-started/install/) and [Quick Start](https://ozankiratli.github.io/PoolSeqFlow/getting-started/quick-start/).

> **Configure through `parameters.config` only.** PoolSeqFlow does not accept command-line parameter overrides, and `./PoolSeqFlow` deliberately rejects any argument beyond a single subcommand. A run is therefore fully described by a file you can version, diff and publish. It also avoids a silent failure: Nextflow delivers `--param` values as **strings**, so `--annotate false` sets the string `"false"`, which Groovy evaluates as *true*.

---

## Commands

| Command | Description |
|---|---|
| `./PoolSeqFlow install` | Create the conda environment, install the pipeline, then verify both |
| `./PoolSeqFlow check` | Verify an existing installation — tools, helpers, config |
| `./PoolSeqFlow run` | Start — or resume — the pipeline |
| `./PoolSeqFlow migrate_config` | Carry an older `parameters.config` onto the current template |
| `./PoolSeqFlow clean` | Remove Nextflow work directories |
| `./PoolSeqFlow reset` | Remove all progress and start fresh (typed confirmation required) |
| `./PoolSeqFlow version` | Print the installed version |
| `./PoolSeqFlow cite` | Print how to cite this copy, and which DOI to use |
| `./PoolSeqFlow analysis <command>` | The analysis layer — see below |
| `./PoolSeqFlow uninstall` | Remove one installed version — environment and pipeline together, after confirmation |

`analysis` is the one subcommand that carries a word of its own: `install`, `check`, `version`, `cite`, `uninstall`, or the name of a module to run. The analysis layer ships with the pipeline and is enabled separately with `./PoolSeqFlow analysis install`, which creates the conda environment that carries R.

There is no `-resume` flag. Every step checks whether its outputs already exist in permanent storage and skips itself if they do, so `run` both starts and resumes — and that survives job timeouts, reboots and `work/` cleanups. [Why →](https://ozankiratli.github.io/PoolSeqFlow/pipeline/resume/)

---

## Documentation

| | |
|---|---|
| [When to use it](https://ozankiratli.github.io/PoolSeqFlow/concepts/) | What pooling buys and costs, and what the pipeline assumes about your design |
| [Design decisions](https://ozankiratli.github.io/PoolSeqFlow/concepts/design-decisions/) | Why configuration is a file, why resume is filesystem-based, what each choice costs |
| [The filter chain](https://ozankiratli.github.io/PoolSeqFlow/concepts/filter-chain/) | All eight filters in order, what each removes, and how to tune them |
| [Interpreting results](https://ozankiratli.github.io/PoolSeqFlow/concepts/interpreting-results/) | The frequency table format, and the mistakes that are easy to make reading it |
| [Configuration](https://ozankiratli.github.io/PoolSeqFlow/configuration/) | Every parameter, sorted by whether it changes your results |
| [Read groups](https://ozankiratli.github.io/PoolSeqFlow/configuration/read-groups/) | `RGTags.csv`, and why `SM` decides what counts as a sample |
| [Pipeline steps](https://ozankiratli.github.io/PoolSeqFlow/pipeline/steps/) | Steps 0–8 in detail |
| [Upgrading](https://ozankiratli.github.io/PoolSeqFlow/getting-started/upgrading/) | Your `parameters.config` is never touched by an update — read this first |
| [Troubleshooting](https://ozankiratli.github.io/PoolSeqFlow/reference/troubleshooting/) | Errors by symptom |

---

## Citation

Your installed copy prints its own citation, with the version filled in:

```bash
./PoolSeqFlow cite
```

**Cite the version you actually ran, not the newest one.** Zenodo issues a separate DOI for every release, and results depend on which release produced them — filters, defaults and parameter names have all changed between versions. Step 0 records the versions that have run in a project in `.poolseqflow_versions`, mirrored into `Output/run_parameters.txt`.

[10.5281/zenodo.19245611](https://doi.org/10.5281/zenodo.19245611) is the **all-versions** DOI: it always resolves to the newest release. Use it to refer to the software in general, and a version DOI when reporting results. [Details →](https://ozankiratli.github.io/PoolSeqFlow/reference/citation/)

---

## License

Apache 2.0 — see [LICENSE](LICENSE). The tools PoolSeqFlow invokes carry their own licenses.

## Contact

**Ozan L. Z. Kiratli** · [@ozankiratli](https://github.com/ozankiratli) · [Issues](https://github.com/ozankiratli/PoolSeqFlow/issues)
