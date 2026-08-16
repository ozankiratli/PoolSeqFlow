# Changelog

All notable changes to PoolSeqFlow will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.2.0] - 2026-08-16

**This release changes results.** `vcffilter.minDP` previously had no effect on the output at all; it now removes sites. Read the first entry under Changed before upgrading a project that has outputs you intend to keep — and expect step 0 to stop your next run, because the analysis parameters have changed. That is the guardrail working; the report names the folders to delete.

Alongside that: a documentation site, an installation check that fails an install rather than letting a half-built environment through, and a release process that publishes a verified download so nobody has to clone the repository to use the pipeline.

### Changed

- **`vcffilter.minDP` now filters, where before it did nothing.** The depth filter was `vcftools --minDP`, which expresses a failed genotype-level test by rewriting `FORMAT/GT` and nothing else — it never touches `AD` or `DP`, and it never removes a site. Because step 7's major-allele normalisation sets every `GT` to `./.` before that filter runs, and because frequency conversion reads `AD` rather than `GT`, the setting had no path to the output: running the old command with `--minDP 20` and with `--minDP 50` produced byte-identical frequency tables. It is now `bcftools view -e "FMT/DP<N"`, applied before the quality filter. **The test is per site, not per sample: a site is removed if *any* sample falls below the depth**, so the weakest library sets the threshold for the whole cohort. Check `Output/Reports/Coverage/` for your least-covered sample before trusting the default of `20` — on a run with one thin library it can remove most of the call set.
- **`params.vcftools` is now `params.vcffilter`.** The block never mapped to one tool and now genuinely does not: depth filtering is bcftools, quality filtering is vcftools. `./PoolSeqFlow migrate_config` carries your values across to the new names and reports them as `Renamed this release`.
- **Two bcftools parameters were the wrong way round.** `baseQualMin` supplied `mpileup -q`, which is the *mapping* quality minimum, and `varQualMin` supplied `-Q`, the *base* quality minimum. Both default to `30`, so no run changes behaviour — but anyone who tuned one was tuning the other.
- **Citations point at the Zenodo concept DOI** ([10.5281/zenodo.19245611](https://doi.org/10.5281/zenodo.19245611)) rather than a version DOI. The badge previously pointed at the v1.0.0 record, which is frozen and therefore permanently flagged "a newer version is available". The concept DOI always resolves to the newest release. Papers should still cite the *version* DOI of the release they ran — `./PoolSeqFlow cite` explains which and why.
- **`install/install.sh` removed.** The wrapper's `install` subcommand creates the environment itself and never called it; the script also used a relative path to `environment.yml` and a `conda activate` with no shell hook, so running it directly would not have worked either.
- `cutadapt.min_length` is still not applied, and the template now carries a commented-out `options` line to switch it on deliberately rather than leaving the parameter looking active.

### Added

- **A documentation site** at <https://ozankiratli.github.io/PoolSeqFlow/>, built with MkDocs Material and published from `main` by GitHub Actions. It goes well beyond the README: when Pool-seq fits and when it does not, why the pipeline replaces Nextflow's `-resume` and what that costs, the full filter chain from alignment flags to frequency conversion with what each stage removes, and how to read the frequency tables. Broken internal links fail the build.
- **`./PoolSeqFlow check`** — verifies an installation and reports what it finds. Every command the pipeline invokes, with the version each reports; every helper in `bin/`, present *and* executable, since they are called by bare name off `nextflow.config`'s `PATH` and a lost executable bit fails mid-run; and that `parameters.config` parses. With a config present the tool list is read from `params.software` through `nextflow config`, so a command repointed at a system binary is checked as configured rather than as shipped. It also runs at the end of `install` and **fails the install** if anything is missing — an environment that was created but is short a tool would otherwise surface partway through step 4, hours in.
- **`./PoolSeqFlow cite`** — prints the citation for the copy you have, with its version filled in, and explains which DOI to use.
- **A release workflow.** Tagging `v*` publishes a curated tarball: the pipeline only, in a versioned directory, built with `git archive` so the executable bit on `./PoolSeqFlow` and `bin/*` comes from the git index rather than the runner's umask. What ships is decided by `export-ignore` in `.gitattributes`, and the workflow asserts both directions — required files present, repository furniture absent — along with the executable bits, shell syntax and the version the extracted wrapper reports. It refuses to publish unless the tag, both version strings in `./PoolSeqFlow` and a changelog section all agree. `SHA256SUMS` is attached, and `PoolSeqFlow.tar.gz` carries a stable name for scripted installs.
- **`config_migrate.sh` handles renamed parameters.** A rename was previously two unrelated events — one `DROPPED`, one `NEW` — and your tuned value silently reverted to the template default. Renames now carry the value across and report it as `Renamed this release`. If a rename also changes what the parameter *means*, adding it to `reformatted()` makes the template value win while still surfacing the change.

### Fixed

- The sensitivity formula in `bin/filterFalsePositives.sh -h` now reads `s = 1 / (2 * [DIPLOIDY] * [POOLSIZE per SAMPLE])`, matching what `parameters.config` computes. The correction in 2.1.1 was itself wrong. Help text only; the value the pipeline passes was never affected.

### Commits

- Depth filtering fix, and minor config corrections. (2c29d35)
- Typo fix, not a functional problem (78ac157)
- site is added to gitignore (b087cd5)
- Renaming check is added to the migration script (8595513)
- dev files added (0e63c74)
- Check install status added (9687114)
- Release workflow added (6b5a549)
- check install added to workflow (7aae36e)
- Citation fixes (aaec06c)
- Website is finished (d423c8e)

---

## [2.1.1] - 2026-08-15

A stability release. Nothing new to configure and no change to how a run is invoked — this closes the gaps where a result could be quietly wrong or quietly irreproducible. An existing `parameters.config` needs no changes.

### Added

- **Step 0 refuses to run when the analysis parameters changed** since the existing outputs were produced. Completed steps are skipped by looking for output files, not by checking what produced them, so a changed `poolSize` or filter threshold would otherwise leave one output folder holding results from two different settings. The values behind a set of outputs are recorded in `.poolseqflow_params` and mirrored to a read-only `Output/run_parameters.txt`. Path, resource and software parameters are excluded; anything added in a later release counts as analysis-affecting until decided otherwise.
- **Step 0 refuses to run when `RGTags.csv` changed** after the file was consumed. The tags are written into the BAMs at step 4 and the row order is fixed into the VCF at step 6, and neither is re-derived once its output exists. The report separates a changed tag value (invalidates `Ready/`, `VCF/`, `Frequencies/`) from a reordering (invalidates `VCF/`, `Frequencies/` only) and names the folders to delete; deleting them is what clears the check. Projects whose outputs predate this release adopt their current file as the baseline, with a note to confirm it against the BAM headers.
- **Sample columns follow `RGTags.csv` row order**, so results come out arranged the way the samples were laid out rather than however they sort as strings. Where several rows share an `SM`, the merged column takes the position of the first of them.
- **Duplicate `ID` detection.** A row is looked up by `ID` and only the first match is read, so a repeated `ID` silently discarded the later rows and gave that sample the wrong tags — producing a perfectly valid BAM that nothing downstream could flag.
- **CRLF repair for `RGTags.csv`.** A file saved from Excel on Windows carries a stray carriage return into the last tag of every row; it previously failed with `Invalid tag 'PU'`, which names nothing useful. Step 0 now rewrites the file with Unix line endings, preserving permissions and ownership, and reports `RGTAGS LINE ENDING CHECK: FIXED`.
- **`bin/atomic_mv.sh`** — moves that cross a filesystem boundary now stage through a `.part` file and rename into place.

### Changed

- **`workDir` is now under `mainDir`.** It was a relative path, so the scratch/permanent split the pipeline documents was not actually in effect — work directories landed wherever the pipeline was launched from.
- **Variant calling receives its BAMs in a defined order.** `collect()` emitted them in task-completion order, so the sample column order of the VCF varied between runs on identical input; three consecutive runs gave three different orders. The sort keys on the sample id, because the file paths begin with Nextflow's work-directory hash and sorting those is no better than chance.
- **All 22 cross-filesystem moves are atomic.** A plain `mv` across filesystems is a copy followed by an unlink, so a job killed mid-move left a truncated file under its final name — which the existence-based skip logic then accepted as a completed step.
- **`reset` is behind a typed `DELETE_MY_ANALYSIS` confirmation** and also clears `.poolseqflow_params` and `.poolseqflow_rgtags`, which would otherwise fail the next run's checks against outputs that no longer exist.
- **`clean` and `reset` resolve paths through `nextflow config`** rather than parsing `parameters.config` as text. Values are interpolated, so text matching returned the wrong path.
- `RGTags.csv.template` now shows the replicate and `SM`-merge pattern, with `DS` carrying a per-replicate descriptor instead of repeating the sample name.

### Fixed

- The sensitivity formula in `bin/filterFalsePositives.sh -h` was missing a factor of two. It read `s = 1 / ([DIPLOIDY] / [POOLSIZE per SAMPLE])` and should read `s = 1 / 2 * ([DIPLOIDY] / [POOLSIZE per SAMPLE])`. Help text only — anyone who ran the script by hand and followed it would have passed the wrong `-s`.

### Commits

- Minor fix in help for manual use (6e18762)
- Parameter change detection added. (715f822)
- workDir and reset fixes (f73b33d)
- Output parameters to a file (0f5666f)
- File move process improved (408efb4)
- Sample ordering in vcf fixed. NF orders samples first come first serve (dc2ea72)
- Sample ordering in vcf fixed. RGTags guardrails added. (4a9f89d)

---

## [2.1.0] - 2026-08-15

Resource allocation is now declared to Nextflow rather than only passed to the tools, and there is a helper for carrying an older configuration forward.

### Added

- **`./PoolSeqFlow migrate_config`** — rebuilds `parameters.config` from the current template, backs the original up, carries across every setting whose parameter still exists, and reports what it kept, what is new, what the pipeline now computes for itself, and what it dropped. It refuses to carry a value the template derives, so it cannot reintroduce a stale `snpEff.db` or a hand-set thread count. The report is a starting point: a parameter whose behaviour changed while its value still looks ordinary will be carried across, so compare against the template afterwards.
- **Every process declares `cpus`**, so Nextflow schedules against real requirements instead of assuming one core per task. Previously three `Align` tasks each using ~2.2 cores ran concurrently on an 8-core machine with `cpus=1` recorded for each.
- `params.memory`, feeding `resourceLimits` alongside `params.threads`, so one place sizes a run.

### Changed

- **Tools now read `task.cpus`** rather than thread counts baked into option strings, so the number Nextflow reserves and the number the tool receives cannot diverge. Overriding `cpus` in a profile now changes the tool's behaviour too.
- **`TrimReads` reserves Trim Galore's full footprint.** `--cores N` runs N+4 threads (measured: `--cores 8` peaks at 12 OS threads), so the process reserves `cores.trimTotal` and maps back to the worker count. A request larger than the machine now fails with `Process requirement exceeds available CPUs` instead of silently oversubscribing.
- **JVM garbage-collection threads come from `task.cpus`.** `-XX:ParallelGCThreads` was read from a config string, so `cpus` had no effect on SnpEff or FastQC.
- `resourceLimits` moved to `params.threads` / `params.memory`; it was hardcoded and would not follow a change to `threads`.
- Eight parameters removed after the rework left them unreferenced: the five per-tool `threads` values, `fastqc.bundledOptions`, `java.garbageCollect` and `java.options`. Each looked like a knob that did nothing.
- `TrimReads` no longer exports `_JAVA_OPTIONS`; Trim Galore 2.x is a native binary with a bundled FastQC and never starts a JVM.

### Fixed

- **`parameters.config.template` was missing parameters the pipeline requires** — `annotate`, `snpEff.runOptions`, `rgTagsPath`, `diploidy` — and carried a different `vcftools.minDP` and different report directory names. A configuration built from it failed step 0 with `RGTAGS VERIFICATION: STATUS=FAIL`. The template is now generated from the reference configuration and resolves identically to it.
- **Step 7 created the wrong output directory.** `SortRefAltByFrequency` ran `mkdir -p` on the frequencies folder and then moved into the VCF folder, which only worked because step 6 had created it first.
- `parameters.config` contained the `dir { }` block and the reference path assignments twice, byte-identical.

---

## [2.0.1] - 2026-08-12

### Fixed

- `parameters.config.template` was missing the `params.cores` block introduced in 2.0.0, so a configuration created from the template kept the old hardcoded per-tool thread counts instead of deriving them from `params.threads`. Existing runs were unaffected; the template now resolves identically to a 2.0.0 configuration at every `threads` value.

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

[2.1.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.1.0
[2.0.1]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.0.1
[2.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.0.0
[1.0.1]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.1
[1.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.0
