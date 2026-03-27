# PoolSeqFlow

**A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data**

[![Nextflow](https://img.shields.io/badge/nextflow-%E2%89%A523.05.0-brightgreen.svg)](https://www.nextflow.io/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.19245612.svg)](https://doi.org/10.5281/zenodo.19245612)

> **Platform note:** PoolSeqFlow is developed and tested on **Linux and macOS**. Windows is not supported — the resume logic relies on symbolic links and Unix-style paths that are not compatible with native Windows filesystems.

---

## Overview

PoolSeqFlow is a reproducible, end-to-end Nextflow pipeline designed for allele frequency estimation from **pooled Illumina short-read sequencing (Pool-seq)** data. It automates quality control, adapter trimming with intelligent clipping, reference alignment, BAM post-processing, variant calling, and VCF-to-frequency table conversion — with optional variant annotation.

The pipeline is designed for evolutionary and population genetics studies where large pools of individuals are sequenced together, and where accurate allele frequency estimates are the primary output.

---

## Pipeline Overview

```
Raw FASTQ reads
      │
      ▼
[Step 0] Verify Environment & folder structure
      │
      ▼
[Step 1] Build Reference Dictionaries (BWA, SAMtools, SnpEff)
      │
      ▼
[Step 2] Quality Control & Trimming (FastQC → Trim Galore → smart Cutadapt clipping)
      │
      ▼
[Step 3] Alignment (BWA-MEM)
      │
      ▼
[Step 4] BAM Cleanup (name-sort → fixmate → coord-sort → markdup → addRG → filter → index)
      │
      ▼
[Step 5] Alignment & Coverage Reports (BAMtools, SAMtools)
      │
      ▼
[Step 6] Variant Calling (BCFtools)
      │
      ├──────────────────────────────────────────────┐
      ▼                                              ▼
[Step 7] VCF → Allele Frequency Tables     [Step 8] Variant Annotation (SnpEff) [optional]
         (major-allele normalisation → min-frequency filter → depth/quality filter → SNP/INDEL split)
```

---

## Features

- **Intelligent trimming**: FastQC report parsing drives automatic Cutadapt clipping thresholds to maximise read quality while minimising data loss.
- **Pool-seq-aware frequency calling**: Allele frequency tables are produced with pool-size- and ploidy-aware minimum frequency filtering (see [Step 7](#step-7-vcf--allele-frequency-tables)).
- **Major-allele normalisation**: VCF files are re-encoded so the major allele is always the reference, enabling consistent downstream comparisons.
- **Multiallelic site support**: The pipeline is designed to handle multiallelic sites throughout the variant calling and frequency conversion steps, preserving complex variation that would be lost under biallelic-only assumptions.
- **Smart resume with permanent storage**: The pipeline uses symbolic links into a permanent output directory so large intermediate files are never duplicated and completed steps are automatically skipped on re-runs — without relying solely on Nextflow's built-in caching (see [Resume Logic](#resume-logic)).
- **Modular design**: Each step is an independent Nextflow DSL2 module — easy to modify, extend, or rerun in isolation.
- **Reproducible environments**: All dependencies are managed via a single conda environment.
- **Optional annotation**: Variant annotation via SnpEff can be toggled on/off.

---

## Requirements

- **Linux or macOS** (symbolic link support required — Windows is not supported)
- [Conda](https://docs.conda.io/en/latest/miniconda.html) or Miniconda
- Git (optional, for cloning)

All bioinformatics tools (Nextflow, FastQC, Trim Galore, Cutadapt, BWA, SAMtools, BAMtools, BCFtools, SnpEff) are installed automatically into an isolated conda environment.

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/ozankiratli/PoolSeqFlow.git
cd PoolSeqFlow
chmod +x PoolSeqFlow
```

### 2. Configure the pipeline

Edit `parameters.config` to point to your data:

```groovy
params {
    mainDir    = "/path/to/working/directory"  // where the pipeline runs (e.g. compute node scratch)
    projectDir = "/path/to/permanent/storage"  // where outputs are permanently stored (can be a different filesystem)
    dataSource = "Data"              // subdirectory of mainDir containing FASTQs
    refGenome  = "Ref.fa.gz"        // reference genome (gzipped FASTA)
    refGFF     = "Ref.gff.gz"       // annotation (gzipped GFF)
    poolSize   = 50                  // number of individuals in pool
    ploidy     = 2                   // ploidy of your organism

    // Adapter sequences
    trim_galore.adapter1 = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
    trim_galore.adapter2 = "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"
}
```

`mainDir` and `projectDir` can be the same path if you have a single storage location. They are separated to support environments where compute nodes and permanent storage are on different filesystems — a common constraint in HPC setups.

Edit `RGTags.csv` to add read group metadata for each sample (see [RG Tag Configuration](#rg-tag-configuration) below).

### 3. Install the environment

```bash
./PoolSeqFlow install
```

### 4. Run the pipeline

```bash
./PoolSeqFlow run
```

### 5. Additional commands

| Command | Description |
|---|---|
| `./PoolSeqFlow resume` | Resume a previous run, skipping completed steps |
| `./PoolSeqFlow clean` | Clean Nextflow work directories |
| `./PoolSeqFlow reset` | Remove all progress and start fresh |

---

## Resume Logic

PoolSeqFlow implements a custom resume strategy designed for large Pool-seq datasets where intermediate files (BAMs, VCFs) can be tens to hundreds of gigabytes, and where compute nodes and permanent storage are often on separate filesystems.

The pipeline separates two concepts:

- **`mainDir`** — the working directory where the pipeline executes (e.g. a compute node's scratch space or a fast local disk).
- **`projectDir`** — the permanent storage location where all outputs are written and kept (e.g. a network-attached archive, a group storage volume, or a different mount point entirely).

Rather than relying solely on Nextflow's built-in caching — which stores copies of outputs inside `work/` and can consume significant additional disk space — PoolSeqFlow writes outputs directly to `projectDir` and places **symbolic links** in `mainDir` pointing back to those permanent files. This means:

- **No file duplication**: large BAM and VCF files exist in exactly one place on disk, in `projectDir`.
- **No data movement**: you can run the pipeline on any node that can reach your permanent storage via a symlink, without copying files between filesystems.
- **Automatic step-skipping**: when `./PoolSeqFlow resume` is invoked, the pipeline checks for the existence of permanent output files in `projectDir`. Any step whose outputs are already present is skipped entirely, regardless of whether the Nextflow `work/` cache is still intact.
- **Resilience across sessions**: the resume logic is filesystem-based, so it survives cluster job timeouts, system reboots, and `work/` directory cleanups that would otherwise invalidate Nextflow's native cache.

`mainDir` and `projectDir` can point to the same path if you have a single unified storage location — the separation is there to gracefully handle the storage constraints common in HPC environments, not to impose them.

> **Requires Linux or macOS.** Symbolic links behave correctly on both. Windows — including WSL with certain filesystem configurations — is not supported.

---

## Directory Structure

### Repository

```
PoolSeqFlow/
├── bin/
│   ├── createDepthFile.sh        # Generate per-site depth files
│   ├── depth2freq.awk            # Convert depth to allele frequency
│   └── MajorAlleleToRef.py       # Re-encode VCF with major allele as REF
├── install/
│   ├── environment.yml           # Conda environment specification
│   ├── install.sh                # Environment setup script
│   └── test-install.sh           # Dependency verification
├── scripts/
│   ├── 0_verify_environment.nf
│   ├── 1_build_dictionaries.nf
│   ├── 2_trim_reads.nf
│   ├── 3_align.nf
│   ├── 4_clean.nf
│   ├── 5_reports.nf
│   ├── 6_variant_call.nf
│   ├── 7_vcf2freq.nf
│   └── 8_annotate_variants.nf
├── nextflow.config
├── parameters.config
├── parameters.config.template
├── poolseqflow.nf
├── RGTags.csv.template
└── README.md
```

### Required project directory layout

```
/path/to/project/          ← mainDir in parameters.config
├── Data/
│   ├── Sample1_R1.fastq.gz
│   ├── Sample1_R2.fastq.gz
│   └── ...
├── RGTags.csv
├── Ref.fa.gz
└── Ref.gff.gz
```

### Output structure

```
/path/to/project/
├── Logs/
├── Reference/
│   ├── Ref.fasta
│   ├── Ref.fasta.{amb,ann,bwt,fai,pac,sa}
│   └── snpEff/
└── Output/
    ├── Trimmed/             # Trimmed FASTQ files
    ├── Unpaired/            # Discarded unpaired reads
    ├── Aligned/             # Raw BAM files
    ├── Ready/               # Cleaned, indexed BAM files
    ├── VCF/                 # Variant calls (raw + annotated)
    ├── Frequencies/         # Allele frequency tables
    └── Reports/             # QC and alignment reports
```

---

## Configuration

### Resource configuration

Adjust CPU and memory in `nextflow.config`:

```groovy
process {
    cpus   = 8
    memory = '16 GB'
}
```

### SAMtools filter flags

Default flags in `parameters.config`:

```groovy
params {
    samFlags.filter   = "0xF0C"   // Remove: unmapped, mate-unmapped, secondary, QC-fail, duplicate, supplementary
    samFlags.required = "0x2"     // Require: properly paired
}
```

| Flag | Value | Effect |
|---|---|---|
| `0x004` | 4 | Exclude unmapped reads |
| `0x008` | 8 | Exclude reads with unmapped mate |
| `0x100` | 256 | Exclude secondary alignments |
| `0x200` | 512 | Exclude reads failing QC |
| `0x400` | 1024 | Exclude PCR/optical duplicates |
| `0x800` | 2048 | Exclude supplementary alignments |

---

## RG Tag Configuration

Create `RGTags.csv` in your project directory. The `ID` field must match the sample prefix in your FASTQ filenames.

```csv
ID,SM,LB,DS,FO,PL,PU
Sample1,Population1,Lib1,Pop1_Rep1,FASTQ,ILLUMINA,Unit1
Sample2,Population1,Lib2,Pop1_Rep2,FASTQ,ILLUMINA,Unit1
```

| Tag | Required | Description |
|---|---|---|
| `ID` | **Yes** | Unique identifier; must match FASTQ filename prefix |
| `SM` | No | Sample / population name |
| `LB` | No | Library identifier |
| `DS` | No | Description |
| `FO` | No | Flow order (typically `FASTQ`) |
| `PL` | No | Platform (e.g., `ILLUMINA`) |
| `PU` | No | Platform unit |
| `CN` | No | Sequencing centre |
| `DT` | No | Run date (ISO8601, e.g., `2024-03-07`) |

---

## Step-by-step Description

### Step 0: Verify Environment

Checks that all required files and software dependencies are present before the run begins. Produces `Reports/0_verify_environment.txt`.

### Step 1: Build Reference Dictionaries

Creates index files for BWA, SAMtools (`.fai`), and SnpEff. Output is written to `Reference/`.

### Step 2: Trim & QC

1. Runs **FastQC** on raw reads.
2. Runs **Trim Galore** to remove adapters (using sequences from `parameters.config`).
3. Parses FastQC HTML reports to compute the per-cycle A/T and G/C imbalance.
4. Automatically determines the number of bases to hard-clip with **Cutadapt** to bring base-composition ratios within configured thresholds.

### Step 3: Align

Aligns trimmed paired reads to the reference genome using **BWA-MEM**. Output: per-sample BAM files in `Aligned/`.

### Step 4: Clean BAM Files

Post-processing pipeline:

1. Name-sort (`samtools sort -n`)
2. Fix mate information (`samtools fixmate -m`)
3. Coordinate-sort (`samtools sort`)
4. Mark and remove duplicates (`samtools markdup`)
5. Add read group tags (`samtools addreplacerg`)
6. Filter alignments (`samtools view -F 0xF0C -f 0x2`)
7. Index (`samtools index`)

Cleaned BAMs are written to `Ready/`.

### Step 5: Generate Reports

Produces alignment statistics (`bamtools stats`) and coverage summaries (`samtools coverage`) for each sample. Written to `Reports/`.

### Step 6: Variant Calling

Calls SNPs and indels with **BCFtools mpileup + call**. The resulting multi-sample VCF contains `AD` (allelic depth) and `DP` (total depth) FORMAT fields. Output: `VCF/`.

### Step 7: VCF → Allele Frequency Tables

1. Re-encode the VCF with the major allele as REF using `MajorAlleleToRef.py`.
2. Update `DP` from `AD` counts.
3. Apply a **ploidy- and pool-size-aware minimum frequency filter**. Variants with allele frequency below

$$f_{\min} = \frac{1}{2 \times ploidy \times poolSize}$$

&nbsp;&nbsp;&nbsp;&nbsp;are removed, as they cannot represent even a single genome copy in the pool.

4. Apply depth and quality filters.
5. Split into SNP and INDEL VCFs.
6. Convert to tab-separated allele frequency tables written to `Frequencies/`.

### Step 8: Annotate Variants *(optional)*

Annotates the variant VCF with **SnpEff** using the reference GFF. Enable with `params.annotate = true` in `parameters.config`.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| Environment creation fails | `conda update -n base conda`, then retry `./PoolSeqFlow install` |
| Missing dependencies after install | `conda activate PoolSeqFlow` before running |
| Pipeline errors | Check `.nextflow.log` for the failing process |
| Resume skips too many steps | Check that permanent output files in `Output/` are intact |
| Symbolic link errors | Confirm you are on Linux or macOS, not Windows |

---

## Citation

If you use PoolSeqFlow in your research, please cite:

> Kiratli, O. L. Z. (2026). *PoolSeqFlow: A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data*. GitHub. https://github.com/ozankiratli/PoolSeqFlow. DOI: [10.5281/zenodo.19245612](https://doi.org/10.5281/zenodo.19245612)

---

## License

This project is licensed under the [Apache 2.0 License](LICENSE).

---

## Contact

**Ozan L. Z. Kiratli**
GitHub: [@ozankiratli](https://github.com/ozankiratli)
Issues: [https://github.com/ozankiratli/PoolSeqFlow/issues](https://github.com/ozankiratli/PoolSeqFlow/issues)
