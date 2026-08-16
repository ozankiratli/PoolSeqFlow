# Getting Started

## Requirements

| | |
|---|---|
| **Operating system** | Linux or macOS. Windows is not supported — see [below](#why-not-windows) |
| **Conda** | [Conda or Miniconda](https://docs.conda.io/en/miniconda.html) |
| **Git** | Optional, for cloning |
| **Disk** | Permanent storage sized for your BAMs and VCFs, plus working space for one sample's intermediates at a time |

Everything else is installed for you. `./PoolSeqFlow install` builds an isolated conda environment from `install/environment.yml`, which pins every tool to an exact build:

| Tool | Version | Role |
|---|---|---|
| Nextflow | 26.04.6 | Workflow engine |
| FastQC | 0.12.1 | Read quality metrics |
| Trim Galore | 2.3.0 | Adapter and quality trimming |
| Cutadapt | 5.2 | Composition-aware clipping |
| BWA | 0.7.19 | Alignment |
| SAMtools | 1.24 | BAM processing and filtering |
| BAMtools | 2.5.3 | Alignment statistics |
| BCFtools | 1.24 | Variant calling and VCF manipulation |
| VCFtools | 0.1.17 | VCF filtering and splitting |
| SnpEff | 5.4.0c | Variant annotation (optional) |
| OpenJDK | 25 | Runtime for FastQC, SnpEff and Nextflow |

Pinning is deliberate. Pool-seq results depend on the exact behaviour of the pileup and filtering tools, and an unpinned environment would make two runs of the same config non-comparable.

### Why not Windows

The resume logic is built on symbolic links into permanent storage, and on Unix path semantics throughout. Neither behaves correctly on native Windows filesystems, and WSL only works under some filesystem configurations — which is not a guarantee worth documenting. See [Symbolic links instead of copies](../concepts/design-decisions.md#symbolic-links-instead-of-copies).

---

## Ready

Download a release, create your configuration, and build the environment — four steps, with a verification pass at the end that fails loudly rather than letting a half-built environment through.

[Install PoolSeqFlow](install.md){ .md-button .md-button--primary } [Quick Start](quick-start.md){ .md-button }

Already have it installed and upgrading from an earlier version? Read [Upgrading](upgrading.md) first — your `parameters.config` is never touched by an update and can be missing parameters the new code expects.
