# PoolSeqFlow
<!--@ home | nav: Home -->

<p class="psf-lead">
A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data. It takes raw FASTQ files and a reference genome, and gives back allele frequency tables — quality control, adapter trimming, composition-aware clipping, alignment, BAM cleanup, variant calling and frequency conversion, in a single resumable run.
</p>

<p class="psf-badges">
<a href="https://www.nextflow.io/"><img src="https://img.shields.io/badge/nextflow-%E2%89%A526.04.0-3cb371.svg" alt="Nextflow ≥26.04.0"></a>
<a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/license-Apache--2.0-60c0ff.svg" alt="Apache 2.0"></a>
<a href="https://doi.org/10.5281/zenodo.19245611"><img src="https://zenodo.org/badge/DOI/10.5281/zenodo.19245611.svg" alt="DOI"></a>
</p>

[Install](#install){ .md-button .md-button--primary } [Quick Start](#quick-start){ .md-button }

!!! info "Platform support"

    PoolSeqFlow is developed and tested on **Linux and macOS**. Windows is not supported — the resume logic relies on symbolic links and Unix-style paths that do not behave correctly on native Windows filesystems.

---

### What it is for

Pool-seq sequences many individuals together in one library. You give up the ability to say which individual carried which allele, and in exchange you get an allele frequency estimate for the whole pool at a fraction of the cost of sequencing each individual separately. The unit of analysis stops being a genotype and becomes a **frequency**.

That difference runs through every stage of this pipeline. A variant caller built for individuals wants to assign one of three genotypes per site; here there is no genotype to assign, only a ratio of read counts that has to survive intact from the pileup to the final table. PoolSeqFlow is built around keeping that ratio honest:

- **No biallelic assumption.** Multiallelic sites are preserved through calling, filtering and conversion rather than being collapsed or dropped.
- **Major-allele normalisation.** VCFs are re-encoded so the most frequent allele is the reference, which makes frequencies comparable across samples and runs.
- **Pool-aware filtering.** The minimum credible frequency is derived from your pool size and ploidy, not from a fixed cutoff — see [The Filter Chain](#the-filter-chain).

If you are weighing Pool-seq against individual sequencing, or checking whether your design fits what this pipeline assumes, start with [When to use PoolSeqFlow](#when-to-use-poolseqflow).

---

### The pipeline

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

Each step is an independent Nextflow DSL2 module. Full detail in [Pipeline Steps](#pipeline-steps).

---

### Start here

<div class="grid cards" markdown>

-   **New to the pipeline**

    ---

    Install the conda environment, write a `parameters.config`, and get a first run going.

    [Getting Started →](#getting-started)

-   **Deciding whether to use it**

    ---

    What Pool-seq buys you, what it costs, and the study designs this pipeline does and does not fit.

    [Concepts →](#when-to-use-poolseqflow)

-   **Choosing your settings**

    ---

    Every parameter that changes a result, what it trades off, and how to pick a value for your data.

    [Configuration →](#configuration)

-   **Understanding your output**

    ---

    What each filter removes, what the frequency tables contain, and how to read a column.

    [Interpreting Results →](#interpreting-results)

</div>

---

### What is different about it

**Configuration is a file, never a flag.** PoolSeqFlow rejects command-line parameter overrides. A run is therefore fully described by a file you can version, diff and publish. It also sidesteps a silent failure mode: Nextflow delivers `--param` values as strings, so `--annotate false` sets the *string* `"false"`, which Groovy evaluates as true and leaves annotation quietly switched on. [Why →](#configuration-is-a-file-never-a-flag)

**Resume is filesystem-based, so there is no `-resume` to remember.** Every step checks whether its outputs already exist in permanent storage and skips itself if they do. That survives job timeouts, reboots and `work/` cleanups that would invalidate Nextflow's own cache. `./PoolSeqFlow run` is both "start" and "resume". [Why →](#resume-is-filesystem-based)

**Nothing is copied.** You give the pipeline two directories: `mainDir`, where you launch it and where everything it works on lives, and `storageDir`, where finished results are kept. Every file a step produces is *moved* out of `work/` and symlinked back, so nothing the pipeline touches — not just the big files — ever exists twice on disk. Results stay on `mainDir` while later steps still need them, and move to `storageDir` once nothing does. [Why →](#symbolic-links-instead-of-copies)

**Clipping thresholds are measured, not guessed.** Step 2 parses the FastQC per-base composition table and derives the clip points from where the A/T and G/C ratios actually settle, per sample. You set a tolerance, not a number of bases. [How →](#composition-aware-clipping)

**Thread counts come from one number.** Set `threads` and every tool's core count follows a benchmarked ladder — including Trim Galore, which is costed on its real footprint of `N+4` threads rather than the `N` it advertises. [How →](#resources)

**The run refuses to mix results from two settings.** Because steps skip on the existence of output files, an edited `parameters.config` or `metadata.csv` — or a different release of the pipeline — would otherwise leave one folder holding results produced under two configurations. Step 0 keeps a copy of each beside your results, compares them on every run, stops before any work happens, and names the outputs to delete. A version change is absolute: a project belongs to one release. [How →](#step-0-verify-environment)

**One invocation, many parameter sets.** A run table lets you analyse the same reads against several references, or under several filter settings, in one go. Work the runs have in common — trimming, alignment, a reference dictionary — is done once rather than once per run, and only what genuinely diverges gets a directory of its own. A single run is unaffected and keeps its plain results tree. [How →](#multi-run)

---

### Citing

If PoolSeqFlow contributes to published work, please cite it — the DOI and a formatted reference are on the [Citation](#citation-license) page.

# Getting Started
<!--@ section: getting-started -->

### Requirements

| | |
|---|---|
| **Operating system** | Linux or macOS. Windows is not supported — see [below](#why-not-windows) |
| **Conda** | [Conda or Miniconda](https://docs.conda.io/en/miniconda.html) |
| **Git** | Optional, for cloning |
| **Working directory** | `mainDir` — where you launch the pipeline. Holds your reads, the reference, this project's configuration and everything actively processed. It has to persist between runs; it is not scratch space |
| **Permanent storage** | `storageDir` — where finished results are kept. Must be a different path from `mainDir`, and neither may be the installation itself. The pipeline will refuse to start otherwise |
| **Disk** | `mainDir` needs room for your inputs and the files produced along the way; `storageDir` for the BAMs, VCFs and tables you keep |

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

#### Why not Windows

The pipeline moves each file it produces to where it belongs and leaves a symbolic link behind, and it relies on Unix path semantics throughout. Neither behaves correctly on native Windows filesystems, and WSL only works under some filesystem configurations — which is not a guarantee worth documenting. See [Symbolic links instead of copies](#symbolic-links-instead-of-copies).

---

### Ready

Download a release, create your configuration, and build the environment — four steps, with a verification pass at the end that fails loudly rather than letting a half-built environment through.

[Install PoolSeqFlow](#install){ .md-button .md-button--primary } [Quick Start](#quick-start){ .md-button }

Already have it installed and upgrading from an earlier version? Read [Upgrading](#upgrading) first — your `parameters.config` is never touched by an update and can be missing parameters the new code expects.

## Install
<!--@ page: install -->

Check the [requirements](#getting-started) first if you have not — in particular that you are on Linux or macOS, and that conda is available.

### 1. Get PoolSeqFlow

=== "Download a release"

    ```bash
    curl -LO https://github.com/ozankiratli/PoolSeqFlow/releases/latest/download/PoolSeqFlow.tar.gz
    tar -xzf PoolSeqFlow.tar.gz
    cd PoolSeqFlow-*/
    ```

    This is the recommended route. The archive is the pipeline only — no documentation sources or CI config — and it extracts into a versioned directory, so you always know which release a working copy came from.

    Verify it if you like: download `SHA256SUMS` from the same release and run `sha256sum -c SHA256SUMS`.

    [All releases](https://github.com/ozankiratli/PoolSeqFlow/releases){ .md-button }

=== "Clone the repository"

    ```bash
    git clone https://github.com/ozankiratli/PoolSeqFlow.git
    cd PoolSeqFlow
    chmod +x PoolSeqFlow
    ```

    Use this if you want to track development, work from a branch, or send a pull request. `main` is not guaranteed to be a released state, and the `chmod` is needed because a clone does not always preserve the executable bit — the release archive does.

### 2. Install it

```bash
./PoolSeqFlow install
```

This does two things at once, because they belong together: it creates a conda environment named `PoolSeqFlow-<version>`, and it copies the pipeline itself to `~/.local/opt/PoolSeqFlow-<version>`. The pinned tools are part of what produced a result, so code without its matching environment cannot reproduce anything.

Two commands are then linked into `~/.local/bin`: `PoolSeqFlow-<version>`, which always means that exact release, and plain `PoolSeqFlow`, which points at the **newest version you have installed**. Releases install alongside each other rather than over each other, so an old project can keep running under the version that produced its results. `PoolSeqFlow list` shows what is installed; `PoolSeqFlow uninstall` removes one.

Install somewhere else by setting `POOLSEQFLOW_PREFIX` — a shared location for a group, for instance:

```bash
POOLSEQFLOW_PREFIX=/opt/shared ./PoolSeqFlow install
```

**Putting that `bin` directory on your `PATH` is yours to do.** The installer checks, tells you whether it is already there, and prints the exact line to add if it is not — but it does not edit your shell configuration. Until you add it, call the command by its full path.

Installing takes a while the first time; later installs reuse the conda package cache. It finishes by verifying itself and **fails if anything is missing** — an environment that was created but is short a tool is not an install, and the alternative is finding out hours into a run.

Once this is done the folder you downloaded has served its purpose. Everything from here uses the installed command, from your own project directory.

### 3. Make your project

A project is a directory of your own. It is **not** the installation — that is a tool, shared by any number of projects and replaced wholesale when you upgrade, so a project kept inside it would not survive one. The pipeline refuses to start if you point it at the installation.

```bash
mkdir -p /path/to/project
cd /path/to/project
PoolSeqFlow init
```

The paths are yours to choose; the structure inside them is not. A project ready to run looks like this — `init` makes everything except the reads, the reference and `metadata.csv`:

```text
/path/to/project/                ← mainDir, and the directory you run from
├── parameters.config            ← your settings, read from wherever you launch
├── metadata.csv                 ← what your samples are; you write this one
├── metadata.csv.example         ← every column explained, to write it from
├── Data/                        ← dataSource names this folder
│   ├── Sample1_R1.fq.gz
│   ├── Sample1_R2.fq.gz
│   ├── Sample2_R1.fq.gz
│   ├── Sample2_R2.fq.gz
│   └── …
└── Reference/
    ├── reference.fasta.gz       ← referenceFile
    └── reference.gff.gz         ← gffFile, only if annotate = true
```

The file names are examples. `readPattern` is what finds the reads — `*_R{1,2}.fq.gz` by default, which is what matches the pairs above — and `referenceFile` and `gffFile` name the two in `Reference/`.

`init` never overwrites. Running it again in a project you have already filled in reports what is there and changes nothing.

It copies `parameters.config` for you because that is a settings file you edit in place. It does **not** write `metadata.csv`, because that is a table describing your experiment — which FASTQ pairs are one pool, how many individuals each holds, and the order your result columns come out in — and a copied one would describe someone else's. Write it yourself, starting from `metadata.csv.example`, and read [Metadata](#metadata) before your first run rather than after it.

Finished results do not go here. They go to `storageDir`, which has to be a different directory. See [Requirements](#getting-started).

Then edit `parameters.config`: `mainDir`, `storageDir`, `readPattern`, `referenceFile`, `poolSize` and `diploidy` at minimum. The reference and the annotation may be gzipped or plain — the pipeline takes either and unpacks what it needs into `Reference/Dictionaries/`.

Analysing one set of reads under several parameter sets — two reference genomes, say? Run `PoolSeqFlow init_multi` instead. It does everything `init` does, switches `multiRun` on, and copies `multi-run.csv.example` into the project. It does not write the run table itself, for the same reason it does not write `metadata.csv`.

### 4. Verify it any time { #check }

```bash
./PoolSeqFlow check
```

```text
Tools

  nextflow       nextflow     OK       26.04.6 build 12646
  samtools       samtools     OK       samtools 1.24
  bcftools       bcftools     OK       bcftools 1.24
  …
  tool list from: params.software in parameters.config

Pipeline helpers

  atomic_mv.sh                 OK
  depth2freq.awk               OK
  …

Configuration

  parameters.config            PARSES

All 21 checks passed.
```

It covers three things:

**Every command the pipeline invokes**, with the version each reports. Once you have a `parameters.config`, the list is read from `params.software` through `nextflow config` rather than assumed — so a command [repointed at a system binary](#using-system-tools) is checked as *you* configured it. That override is the setting most likely to be wrong and least likely to announce itself.

**Every helper in `bin/`**, present and executable. `nextflow.config` puts that directory on `PATH` and the process scripts call the helpers by bare name, so a lost executable bit fails mid-run rather than at startup.

**That `parameters.config` parses**, once it exists.

---

### Next

<div class="grid cards" markdown>

-   **Configure and run**

    ---

    Fill in `parameters.config` and start the pipeline.

    [Quick Start →](#quick-start)

-   **Coming from an earlier version**

    ---

    Your existing `parameters.config` will be missing parameters the new code expects, and nothing detects that automatically.

    [Upgrading →](#upgrading)

</div>

## Quick Start
<!--@ page: quick-start -->

This page gets a run going. It assumes you have installed the environment and laid out your project directory as described in [Getting Started](#getting-started).

### 1. Fill in the essentials

Open `parameters.config`. Nine settings need your attention before a first run; everything else has a working default.

```groovy
params {
    mainDir       = "/path/to/working/directory"  // where you run, and where your inputs live
    storageDir    = "/path/to/permanent/storage"  // where finished results are kept
    dataSource    = 'Data'                        // subdirectory of mainDir holding the FASTQs
    readPattern   = "*_R{1,2}.fq.gz"              // glob matching your paired FASTQ files
    referenceFile = 'reference.fasta.gz'          // reference genome, in mainDir/Reference
    gffFile       = 'reference.gff.gz'            // annotation (only if annotate = true)
    poolSize      = 50                            // individuals per pool
    diploidy      = 2                             // ploidy of your organism
    annotate      = true                          // run SnpEff annotation (step 8)
}
```

| Setting | How to choose it |
|---|---|
| `mainDir` | The working directory you ran `init` in. Holds `Data/`, `Reference/`, your configuration and everything actively processed, so it has to persist between runs — not node scratch that is wiped between jobs. Put it on the fastest storage that satisfies that. |
| `storageDir` | Where finished results are kept. **A different directory from `mainDir`**, and the pipeline refuses to start otherwise: the two are storage tiers, and outputs move from the first to the second as each step that needs them completes. |
| `readPattern` | Must match **both** mates with a `{1,2}` group. If your files end `_1.fastq.gz`/`_2.fastq.gz`, write `"*_{1,2}.fastq.gz"`. |
| `poolSize` | Individuals in **one** pool, not the total across pools. Sets the smallest allele frequency worth believing — see [The Filter Chain](#where-s-comes-from). If your pools differ in size, give each its own value in `metadata.csv`; this setting is the default for any that do not. |
| `diploidy` | Ploidy of the organism: `2` for diploid, `1` for haploid, `4` for tetraploid. |
| `annotate` | `false` skips step 8 and makes `gffFile` unnecessary. |

!!! warning "Set these through the file, never the command line"

    PoolSeqFlow rejects command-line parameter overrides, and the wrapper refuses any argument beyond a single subcommand. Nextflow delivers `--param` values as strings, so `--annotate false` sets the string `"false"` — which Groovy evaluates as **true**, leaving annotation switched on with no warning. [Why →](#configuration-is-a-file-never-a-flag)

The two directories cannot be the same path. They are storage tiers, not a preference: the pipeline works on `mainDir` and moves each output to `storageDir` once the last step that needed it has finished, which cannot mean anything if they are one place. On a cluster this is the difference between a node's fast disk and the archive it is backed by; on a laptop, make them two directories and the same reasoning still holds — one is churn, the other is what you keep.

### 2. Size the run to your machine

```groovy
threads = 8          // cores a single task may use
memory  = '24 GB'    // memory ceiling for a single task
```

Set `threads` to the cores you actually have — on HPC, the size of one node. Every tool's thread count follows from this one number; do not set the per-tool counts by hand. A request larger than the machine fails immediately:

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

Details and the full ladder: [Resources](#resources).

### 3. Write `metadata.csv`

One row per FASTQ pair. `SampleID` must match the sample name `readPattern` takes from your filenames — with `*_R{1,2}.fq.gz`, the file `Sample1T1Rep1_R1.fq.gz` gives `Sample1T1Rep1`.

```csv
SampleID,RG_Sample,RG_Library,RG_Platform,param_poolSize,population,timepoint
Sample1T1Rep1,Sample1T1,Lib1,ILLUMINA,50,Pop1,T1
Sample1T1Rep2,Sample1T1,Lib1,ILLUMINA,50,Pop1,T1
Sample2T1Rep1,Sample2T1,Lib1,ILLUMINA,40,Pop2,T1
Sample2T1Rep2,Sample2T1,Lib1,ILLUMINA,40,Pop2,T1
```

Three things this file decides:

- **`RG_Sample` decides what counts as a sample.** Rows sharing one are merged into a single VCF column and their read depths add together. The four rows above produce **two** columns, not four.
- **`param_poolSize` sets that pool's detection limit.** It describes the pool rather than the row, so rows sharing an `RG_Sample` have to agree on it. Leave the column out and every pool uses the global `poolSize`.
- **Row order decides column order** in the VCF and the frequency tables.

`population` and `timepoint` are columns of your own — add as many as your experiment needs. The pipeline records them and never interprets them, and editing them never invalidates results you already have.

All of it is covered in [Metadata](#metadata). Getting `RG_Sample` wrong is the most common way to end up with results that are valid but not what you meant.

### 4. Run

```bash
PoolSeqFlow run
```

That is also the resume command. Every step checks whether its outputs already exist and skips itself if they do, so an interrupted run picks up where it left off with no extra flag. There is no `-resume`.

Run it from your project directory — the one holding `parameters.config`. The pipeline reads its settings from wherever you launch, so running from anywhere else stops with a message saying so.

To see where a run's results would go before spending any compute on it, `PoolSeqFlow dryrun` builds that directory tree empty and changes nothing else; `PoolSeqFlow dryclean` removes the preview.

To start genuinely from scratch, use `PoolSeqFlow reset` first — it requires typing `DELETE_MY_ANALYSIS` to confirm.

### 5. Check the output

```text
storageDir/
├── Logs/
└── Output/
    ├── Frequencies/        ← the result: <name>_snp_freq.tsv, <name>_indel_freq.tsv
    ├── VCF/
    ├── Ready/              ← cleaned, indexed BAMs
    ├── Reports/
    ├── run_parameters.txt  ← the settings these results were produced under
    └── …
```

`<name>` is `vcf.fileName`, which is `Test` until you change it.

Start with `Output/Reports/Coverage/` and `Output/run_parameters.txt`. The first tells you whether your depth was truncated by the pileup cap; the second is a read-only record of exactly which settings produced these files.

Your inputs stay where they were, under `mainDir` — `Data/`, `Reference/` and the dictionaries built from your reference are working material, not results, and none of them are copied here.

If you are running a table of several runs, `Output/` and `Logs/` gain a level: work every run shared sits under `All_Runs/`, work some of them shared under `Shared_<N>/`, and whatever one run did alone under its own `RunID`. A single run keeps the plain tree above.

How to read the tables: [Interpreting Results](#interpreting-results).

---

### Commands

| Command | Description |
|---|---|
| `PoolSeqFlow install` | Create this release's conda environment, install the pipeline, then verify both |
| `PoolSeqFlow init` | Populate the current directory as a project ([what it writes](#3-make-your-project)) |
| `PoolSeqFlow init_multi` | The same, for a project running several parameter sets over one set of reads |
| `PoolSeqFlow check` | Verify an existing installation ([what it covers](#check)) |
| `PoolSeqFlow run` | Start — or resume — the pipeline |
| `PoolSeqFlow dryrun` | Create the directory tree the run would write, empty, so the layout can be approved before any compute is spent. Records nothing and changes none of your files |
| `PoolSeqFlow dryclean` | Remove the preview `dryrun` made |
| `PoolSeqFlow migrate_config` | Carry an older `parameters.config` onto the current template ([details](#upgrading)) |
| `PoolSeqFlow clean` | Remove Nextflow work directories |
| `PoolSeqFlow reset` | Remove all progress and start fresh (requires typed confirmation) |
| `PoolSeqFlow version` | Print the version of this copy |
| `PoolSeqFlow cite` | Print how to cite this copy, and which DOI to use ([why it matters](#which-doi-to-use)) |
| `PoolSeqFlow list` | List the pipelines and conda environments installed on this machine |
| `PoolSeqFlow uninstall` | Remove one installed version, environment and pipeline together |
| `PoolSeqFlow uninstall_all` | Remove every PoolSeqFlow environment and installation, after confirmation |

Before anything is installed there is no `PoolSeqFlow` on your `PATH`, so the first command is `./PoolSeqFlow install`, run from the folder you downloaded. Everything after that uses the installed command.

**Each subcommand takes no arguments of its own** — the wrapper accepts exactly one word and rejects anything else. Two environment variables adjust it instead: `POOLSEQFLOW_PREFIX`, where `install` puts things and where `list` and `uninstall` look, and `POOLSEQFLOW_HOME`, to run a checkout without installing it.

**Naming a version.** Every installed release is also on your `PATH` under its own name, so `PoolSeqFlow-2.1.0 run` uses that release and plain `PoolSeqFlow` uses the newest. This matters most for `uninstall`: with several versions installed it lists them and asks which to remove, and if nothing is attached to ask — a script, a CI job — it refuses and tells you to name one, rather than guessing at which installation to delete. `PoolSeqFlow-2.1.0 uninstall` names it and is never asked.

`PoolSeqFlow resume` still works as a deprecated alias for `run` and prints a notice.

## Upgrading
<!--@ page: upgrading -->

Two separate things upgrade here, and it helps to keep them apart. **The installation** is a tool: a new release installs alongside the ones you already have and disturbs none of them. **A project** is your results — and a project belongs to one release for as long as it exists.

### Installing a new release

Download and install it exactly as you did the first time. Nothing is replaced: `~/.local/opt` gains a directory, `~/.local/bin` gains a `PoolSeqFlow-<version>` command, and plain `PoolSeqFlow` starts meaning the new one. Every earlier release still runs, under its own name.

Your projects are untouched by this. `parameters.config` lives in your project directory, not in the installation, so nothing an install or an uninstall does can reach it.

### A project belongs to one release

This is the part that changes how upgrading works. Completed steps are skipped by looking for output files, not by checking what produced them, so continuing an existing project under a new release would leave one set of results built by two versions of the pipeline, with nothing on disk to say which is which.

The pipeline refuses. On the first run after upgrading it stops before any work happens:

```text
PIPELINE VERSION:      These results were produced by 2.2.0,
PIPELINE VERSION:      and this is 3.0.0.
```

There are two ways forward, and both are deliberate choices rather than defaults:

- **Finish the project on the release that started it** — `PoolSeqFlow-2.2.0 run`. The version that produced your results is still installed and still works, which is the reason releases sit side by side.
- **Start the project again under the new one** — `PoolSeqFlow reset`, then run. This deletes the existing results.

There is deliberately no third option. A project that changed version midway has no answer to the question of which version to cite.

### Bringing your configuration forward

`parameters.config` belongs to you and is never touched by an update — an update must not silently change your analysis settings. The consequence is that after installing a new release your file can be **missing parameters the newer code expects**, and `migrate_config` is the tool for exactly that. Run it before anything else.

Skip it and the failure is not a clean one. An absent parameter interpolates as the literal string `null`, so a later step dies with `.command.sh: line 17: null: command not found` — naming no parameter, and pointing at a generated script. If you ever see that, your config predates the code.

### The assisted route

```bash
PoolSeqFlow migrate_config
```

Run it in your project directory. It backs your file up, rebuilds it from the current template, carries across every setting whose parameter still exists, and reports what happened to each one:

| Report | Meaning |
|---|---|
| `Kept your value` | The parameter still exists and your setting was carried over |
| `Renamed this release` | The parameter was renamed and your value followed it to the new name |
| `Now computed by the pipeline` | This release derives the value; yours was ignored |
| `Format changed this release` | The value's meaning or format changed, so the template's wins |
| `New in this release` | The template has a parameter your file did not — review the default |
| `No longer used` | Your file had a parameter this release does not use |

It also ends with a list of **files to move yourself**, and moves none of them. If you are upgrading from 2.2.0 or older, there will be several, because the layout changed: your reads, reference and sample table used to live under the storage directory and now belong on `mainDir`. It prints the exact `mv` commands, having checked which files are actually there — read them before running them.

One group in that list matters more than the rest. `.poolseqflow_params` and its neighbours are the records the change guard compares against — they are how "has anything changed since these results were produced" gets answered. Leave them behind and the next run finds no record, decides the project is new, and writes down your *current* configuration as though it had produced the results already on disk. The guard would then report that nothing has changed, having quietly stopped guarding.

**Treat the migrated config as a starting point, not an answer.** Migration can only recognise a parameter that still exists *and still means the same thing*. A parameter whose behaviour changed while its value still looks like an ordinary number or string is carried across and is silently wrong. Always read the report, and compare afterwards.

### The manual route

Every release adds parameters, and rebuilding by hand is often the safer choice — it is the only way to be certain you have actually looked at the new ones. The template ships inside the installation, and `init` is what puts a copy of it in front of you:

```bash
mv parameters.config parameters.config.bak            # keep your settings
PoolSeqFlow init                                      # writes a fresh parameters.config
diff parameters.config.bak parameters.config          # see what changed, then re-apply yours
```

`init` never overwrites, so move your own file aside first, as above — otherwise it reports the config as already present and leaves it alone.

### Coming from 2.2.0

3.0 is a major release that brings in a complete new design and more reproducibility options, and the changes are structural rather than a handful of new settings.

**Where things live has changed.** Before 3.0 there was one storage directory holding your inputs and your results together. There are now two, and they must be different paths: `mainDir` holds your reads, reference and configuration and is where you run, `storageDir` holds finished results. `migrate_config` prints the `mv` commands for the files that need to move.

**`projectDir` is now `storageDir`.** A straight rename, and your value is carried over — note that `projectDir` is also a name Nextflow defines for itself, which is why it could not stay.

**`RGTags.csv` is replaced by `metadata.csv`.** This one is not a rename and cannot be migrated: the old file held raw SAM read-group tags and nothing else, while the new one has three kinds of column and carries your pool sizes as well. `migrate_config` reports `rgTagsFile` as no longer used and tells you to move the file, but rewriting it into the new schema is yours to do. Start from `metadata.csv.example` and read [Metadata](#metadata). It is the change that buys the most: the experiment itself — populations, timepoints, replicates — finally has somewhere to live.

**The installation is separate from your project now.** Earlier releases were run from the folder you unpacked, with `parameters.config` beside the pipeline. From 3.0 you install once, releases sit side by side, and you run the installed command from your own project directory. If your project *is* the old unpacked folder, move it out — the pipeline refuses to run inside its own installation.

**Some parameters are gone**: `params.gff`, `params.dir.scripts`, and the temporary-directory subpaths. `migrate_config` reports each as no longer used.

**Multi-run is new**, and off by default — `multiRun = false` changes nothing about how an existing project behaves.

### After upgrading

Once your configuration is current, the first run will still stop, because your existing results were produced by an older release. That is the version block described above, and `migrate_config` does not clear it: choose between finishing on the old release and starting again on the new one.

For a project started fresh under 3.0, the ordinary guard applies from then on — a change to an analysis-affecting parameter stops the next run, and the report names the folders to delete.

See [The run refuses to mix settings](#the-run-refuses-to-mix-settings) for what is and is not tracked, and the [Changelog](#changelog) for what each release changed.

# When to use PoolSeqFlow
<!--@ section: concepts | nav: Concepts -->

This page is about fit. It describes what pooled sequencing changes about an analysis, what PoolSeqFlow assumes your design looks like, and the cases where a different tool is the better answer. If you already know Pool-seq is what you want, skip to [Getting Started](#getting-started).

### What pooling buys and what it costs

In a pooled library, DNA from many individuals is combined before sequencing. Every read still comes from exactly one chromosome in one individual, but nothing in the data records which. What survives is the **proportion** of reads carrying each allele, which is an estimate of the allele frequency in the pool.

| You gain | You give up |
|---|---|
| Frequency estimates for many individuals at a fraction of the per-individual cost | Individual genotypes — and therefore heterozygosity, relatedness, and anything phased |
| Depth concentrated where it matters: on the frequency estimate, not on calling a genotype confidently | The ability to separate sampling noise from real low-frequency variation without care |
| A design that scales to large populations and many time points | Straightforward variant filtering — the usual genotype-based heuristics do not apply |

The second row is the one that shapes this pipeline. In individual sequencing, a variant seen on two reads out of a hundred is almost certainly an error. In a pool of 50 diploids, one chromosome out of 100 is a real allele at frequency 0.01, and it looks exactly the same. Distinguishing the two is not something a fixed cutoff can do, which is why PoolSeqFlow derives its threshold from your pool size and ploidy rather than hard-coding one. See [The Filter Chain](#the-filter-chain).

### What PoolSeqFlow assumes

These are structural assumptions. If your data does not match, the pipeline will either refuse to start or produce something that is not what you meant.

| Assumption | Where it comes from | If you do not match |
|---|---|---|
| Paired-end Illumina reads | `readPattern` matches an `R1`/`R2` pair; step 4 requires properly-paired alignments (`0x2`) | Single-end data will not survive the pairing filter |
| One reference genome per run | Variant calling is a single joint `bcftools mpileup` over all BAMs | Samples on different references cannot be called together. Running one set of reads *against* several references is a different thing, and supported — that is what a run table is for |
| One ploidy per run | `diploidy` sets the detection threshold for every pool in the run | Split the work into runs, each with its own `diploidy` — see [below](#sequences-with-a-different-ploidy) |
| Several comparable pools per run | The false-positive filter keeps a variant only if a **fraction of samples** support it | A single-sample run needs `sampleThreshold` reconsidered — see [below](#single-sample-runs) |
| A reference FASTA, and a GFF if you annotate | `referenceFile`, `gffFile` | Either may be gzipped or plain; the pipeline takes both and unpacks what it needs |
| Compute and storage reachable from one process | `mainDir` and `storageDir` can be on different filesystems, and both must be mounted | Cloud object storage without a filesystem mount is not supported |

### Where PoolSeqFlow ends

PoolSeqFlow produces **allele frequency tables**. It deliberately stops there. It does not compute F~ST~, run CMH or other tests for allele frequency change, generate `sync`/`mpileup` formats for PoPoolation, call structural variants or copy number, or perform any population-genetic modelling.

That is a scope decision, not an omission: the statistics you want depend entirely on your design, and a per-site frequency table is the input nearly all of them take. Annotation via SnpEff is included because it operates per-variant and needs the same reference build the pipeline already indexed.

### Cases that need a second look

#### Pools of different sizes

Pool size feeds the sensitivity threshold:

$$f_{\min} = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}$$

A pool holds $\text{diploidy} \times \text{poolSize}$ chromosomes, so a single one of them represents a frequency of $1/(\text{diploidy} \times \text{poolSize})$; the threshold is set at half that. A pool of 10 and a pool of 500 therefore have very different limits, and judging both at one threshold is either too permissive for the small pool or too strict for the large one.

**So give each pool its own.** `param_poolSize` in `metadata.csv` is a column of pool sizes, and each pool's threshold is computed from its own. Because the size describes the pool rather than the row, rows sharing an `RG_Sample` must agree on it, and a blank cell means the global `poolSize` rather than agreement with anything.

The global `poolSize` in `parameters.config` stays as the default for any pool that does not state one, so a run where every pool really is the same size needs nothing extra.

#### Sequences with a different ploidy

`diploidy` applies to a whole run, and it belongs to the sequence rather than to the sample: a diploid animal carries a haploid mitochondrial genome, and one threshold cannot be right for both.

**Separate them into runs.** A [run table](#multi-run) can vary any parameter, so give the nuclear chromosomes and the organellar sequences their own references and their own `diploidy`:

```csv
RunID,referenceFile,gffFile,diploidy
nuclear,chromosomes.fasta.gz,chromosomes.gff.gz,2
mitochondrial,mito.fasta.gz,mito.gff.gz,1
```

Both runs read the same FASTQ files, and the work they share — trimming and quality control — is done once rather than twice. Changing `diploidy` re-derives that run's sensitivity threshold automatically, so there is nothing else to keep in step.

The same argument applies to anything else whose copy number differs from the nuclear genome: chloroplast sequences, and unplaced scaffolds whose ploidy you are not confident about. Splitting them out costs one row in the table and makes each threshold defensible.

#### Single-sample runs

The false-positive filter is a **cross-sample** consistency check: an allele is kept only if at least `sampleThreshold` (default `0.2`) of the samples show it at or above $f_{\min}$. With one sample, that fraction rounds to a requirement that the one sample support it, so the filter degrades to a plain per-site frequency cutoff. It still works, but it is doing much less than it does on a multi-sample run, and the cross-sample corroboration that justifies a permissive $f_{\min}$ is gone.

#### Genuinely private variants

At the default `sampleThreshold = 0.2`, an allele present in only one pool out of eight (12.5% of samples) is **removed**, even at high frequency in that pool. This is the correct default for detecting shared, evolving variation; it is the wrong default if population-private alleles are the point of your study. Lower `sampleThreshold` accordingly, and see [Variant Calling](#samplethreshold) for what that costs you.

#### Very high depth

`variantCall.maxDepth` defaults to `2000` and becomes `mpileup -d`, a per-file cap on reads considered at a position. Pooled libraries are often sequenced deeply on purpose, and a cap that bites truncates the read counts the frequencies are computed from. Check your coverage reports from step 5 against this value before trusting the output — details in [Variant Calling](#maxdepth).

### Choosing between run layouts

| If your samples are… | Do this |
|---|---|
| Independent pools you want compared | One run, one row per pool in `metadata.csv`, distinct `RG_Sample` values |
| One pool split across lanes or runs to reach depth | One run, one row per FASTQ pair, **sharing** an `RG_Sample` so the reads are combined |
| Technical replicates you want treated as one observation | Share an `RG_Sample` |
| Technical replicates you want to compare against each other | Distinct `RG_Sample` values |
| Pools of different sizes | One run — give each pool its own `param_poolSize` in `metadata.csv` |
| To be compared against different reference genomes | One project, one row per reference in a run table |
| Nuclear and organellar sequences together | One project, one row per ploidy in a run table |

Only the last two need a [run table](#multi-run); everything above them is a single run.

The `RG_Sample` decision is the one most often got wrong by accident, because two FASTQ pairs from one pool look exactly like two ordinary samples. It is covered in full in [Metadata](#rg_sample-decides-what-counts-as-a-sample).

## Design Decisions
<!--@ page: design-decisions -->

PoolSeqFlow departs from stock Nextflow practice in several places. Each departure was made for a reason, and each one costs something. This page states both, so you can tell whether a behaviour you are seeing is a bug or the design working as intended.

---

### Configuration is a file, never a flag

**The decision.** Every setting lives in `parameters.config`. The wrapper accepts a single subcommand and rejects any further argument. There is no `--poolSize 50`.

**Why.** Two reasons, one about reproducibility and one about correctness.

A run described entirely by a file is a run you can version, diff, publish alongside a paper, and hand to someone else with a guarantee they will get the same numbers. Once any setting can come from the command line, the file stops being a complete record and the shell history becomes part of the method.

The correctness reason is sharper. Nextflow passes `--param` values as **strings**. So this:

```bash
nextflow run poolseqflow.nf --annotate false    # do not do this
```

sets `annotate` to the string `"false"`, and Groovy evaluates any non-empty string as true. Annotation stays switched on, no warning is printed, and the only symptom is that step 8 runs when you asked it not to. Written in the config file:

```groovy
annotate = false
```

it is a real boolean and behaves as expected. This class of failure is silent and type-dependent, and the only reliable fix is to remove the path that creates it.

**What it costs.** Sweeping a parameter across values means editing a file between runs rather than scripting a loop over flags. For a parameter sweep, copy the project directory or keep several config files and swap them into place.

---

### Resume is filesystem-based

**The decision.** Every step checks whether its own outputs already exist, and skips itself if they do. It looks in permanent storage first and then on the working volume, so an output that has been produced but not yet moved to `storageDir` counts as done. This replaces Nextflow's `-resume` entirely; the wrapper never passes that flag. `PoolSeqFlow run` is both "start" and "resume".

**Why.** Nextflow's cache lives in `work/`. It is invalidated by anything that removes or changes those directories, which for this pipeline is routine:

- `cleanup = true` in `nextflow.config` deletes task working directories once a run completes. `-resume` replays task outputs *from* those directories, so after a successful run there is nothing left to replay.
- Several steps delete their own inputs once the next stage has consumed them — the trimmed reads are removed after clipping, and each VCF is removed after the next filter produces its successor. That leaves the upstream task's recorded outputs dangling, which invalidates the cache entry regardless.
- On HPC, jobs hit walltime, nodes reboot, and scratch is purged on a schedule. A cache that lives in scratch does not survive the failure modes that actually interrupt long runs.

A check for "does this output file already exist" survives all of that, because it depends on nothing but the storage the results are already in.

**What it costs.** Two things worth knowing.

Step-skipping happens *inside* each task rather than before it, so a re-run still submits every process to the scheduler. Those jobs exit almost immediately — they test for a file, create a symlink and copy two log files — but they are real submissions. Expect roughly one short job per process per sample on a fully resumed run.

More importantly, "the output exists" is not the same as "the output is correct for your current settings". A file produced under `poolSize = 50` looks identical to one produced under `poolSize = 100`. That gap is closed separately, by the guardrails [below](#the-run-refuses-to-mix-settings).

---

### Symbolic links instead of copies

**The decision.** Each output is **moved** out of the task's working directory to where it belongs, and a **symbolic link** is left behind pointing at it. Nothing is copied, and no file the pipeline produces exists twice.

**Why.** Pool-seq intermediates are large. A run with a dozen pools moves through hundreds of gigabytes of BAMs and VCFs. Nextflow's default is to publish outputs by copying them out of `work/`, which means every large file exists twice for as long as `work/` survives.

An output is not moved to its final home immediately, though, and that is the second half of the design. It first lands on `mainDir`, the working volume, and moves to `storageDir` only once the last step that needed it has finished. A BAM is read several times on its way to a frequency table, and reading it repeatedly across a network mount is the slowest thing a run does.

The two directories therefore have distinct jobs, and **cannot be the same path**:

- `mainDir` is the fast one. Your reads, your reference and everything in progress live here, and it is where the work happens.
- `storageDir` is the durable one, and holds what you keep.

On a cluster this maps onto a node's local disk and the network volume behind it; on a laptop it is one directory that churns and one you back up. Either way an output crosses between them exactly once, at the point where it stops being working material and becomes a result.

**What it costs.** Symbolic links, which is why Windows is not supported — including WSL under some filesystem configurations. It also means a task's working directory is not self-contained: deleting either directory while a run is in flight breaks links that are already in use. And `mainDir` is not scratch — it holds your inputs and your configuration, so it has to survive between runs.

---

### Threads are budgeted, not divided

**The decision.** One `threads` value sizes the whole run. Every tool's core count is derived from it through a fixed ladder, and each process reserves what it actually uses.

**Why.** The obvious alternative — divide the available cores evenly among concurrent tasks — assumes tools scale linearly with threads. They do not. Each tool here is quantised to the point where its published scaling flattens out, so extra cores go to another task instead of into diminishing returns.

The sharper reason is that a tool's advertised thread count is not always what it spawns. Trim Galore's `--cores N` runs **N+4** threads: N workers, two decompressors, a batcher and a writer. A process that declares `cpus 4` and then passes `--cores 4` is really using eight. Nextflow decides how many tasks to run concurrently by comparing `cpus` against available resources, so an under-declared task causes oversubscription — the machine ends up running twice the work it thinks it is.

PoolSeqFlow reserves Trim Galore's full footprint and maps back to the worker count in the script, so the declaration and the reality agree. The full ladder is in [Resources](#resources).

**What it costs.** Honest accounting is slower than optimistic accounting on a small machine. At `threads = 8`, a single trimming task reserves all eight cores, so samples are trimmed one at a time. Earlier behaviour ran three concurrently at twelve threads each on an eight-core box — faster in wall-clock, and a 4.5× oversubscription. A request larger than the machine now fails immediately rather than quietly degrading:

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

---

### The run refuses to mix settings

**The decision.** The run stops when the pipeline version, the analysis parameters, the run table or `metadata.csv` have changed since the existing outputs were produced.

**Why.** This is the direct consequence of [filesystem-based resume](#resume-is-filesystem-based). Because a step skips itself when its output file exists, and the file carries no record of what produced it, changing `poolSize` and re-running would leave one `Frequencies/` folder holding tables computed under two different thresholds. Nothing downstream could detect that, and the mixture would be invisible in the output.

So a record of what produced them is kept beside the results:

| Record | Covers |
|---|---|
| `.poolseqflow_version` | The release that produced these results. **A mismatch is a hard stop**, not a warning — see [A project belongs to one release](#a-project-belongs-to-one-release) |
| `.poolseqflow_params` | The analysis-affecting parameters, mirrored to a readable `run_parameters.txt` beside it |
| `.parameters.config` | Your configuration file, copied verbatim as you wrote it |
| `.multirun.csv` | Your run table, copied verbatim, if you used one |
| `.poolseqflow_metadata` | The parts of `metadata.csv` that can change a result — the read-group tags, the pool sizes, and the row order that sets column order. Kept beside the results it describes |

That last one is also why most of your own columns cost nothing to change. A column recording experimental design, or a result from somewhere else — how the samples were grouped, when they were collected, what was measured about them — is not in the record, so adding or editing one never invalidates results you already have. **That holds for now.** Once the analysis layer arrives, the columns it reads will start to matter, and that freedom will narrow.

Path and resource parameters are excluded, since they change where and how fast the work happens rather than what the answer is; so are the `software` entries that name the commands to run. Anything added in a later release counts as analysis-affecting until decided otherwise, which is the conservative direction to err in.

The two verbatim copies serve a different purpose from the rest. They are not what the comparison is made against — they are the citable record, the exact files you ran kept next to the numbers they produced.

**What it costs.** You cannot change a threshold and re-run to see the difference in place. The report names the folders to delete, and deleting them is what clears it — that is deliberate, because the alternative is a folder of results you can no longer attribute to a setting.

---

### Moves across filesystems are atomic

**The decision.** All cross-filesystem moves stage through a `.part` file and rename into place, via `bin/atomic_mv.sh`.

**Why.** A plain `mv` across a filesystem boundary is a copy followed by an unlink, not an atomic rename. A job killed mid-move — walltime, preemption, a node failure — leaves a **truncated file under its final name**. Combined with existence-based resume, that is the worst possible failure: the next run sees the file, concludes the step is done, and builds everything downstream on a partial BAM.

Staging through a temporary name and renaming means an interrupted move leaves a `.part` file that no existence check looks for, and the step simply runs again.

---

### Steps delete their own inputs

**The decision.** Once a stage's output is safely in permanent storage, several steps delete the input they consumed — trimmed reads after clipping, each VCF after the next filter produces its successor.

**Why.** Peak disk usage on a Pool-seq run is dominated by intermediates that nobody needs once the next stage has run. Keeping every one of them would roughly multiply the storage requirement by the number of filter stages, for files that exist only to be consumed.

**What it costs.** You cannot inspect an intermediate after the fact without re-running from an earlier point, and it is part of why Nextflow's own cache cannot be used.

Note that this applies to the permanent copies too, not just the scratch ones: the step deletes the file the symlink resolves to. After a complete run, `Output/VCF/` holds the raw call set, the fully filtered VCF, and the annotated VCF if you enabled it — the per-stage intermediates between them are gone. Exactly which files survive is listed in [Directory Layout](#what-survives-a-completed-run).

## The Filter Chain
<!--@ page: filter-chain -->

A read that makes it into a frequency table has passed eight separate filters spread across four steps. This page walks the whole chain in order: what each filter removes, which parameter controls it, and what you are trading when you move that parameter.

If you are trying to work out why a variant you expected is missing, read this page top to bottom — the answer is usually earlier in the chain than people look.

### The chain at a glance

| # | Stage | Operates on | Removes | Parameter |
|---|---|---|---|---|
| 1 | Alignment filter | Reads | Unmapped, non-paired, duplicate, secondary, supplementary, low-MAPQ reads | `cleanBAM.filter`, `cleanBAM.required`, `cleanBAM.mapq` |
| 2 | Pileup filter | Reads at a position | Low mapping quality, low base quality; caps depth | `variantCall.baseQualMin`, `variantCall.varQualMin`, `variantCall.maxDepth` |
| 3 | Variant calling | Sites | Non-variant sites | `variantCall.callOptions` |
| 4 | Major-allele normalisation | Allele order | Nothing — it rewrites | — |
| 5 | False-positive filter | Alternate alleles | Alleles without cross-sample support | `poolSize` or `param_poolSize`, `diploidy`, `filterFalsePositives.sampleThreshold` |
| 6 | Depth & quality filter | Sites | Sites where any sample is under-covered, and low-QUAL sites | `vcffilter.minDP`, `vcffilter.minQUAL` |
| 7 | SNP/INDEL split | Sites | Splits into two files; nothing is lost | — |
| 8 | Frequency conversion | — | Nothing | — |

Stages 1–3 happen in [steps 4 and 6](#pipeline-steps); stages 4–8 are the five sub-steps of step 7.

---

### 1. Alignment filter (step 4)

The last stage of BAM cleanup is a `samtools view` with three conditions:

```bash
samtools view -F 0xF0C -f 0x2 -q 30 -b
```

| Flag | Source | Effect |
|---|---|---|
| `-F 0xF0C` | `cleanBAM.filter` | **Excludes** unmapped, mate-unmapped, secondary, QC-fail, duplicate and supplementary reads |
| `-f 0x2` | `cleanBAM.required` | **Requires** the read to be properly paired |
| `-q 30` | `cleanBAM.mapq` | **Excludes** reads with mapping quality below 30 |

The MAPQ floor is easy to miss because it is not part of either flag word. At `30` it is a strict filter — it discards reads that map ambiguously, which in a repetitive genome can be a substantial fraction. That is usually the right call for Pool-seq, because an ambiguously placed read contributes a read count to the wrong position and frequencies are read counts. But if your coverage reports from step 5 show much less depth than you sequenced for, this is the first place to look.

Duplicate removal happens just upstream (`samtools markdup -r`) and matters more here than in individual sequencing: a PCR duplicate is a second vote from a molecule that should only vote once, and in a frequency estimate every vote counts directly.

Full flag reference: [Alignment Filters](#alignment-filters).

### 2. Pileup filter (step 6)

```bash
bcftools mpileup -B -C 50 -q 30 -Q 30 -d 2000 -a AD,DP,SP,INFO/AD -Ou
```

| Flag | Parameter | Effect |
|---|---|---|
| `-q 30` | `variantCall.varQualMin` | Minimum **mapping** quality for a read to be counted |
| `-Q 30` | `variantCall.baseQualMin` | Minimum **base** quality for a base to be counted |
| `-C 50` | `variantCall.scaleMapQ` | Downgrades mapping quality for reads with excessive mismatches |
| `-d 2000` | `variantCall.maxDepth` | Caps reads considered per file per position |
| `-B` | fixed | Disables BAQ (base alignment quality) recalculation |
| `-a AD,DP,SP,INFO/AD` | fixed | Emits the allelic-depth fields everything downstream depends on |

`-d 2000` deserves attention on a pooled run. It is a per-file cap, and deep pooled libraries can exceed it. When they do, the read counts the frequencies are computed from are truncated, which biases estimates in a way nothing downstream will flag. Compare it against your step 5 coverage reports — see [maxDepth](#maxdepth).

`-B` is a deliberate choice for pooled data. BAQ downweights bases near indels to suppress false positives that arise from misalignment in a single diploid genome. In a pool, the same signal may be a genuine low-frequency indel, and BAQ's correction assumes a genotype model that does not apply. Disabling it keeps the raw evidence and leaves the decision to the cross-sample filter at stage 5.

### 3. Variant calling (step 6)

```bash
bcftools call -m -A -v -Ov
```

| Flag | Effect | Why it matters here |
|---|---|---|
| `-m` | Multiallelic caller | Handles sites with more than one alternate allele, which biallelic-only calling would collapse |
| `-A` | Keep **all** alternate alleles from the pileup | Without this, bcftools discards alternates it considers unlikely under a genotype model — exactly the low-frequency alleles a pool is meant to detect |
| `-v` | Variant sites only | Invariant sites are dropped |

`-A` is the flag that makes this a Pool-seq caller rather than a general one. The default behaviour prunes alternate alleles that no plausible genotype supports, which is sound for an individual and wrong for a pool, where a true allele at frequency 0.01 supports no genotype at all.

### 4. Major-allele normalisation (step 7)

`bin/MajorAlleleToRef.py` re-encodes the VCF so the **most-read allele is the reference**. It does not remove anything; it rewrites.

For each site it sorts the alleles by `INFO/AD` — the read count summed across every sample — and reorders `REF`, `ALT`, `INFO/AD`, `INFO/DP`, `FORMAT/AD` and `FORMAT/DP` to match. `DP` is recomputed as the sum of the reordered `AD`, so depth and allelic depth cannot disagree.

**Why do it at all.** The reference genome is one individual's assembly. There is no reason its allele should be the common one in your population, and when it is not, every frequency in that row is reported against a rare baseline. Two studies on the same species then report mirror-image frequencies for the same site. Normalising to the major allele makes rows comparable across samples, across runs and across projects.

**Two consequences worth knowing.**

The ordering is **cohort-wide**, not per-sample. `REF` is the allele most read across all samples combined. In an individual sample where the cohort-minor allele is locally dominant, that sample's frequency for `REF` will be below 0.5 — which is meaningful, not an error.

`FORMAT/GT` is set to `./.` on every genotype. A pool has no genotype, and leaving bcftools' diploid call in place would invite downstream tools to read it as one. Making it explicitly missing is the honest encoding. Keep it in mind if you point a genotype-based tool at these VCFs: it will find nothing, by design.

The script runs **twice** — once before the false-positive filter and again after it, because splitting and rejoining multiallelic records can change allele order.

### 5. False-positive filter (step 7)

This is the filter that makes the pipeline pool-aware, and the one most worth understanding before you change anything.

```bash
bcftools norm -m -  vcf                    # 1. split multiallelic sites into one line per ALT
| bcftools view -i "INFO/AD[1]>0"          # 2. drop alleles with no supporting read at all
| awk  …                                   # 3. count samples that clear their own threshold
| sed  '*' → 'X'                           # 4. mask the spanning-deletion allele
| bcftools norm -m+                        # 5. rejoin into multiallelic records
| sed  'X' → '*'
```

#### What the filter keeps

An alternate allele survives only if **both** hold:

`INFO/AD[1] > 0`
: The allele has at least one supporting read somewhere in the cohort.

At least `M` samples show it at or above **their own** threshold `S`
: Each sample is judged against the threshold for the pool it belongs to, not against a single number for the run.

where, for a given pool,

$$S = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}
\qquad
M = n_{\text{samples}} \times \text{sampleThreshold}$$

This is a **cross-sample corroboration** filter, not a frequency cutoff. A site is not kept because it is frequent; it is kept because several independent pools saw it. That distinction is what allows `S` to be set very low without drowning in sequencing error: errors are random and do not recur in the same place across libraries, whereas real low-frequency variants do.

#### Why this is not one bcftools expression

Earlier releases did the counting inside `bcftools view -i`, which can only apply **one** threshold across every sample. Per-pool sensitivity does not fit in that expression: a per-sample threshold would have to become a per-sample FORMAT field, annotated onto every record and stripped off again afterwards.

Doing the counting in `awk` instead buys a property worth more than the tidiness it costs. **Each threshold is bound to the sample's name, not to its column position.** A column that changes place — because you reordered `metadata.csv`, which you are free to do — still gets its own pool's threshold. Binding by position would have applied the wrong pool's threshold after a reorder and produced a perfectly ordinary-looking table.

It also fails loudly rather than guessing. If the VCF contains a sample column that your pool sizes do not mention, the filter stops rather than judging that column at some other pool's threshold.

#### What was applied, recorded in the VCF

Each filtered VCF carries a header line per pool, stating the size used and the threshold derived from it:

```text
##PoolSeqFlowPool=<ID=Sample1T1,PoolSize=50,Sensitivity=0.005>
```

These are provenance, written beside the data they were applied to. Note that the filtered VCFs are intermediates and most do not survive a completed run — the durable record of your pool sizes is `.poolseqflow_metadata`, kept beside the results.

#### Where S comes from

A pool of `poolSize` individuals at ploidy `diploidy` contains $\text{diploidy} \times \text{poolSize}$ chromosomes, so a single chromosome carries a frequency of $1 / (\text{diploidy} \times \text{poolSize})$. The extra factor of two puts `S` at **half** that — a true singleton clears the threshold with margin rather than sitting exactly on it, which matters because the observed fraction of a singleton is itself noisy.

| `poolSize` | `diploidy` | One chromosome is | `S` (threshold) |
|---|---|---|---|
| 10 | 2 | 0.0500 | 0.0250 |
| 25 | 2 | 0.0200 | 0.0100 |
| 50 | 2 | 0.0100 | 0.0050 |
| 100 | 2 | 0.0050 | 0.0025 |
| 200 | 2 | 0.0025 | 0.00125 |

Larger pools give a smaller `S`, so the filter admits rarer alleles — appropriately, since a larger pool really can contain rarer ones.

Each pool can be set to get its own row of that table. `param_poolSize` in `metadata.csv` can set the size per pool, and any pool without one falls back to the global `poolSize`. `diploidy` can be set per run rather than per pool, so a design mixing ploidies is split into runs — see [Sequences with a different ploidy](#sequences-with-a-different-ploidy).

#### Where M comes from

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

    At the default, an allele found in only one pool out of eight is discarded no matter how frequent it is in that pool — one sample does not reach the two the threshold requires. If private variation is what you are studying, lower `sampleThreshold` before your first run, not after. See [sampleThreshold](#samplethreshold).

#### Why the splitting and rejoining

`FORMAT/AD[:1]` indexes the **first** alternate allele. On a multiallelic record, a rare third allele would never be tested — it would simply ride along on whatever the second allele did. Splitting to one line per alternate (`norm -m -`) makes each allele stand on its own evidence; `norm -m+` puts the survivors back together.

The `*` → `X` substitution around the rejoin masks the spanning-deletion allele, which `norm -m+` does not handle in this position. It is restored immediately afterwards.

### 6. Depth and quality filter (step 7)

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

Alternative expressions, what each trades, and how to pick a value: [Depth and quality](#depth-and-quality).

### 7. SNP/INDEL split (step 7)

Two `vcftools` passes over the same input — `--remove-indels` and `--keep-only-indels` — produce a SNP VCF and an INDEL VCF. Nothing is discarded; every surviving site lands in exactly one of the two files, and each is converted to its own frequency table.

### 8. Frequency conversion (step 7)

No filtering. `bin/createDepthFile.sh` extracts `CHROM`, `POS`, `REF`, `ALT`, `INFO/AD` and per-sample `FORMAT/AD`, and `bin/depth2freq.awk` divides each allele's read count by the row's total to give a frequency. The output format is described in [Interpreting Results](#interpreting-results).

---

### Tuning the chain

Work from the outside in. A variant lost at stage 1 cannot be recovered by loosening stage 5.

| Symptom | Most likely stage | Parameter to examine |
|---|---|---|
| Far less depth than sequenced | 1 | `cleanBAM.mapq`, then duplicate rate in the step 5 reports |
| Depth plateaus at a round number | 2 | `variantCall.maxDepth` |
| Low-frequency alleles absent everywhere | 5 | `poolSize`, or `param_poolSize` for the pool in question, and `diploidy` |
| Low-frequency alleles absent from one pool only | 5 | That pool's `param_poolSize` — a size set too low raises its threshold alone |
| Alleles present in one pool only, absent from output | 5 | `filterFalsePositives.sampleThreshold` |
| Whole sites missing despite good depth | 6 | `vcffilter.minQUAL` |
| Almost every site gone after filtering | 6 | `vcffilter.minDP` — one under-covered sample removes sites for all of them |
| Multiallelic sites reduced to two alleles | 3 | `variantCall.callOptions` — confirm `-A` is still present |

Changing any of these invalidates existing outputs, and step 0 will stop the next run rather than mix results. That is covered in [Design Decisions](#the-run-refuses-to-mix-settings).

## Interpreting Results
<!--@ page: interpreting-results -->

The pipeline's product is a pair of tab-separated allele frequency tables. This page describes their format precisely, works through an example, and covers the mistakes that are easy to make when reading them.

### The frequency tables

Two files are written to `Output/Frequencies/`, named after `vcf.fileName`:

| File | Contents |
|---|---|
| `<name>_snp_freq.tsv` | Every surviving SNP site |
| `<name>_indel_freq.tsv` | Every surviving insertion or deletion site |

With the default `vcf.fileName = 'Test'` those are `Test_snp_freq.tsv` and `Test_indel_freq.tsv`.

#### Columns

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

Sample columns appear in `metadata.csv` row order — see [Row order decides column order](#row-order-decides-column-order).

#### One row per allele

This is the part that surprises people. A site does not occupy one row; it occupies **one row per allele, including the reference allele.** A biallelic SNP produces two rows, a triallelic site three.

`REF` is constant within a site and `ALLELE` varies. The reference row is the one where the two are equal.

#### The header says `TOTAL_AD`, the column holds a frequency

The fifth column is derived from `INFO/AD`, the cohort-wide allelic depth, and the conversion divides it by the row total exactly as it does for the sample columns. The header label is carried over from the intermediate depth file and was not renamed. Read it as *overall frequency*, not as a depth.

#### Worked example

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

### Reading the tables correctly

**`REF` is the major allele, not the reference genome's base.** Step 7 re-encodes each site so the most-read allele becomes `REF` ([why](#4-major-allele-normalisation-step-7)). This makes rows comparable across samples and runs, but it means `REF` will often disagree with the FASTA you supplied. If you need the assembly's base, take it from the assembly.

**"Most-read" is decided across the whole cohort.** A sample where the cohort-minor allele dominates locally will show a `REF` frequency below 0.5. That is a real signal, not a defect.

**A missing row means the variant did not survive the chain, not that it is absent.** Sites are removed at eight points between the FASTQ and the table. Before concluding a variant is absent from your population, check it against [The Filter Chain](#tuning-the-chain) — in particular the cross-sample requirement at stage 5, which discards alleles seen in too few pools regardless of how frequent they are in those pools.

**Frequencies are read proportions, not estimates with error bars.** The table reports the fraction of reads carrying each allele. Sampling error in that fraction depends on depth at the position and on the pool size, and the pipeline does not propagate it. If your analysis needs uncertainty, compute it from the depth — which is why the VCFs retain `AD` and `DP`.

**There is no genotype to read.** `FORMAT/GT` is `./.` throughout, deliberately. Genotype-based tools pointed at these VCFs will find nothing.

### The VCF files

`Output/VCF/` holds the call sets. After a complete run:

| File | What it is |
|---|---|
| `<name>.vcf` | Raw output of step 6 — every called site, no step 7 filtering, original reference encoding |
| `<name>_annotated.vcf` | SnpEff annotation of the **raw** call set, if `annotate = true` |

Those two are the whole of it. Every VCF step 7 produces — `_sort`, `_sort_fp`, `_sort_fp_dq`, and the split `_snp` and `_indel` files — is consumed by the next process and deleted, so none of them survives a finished run. See [Steps delete their own inputs](#steps-delete-their-own-inputs).

**The filtered call set is therefore not kept as a VCF.** What it becomes is the frequency tables. If you need the filtered sites in VCF form, the raw call set plus the positions in the tables is what you have to work from.

!!! note "Annotation is applied to the unfiltered call set"

    Step 8 runs on the output of step 6, in parallel with the frequency branch rather than after it. So `<name>_annotated.vcf` contains sites that the step 7 filters removed, and its allele encoding is the original reference-based one, not the major-allele normalised one. To attach annotations to your frequency tables, join on `CHROM`/`POS` and expect unmatched rows on the annotation side.

### The reports

`Output/Reports/` collects everything generated along the way.

| Path | Produced by | Useful for |
|---|---|---|
| `Alignment/<sample>_alignment_report.txt` | `bamtools stats` | Mapping rate, duplicate rate, paired-end statistics |
| `Coverage/<sample>_coverage_report.txt` | `samtools coverage` | Per-contig depth and breadth — **check this against `variantCall.maxDepth`** |
| `Fastqc/<sample>/` | FastQC | Raw, trimmed and clipped read quality |
| `Trimming/<sample>/` | Trim Galore | How much was removed, and which adapter was detected |
| `snpeff_summary.html` | SnpEff | Variant effect summary, if annotation ran |
| `PoolSeqFlow_pipeline_report.html` | Nextflow | Per-task resource usage |
| `PoolSeqFlow_pipeline_timeline.html` | Nextflow | Where wall-clock time went |
| `PoolSeqFlow_pipeline_trace.txt` | Nextflow | Machine-readable task trace |
| `PoolSeqFlow_pipeline_dag.html` | Nextflow | Workflow graph |

`run_parameters.txt` is **not** in here — it sits one level up, at the root of `Output/`, beside the results rather than among the reports about them. It is a readable record of the analysis parameters these outputs were built from.

The two worth reading on every run are the coverage report and `run_parameters.txt` — the first tells you whether the depth cap bit, the second tells you exactly what settings produced the files sitting next to it.

If you ran a table of several runs, the four Nextflow reports describe the whole invocation rather than any one run, and are written once under `Output/All_Runs/Reports/`.

### A quick sanity pass

After a run finishes, four checks catch most problems:

1. **Sample columns.** Does the table have the number of columns you expect, in the order you laid out in `metadata.csv`? A count lower than expected means rows were merged by a shared `RG_Sample` ([why](#rg_sample-decides-what-counts-as-a-sample)).
2. **Coverage against the cap.** If `samtools coverage` reports mean depth near `variantCall.maxDepth` (default 2000), the pileup was truncated and frequencies are biased.
3. **Row counts.** Compare the site count in `<name>.vcf` with the distinct positions that reached the tables — `tail -n +2 <name>_snp_freq.tsv | cut -f1,2 | sort -u | wc -l`, and the same for the indel table. A very large drop points at the cross-sample filter; check `sampleThreshold` against your sample count in [the table above](#where-m-comes-from).
4. **Column sums.** Frequencies within a site should sum to 1 in every column.

# Configuration
<!--@ section: configuration -->

Everything is set in `parameters.config`. There are no command-line overrides ([why](#configuration-is-a-file-never-a-flag)).

This page sorts the parameters by what they actually affect, which is the distinction that matters most: some change your numbers, some change only where files land or how fast the run goes, and some are computed for you and should not be edited at all.

### Three kinds of parameter

#### Parameters that change your results

Change one of these and your output changes. Step 0 records them and **refuses to run** if they differ from what produced your existing outputs, so that one folder never holds results from two settings.

| Parameter | Effect | Page |
|---|---|---|
| `poolSize` | Individuals per pool; sets the minimum credible allele frequency. Can be set per pool in `metadata.csv` | [Variant Calling](#poolsize-and-diploidy) |
| `diploidy` | Ploidy; same threshold. Can be set per run | [Variant Calling](#poolsize-and-diploidy) |
| `filterFalsePositives.sampleThreshold` | Fraction of samples that must support an allele | [Variant Calling](#samplethreshold) |
| `bcftools.*` | Pileup and calling behaviour, including the depth cap | [Variant Calling](#variant-calling) |
| `vcffilter.minDP`, `vcffilter.minQUAL` | Post-call depth and quality filtering | [Variant Calling](#depth-and-quality) |
| `cleanBAM.filter`, `cleanBAM.required`, `cleanBAM.mapq` | Which alignments reach the pileup | [Alignment Filters](#alignment-filters) |
| `cutadapt.at_gc_error` | Composition tolerance driving the clip points | [Trimming & Clipping](#trimming-clipping) |
| `trim_galore.quality`, `.autodetect`, `.adapter1/2` | What is trimmed off the reads | [Trimming & Clipping](#trimming-clipping) |
| `annotate`, `gffFile` | Whether step 8 runs and against what | [Pipeline Steps](#step-8-annotate-variants) |
| `metadata.csv` | Which FASTQ pairs are one pool, each pool's size, and column order — the `RG_*` and `param_*` columns only | [Metadata](#metadata) |
| The run table | Whatever it varies, per run. Every column in it is a parameter | [Multi-run](#multi-run) |

#### Parameters that change speed, not answers

Safe to tune between runs. Step 0 does not track them, precisely because they cannot change a result.

| Parameter | Effect | Page |
|---|---|---|
| `threads` | Cores a single task may use; drives every tool's thread count | [Resources](#resources) |
| `memory` | Memory ceiling for a single task | [Resources](#resources) |
| `java.heapSize` | JVM heap for FastQC and SnpEff | [Resources](#java) |
| `fastqc.memory` | FastQC's own memory setting, in megabytes | [Resources](#java) |
| `software.*` | Paths to executables, if not using the conda environment | [below](#using-system-tools) |

#### Parameters that change where files go

| Parameter | Effect |
|---|---|
| `mainDir` | Working directory — your inputs, `work/`, and everything in progress. Where you run from |
| `storageDir` | Permanent storage — the finished results. Must be a different path from `mainDir` |
| `dataSource` | Subdirectory of `mainDir` holding the FASTQs |
| `readPattern` | Glob matching paired FASTQs; needs a `{1,2}` group |
| `referenceFile`, `gffFile` | Input filenames within `mainDir/Reference` |
| `metadataFile` | Name of the sample table, in `mainDir` |
| `multiRun`, `multiRunFile` | Whether to read a run table, and what it is called |
| `vcf.fileName` | Base name for the VCFs and frequency tables |

#### Do not edit: derived values

A large part of `parameters.config` is computed. The `cores` block derives every tool's thread count from `threads`; the `dir` block builds every path from `mainDir` and `storageDir`; `filterFalsePositives.sensitivity` is computed from `poolSize` and `diploidy`; `snpEff.db` is derived from `gffFile`.

Editing these by hand breaks the invariant that makes the pipeline predictable — that one number sizes the run, and one pair of paths places everything. Change the input, not the derivation.

The template ships these lines commented out, and uncommenting one is supported rather than forbidden: a derived value you set by hand is used exactly as written, and nothing is derived from its inputs any more. Pin `variantCall.mpileupOptions` and `variantCall.maxDepth` stops meaning anything for that run. That is a reasonable thing to want when you need full control of a command line — it is only a trap when it happens by accident.

Where the pipeline can tell, it says so. The verification step at the beginning of a run reports when your trimming options have been pinned rather than derived, and if you are using a run table it names any column that sets a computed value directly.

### What to decide before your first run

In rough order of how expensive it is to get wrong:

1. **`metadata.csv`** — which FASTQ pairs share an `RG_Sample`. Wrong here means valid results that answer a different question, and fixing it invalidates every BAM. [→](#rg_sample-decides-what-counts-as-a-sample)
2. **`poolSize` and `diploidy`** — these set the frequency floor. `poolSize` can be given per pool in `metadata.csv`, and `diploidy` applies to a whole run. [→](#poolsize-and-diploidy)
3. **`filterFalsePositives.sampleThreshold`** — decides whether alleles seen in few pools survive. The default removes them. [→](#samplethreshold)
4. **`variantCall.maxDepth`** — check it against the depth you sequenced for. [→](#maxdepth)
5. **`threads`** — must fit the machine, or the run fails at submission. [→](#resources)

Changing any of items 1–4 after outputs exist means deleting those outputs. That is enforced, not advisory.

### Using system tools

The `software` block maps each tool to a command:

```groovy
software {
    samtools = 'samtools'
    bcftools = 'bcftools'
    // …
}
```

Replacing a command with an absolute path makes the pipeline use a system installation instead of the conda environment. This is supported but not recommended: the environment pins exact builds because Pool-seq results depend on the precise behaviour of the pileup and filtering tools, and a version mismatch will not announce itself. Use it to work around a genuine packaging problem, not as a default.

## Resources
<!--@ page: resources -->

Two values size an entire run:

```groovy
threads = 8          // cores a single task may use
memory  = '24 GB'    // memory ceiling for a single task
```

Every tool's thread count is derived from `threads`. **Do not set the per-tool counts by hand** — they live in the `cores` block, which exists to be computed, not edited.

### The ladder

| `threads` | Trim Galore `--cores` | actual threads | BWA `-t` | cutadapt | FastQC `-t` | SAMtools `-@` | Java GC |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 1 | 1 | 1 | 1 | 0 | 1 |
| 2 | 1 | 1 | 2 | 2 | 2 | 1 | 2 |
| 4 | 1 | 1 | 4 | 4 | 2 | 1 | 2 |
| 6 | 2 | 6 | 4 | 4 | 2 | 1 | 2 |
| 8 | 4 | 8 | 8 | 8 | 2 | 1 | 2 |
| 12+ | 8 | 12 | 8 | 8 | 2 | 1 | 2 |

Three details explain the shape of that table.

**Tools are quantised to where their scaling flattens.** BWA and cutadapt take the largest power of two at or below `threads`, capped at 8. Past that point the published scaling for these tools returns very little, so the cores are better spent on another task. FastQC is given two because step 2 only ever hands it a pair of files, and one thread per file is all it can use.

**Trim Galore's `--cores N` really runs N+4 threads** — N workers, two decompressors, a batcher and a writer. The ladder picks the largest N whose *full footprint* still fits in `threads`, which is why 4 cores yields `--cores 1` rather than `--cores 4`. The `--cores 1` case is the exception: it bypasses the worker pool entirely and is genuinely single-threaded.

**SAMtools' `-@` counts additional threads**, so `0` means one core and `1` means two.

### How the numbers reach the tools

Each process declares what it needs with the `cpus` directive and passes that same number to its tool as `task.cpus`, so there is exactly one value per task and nothing can drift:

```groovy
process Align {
    cpus { params.cores.bwa }
    script:
    """
    bwa mem -t ${task.cpus} ...
    """
}
```

| Process | Reserves | At `threads = 8` |
|---|---|---|
| `TrimReads` | `params.cores.trimTotal` | 8 |
| `ClipReads` | `params.cores.cutadapt` | 8 |
| `Align` | `params.cores.bwa` | 8 |
| `SortCleanBam` | `params.cores.samtools + 1` | 2 |
| `BuildSnpEffDb`, `AnnotateVariants` | `params.cores.javaGc` | 2 |
| every other step | *(single-threaded)* | 1 |

!!! note "`fixmate` is a deliberate exception"

    Inside `SortCleanBam`, every stage of the streamed pipeline is given `task.cpus - 1` except `samtools fixmate`, which gets the run's `threads - 1`. That is intentional: fixmate's algorithm scales further than the sort and markdup stages around it, so it is allowed more of the machine than the task reserves.

This is more than bookkeeping. **Nextflow decides how many tasks to run at once by comparing `cpus` against the resources available**, so an under-declared task leads to oversubscription — the machine runs more work than it thinks it is. Overriding `cpus` in a profile automatically changes what the tool is told, because both come from `task.cpus`.

`TrimReads` is the one place the number is not passed through unchanged. Its reservation is Trim Galore's *footprint*, so the script maps back to the worker count:

```groovy
cpus { params.cores.trimTotal }                  // 8 at threads = 8
trim_cores = task.cpus > 4 ? task.cpus - 4 : 1   // -> --cores 4
```

Reserving the worker count instead would understate the task by four threads. The guard covers `--cores 1`, which is genuinely single-threaded.

### `threads` must fit the machine

Because tasks reserve what they really use, a request larger than the available cores fails immediately rather than quietly oversubscribing:

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

Set `threads` to the cores you actually have — on HPC, the size of one node.

Note the consequence on a small machine. At `threads = 8`, a single `TrimReads` task reserves all eight, so samples are trimmed one at a time instead of three at once. That is slower in wall-clock than running three concurrently at twelve threads each on eight cores — and it is also the only version of that arrangement which respects the machine. See [Threads are budgeted, not divided](#threads-are-budgeted-not-divided).

### `resourceLimits` is a ceiling, not an allocation

`nextflow.config` caps requests using the same two parameters:

```groovy
process {
    resourceLimits = [ memory: params.memory, cpus: params.threads ]
}
```

If a task requests more than this, Nextflow reduces the request before submitting it, which prevents a job that no node can satisfy from queueing forever. It does **not** reserve anything and does **not** limit concurrency on its own — that is what `cpus` does. Set `threads` and `memory` to match the node you are running on.

### Java {: #java }

Two settings govern the JVM tools (FastQC, SnpEff):

```groovy
java {
    heapSize = '-Xmx8g'    // passed via _JAVA_OPTIONS
}

fastqc {
    memory = 2048          // megabytes, as a plain number
}
```

`fastqc.memory` must be a bare number — FastQC rejects `2G`.

`-XX:ParallelGCThreads` is **not** set here. It is applied per process from `task.cpus`, so the JVM always gets the cores that task actually reserved rather than a figure fixed in the config.

### Choosing values

| Situation | `threads` | `memory` |
|---|---|---|
| Laptop or workstation | Physical cores, minus one or two if you want the machine usable | Comfortably under total RAM — one task can use all of it |
| HPC node, exclusive | Cores on one node | Node memory |
| HPC node, shared | Cores your allocation guarantees | Memory your allocation guarantees |
| Debugging a failure | `1` | Generous |

`threads = 1` forces every tool to a single core, which makes a failing run reproducible and its logs readable. It is slow, but it removes concurrency as a variable.

Neither value can change your results, which is exactly why the change guard does not track them. Tune them freely between runs — you will not be asked to delete anything.

## Trimming & Clipping
<!--@ page: trimming -->

Step 2 runs in two stages: Trim Galore removes adapters and low-quality tails, then a second pass clips a fixed number of cycles from both ends based on what FastQC measured about base composition. The second stage is unusual and worth understanding before you change its one tunable.

### Stage 1 — Trim Galore

```groovy
trim_galore {
    quality    = 25
    autodetect = true
    adapter1   = ''
    adapter2   = ''
}
```

The assembled command is `--fastqc --paired --retain_unpaired -q 25`, plus adapters and `--cores`.

| Setting | Meaning |
|---|---|
| `quality` | Phred score below which bases are trimmed from the 3′ end |
| `autodetect` | `true` — no adapter is passed and Trim Galore detects it (Illumina, Nextera or smallRNA) |
| `adapter1`, `adapter2` | Used only when `autodetect = false`, and then **both** are required |

`--retain_unpaired` keeps reads whose mate was discarded, in `Output/Unpaired/`. They are not used downstream — step 4 requires properly-paired alignments — but they are kept so you can see what was lost rather than having it disappear.

#### When to turn autodetect off

Autodetection samples the first reads of a file and matches against known adapter sequences. Set `autodetect = false` and supply both sequences when:

- your library used a custom or non-standard adapter that will not be recognised;
- the trimming reports in `Output/Reports/Trimming/` disagree between samples of the same library, which means detection is not landing on a consistent answer;
- you need the run to be exactly reproducible against a specific adapter regardless of what the first reads happen to contain.

Setting only one of `adapter1`/`adapter2` is not valid — the option string is built from both.

#### Per-sample adapters

Those settings apply to the whole run. One library prepared with a different adapter does not need a project of its own: `param_adapter1` and `param_adapter2` in `metadata.csv` can override them for a single row.

```csv
SampleID,RG_Sample,param_adapter1,param_adapter2
Sample1T1Rep1,Sample1T1,,
Sample1T1Rep2,Sample1T1,AGATCGGAAGAGC,AGATCGGAAGAGC
```

A row that sets both replaces the run's adapter setting for that sample, whatever `autodetect` is set to — the adapters you name are used. A row that leaves both blank uses the run's settings, which is the ordinary case.

Give both or neither. One adapter on its own is a setting that cannot be acted on, so it is refused rather than half-applied.

There is one combination the pipeline cannot honour, and it stops rather than guessing: if you have pinned `trim_galore.options` by hand, that string is used exactly as written and a per-sample adapter has nowhere to go. The run stops, names the samples that set adapter columns, and asks you to remove either the pin or the columns.

### Stage 2 — Composition-aware clipping {: #composition-aware-clipping }

```groovy
cutadapt {
    at_gc_error = 0.025
    min_length  = 50     # see the note below - not currently applied
    options     = ""
}
```

Rather than clipping a fixed number of bases, the pipeline reads what FastQC measured and derives the clip points per sample.

#### What it measures

In an unbiased library, each cycle should show roughly equal A and T, and roughly equal G and C. Departures at the read ends are a well-known artefact — residual adapter, priming bias, and end-of-read quality decay all show up as a composition skew before they show up as a base-quality failure.

For Pool-seq that matters more than usual. Allele frequencies are read counts, so a systematic bias in which base gets called at a given cycle propagates directly into the frequency estimate. Cycles where composition has not settled are cycles you cannot trust to count alleles.

#### The algorithm

For each read file, step 2 parses the `>>Per base sequence content` block of `fastqc_data.txt` and keeps the cycles where **both** ratios sit inside the tolerance:

$$1 - \varepsilon \;\le\; \frac{A}{T} \;\le\; 1 + \varepsilon
\qquad
1 - \varepsilon \;\le\; \frac{G}{C} \;\le\; 1 + \varepsilon$$

with $\varepsilon$ = `at_gc_error`. At the default of `0.025` that is a ratio between 0.975 and 1.025. The first and last qualifying cycle give a usable range per read — `Min1`–`Max1` for R1 and `Min2`–`Max2` for R2 — and the two are combined:

```text
Clip5           = max(Min1, Min2)
readLengthLimit = max(Max1 - Clip5, Max2 - Clip5)
```

then applied symmetrically:

```bash
cutadapt -u Clip5 -U Clip5 -l readLengthLimit -o R1_clipped.fq.gz -p R2_clipped.fq.gz
```

`-u`/`-U` remove `Clip5` bases from the 5′ end of R1 and R2; `-l` truncates both to the same length. FastQC then runs again on the result, so you can check the clipping did what it was supposed to.

#### Two deliberate asymmetries

**Both mates get the same treatment.** `Clip5` is the *larger* of the two 5′ bounds and the length limit applies to both files, so R1 and R2 come out the same length. The alternative — clipping each mate to its own measured range — would leave mates of different lengths for no downstream benefit.

**The length limit is the more permissive of the two.** Because `readLengthLimit` takes the `max`, a read whose own usable range ended earlier is kept to the longer mate's length, retaining a few cycles past its own bound. This favours read length over strict adherence to the tolerance. If that trade is wrong for your data, tighten `at_gc_error` — which pulls both bounds in — rather than trying to change the rule.

#### When it refuses to run

The clip range calculation fails loudly rather than guessing:

| Exit | Cause |
|---|---|
| `3` | The FastQC table did not have the expected `A`/`T`/`G`/`C` header columns |
| `4` | **No cycle** fell inside `at_gc_error` |

Both produce:

```text
CLIPPING READS <sample>: ERROR: no usable clip range in <file>
CLIPPING READS <sample>: exit 3 = unexpected FastQC header; 4 = no cycle within at_gc_error (0.025)
```

Cycles where T or C is zero are skipped rather than divided by — that division would abort awk mid-pipeline, which plain `set -e` does not catch, and the bounds would be silently derived from a truncated table.

#### Tuning `at_gc_error`

This is the only value here you would normally change, and it trades data volume against composition purity.

| Direction | Effect | Risk |
|---|---|---|
| **Tighter** (e.g. `0.01`) | Fewer cycles qualify, so more is clipped from both ends | Exit 4 — no cycle qualifies and the run stops. Shorter reads map less uniquely |
| **Looser** (e.g. `0.05`) | More cycles qualify, so reads stay longer | Retains cycles with real composition bias, which feeds into your frequencies |

Exit 4 on a library that is otherwise fine usually means the tolerance is too tight for its natural composition — GC-skewed genomes will not produce a G/C ratio near 1 anywhere. In that case raising `at_gc_error` is the correct response, not a workaround.

Check the before/after FastQC reports in `Output/Reports/Fastqc/<sample>/` after changing it. The clipped-read report is the one that tells you whether the value you chose did what you wanted.

!!! note "`min_length` is off by default"

    `cutadapt.options` is empty, so no minimum read length is enforced at this stage and changing `min_length` on its own has no effect. The template carries the line ready to uncomment:

    ```groovy
    options        = ""
    // options     = "-m ${params.cutadapt.min_length}"
    ```

    Swap the two and reads shorter than `min_length` are discarded after clipping. This is an analysis-affecting change — existing trimmed output has to be removed before it takes effect.

    Mind the order the two settings apply in. Cutadapt truncates to the computed read length limit **first**, and only then drops reads shorter than `min_length` — so a `min_length` above that limit discards every pair, and cutadapt still exits 0. That would leave empty FASTQ files which the existence checks would happily treat as a finished step, for good. The pipeline checks for it and stops with the two numbers in the message rather than letting it happen. The limit is computed per sample from its own FastQC report, so the value that is safe for one library is not automatically safe for another.

### What this step writes

| Path | Contents |
|---|---|
| `Output/Trimmed/<sample>/` | `*_val_1.fq.gz`, `*_val_2.fq.gz` (Trim Galore) and `*_clipped.fq.gz` (cutadapt) |
| `Output/Unpaired/<sample>/` | Reads whose mate was discarded |
| `Output/Reports/Fastqc/<sample>/` | FastQC on trimmed and on clipped reads |
| `Output/Reports/Trimming/<sample>/` | Trim Galore reports (`.txt` and, on 2.x, `.json`) |

The trimmed reads are **deleted** once clipping has consumed them ([why](#steps-delete-their-own-inputs)); the clipped reads are what step 3 aligns.

## Metadata
<!--@ page: metadata | nav: Metadata -->

`metadata.csv` sits in `mainDir` and carries one row per pair of FASTQ files. It is the file that says what your samples **are**: which pool each belongs to, how many individuals went into that pool, and whatever else the experiment needs recorded.

Three of its columns change your results. The rest are yours, and the pipeline never interprets them.

```csv
SampleID,RG_Sample,RG_Library,RG_Platform,RG_PlatformUnit,param_poolSize,population,timepoint,replicate
Sample1T1Rep1,Sample1T1,Lib1,ILLUMINA,Unit1,50,Pop1,T1,1
Sample1T1Rep2,Sample1T1,Lib1,ILLUMINA,Unit1,50,Pop1,T1,2
Sample1T2Rep1,Sample1T2,Lib1,ILLUMINA,Unit1,50,Pop1,T2,1
Sample1T2Rep2,Sample1T2,Lib1,ILLUMINA,Unit1,50,Pop1,T2,2
Sample2T1Rep1,Sample2T1,Lib1,ILLUMINA,Unit1,40,Pop2,T1,1
Sample2T1Rep2,Sample2T1,Lib1,ILLUMINA,Unit1,40,Pop2,T1,2
Sample2T2Rep1,Sample2T2,Lib1,ILLUMINA,Unit1,40,Pop2,T2,1
Sample2T2Rep2,Sample2T2,Lib1,ILLUMINA,Unit1,40,Pop2,T2,2
```

*Eight FASTQ pairs, four distinct `RG_Sample` values — this file produces a VCF with **four** columns: `Sample1T1`, `Sample1T2`, `Sample2T1`, `Sample2T2`. Each pool was sequenced twice, so its two rows share an `RG_Sample` and repeat that pool's `param_poolSize`. The last three columns are the author's own.*

`PoolSeqFlow init` does not write this file, because its content is your experiment and a copied one would describe someone else's. It leaves `metadata.csv.example` beside you to write it from — the same table with every column explained in comments. Blank lines and lines beginning with `#` are ignored, so those comments can stay in the file you keep. A value containing a comma must be quoted: `"Pop1, coastal"`.

### The four kinds of column

The **name** of a column is what decides how it is treated. There is no second schema to keep in step with it.

| Column | What it is |
|---|---|
| `SampleID` | **Required and unique.** Matched against the sample name `readPattern` takes from your FASTQ filenames, and becomes the read group's `ID` in the BAM |
| `RG_*` | A read-group tag. Eight are known, listed below. A blank cell omits that tag rather than writing an empty one |
| `param_*` | A setting from `parameters.config`, overridden for these samples only. Three are known: `param_poolSize`, `param_adapter1`, `param_adapter2`. A blank cell means "use the global value" |
| anything else | Yours. Population, timepoint, replicate, phenotype, collection site, a measurement from another experiment — whatever this study needs recorded |

**`RG_` and `param_` are closed lists, and an unrecognised one is refused rather than ignored.** For `RG_` that stops a typo quietly losing a tag. For `param_` the reason is sharper: a `param_` column the pipeline did not recognise would be a setting you had written down, could see in your own file, and that was never applied to anything.

Everything else is free. **You can add, remove and edit your own columns without invalidating results you already have** — the change guard does not look at them. That freedom is a large part of why the file exists. It holds for now; once the analysis layer arrives, the columns it reads will begin to matter.

#### The read-group tags

| Column | SAM tag | Meaning |
|---|---|---|
| `RG_Sample` | `SM` | The pool. **Decides VCF columns** — see [below](#rg_sample-decides-what-counts-as-a-sample) |
| `RG_Library` | `LB` | Library identifier |
| `RG_Platform` | `PL` | Sequencing platform, e.g. `ILLUMINA` |
| `RG_PlatformUnit` | `PU` | Platform unit — flowcell, lane |
| `RG_Description` | `DS` | Free text |
| `RG_Center` | `CN` | Sequencing centre |
| `RG_Date` | `DT` | Run date, ISO 8601, e.g. `2024-03-07` |
| `RG_FlowOrder` | `FO` | Flow order |

You never write the two-letter tags yourself; the prefix is what marks a column as one. `RG_Sample` is optional and defaults to `SampleID`, which makes every row its own pool — what you want when each sample was sequenced once.

**Every `SampleID` must appear exactly once.** A row is looked up by it and only the first match would be read, so a repeat would quietly give a sample the wrong tags and produce a perfectly valid BAM that nothing downstream could flag. The run stops and lists the offending values — along with every other problem in the file, reported together with line numbers rather than one at a time.

Line endings are not your problem. The file is parsed as CSV, so a file saved from Excel on Windows is read correctly as it stands, and **nothing rewrites the file you wrote**.

### `RG_Sample` decides what counts as a sample

`SampleID` identifies each FASTQ pair, but **`RG_Sample` determines the samples in your variant calls.** BCFtools names VCF columns after the `SM` tag, and any read groups sharing a value are pooled into a single column.

| `RG_Sample` values in `metadata.csv` | Resulting VCF columns |
|---|---|
| `Sample1`, `Sample2`, `Sample3` | `Sample1` `Sample2` `Sample3` |
| `Population1`, `Population1`, `Sample3` | `Population1` `Sample3` |

**Give every pool its own `RG_Sample`** when you want them analysed separately. This is what most runs want, and it is the safe default — and it is what you get by leaving the column out, since it falls back to `SampleID`.

**Share an `RG_Sample` deliberately** when several FASTQ pairs are really the same biological pool:

- **One pool sequenced more than once** — split across lanes or runs to reach the depth Pool-seq needs. Each run arrives as its own FASTQ pair, but they describe one set of individuals, and the allele frequencies are only correct once the reads are combined.
- **Technical replicates** of the same library that you want treated as one observation rather than compared with each other.

Because merging happens at variant calling, it changes the numbers: read depths add together and each frequency is computed across the pooled reads. Leaving one pool split across two `RG_Sample` values instead gives you **two under-powered estimates of the same thing** — which is easy to do by accident, since the FASTQ files look like two ordinary samples.

The pooling that was worked out is printed before any compute is spent, so a mistake here is visible in seconds rather than in a result months later.

!!! warning "This interacts with the cross-sample filter"

    Merging changes the sample count, and the false-positive filter requires an allele to appear in a *fraction* of samples. Eight pairs as eight samples require two supporting samples; the same eight merged into four require one. Deciding `RG_Sample` is therefore also deciding how strict your filtering is — see [The Filter Chain](#where-m-comes-from).

### Pool size belongs to the pool

`param_poolSize` is how many individuals went into a pool, and it sets that column's detection limit:

$$S = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}$$

A pool of 10 and a pool of 500 have very different limits, so giving the whole run one number judges the small pool at the large one's resolution. The column exists so each pool can be judged at its own — see [Where S comes from](#where-s-comes-from).

Because the size describes the **pool** rather than the row, two rules follow:

- **Rows sharing an `RG_Sample` must give the same value.** They are one pool; they cannot have been made from two different numbers of individuals.
- **A blank cell means the global `poolSize`, not agreement.** So a pool with one row filled in and one row blank is a disagreement, and is refused rather than resolved by guessing which was meant.

Leave the column out entirely and every pool uses the global `poolSize` from `parameters.config`, which is the right answer when your pools really are all the same size.

The threshold each column was filtered at is recorded in the filtered VCF's header. Those VCFs are intermediates and do not survive a completed run — the durable record is `.poolseqflow_metadata`, kept beside the results.

### Adapter overrides

`param_adapter1` and `param_adapter2` override the run's adapter settings for one row. Give both or neither. They are covered with the rest of trimming in [Per-sample adapters](#per-sample-adapters).

### Row order decides column order

**The order of the rows in `metadata.csv` is the order of the sample columns** in the VCF and in the frequency tables. Put the rows in whatever order you want to read your results in — treatment before control, or by time point — and the output follows.

```csv
SampleID,RG_Sample,RG_Library,RG_Platform
Sample3,Sample3,Lib1,ILLUMINA          # -> first column
Sample1,Sample1,Lib1,ILLUMINA          # -> second column
Sample2,Sample2,Lib1,ILLUMINA          # -> third column
```

When several rows share an `RG_Sample`, the merged column appears where the **first** of those rows sits.

Reordering rows only moves columns; it never changes a value. Nothing else about the file is positional.

This exists because the alternative is worse. `collect()` alone emits BAMs in task-completion order, so whichever sample finished first landed first on the bcftools command line — and three consecutive runs on identical input gave three different column orders. Sorting on the file path is no better, since Nextflow's paths begin with a random work-directory hash. Row order is the only ordering that is both stable and meaningful.

### Editing `metadata.csv` after a run

Completed steps are skipped by looking for their output files, not by checking what produced them. So once this file has been consumed, editing it does **not** update anything that already exists — the tags are inside the BAMs, the column order is inside the VCF, and the pool sizes are inside the filter that produced the tables.

The analysis-affecting part of the file is recorded the first time it is used and compared on every later run. **If it has changed, the run stops before any work happens** and names what is now stale. How much that is depends on what you changed:

| What you changed | What it invalidates | Delete and rerun |
|---|---|---|
| A read-group tag value | The BAMs, and everything called from them | `Output/Ready/`, `Output/VCF/`, `Output/Frequencies/` |
| Row order only | The VCF sample column order | `Output/VCF/`, `Output/Frequencies/` |
| `param_poolSize` only | The false-positive filter's output, and nothing before it | `Output/Frequencies/` and the filtered VCFs |
| One of your own columns | Nothing | — |

The pool-size row is the one worth noticing. A changed pool size moves a threshold inside step 7, and step 7's input is the called VCF — so the BAMs and the call set are still valid and **you are not asked to delete them.** Re-running redoes the filtering and the tables, which is minutes rather than hours.

Deleting what is named is what clears the check; the edit becomes the new baseline on the next run. Or discard everything and start over with `PoolSeqFlow reset`.

The record is `.poolseqflow_metadata`, kept beside the results it describes. It holds only the read-group tags, the pool sizes and the row order — never your own columns, which is why the last row of that table says nothing. Line endings and trailing whitespace are ignored when comparing; row order is not.

### Checklist

Before your first run:

- [ ] One row per FASTQ pair, no `SampleID` repeated
- [ ] Every `SampleID` matches a sample name `readPattern` will find
- [ ] `RG_Sample` shared only where pairs are genuinely the same pool
- [ ] `param_poolSize` the same on every row of a pool, or absent everywhere
- [ ] Rows in the order you want your result columns
- [ ] Any column of your own you will want later — adding them now costs nothing, and adding them afterwards costs nothing either

## Multi-run
<!--@ page: multi-run | nav: Multi-run -->

Sometimes one set of reads needs analysing more than once: against two reference genomes, under three trimming stringencies, at a range of filter settings. A **run table** describes those analyses in one file, and one invocation carries them all out.

The reason to do it this way rather than copying the project is that the runs have most of their work in common. Two runs that differ only in filter thresholds share every step up to variant calling, and that work is done **once** rather than once per run.

### Turning it on

```bash
PoolSeqFlow init_multi
```

in a new project, or in an existing one set it yourself:

```groovy
multiRun     = true
multiRunFile = 'runs.csv'
```

`init_multi` also copies `multi-run.csv.example` into the project. It does not write the table: the runs, and the parameters that differ between them, are the whole content of that file, and only you know them.

### The run table

Four rules, and they are all of them.

**One column must be `RunID`.** It names the run and becomes a directory, so keep it to letters, digits, dot, dash and underscore.

**Every other column is a parameter name, spelt exactly as `parameters.config` spells it, with no `params.` prefix.** Nested ones are dotted: `trim_galore.quality`, `variantCall.maxDepth`. Any parameter may be varied, including ones the pipeline normally computes for itself. A column that does not name a parameter is refused rather than ignored — that is a typo, not a preference.

**A blank cell means "take it from `parameters.config`".** That is what keeps a table as short as the difference between the runs. One consequence worth knowing: there is no way to set a parameter to an empty string here, because blank already means something else.

**A value containing a comma must be quoted** — `"-a AD,DP,SP,INFO/AD"`. The default `readPattern`, `*_R{1,2}.fq.gz`, is exactly such a value.

Blank lines and lines starting with `#` are ignored, so a run can be kept in the file with a `#` in front of it rather than deleted.

```csv
RunID,referenceFile,gffFile,trim_galore.quality
reference_a,reference_a.fasta.gz,reference_a.gff.gz,
reference_b,reference_b.fasta.gz,reference_b.gff.gz,30
```

*Two references, the second trimmed harder. The blank cell on the first row takes the configured quality, so the baseline is whatever `parameters.config` already says rather than a number repeated here.*

### Setting a value the pipeline would compute

Some parameters are derived from others — `filterFalsePositives.sensitivity` from `poolSize` and `diploidy`, `variantCall.mpileupOptions` from the four `bcftools` values, the whole `cores` ladder from `threads`. Varying either end of that relationship is allowed, and the two behave differently.

**Set an input and the computed value follows it.** A run with `poolSize = 200` gets the sensitivity that a pool of 200 implies; one with `trim_galore.quality = 30` gets trimming options built around 30. You do not have to keep the derived values in step by hand.

**Set a computed value directly and it is used exactly as written** — and nothing is derived from its inputs any more. Pin `variantCall.mpileupOptions` and `variantCall.maxDepth` stops meaning anything for that run. That is a legitimate thing to want when you need a command line under your own control, and any column doing it is named in the report, so it is a choice rather than a surprise.

### Where the results go

There is one results tree, and **only divergence gets a name**:

```text
storageDir/Output/
├── All_Runs/        ← work every run shared
├── Shared_1/        ← work some of them shared
├── Shared_2/
├── reference_a/     ← work this run did alone
└── reference_b/
```

`Logs/` follows the same shape. Each `Shared_<N>` directory holds a `members.txt` naming the runs it belongs to, because a group number on its own says nothing about which runs are in it.

A single run gets none of this and keeps the plain tree. Turning `multiRun` on for one run is not a different layout, but there is no reason to do it.

Group numbers are assigned in order of appearance in the table, so reordering rows can leave `Shared_1` naming a different pair than before. The change guard compares the table you ran against the one recorded beside the results, and row order counts as a change for exactly this reason.

### What is shared, and what is not

Sharing is decided by comparing the parameters each step actually reads. Two runs share a step when every value that step depends on is the same for both — so runs differing only in `vcffilter.minDP` share everything up to and including variant calling, and diverge at the filtering.

One thing switches it off entirely. **A run that sets its own `storageDir` shares nothing**, because sharing means writing one artifact into one results tree, and a run with its own tree has nowhere to put a shared one. It repeats every step alone. That is allowed and occasionally what you want; the report names any run in that position so it is not discovered from a task count.

### Checked before any compute is spent

The table is read and validated at the start of the run, and an unusable one stops it outright. A usable one is printed in full: the runs, where each one's results will go, and what differs for each. A mistake in the table costs seconds rather than a night of alignment.

`PoolSeqFlow dryrun` goes further and creates the directory tree the run would write, empty, so the layout can be looked at and approved before anything is computed. `PoolSeqFlow dryclean` removes the preview.

## Variant Calling
<!--@ page: variant-calling -->

These are the parameters that decide which variants exist in your output and at what frequency. Every one of them is analysis-affecting: change one and the next run stops rather than letting old and new results share a folder.

For how these fit together end to end, read [The Filter Chain](#the-filter-chain).

### `poolSize` and `diploidy`

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

**If your pools differ in size**, give each one its own `param_poolSize` in `metadata.csv` and every column is judged at its own threshold. The global `poolSize` here stays as the default for pools that do not state one. See [Pool size belongs to the pool](#pool-size-belongs-to-the-pool).

**`diploidy` applies to a whole run.** It describes the sequence rather than the sample, so a diploid animal's haploid mitochondrial genome belongs in a separate run with its own value — see [Sequences with a different ploidy](#sequences-with-a-different-ploidy).

### `sampleThreshold`

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

Remember that the denominator is the number of **VCF columns**, which is the number of distinct `RG_Sample` values — not the number of FASTQ pairs. Merging replicates by sharing an `RG_Sample` changes this threshold as a side effect ([see Metadata](#rg_sample-decides-what-counts-as-a-sample)).

### Pileup settings

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

#### `maxDepth`

`-d 2000` caps the reads considered **per file per position**. This is the parameter most likely to bite a Pool-seq run without announcing itself.

Pooled libraries are often sequenced deeply on purpose — depth is what buys frequency resolution. When depth exceeds the cap, the pileup stops counting, and the read counts your frequencies are computed from are truncated. Nothing downstream flags this.

**Check it against your data.** After a run, look at `Output/Reports/Coverage/`:

```bash
grep -H . Output/Reports/Coverage/*_coverage_report.txt | head
```

If mean depth approaches or exceeds 2000 anywhere you care about, raise `maxDepth` above your highest expected per-sample depth. There is a memory and runtime cost to a higher cap, but a truncated pileup is a biased result.

### Calling

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

### Depth and quality

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

    Check `Output/Reports/Coverage/` for your weakest sample before choosing a value, and after the first run compare the site count in `<name>.vcf` against the distinct positions that reached the frequency tables. A near-total wipeout is this filter, not a broken pipeline.

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

    A per-sample depth floor — blanking one pool's frequency while keeping the row — cannot be done in the VCF, because vcftools and bcftools both express a genotype-level verdict by rewriting `GT`, and `GT` is set to `./.` throughout by major-allele normalisation ([why](#4-major-allele-normalisation-step-7)). Frequency conversion reads `AD`. If you need per-sample blanking rather than whole-site removal, it has to happen in `bin/depth2freq.awk`, which already computes each sample's depth as the denominator.

### Output naming

```groovy
vcf {
    fileName = 'Test'
}
```

Base name for every VCF and frequency table. With the default, a finished run leaves `Test.vcf`, `Test_snp_freq.tsv`, `Test_indel_freq.tsv`, and `Test_annotated.vcf` if annotation ran. Worth setting to something descriptive — it is the name your results carry from here on.

Changing it after a run does not rename anything; it makes the resume checks look for files that do not exist, and the whole VCF and frequency branch runs again alongside the old files.

## Alignment Filters
<!--@ page: filters -->

Step 4 turns a raw BWA alignment into the BAM that variant calling reads. The last stage of that is a filter, and it is the first place a variant can be lost — nothing later in the pipeline can recover a read discarded here.

### The cleanup pipeline

Seven operations, streamed so no intermediate BAM is written:

| # | Operation | Command | Why |
|---|---|---|---|
| 1 | Name-sort | `samtools sort -n` | `fixmate` requires mates adjacent |
| 2 | Fix mate info | `samtools fixmate -m` | Corrects mate coordinates and adds the mate score tag `markdup` needs |
| 3 | Coordinate-sort | `samtools sort` | `markdup` requires coordinate order |
| 4 | Mark and **remove** duplicates | `samtools markdup -r -s` | See [below](#why-duplicates-are-removed-not-just-marked) |
| 5 | Add read groups | `samtools addreplacerg` | Writes the `@RG` string built from this sample's row in [`metadata.csv`](#metadata) |
| 6 | Filter | `samtools view -F … -f … -q …` | The filter proper |
| 7 | Index | `samtools index` | Produces the `.bai` |

The result is written to `Output/Ready/` as `<sample>_ready.bam` with its index.

### The filter

```groovy
samtools {
    filter   = "0xF0C"   // -F : exclude any read with these bits set
    required = "0x2"     // -f : require these bits
    mapq     = 30        // -q : minimum mapping quality
}
```

#### `filter` — what is excluded

`0xF0C` is the sum of six flag bits:

| Flag | Value | Excludes |
|---|---|---|
| `0x004` | 4 | Unmapped reads |
| `0x008` | 8 | Reads whose mate is unmapped |
| `0x100` | 256 | Secondary alignments |
| `0x200` | 512 | Reads failing platform QC |
| `0x400` | 1024 | PCR / optical duplicates |
| `0x800` | 2048 | Supplementary alignments |

Secondary and supplementary alignments are excluded because a read that aligns in more than one place would otherwise contribute its bases to several positions. In a frequency estimate that is double-counting, not extra evidence.

#### `required` — what must be true

`0x2` requires the read to be **properly paired**: both mates mapped, in the expected orientation, at a plausible insert size. This is a strict requirement, and it is why single-end data does not work with the pipeline as configured.

#### `mapq` — the quality floor

This one is not part of either flag word and is easy to overlook. At `30`, reads whose mapping quality falls below the threshold are discarded — meaning reads that could plausibly have come from more than one location in the genome.

For Pool-seq this matters more than usual. An ambiguously placed read still adds a read count wherever it lands, and allele frequencies *are* read counts. A repetitive region that collects mismapped reads produces frequencies that look real and are not.

The cost is coverage. In a repeat-rich or recently duplicated genome, a MAPQ 30 floor can discard a substantial fraction of reads. If your step 5 coverage reports show much less depth than you sequenced for, this is the first thing to check.

| Value | Effect |
|---|---|
| `30` (default) | Strict. Discards anything with meaningful placement ambiguity |
| `20` | Moderate. Common compromise on repetitive genomes |
| `0` | No MAPQ filtering. Only appropriate if you intend to handle mismapping yourself |

### Why duplicates are removed, not just marked

`markdup -r` removes duplicate reads rather than flagging them. Downstream callers usually respect the duplicate flag anyway, so the two are close to equivalent — but removal is the safer default here, and duplicates matter more in a pool than in an individual.

A PCR duplicate is a second read from a molecule that should only be counted once. In individual sequencing that inflates confidence in a genotype you would have called anyway. In Pool-seq it changes the answer: the duplicate adds a vote to one allele, and the frequency shifts. A library with uneven amplification produces a frequency estimate biased toward whichever molecules amplified best.

`-s` prints duplicate statistics into the step's log, which is worth reading — a high duplicate rate is a library-prep signal that no amount of filtering fixes.

### Changing these values

All three are analysis-affecting. Changing any of them means the existing BAMs no longer match your configuration, and the next run stops before doing any work ([why](#the-run-refuses-to-mix-settings)). Clearing it means deleting `Output/Ready/`, `Output/VCF/` and `Output/Frequencies/`.

Because the alignment step itself is unaffected, `Output/Aligned/` is preserved and the re-run starts from BAM cleanup rather than from BWA.

### Verifying what was applied

The `@RG` line written at stage 5 is the record of what this step did with your `metadata.csv`:

```bash
samtools view -H Output/Ready/<sample>_ready.bam | grep '^@RG'
```

For read counts before and after filtering, compare `Output/Aligned/` against `Output/Ready/`:

```bash
samtools view -c Output/Aligned/<sample>.bam
samtools view -c Output/Ready/<sample>_ready.bam
```

The difference is duplicates plus everything the flag and MAPQ filters removed. The step 5 alignment report (`bamtools stats`) breaks the same numbers down by category.

# Pipeline Overview
<!--@ section: pipeline | nav: Pipeline -->

PoolSeqFlow is a set of Nextflow DSL2 modules, each an independent file under `scripts/` and each responsible for its own resume logic. Steps 0 to 8 are the analysis; a tenth module handles promotion, moving each finished artifact to permanent storage once nothing needs it any more. This page is the map; the detail is in [Steps](#pipeline-steps).

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
      ├──────────────────────┐
      ▼                      ▼
[Step 5] Reports    [Step 6] Variant calling (BCFtools mpileup + call)
                             │
                             ├────────────────────────────────┐
                             ▼                                ▼
                    [Step 7] VCF → frequency tables   [Step 8] Annotation (optional)
```

### What runs per sample and what runs once

This distinction explains most of the pipeline's runtime behaviour.

| Step | Granularity | Notes |
|---|---|---|
| 0 Verify | Once | Gate for everything else |
| 1 Dictionaries | Once | Three parallel index builds |
| 2 Trim & clip | Per sample | Two sub-steps, the second depends on the first's FastQC output |
| 3 Align | Per sample | |
| 4 Cleanup | Per sample | |
| 5 Reports | Per sample | Two sub-steps, independent |
| 6 Variant call | **Once, jointly** | One `bcftools mpileup` over every BAM |
| 7 Frequencies | Once, five sub-steps | Serial chain; the last runs twice, on SNPs and on INDELs |
| 8 Annotation | Once | Optional; runs on step 6's output, not step 7's |

Step 6 is the pipeline's barrier: it needs every BAM before it can start, so a single slow sample delays the whole run from that point. It is also why samples must share a reference, and why the sample column order needs deciding ([in `metadata.csv`](#row-order-decides-column-order)).

Under a run table, "once" means once per **variant** rather than once overall: runs that agree on everything a step reads share that step's single task, and only diverging work is repeated. See [Multi-run](#multi-run).

### The two output branches

After variant calling the workflow forks, and the branches never rejoin:

**Step 7** takes the raw VCF through major-allele normalisation, the cross-sample false-positive filter, depth and quality filtering, a SNP/INDEL split, and conversion to frequency tables. This is the analytical path.

**Step 8** takes the *same raw VCF* — not step 7's output — splits multiallelic sites, and annotates with SnpEff. So the annotated VCF contains sites step 7 removed, in the original reference encoding rather than the major-allele one. Joining the two requires matching on `CHROM`/`POS` and expecting unmatched rows ([details](#the-vcf-files)).

### Where the work happens

Every step follows the same pattern:

1. Check whether its output already exists — in `storageDir`, or on the working volume waiting to be promoted. If so, symlink it and exit.
2. Otherwise do the work in `mainDir/work/`.
3. Move the result out atomically: to `mainDir/Utilized/` if a later step will read it, or straight to `storageDir` if nothing will.
4. Symlink it back into the task's working directory.
5. Copy `.command.log` and `.command.err` into `Logs/`.

Then, separately: when the last step that needed an artifact has succeeded, it is moved from `Utilized/` to `storageDir`. Each byte crosses between the two volumes exactly once, and something enters `Utilized/` precisely when it will be read again — the unpaired reads, the trimming reports and the FastQC output have no consumer at all, so they go straight to permanent storage and never appear there.

That pattern is what makes the pipeline resumable without Nextflow's cache, keeps files from being duplicated, and survives an interrupted move. The reasoning is in [Design Decisions](#design-decisions); the mechanics are in [Resume Logic](#resume-logic).

### Error handling

`nextflow.config` sets `errorStrategy = 'finish'`: on a failure, running tasks are allowed to complete and no new ones start. Nothing is left half-written, and a re-run picks up from whatever genuinely finished.

`ClipReads` is the exception, with `errorStrategy 'retry'` and `maxRetries 3` — it is the one step whose failures are commonly transient.

`cleanup = true` removes task working directories after a successful run, leaving only empty hash-prefix folders under `work/`. `./PoolSeqFlow clean` clears those.

## Pipeline Steps
<!--@ page: steps | nav: Steps -->

Each step is an independent module under `scripts/`. This page covers what each one does, what it writes, and what makes it skip itself.

---

### Step 0: Verify Environment {: #step-0-verify-environment }

`scripts/0_verify_environment.nf`

The gate for everything else. Nine stages run in parallel, each writing its own section, and the results are assembled into `Output/Reports/0_verify_environment.txt`. Nothing downstream starts until every one of them has passed.

#### The nine stages

| Stage | Reports as | Fails when |
|---|---|---|
| `CheckReference` | `REFERENCE FILE CHECK` | The reference is missing. Gzipped or plain are both accepted |
| `CheckGFF` | `GFF FILE CHECK` | The annotation is missing while `annotate = true` |
| `CheckData` | `DATA SOURCE CHECK`, `DATA FOLDER CHECK`, `DATA FILES CHECK` | `dataSource` does not resolve, the directory is absent, or nothing matches `readPattern` |
| `CheckMetadataFile` | `METADATA FILE CHECK`, `METADATA CHECK`, `METADATA SAMPLE MATCH`, `METADATA CHANGE CHECK` | `metadata.csv` is missing or malformed, a FASTQ sample has no row, or the analysis-affecting columns differ from what produced your results |
| `CheckInstalledSoftware` | `SOFTWARE CHECK` | A tool named in `params.software` is not on `PATH` |
| `CheckTrimParameters` | `TRIM PARAMETER CHECK` | `autodetect = false` with `adapter1` or `adapter2` unset |
| `CheckRunParameters` | `PIPELINE VERSION`, `RUN PARAMETER CHECK` | The release differs from the one that produced your results, or an analysis-affecting parameter has changed |
| `CheckDirectories` | `DIRECTORY CHECK` | `mainDir` and `storageDir` are the same path, or either is the installation itself |
| `CheckMultiRun` | `MULTI-RUN CHECK` | The run table is missing, unparseable, or names a column that is not a parameter |

`CheckMetadataFile` reports more than it refuses. It prints the pooling it worked out — which rows merged into which VCF column — and the pool sizes it will apply, before any compute is spent. A mistake there is visible in seconds rather than in a result months later.

#### The consistency guards

Three of those stages are not validating your input; they are checking that what you are about to run matches what produced the results already on disk. They exist because of how resume works: completed steps are skipped by looking for output files, not by checking what produced them, so a changed `poolSize` would leave one `Frequencies/` folder holding tables computed under two different thresholds, invisibly.

| Record | Contents |
|---|---|
| `.poolseqflow_version` | The release that produced these results. A mismatch is a **hard stop** — nothing else is compared, because the parameter set itself moves between releases |
| `.poolseqflow_params` | The analysis-affecting parameters, mirrored to a readable `run_parameters.txt` |
| `.parameters.config` | Your configuration file, copied verbatim |
| `.multirun.csv` | Your run table, copied verbatim, if you used one |
| `.poolseqflow_metadata` | The `RG_*` and `param_*` columns and the row order, kept beside the results they describe |

Path and resource parameters are excluded, along with the `software` entries — they change where and how fast work happens rather than what the answer is.

When a guard trips, the run stops **before any work happens** and the report names what to delete. Deleting it is what clears the check. How much has to go depends on what changed: a reordered `metadata.csv` invalidates less than an edited tag value, and a changed pool size less again ([table](#editing-metadatacsv-after-a-run)).

---

### Step 1: Build Reference Dictionaries

`scripts/1_build_dictionaries.nf`

Puts an uncompressed reference into `Reference/Dictionaries/` — decompressing it if it was gzipped, copying it if it was not — and builds three index sets there, in parallel:

| Sub-step | Produces |
|---|---|
| `CreateBwaIndex` | `Ref.fasta.{amb,ann,bwt,pac,sa}` |
| `CreateSamtoolsFaiIndex` | `Ref.fasta.fai` |
| `BuildSnpEffDb` | `Reference/Dictionaries/snpEff/` and `snpEff.config` (only if `annotate = true`) |

All of it lives under `mainDir`, beside the reference it was built from, and none of it is copied to `storageDir`. Dictionaries are working material: they are derived from your reference and can be rebuilt from it, so they are not a result to keep. Under a run table, runs sharing a reference build them **once**.

The SnpEff database name is derived from the GFF filename — `reference.gff.gz` becomes database `reference.gff`. The build copies the reference and GFF into a SnpEff `data/` layout, generates a minimal config, and verifies that `.bin` files were produced before declaring success. Completion is marked by `.build_complete`, which is what the resume check looks for.

Build options are `-gff3 -noCheckCds -noCheckProtein -v`. The two `-noCheck` flags suppress SnpEff's protein and CDS consistency checks, which fail on many non-model GFFs for reasons that do not affect variant annotation.

---

### Step 2: Trim & QC

`scripts/2_trim_reads.nf`

Two sub-steps.

**`TrimReads`** runs Trim Galore with `--fastqc --paired --retain_unpaired -q 25`, which removes adapters and low-quality 3′ ends and produces a FastQC report on the result.

**`ClipReads`** parses that FastQC report and derives per-sample clip points from the per-base composition table, then applies them with cutadapt and re-runs FastQC on the output.

The clipping algorithm, its failure modes and the one parameter worth tuning are covered in [Trimming & Clipping](#composition-aware-clipping).

Trimmed reads are deleted once clipping has consumed them. `ClipReads` is the only step configured to retry on failure.

---

### Step 3: Align

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

### Step 4: Clean BAM Files

`scripts/4_clean.nf`

A single streamed pipeline of seven operations: name-sort, fixmate, coordinate-sort, mark and remove duplicates, add read groups, filter, index. The `@RG` string is assembled per sample from that sample's row in `metadata.csv`, skipping empty fields.

Full detail, including why duplicates are removed rather than marked and what the MAPQ floor costs you: [Alignment Filters](#alignment-filters).

Output: `Output/Ready/<sample>_ready.bam` and `.bai`.

---

### Step 5: Generate Reports

`scripts/5_reports.nf`

Two independent sub-steps per sample:

| Sub-step | Command | Output |
|---|---|---|
| `AlignmentReport` | `bamtools stats` | `Output/Reports/Alignment/<sample>_alignment_report.txt` |
| `CoverageReport` | `samtools coverage` | `Output/Reports/Coverage/<sample>_coverage_report.txt` |

The coverage report is the one to read on every run: it is how you find out whether `variantCall.maxDepth` truncated your pileup ([why that matters](#maxdepth)).

---

### Step 6: Variant Calling

`scripts/6_variant_call.nf`

```bash
bcftools mpileup -B -C 50 -q 30 -Q 30 -d 2000 -a AD,DP,SP,INFO/AD -Ou -f reference <all BAMs> \
  | bcftools call -m -A -v -Ov -o <name>.vcf
```

One joint task over every BAM, producing a multi-sample VCF with `AD` and `DP` FORMAT fields. Every flag and its consequence: [Variant Calling](#variant-calling).

**The BAMs are sorted before being handed to bcftools**, in `metadata.csv` row order. bcftools orders VCF columns by command-line order, so without this the column order would follow task-completion order — three consecutive runs on identical input gave three different orders.

A header fix is applied afterwards: `INFO/MQ` is declared `Integer` by bcftools but can carry a float, so the declaration is rewritten to `Float`. Without it, strict VCF parsers reject the file.

---

### Step 7: VCF → Allele Frequency Tables

`scripts/7_vcf2freq.nf`

Five sub-steps in a serial chain, each deleting its input once its output is safe:

| # | Sub-step | Does |
|---|---|---|
| 1 | `SortRefAltByFrequency` | Re-encodes so the most-read allele is `REF`; recomputes `DP` from `AD`; sets `GT` to `./.` |
| 2 | `FilterPotentialFalsePositives` | Splits multiallelics, applies the cross-sample support test, rejoins, re-normalises |
| 3 | `DepthAndQualityFilter` | `bcftools view -e "FMT/DP<20"` then `vcftools --minQ 30` |
| 4 | `SplitSNPsAndINDELs` | Two vcftools passes into a SNP VCF and an INDEL VCF |
| 5 | `CalculateFrequencies` | Extracts `AD` and divides to frequencies; runs once per split file |

Sub-step 2 is the pool-aware core of the pipeline and is documented in full in [The Filter Chain](#5-false-positive-filter-step-7). The minimum credible frequency it enforces is

$$f_{\min} = \frac{1}{2 \times \text{diploidy} \times \text{poolSize}}$$

but the test is not a plain cutoff in either direction. An allele must reach that frequency in a *fraction of samples*, which is what lets the threshold sit so low — and each sample is judged against **its own** pool's threshold, taken from `param_poolSize`, rather than against one number for the whole run.

Output: `Output/Frequencies/<name>_snp_freq.tsv` and `<name>_indel_freq.tsv`. Format: [Interpreting Results](#the-frequency-tables).

---

### Step 8: Annotate Variants {: #step-8-annotate-variants }

`scripts/8_annotate_variants.nf` — optional, controlled by `annotate`.

```bash
bcftools norm -m - <name>.vcf | snpEff -v -stats snpeff_summary.html <db>
```

Splits multiallelic sites onto separate lines — SnpEff annotates one alternate allele per record — and annotates against the database built in step 1.

!!! warning "This runs on the raw call set"

    Step 8 takes step **6**'s output, not step 7's. It runs in parallel with the frequency branch, so `<name>_annotated.vcf` contains sites the step 7 filters removed, encoded against the original reference rather than the major allele. To attach annotations to your frequency tables, join on `CHROM`/`POS` and expect unmatched rows on the annotation side.

Output: `Output/VCF/<name>_annotated.vcf` and `Output/Reports/snpeff_summary.html`.

Setting `annotate = false` skips this step and makes `gffFile` unnecessary — step 1 also stops building the SnpEff database.

---

### Promotion

`scripts/9_completion.nf`

Not an analysis step, and it produces nothing of its own. It moves each finished artifact from the working volume to permanent storage once nothing needs it any more, so every byte crosses between the two exactly once.

An artifact enters `mainDir/Utilized/` precisely when a later step will read it again. Things with no consumer at all — the unpaired reads, the trimming reports, the FastQC output, both step 5 reports — go straight to `storageDir` and never appear there.

What moves it is a **completion signal from the last step that reads it**, not the artifact itself. Which step that is can depend on your configuration: `<name>.vcf` is read by step 7 always and by step 8 only when `annotate = true`, with no ordering between them, so the gate has to wait for whichever set applies to this run.

If a run is interrupted, artifacts stay in `Utilized/` and the skip checks find them there — a resumed run counts them as done and picks up where it stopped, rather than repeating the work because the file is not in its final place yet.

## Resume Logic
<!--@ page: resume -->

PoolSeqFlow implements its own resume strategy rather than using Nextflow's. This page covers how it behaves; the reasoning behind replacing `-resume` is in [Design Decisions](#resume-is-filesystem-based).

### Two directories

| | |
|---|---|
| **`mainDir`** | Where the pipeline runs and where everything it works on lives — your reads, your reference, the dictionaries built from it, `work/`, and outputs still being read. Not scratch: it holds your inputs, so it has to survive between runs |
| **`storageDir`** | Where finished results are kept. Network storage, a group volume, a different mount |

**They cannot be the same path**, and the run stops if they are. The two are storage tiers with different jobs, and an output moving from one to the other is the event that marks it finished — which cannot mean anything if they are one place.

Each output is **moved** out of `work/` and a symlink left behind. Consequences:

- **No duplication.** Nothing the pipeline produces exists twice on disk.
- **One crossing.** An artifact moves between the two volumes exactly once, when the last step that needed it has finished.
- **Automatic step-skipping.** Every step looks for its own outputs — in `storageDir` first, then on the working volume — and skips itself if they are there, regardless of the state of `work/`.
- **Resilience.** The check depends on nothing but the storage the results are already in, so it survives cluster timeouts, reboots and `work/` cleanups.

The order of that search matters. Permanent storage is consulted first so that a stray copy left on the working volume can never outrank a promoted one.

### There is no `-resume`

This strategy **replaces** Nextflow's `-resume`, and the wrapper never passes that flag. Two reasons it could not work here even if it were passed:

- `cleanup = true` deletes task working directories once a run completes. `-resume` replays task outputs *from* those directories; after a successful run there is nothing to replay.
- Several steps delete their own inputs once consumed. That leaves the upstream task's recorded outputs dangling, which invalidates the cache entry regardless.

So `PoolSeqFlow run` is both "start" and "resume". `PoolSeqFlow resume` survives as a deprecated alias and prints a notice.

To start genuinely from scratch:

```bash
PoolSeqFlow reset
```

It lists exactly what it is about to remove, across both directories, and requires typing `DELETE_MY_ANALYSIS` to confirm. That covers `Output/` and `Logs/` in `storageDir`; on `mainDir`, the dictionaries built from your reference, anything not yet promoted, and `work/`; Nextflow's own history; and the `.parameters.config`, `.multirun.csv` and `.poolseqflow_*` records describing all of it. Those records go too, because leaving them would have the next run comparing your configuration against outputs that no longer exist.

Your reads, your reference and your two configuration files are not touched.

### What a resumed run looks like

Every process is still submitted. Step-skipping happens *inside* each task, not before it, so a fully resumed run submits roughly one job per process per sample. Those jobs test for a file, create a symlink, copy two log files and exit — but on a scheduler they are real submissions with real queue time.

The log lines to look for are the `COMPLETED` messages that follow a "Found existing" line:

```text
ALIGNING Sample1: Found existing BAM file
ALIGNING Sample1: Found: /storage/project/Output/Aligned/Sample1.bam
ALIGNING Sample1: Creating symbolic link...
ALIGNING Sample1: COMPLETED
```

### Partial-stage resume

Step 7 is a chain of five sub-steps, and each checks for the outputs of every *later* stage as well as its own. If the frequency tables already exist, the earlier sub-steps create an empty placeholder and exit rather than redoing work whose result was superseded. This is why a partially completed step 7 resumes correctly even though its intermediates have been deleted.

### Interrupted moves

A plain `mv` across a filesystem boundary is a copy followed by an unlink. A job killed mid-move would leave a **truncated file under its final name**, which existence-based resume would then accept as a completed step.

All cross-filesystem moves go through `bin/atomic_mv.sh`, which stages via a `.part` file and renames into place. An interrupted move leaves a `.part` that no check looks for, and the step simply runs again.

### What resume does not protect you from

"The output exists" is not "the output is correct for your current settings". A file produced under `poolSize = 50` is indistinguishable from one produced under `poolSize = 100`.

That gap is closed by the consistency guards at the start of a run, which record the release, the analysis parameters, the run table and the analysis-affecting parts of `metadata.csv` behind a set of outputs, and stop the run when any of them has changed. See [Step 0](#step-0-verify-environment).

### Cleaning up

| Command | Removes |
|---|---|
| `PoolSeqFlow clean` | Nextflow work directories — the empty hash-prefix folders `cleanup = true` leaves behind |
| `PoolSeqFlow dryclean` | The empty directory tree `dryrun` created as a preview |
| `PoolSeqFlow reset` | All progress, across both directories, after listing it and asking you to type a confirmation |

`clean` is safe at any time and does not affect resume — nothing in `work/` is consulted by the skip logic. `reset` deletes results.

!!! danger "Do not delete either directory's contents while a run is in flight"

    Task working directories contain symlinks into the volume the output was moved to. Removing the target breaks links that are actively in use, and the failure will not be obvious. That applies to the working volume as well as to permanent storage — an artifact waiting to be promoted is being read from where it is.

## Directory Layout
<!--@ page: directories -->

There are three directories, and keeping them apart is most of understanding the layout: **the installation**, which is a tool; **`mainDir`**, which is your project and where the work happens; and **`storageDir`**, which holds finished results.

### The installation

```text
~/.local/opt/PoolSeqFlow-<version>/
├── bin/
│   ├── atomic_mv.sh              # Cross-filesystem moves, staged and renamed
│   ├── classify_manifest.sh      # Sorts a parameter change into added/changed/removed
│   ├── config_migrate.sh         # Backs migrate_config
│   ├── createDepthFile.sh        # Extract AD/DP columns from a VCF
│   ├── depth2freq.awk            # Convert allelic depths to frequencies
│   ├── filterFalsePositives.sh   # Cross-sample support filter
│   ├── find_artifact.sh          # Locate an output across the storage tiers
│   ├── MajorAlleleToRef.py       # Re-encode VCF with the major allele as REF
│   ├── parse_metadata.py         # Read and validate metadata.csv
│   └── parse_multirun.py         # Read and validate the run table
├── install/
│   ├── environment.yml           # Pinned conda environment
│   └── check_install.sh          # Verifies an installation (PoolSeqFlow check)
├── scripts/
│   ├── 0_verify_environment.nf   # The nine checks that gate everything else
│   ├── 1_build_dictionaries.nf   # BWA, SAMtools and SnpEff indices from your reference
│   ├── 2_trim_reads.nf           # Trim Galore, then composition-aware clipping
│   ├── 3_align.nf                # BWA-MEM
│   ├── 4_clean.nf                # Name-sort → fixmate → markdup → addRG → filter → index
│   ├── 5_reports.nf              # Alignment and coverage reports
│   ├── 6_variant_call.nf         # One joint bcftools mpileup and call
│   ├── 7_vcf2freq.nf             # Normalise, filter, split, convert to frequencies
│   ├── 8_annotate_variants.nf    # SnpEff, optional
│   ├── 9_completion.nf           # Promotion: moving finished artifacts to storageDir
│   ├── metadata.nf               # Reading metadata.csv, and the projections from it
│   ├── resolve_parameters.nf     # Computed parameters, and one parameter set per run
│   └── variants.nf               # Which runs share which work, and where it goes
├── manual/                       # This manual
├── nextflow.config
├── parameters.config.template
├── metadata.csv.template
├── multi-run.csv.example
├── poolseqflow.nf                # Workflow entry point
├── dryrun.nf                     # Entry point for the layout preview
└── PoolSeqFlow                   # CLI wrapper
```

One copy serves any number of projects, and it is replaced wholesale when you upgrade — which is why nothing of yours belongs in it. `bin/` is prepended to `PATH` by `nextflow.config`, which is how the helper scripts are callable by bare name inside process scripts.

### What you provide, on `mainDir`

```text
/path/to/working/directory/  ← mainDir, and where you run from
├── parameters.config
├── metadata.csv
├── metadata.csv.example     ← left by init; reference, nothing reads it
├── Data/                    ← dataSource names this folder
│   ├── Sample1_R1.fq.gz
│   ├── Sample1_R2.fq.gz
│   └── …
└── Reference/
    ├── reference.fasta.gz
    └── reference.gff.gz     ← only if annotate = true
```

Either reference file may be gzipped or plain.

### What appears on `mainDir` as the run proceeds

```text
/path/to/working/directory/
├── Reference/Dictionaries/       # Built from your reference in step 1
│   ├── reference.fasta
│   ├── reference.fasta.{amb,ann,bwt,fai,pac,sa}
│   └── snpEff/
├── Utilized/                     # Outputs still to be read; mirrors Output/'s tree
└── work/                         # Nextflow's task directories
```

`Utilized/` empties itself as the run proceeds — each artifact moves to `storageDir` once the last step that needed it has finished, so a completed run leaves it empty. Under a run table each run gets its own, `Utilized_<RunID>`, because the runs share `mainDir` and would otherwise write to one path.

`work/` is emptied by `cleanup = true` after a successful run, and `PoolSeqFlow clean` removes what is left. The dictionaries stay: they are derived from your reference and rebuilding them costs time for no gain.

### What the pipeline produces, on `storageDir`

```text
/path/to/permanent/storage/
├── Logs/                         # Per-step .log and .err, mirrored from every task
└── Output/
    ├── .poolseqflow_version      # The release that produced these results
    ├── .poolseqflow_params       # The analysis parameters behind them
    ├── .parameters.config        # Your configuration, copied verbatim
    ├── .multirun.csv             # Your run table, copied verbatim, if you used one
    ├── .poolseqflow_metadata     # The analysis-affecting columns of metadata.csv
    ├── run_parameters.txt        # Readable mirror of .poolseqflow_params
    ├── Trimmed/<sample>/         # Clipped FASTQs
    ├── Unpaired/<sample>/        # Reads whose mate was discarded
    ├── Aligned/                  # Raw BWA output
    ├── Ready/                    # Cleaned, filtered, indexed BAMs
    ├── VCF/                      # Call sets
    ├── Frequencies/              # The result
    └── Reports/
        ├── Alignment/
        ├── Coverage/
        ├── Fastqc/<sample>/
        ├── Trimming/<sample>/
        ├── 0_verify_environment.txt
        ├── snpeff_summary.html
        └── PoolSeqFlow_pipeline_{report,timeline,trace,dag}.*
```

That is the shape for a single run.

### Under a run table

`Output/` and `Logs/` gain one level, and **only divergence is named**. Work every run shared goes under `All_Runs/`, work some of them shared under `Shared_<N>/`, and whatever a run did alone under its own `RunID`. Below each of those, the subtree is exactly the one above.

Take three runs against two references, one of them filtered harder:

```csv
RunID,referenceFile,gffFile,vcffilter.minDP
run_a1,ref_a.fasta.gz,ref_a.gff.gz,20
run_a2,ref_a.fasta.gz,ref_a.gff.gz,40
run_b,ref_b.fasta.gz,ref_b.gff.gz,20
```

```text
/path/to/permanent/storage/Output/
├── .poolseqflow_version          # The invocation's records stay at the root,
├── .poolseqflow_params           #   describing the whole set of runs
├── .parameters.config
├── .multirun.csv
├── run_parameters.txt
│
├── All_Runs/                     # every run agreed on the reads and the trimming
│   ├── Trimmed/<sample>/
│   ├── Unpaired/<sample>/
│   └── Reports/
│       ├── Fastqc/<sample>/
│       ├── Trimming/<sample>/
│       └── PoolSeqFlow_pipeline_{report,timeline,trace,dag}.*
│
├── Shared_1/                     # run_a1 and run_a2 share reference A
│   ├── members.txt               #   -> "run_a1", "run_a2"
│   ├── Aligned/
│   ├── Ready/
│   ├── VCF/
│   └── Reports/{Alignment,Coverage}/
│
├── run_a1/                       # same reference, different minDP: only step 7 differs
│   └── Frequencies/
├── run_a2/
│   └── Frequencies/
│
└── run_b/                        # a reference of its own, so it shares nothing past trimming
    ├── Aligned/
    ├── Ready/
    ├── VCF/
    ├── Reports/{Alignment,Coverage}/
    └── Frequencies/
```

`Logs/` mirrors that shape exactly, so a step's log sits beside the output it produced.

Three things are worth reading off it:

- **The trimming is done once, not three times.** Every run reads the same FASTQ files with the same settings, so there is one set of trimmed reads under `All_Runs/`.
- **`Shared_1` needs `members.txt`**, because a group number says nothing about which runs are in it. Numbers are assigned in order of appearance in the table, so reordering rows can move them.
- **`run_a1` and `run_a2` hold only `Frequencies/`.** Everything earlier was identical between them and lives in `Shared_1`; the filtered VCFs that differ are intermediates and do not survive.

`.poolseqflow_metadata` is the one record that does not sit at the root with the others. It describes the column order of a particular VCF, so it is kept beside that VCF — here, one in `Shared_1/` and one in `run_b/`.

The Nextflow reports describe the whole invocation rather than any one run, so there is a single set under `All_Runs/Reports/`.

A run that sets its own `storageDir` gets none of this. It has a results tree to itself, shares nothing, and repeats every step alone.

### What survives a completed run {: #what-survives-a-completed-run }

Several steps delete their inputs once the next stage has consumed them, and the deletion follows the symlink — the permanent copy goes too ([why](#steps-delete-their-own-inputs)). So the contents of `Output/VCF/` mid-run and after a completed run are not the same.

With `vcf.fileName = 'Test'`:

| File | Survives | Notes |
|---|---|---|
| `Test.vcf` | **Yes** | Raw call set from step 6 |
| `Test_sort.vcf` | No | Deleted by the false-positive filter |
| `Test_sort_fp.vcf` | No | Deleted by the depth/quality filter |
| `Test_sort_fp_dq.vcf` | No | Deleted by the SNP/INDEL split |
| `Test_sort_fp_dq_snp.vcf` | No | Deleted by frequency conversion |
| `Test_sort_fp_dq_indel.vcf` | No | Deleted by frequency conversion |
| `Test_annotated.vcf` | **Yes** | If `annotate = true`; annotates the *raw* call set |
| `Test_snp_freq.tsv` | **Yes** | In `Frequencies/` |
| `Test_indel_freq.tsv` | **Yes** | In `Frequencies/` |

So `Output/VCF/` holds exactly two files after a completed run: the raw call set, and the annotated one if you enabled annotation. **Every VCF step 7 produces is an intermediate**, including the fully filtered one — what that becomes is the frequency tables.

Likewise, `Output/Trimmed/<sample>/` keeps only the `_clipped.fq.gz` files after a completed run — the intermediate `_val_1`/`_val_2` files are removed once clipping has used them.

`Output/Aligned/` and `Output/Ready/` are both kept. Nothing deletes a BAM.

### Sizing storage

Rough guidance for planning, per sample:

| Directory | Relative size | Kept? |
|---|---|---|
| `Data/` | Your input | Yours |
| `Trimmed/` | Slightly under input, after clipping | Yes |
| `Unpaired/` | Small | Yes |
| `Aligned/` | Comparable to trimmed input | Yes |
| `Ready/` | Smaller — duplicates and filtered reads removed | Yes |
| `VCF/` | Depends on variant density, not read count | Partly |
| `Frequencies/` | Larger than the VCF it came from — one row per allele, not per site | Yes |

The two BAM directories dominate. If disk is tight, `Output/Aligned/` is the safe thing to remove after a completed run: step 4 has consumed it, and only a re-run from alignment would need it back.

**`mainDir` needs room for more than scratch.** It holds your reads and reference permanently, the dictionaries built from them, and — while the run is going — every output that a later step still has to read. At peak that is most of a run's intermediates at once. `work/` itself stays small, because it holds symlinks rather than copies.

The peak on `mainDir` falls as the run proceeds, since each artifact leaves for `storageDir` as soon as the last step needing it finishes. A completed run leaves `Utilized/` empty.

# Reference
<!--@ section: reference -->

## Troubleshooting
<!--@ page: troubleshooting -->

### Installation and environment

| Problem | Cause and fix |
|---|---|
| Environment creation fails | `conda update -n base conda`, then retry `./PoolSeqFlow install` |
| Missing dependencies after install | Activate it: `conda activate PoolSeqFlow` |
| A tool is found but misbehaves | Check whether `params.software.*` points at a system binary rather than the environment's — version mismatches are not detected |

### The run will not start

#### `null: command not found`

```text
.command.sh: line 17: null: command not found
```

Your `parameters.config` predates the installed version. An absent parameter interpolates as the literal string `null`, which is why the error names nothing useful and points at a generated script. Rebuild the file — see [Upgrading](#upgrading).

#### `Process requirement exceeds available CPUs`

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

`threads` is larger than the machine. Tasks reserve what they really use, so an oversized request fails at submission rather than quietly oversubscribing. Set `threads` to the cores you have. [Resources →](#resources)

#### `RUN PARAMETER CHECK` or `METADATA CHANGE CHECK` fails

Working as designed. An analysis-affecting parameter, or the analysis-affecting part of `metadata.csv`, differs from what produced your existing outputs. Because completed steps are skipped by looking for output files, continuing would mix results from two configurations in one folder.

The report names what to delete, and how much that is depends on what you changed — a reordered file invalidates less than an edited tag value, and a changed pool size less again. Deleting what it names clears the check. Or `PoolSeqFlow reset` to discard everything. [Why →](#the-run-refuses-to-mix-settings)

#### `PIPELINE VERSION` fails

These results were produced by a different release. A project belongs to one release, so this one is absolute: nothing else is compared and there is nothing to delete selectively. Either finish the project under the release that started it — every installed version is on your `PATH` by its own name — or `PoolSeqFlow reset` and start again under this one. [Why →](#a-project-belongs-to-one-release)

#### `METADATA CHECK` reports a duplicate `SampleID`

A `SampleID` appears more than once. A row is looked up by it and only the first match is read, so the duplicate would have silently given a sample the wrong read-group tags — producing a valid BAM that nothing downstream could flag. Every problem in the file is reported at once, with line numbers, so fix the whole list before rerunning.

#### `DIRECTORY CHECK` fails

`mainDir` and `storageDir` are the same path, or one of them is the installation. They are two storage tiers and an output moving from one to the other is what marks it finished, which cannot mean anything if they are one place. The installation is a tool that is replaced wholesale on upgrade, so a project inside it would not survive one. [Why →](#symbolic-links-instead-of-copies)

### Failures during the run

#### `no usable clip range`

```text
CLIPPING READS <sample>: ERROR: no usable clip range in <file>
CLIPPING READS <sample>: exit 3 = unexpected FastQC header; 4 = no cycle within at_gc_error (0.025)
```

Exit **4** means no read cycle had A/T and G/C ratios inside `at_gc_error`. On a GC-skewed genome this is expected, not a fault — raise `at_gc_error`.

Exit **3** means the FastQC per-base composition table did not have the expected `A`/`T`/`G`/`C` columns, which points at a FastQC version change or a corrupt report.

[Trimming & Clipping →](#when-it-refuses-to-run)

#### Symbolic link errors

Confirm you are on Linux or macOS. Windows — including WSL under some filesystem configurations — is not supported. Also check that `storageDir` is still mounted and was not cleared while the run was in flight.

#### A step fails and I cannot tell why

`.nextflow.log` names the failing process. Each step also mirrors its own `.command.log` and `.command.err` into `Logs/<step>/`, which is usually more readable.

For a reproducible failure, set `threads = 1`. That removes concurrency as a variable and makes the logs sequential.

### Results are not what I expected

#### Fewer sample columns than samples

Rows in `metadata.csv` sharing an `RG_Sample` are merged into one VCF column and their depths add together. Eight FASTQ pairs with four distinct `RG_Sample` values give four columns — usually intentional, occasionally not. The pooling is printed at the start of every run, before any compute. [Metadata →](#rg_sample-decides-what-counts-as-a-sample)

#### Sample columns in an unexpected order

Column order follows `metadata.csv` **row order**. Where rows share an `RG_Sample`, the merged column takes the position of the first of them. [Metadata →](#row-order-decides-column-order)

#### `REF` does not match my reference genome

Correct. Step 7 re-encodes each site so the most-read allele across the whole cohort becomes `REF`, which is what makes frequencies comparable across samples and runs. If you need the assembly's base, take it from the assembly. [Why →](#4-major-allele-normalisation-step-7)

#### A variant I know is real is missing

Work outward through the chain — a read lost at alignment cannot be recovered later.

| Check | Parameter |
|---|---|
| Was it filtered at alignment? | `cleanBAM.mapq` (30 is strict), `cleanBAM.filter` |
| Was the pileup truncated? | `variantCall.maxDepth` vs your coverage reports |
| Was it seen in too few pools? | `filterFalsePositives.sampleThreshold` — the default discards alleles found in one pool out of eight |
| Below the frequency floor? | `poolSize`, `diploidy` |
| Site removed on quality? | `vcffilter.minQUAL` |

[The Filter Chain →](#tuning-the-chain)

#### Much less depth than I sequenced for

Two usual causes, in order of likelihood:

1. **MAPQ filtering.** At `cleanBAM.mapq = 30`, repetitive genomes lose a lot. Compare read counts in `Output/Aligned/` and `Output/Ready/`.
2. **Duplicate removal.** The step 4 log carries `markdup -s` statistics; a high duplicate rate is a library-prep problem, not a pipeline one.

#### Depth plateaus at a round number

`variantCall.maxDepth`, default 2000, caps reads considered per file per position. Deep pooled libraries exceed it, and the truncation biases every frequency at those positions. [maxDepth →](#maxdepth)

#### Genotype-based tools find nothing in my VCFs

`FORMAT/GT` is set to `./.` throughout, deliberately — a pool has no genotype, and leaving bcftools' diploid call in place would invite tools to read it as one. Use `AD` and `DP`.

#### Annotated VCF contains sites missing from my frequency tables

Step 8 runs on step **6**'s output, in parallel with the frequency branch, so it never sees the step 7 filters. Its allele encoding is also the original reference-based one, not the major-allele normalised one. Join on `CHROM`/`POS` and expect unmatched rows. [Details →](#the-vcf-files)

### Resume behaviour

#### A re-run skips too many steps

Steps skip themselves when their outputs already exist. Delete the stale outputs, or `PoolSeqFlow reset` to start over.

#### A re-run submits every job anyway

Expected. Step-skipping happens inside each task rather than before it, so a fully resumed run still submits roughly one short job per process per sample. [Resume Logic →](#resume-logic)

#### `-resume` appears to do nothing

Correct — PoolSeqFlow does not use Nextflow's `-resume`, and the wrapper never passes it. `PoolSeqFlow run` already resumes. [Resume Logic →](#resume-logic)

#### A step reruns after an interrupted job

If the interruption hit a cross-filesystem move, the partial file was left as `.part` rather than under its final name, so the step correctly runs again. That is the atomic move working.

### Getting help

Include the failing step, the relevant `Logs/` excerpt and your `parameters.config` with paths redacted when opening an issue: [github.com/ozankiratli/PoolSeqFlow/issues](https://github.com/ozankiratli/PoolSeqFlow/issues)

## Changelog
<!--@ page: changelog | include: CHANGELOG.md -->

## Citation & License
<!--@ page: citation -->

### Citing PoolSeqFlow

The installed copy will print its own citation, with its version filled in:

```bash
./PoolSeqFlow cite
```

Use that rather than copying from here — it knows which version you have, and this page does not.

### Which DOI to use

Zenodo issues **two kinds of DOI**, and the difference matters.

| DOI | What it identifies | Use it for |
|---|---|---|
| [10.5281/zenodo.19245611](https://doi.org/10.5281/zenodo.19245611) | **All versions.** Always resolves to the newest release | Referring to PoolSeqFlow as a piece of software — a related-work mention, a README, a link |
| A version DOI, one per release | **One specific release**, frozen | **Reporting results.** This is the one a methods section needs |

!!! warning "Cite the version you ran, not the newest one"

    Results depend on which release produced them. Filters, defaults and parameter names have all changed between versions — `vcffilter.minDP` went from having no effect to removing whole sites, and sample column ordering changed in 2.1.1. A paper citing the current release for numbers produced by an older one is describing a method it did not use.

    Find the version that produced a given set of results in that project's `Output/run_parameters.txt`, which lists every release that has run there — `./PoolSeqFlow version` tells you only what is installed now, which is not the same thing once you have upgraded. Then open the [all-versions record](https://doi.org/10.5281/zenodo.19245611) and pick that version from the **Versions** list to get its DOI.

    If more than one version is listed, the outputs were not all produced by the same release: completed steps are not redone on upgrade. Say so in your methods, or `./PoolSeqFlow reset` and re-run under one version.

### Reference

> Kiratli, O. L. Z. (2026). *PoolSeqFlow: A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data* (Version *x.y.z*) \[Computer software\]. <https://doi.org/10.5281/zenodo.19245611>

```bibtex
@software{kiratli_poolseqflow,
  author  = {Kiratli, Ozan L. Z.},
  title   = {PoolSeqFlow: A Nextflow pipeline for allele frequency
             analysis from pooled Illumina sequencing data},
  version = {x.y.z},
  year    = {2026},
  doi     = {10.5281/zenodo.19245611},
  url     = {https://github.com/ozankiratli/PoolSeqFlow}
}
```

Replace `x.y.z` with the version you ran, and swap the DOI for that version's own.

### Citing the tools it runs

PoolSeqFlow orchestrates other people's software, and a methods section should credit it. **You do not have to assemble that list yourself.** Every run writes it, beside the results it produced:

```text
storageDir/Output/
├── CITATIONS.md      ← readable, for a methods section
└── references.bib    ← BibTeX, for a bibliography
```

Both are generated from the run that produced them, which makes them accurate in two ways a static list cannot be:

- **They carry the versions that actually ran**, asked of each tool at run time rather than read from the environment file. If you repointed a tool at a system installation with `params.software`, the version recorded is the one that did the work.
- **They list only what the run invoked.** A run with `annotate = false` never calls SnpEff, so SnpEff is not in its citations — citing it would be claiming a step that did not happen.

The tools a full run credits:

| Tool | Used for |
|---|---|
| Nextflow | Workflow execution |
| FastQC | Read quality metrics, and the composition table driving clipping |
| Trim Galore | Adapter and quality trimming |
| Cutadapt | Composition-aware clipping |
| BWA | Alignment (`bwa mem`) |
| SAMtools | BAM processing, duplicate removal, filtering |
| BAMtools | Alignment statistics |
| BCFtools | Variant calling, normalisation, filtering |
| VCFtools | Depth/quality filtering and SNP/INDEL splitting |
| SnpEff | Variant annotation, if enabled |
| Python | The pipeline's helper scripts |

SAMtools and BCFtools share one paper, so the bibliography carries that reference once while both tools are named in the readable list. Two tools are deliberately absent: the JVM, which is a runtime for FastQC and SnpEff rather than a method of its own, and `unzip`.

Exact versions are pinned in `install/environment.yml`, and the versions for the current release are listed under [Requirements](#requirements).

### License

PoolSeqFlow is licensed under the [Apache License 2.0](https://github.com/ozankiratli/PoolSeqFlow/blob/main/LICENSE).

The tools it invokes carry their own licenses, which are not affected by this one.

### Contact

**Ozan L. Z. Kiratli**

- GitHub: [@ozankiratli](https://github.com/ozankiratli)
- Issues: [github.com/ozankiratli/PoolSeqFlow/issues](https://github.com/ozankiratli/PoolSeqFlow/issues)
- Website: [ozankiratli.github.io](https://ozankiratli.github.io)
