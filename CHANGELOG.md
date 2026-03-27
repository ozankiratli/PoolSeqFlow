# Changelog

All notable changes to PoolSeqFlow will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-03-26 — Initial Public Release

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.19245612.svg)](https://doi.org/10.5281/zenodo.19245612)

### Added

**Core pipeline (Nextflow DSL2)**
- End-to-end Pool-seq analysis workflow (`poolseqflow.nf`) with 9 modular steps
- Wrapper script (`PoolSeqFlow`) exposing `install`, `run`, `resume`, `clean`, and `reset` subcommands

**Step 0 — Environment verification**
- Pre-run checks for all required input files, folder structure, RGTags CSV format, and software dependencies
- Generates `Reports/0_verify_environment.txt`

**Step 1 — Reference indexing**
- Builds BWA, SAMtools (`.fai`), and SnpEff indices from a gzipped reference FASTA and GFF

**Step 2 — Quality control and trimming**
- FastQC assessment of raw reads
- Adapter trimming via Trim Galore with user-specified adapter sequences
- Automated per-cycle base-composition analysis of FastQC reports
- Intelligent hard-clipping via Cutadapt driven by A/T and G/C imbalance thresholds — no manual parameter tuning required

**Step 3 — Alignment**
- Paired-end alignment to the reference genome using BWA-MEM

**Step 4 — BAM post-processing**
- Full SAMtools-based cleanup: name-sort → fixmate → coord-sort → markdup → addreplacerg → filter → index
- Configurable alignment filter flags (`samFlags.filter`, `samFlags.required`)

**Step 5 — Alignment reporting**
- Per-sample alignment statistics via `bamtools stats`
- Coverage summaries via `samtools coverage`

**Step 6 — Variant calling**
- Multi-sample SNP and indel calling with BCFtools mpileup + call in multiallelic mode
- Outputs VCFs with per-sample `AD` and `DP` FORMAT fields

**Step 7 — VCF to allele frequency tables**
- Major-allele normalisation: VCF re-encoded so the major allele is always REF
- Multiallelic site support throughout variant calling and frequency conversion
- Ploidy- and pool-size-aware minimum frequency filter: $f_{\min} = 1 / (2 \times ploidy \times poolSize)$
- Depth and quality filtering
- SNP / INDEL split
- Export to tab-separated allele frequency tables

**Step 8 — Variant annotation (optional)**
- SnpEff-based functional annotation, toggled via `params.annotate`

**Resume logic**
- Custom filesystem-based resume strategy using symbolic links between `mainDir` (working directory) and `projectDir` (permanent storage)
- Completed steps are skipped based on presence of permanent output files — resilient to job timeouts, reboots, and `work/` directory cleanups
- Supports HPC environments where compute nodes and storage are on separate filesystems

**Configuration**
- `parameters.config` for analysis parameters (`mainDir`, `projectDir`, `poolSize`, `ploidy`, adapter sequences, filter flags)
- `nextflow.config` for computational resources (CPUs, memory, executor)
- `RGTags.csv` template for sample read group metadata
- `parameters.config.template` for getting started

**Environment**
- Single conda environment (`install/environment.yml`) covering all dependencies
- Automated install and verification scripts (`install/install.sh`, `install/test-install.sh`)

---

[1.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.0
