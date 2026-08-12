# Changelog

All notable changes to PoolSeqFlow will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.0.0] - 2026-08-12

Major upgrade to **Nextflow 26** and **Trim Galore 2.x**. This release is not backwards compatible: an existing `parameters.config` will fail mid-run, and completed trimming and annotation outputs are regenerated on first use.

### Breaking

- **Requires Nextflow 26** (`26.04.6`). The `cleanup { }` block in `nextflow.config` was invalid and is rejected by the stricter config parser; the pipeline could not start on 26 before this release.
- **Requires Trim Galore 2.x** (`2.3.0`). The bundled FastQC engine and `--basename` naming are both assumed.
- **`parameters.config` is no longer tracked in git.** Copy `parameters.config.template` and re-apply your settings — see *Upgrading from an earlier release* in the README. Carrying an older file over causes a later step to fail with a bare `null: command not found`.
- **Trimmed read filenames changed** from `<sample>_R1_val_1.fq.gz` to `<sample>_val_1.fq.gz`. Trimming is redone once on the first run after upgrading.
- **SnpEff database name is derived from the GFF filename** instead of being set by hand, so an existing database directory is not found and is rebuilt.
- **`params.fastqc.memory` is now a plain number of megabytes** (`2048`). The previous `"2G"` was rejected by FastQC, which silently fell back to its 512 MB default.
- **`-resume` is no longer passed to Nextflow.** `./PoolSeqFlow run` already resumes through its own filesystem checks; `./PoolSeqFlow resume` remains as a deprecated alias.

### Added

- Automatic core allocation: a `params.cores` block derives every tool's thread count from `params.threads`. Trim Galore is costed on its true footprint (`--cores N` runs N+4 threads), and `threads = 1` forces everything single-core.
- `params.trim_galore.autodetect` — when `true`, no adapter is passed and Trim Galore detects it; when `false`, both adapter sequences are required.
- Step 0 now validates trimming parameters, failing early if auto-detection is off and the adapters are missing or are not DNA sequences.
- `unzip` added to `environment.yml` and to `params.software`, so step 0 verifies it. It was always required by the clipping step but never declared.
- Trim Galore 2.x `*_trimming_report.json` files are kept alongside the `.txt` reports.
- README section on upgrading, covering the stale-configuration failure mode.

### Fixed

- **Trimming failed on standard Illumina filenames.** Output patterns assumed the read number ended the filename, so `<sample>_R1_001.fastq.gz` produced `Missing output file(s) *_R1_val_1.fq.gz`. Output naming is now pinned with `--basename`.
- **The SnpEff database could never be built.** Only the GFF was staged, so the build aborted with `Cannot find reference sequence.` and produced no `.bin` files. The reference FASTA is now copied in alongside it.
- **Clipping thresholds could be computed from truncated data.** A zero base fraction aborted the AWK pass mid-pipeline; without `pipefail` the failure was swallowed and a wrong read-length limit was used silently. Zero divisors are skipped, bounds are validated, and the chosen parameters are logged.
- **Alignment and coverage reports paired BAMs with indexes by position** rather than by sample; the two channels are now joined on `pair_id`.
- **`SkipGFFCheck` was unparseable** because of a duplicated `script:` label, so `annotate = false` could not run at all on Nextflow 26.
- **Resuming a completed run failed at the frequency step**, which linked a bare filename and created a self-referential symlink.
- **`parameters.config.template` did not parse on Nextflow 26** — it used `${mainDir}` instead of `${params.mainDir}` in nine places.
- README documented parameters that do not exist (`refGenome`, `refGFF`, `ploidy`) and placed the data directory under the wrong root.

---

## [1.0.1] - 2026-06-02

### Fixed
- Removed `conda update --all` from the install script. Package versions are now fully governed by `environment.yml`, improving reproducibility and preventing unintended upgrades after installation.

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

[2.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.0.0
[1.0.1]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.1
[1.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.0
