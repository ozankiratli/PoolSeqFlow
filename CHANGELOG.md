# Changelog

All notable changes to PoolSeqFlow will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [3.1.0] - 2026-09-10

**This version makes the module system do what it was built for.** 3.0.0 introduced modules that are published, versioned and installed on their own timetable — and then shipped three of them inside the release, which is the one thing that design was meant to avoid. A module in the payload is a module that moves when the pipeline moves. Now nothing ships: `analysis/modules/` is a store that arrives empty and holds what you put in it.

**Upgrading leaves you with an empty module store, and that is the whole of the upgrade.** Ask the release you are leaving what it has, then install each into the new one. Nothing else moves: your projects, your configuration and every analysis already published are untouched, and the old release keeps its own modules and still runs.

```bash
PoolSeqFlow-3.0.0 analysis modules list      # what the old release has
PoolSeqFlow analysis modules install mds     # and again, into the new one
```

**`PoolSeqFlow check` now takes a word.** There are two questions — is this installation sound, and is this project sound — and one command answering both meant answering neither well. A bare `check` is refused rather than guessing which you meant, because whichever it picked would leave the other unchecked while reporting success.

### Changed

- **No module ships inside a release, and no library either.** `analysis/modules/` is the install store: gitignored, absent from the tarball, and empty until you install something. `PoolSeqFlow analysis modules install <name>` puts one there. This is what lets a module be fixed, improved or published without waiting for a pipeline release — and the cost is that a new installation starts with nothing in it and you choose what goes back.
- **A module arrives with the libraries it declares.** The shared arithmetic more than one module wants — effective pool size, gene diversity, per-site allele frequencies, Nei's distance, the chunking — is now five libraries, each published and versioned like a module and installed into `analysis/modules/lib/`. You never ask for one by name: it arrives with whatever needs it, and leaves when nothing installed still declares it. A published result still carries the library code folded into the script that produced it, so a result explains itself whatever the store holds later.
- **`check` is two commands.** `check install` verifies the installation — every tool the release is built to run, and every helper in `bin/`. `check project` verifies a project — that `parameters.config` is current and parses, that `metadata.csv` and the run table parse, and that every command resolves *as that project configures them*, so a tool repointed at a system binary is checked the way the run will call it. Run `check install` from anywhere, including before you have a project; run `check project` from your project directory.
- **`check install` asks the release's own environment rather than your `PATH`.** Every tool it looks for is pinned in `install/environment.yml`, so one that resolves from anywhere else means the environment is missing a package and your system's copy is standing in — at some other version, on your machine only. That is now reported as `OUTSIDE THE ENVIRONMENT` and fails the check. It is worth catching because it is quiet: the pipeline runs, the results look fine, and nothing reproduces anywhere else.
- **The installation directories say what they are for.** `bin/` holds everything that is run rather than sourced, the check scripts included; `lib/` holds what is sourced; `install/` holds the two pinned environment files and nothing else; and `citations/` is new, holding the pipeline's own `references.bib` and the `citations.json` generated from it. Nothing you set moves, and no project is affected.

### Added

- **`PoolSeqFlow check project`** — the configuration and the commands a project names, checked without spending a run. It reads `parameters.config` through Nextflow itself and the two tables through the same parsers step 0 uses, so what it tells you is what a run would tell you.

### Fixed

- **Uninstalling a module could take a package another module still needs.** The keep-list is built by reading one manifest per installed module, and the reader did not terminate its last line — so with several modules in the store the last package of one and the first of the next arrived joined, and a name at that boundary dropped out of the list of things to keep. The same defect applied to libraries. The shipped modules declared no packages, so this could only be reached by a module published against 3.0.0 that declared its own.
- **Uninstalling a module could take a package the release itself is built on.** A module declares what it needs whether or not the baseline already carries it, so `r-ggplot2` appears in a manifest and in `install/environment-analysis.yml` both. The removal now subtracts the baseline, and nothing the release provides can leave with a module.

### Commits

- (91e027f) Publish the three shipped modules
- (45770fd) Release notes now reads from changelog
- (7428880) install no longer checks for paramters.config, which is not in the install folder anymore
- (6d38c88) Full rework of modules
- (598d955) wrapper check is aligned with the current file structure
- (4f8a313) citations move to their own folder
- (dbc522d) modules rework continued
- (c9b26e2) check project fix
- (bdd3c93) Major bug fixes related to the migration of files to different folders
- (ae1af19) Release notes updated

---

## [3.0.0] - 2026-09-10

**This version is about accessibility.** I tried to do as much engineering as possible using the most common tools and knowledge to make sure that the pipeline can create reproducible results for the users. The outputs now contain, not only the parameter set used in each analysis, there is a list of citations for all the tools used for each portion of the analysis. The pipeline refuses to run when parameter combination is changed mid-run, this is because, one cannot say which one is used for certain analysis if they change it mid-run. This was a reproducibility choice. However, if the user wants to compare multiple parameter combinations, multi-run feature is added. The pipeline handles it in the most efficient way, by finding where the divergent parameter applies and creates separate workflows for each parameter combination. Analysis layer is built to accommodate different ploidies and multiallelic sites. I also improved the manual/website which now has all explanation and history about the tool.

**Upgrading is not automatic and it is not optional reading.** Your project now has two directories instead of one, `RGTags.csv` is replaced by a file that does not convert from it, and the depth ceiling is measured per sample rather than fixed. Run `./PoolSeqFlow migrate_config` before anything else — it carries your settings across, prints the `mv` commands for the files that have to move, and explains each change in place. A configuration from 2.2.0 is now **refused** rather than half-read, so there is no way to discover this partway through a run.

**The pipeline also grew a second half.** `./PoolSeqFlow analysis` runs statistical modules over a finished run's frequency tables: three ship in this release, more install from a repository without waiting for a PoolSeqFlow release, and every published result carries the script that produced it, the assumptions it was computed under, and a PDF report. It runs in its own conda environment and does not touch the pipeline's.

### Changed

- **A project now has two roots and they must be different paths.** `mainDir` holds your reads, reference, `parameters.config` and `metadata.csv`, and is where you launch; `storageDir` holds finished results. Before 3.0 there was one directory doing both, called `projectDir`. `migrate_config` renames the parameter, reports it under `Renamed this release`, and prints the moves for the files that were on the old root — it never moves anything itself.
- **`RGTags.csv` is replaced by `metadata.csv`, and it is not a rename.** The old file carried SAM read-group tags and nothing else. The new one describes the experiment: it names each sample, decides which rows merge into one pool through `RG_Sample`, and carries per-sample pool sizes and adapters. It also has somewhere to put the experiment itself — `exp_` for what you set, `pt_` for what you measured as a response, `cov_` for what you measured alongside — which is what the analysis layer reads. **Nothing converts the old file, and the run stops at step 0 until the new one exists.** Start from `metadata.csv.template`, which documents every column.
- **The depth ceiling is measured per sample instead of fixed at 2000.** Step 5 reads each sample's own depth histogram and step 6 caps that sample's BAM before calling, so a shallow library is no longer judged at a deep one's ceiling. `capBAM.maxDepth = -1` is that measurement; `variantCall.maxDepth` becomes a second ceiling on top of it and ships as `0`, which mpileup reads as no limit. Your old `2000` is **not** carried across, and `migrate_config` reports it under `Format changed this release` with the reason. **To reproduce 2.2.0 results exactly: `variantCall.maxDepth = 2000` and `capBAM.maxDepth = 0`.**
- **Pool size, ploidy and detection sensitivity can vary per sample**, set in `metadata.csv` through `param_poolSize`. One number for a whole run judged a pool of 10 at a pool of 500's resolution. Rows sharing an `RG_Sample` must agree, and a blank cell counts as a different answer rather than as agreement.
- **Parameters renamed for what they do rather than which tool runs them.** `samtools.*` is `cleanBAM.*`, `bcftools.*` is `variantCall.*`, `diploidy` is `ploidy` — the pipeline was never limited to diploids and the name said otherwise. `migrate_config` carries every value across.
- **A configuration from an older release is refused rather than partly read.** Nextflow reads `parameters.config` as given, so an absent parameter used to interpolate into a path as the literal string `null` and the run started anyway. `run`, `resume`, `dryrun`, `reset`, `analysis complete` and running a module now stop and name `migrate_config`. `clean`, `dryclean` and `migrate_config` itself are unaffected.
- **The `cores` block and the tool `options` strings are computed for you and ship commented out.** They are not gone: `migrate_config` reports them under `Still yours to set`, and uncommenting a line takes one back. Coming from 2.2.0 that is thirteen parameters — the eight `cores` values and the five `options` strings your file already had.

### Added

- **The analysis layer.** `./PoolSeqFlow analysis <module>` runs a module over a finished run's frequency tables, in a conda environment of its own that `./PoolSeqFlow analysis install` creates. Three modules ship: **`basicstats`** (site counts, depth, effective pool size and gene diversity per pool), **`association`** (each allele's frequency regressed on a phenotype measured per pool, with a permutation *p*), and **`mds`** (the pools placed by Nei's minimum distance, corrected for sampling, on a classical MDS). Each publishes the script that produced its numbers, the shared library folded in, a `references.bib` for the methods it used, and a PDF report of the whole folder.
- **Every module states what it cannot answer.** A module's manifest carries its assumptions and its limits as text, and the run prints them beside the result — the permutation floor a small design cannot go below, why an MDS distance can be negative and that this is correct, that a capped BAM is biased toward reads mapping earliest. A result that is model-based says so where it is read.
- **A module store and a repository.** `./PoolSeqFlow analysis modules {list|available|install|uninstall}` installs a module published separately from the pipeline, with its conda packages, checked against a checksum and against what this release can run. Installing one that needs a GPL package tells you so: the pipeline stays Apache-2.0 and each module carries its own license.
- **Every run writes its own citations.** A pipeline run leaves `citations.txt` in `Output/`, naming each tool it actually invoked with the version that tool reported — probed at run time, so a tool repointed at a system binary is recorded as what ran rather than as what shipped. A published analysis carries `CITATIONS.md` and `references.bib` beside its results, covering the methods each module used as well as the software. What to cite stops being something you reconstruct months later.
- **Multi-run projects.** One data source, several parameter sets, described in `runs.csv` with `multiRun = true`. Runs sharing an input share the work rather than repeating it, and step 0 prints what is shared before any compute is spent.
- **`./PoolSeqFlow dryrun` and `dryclean`** — check the configuration and preview what a run would do, writing nothing into either root, then remove the preview.
- **`./PoolSeqFlow init`** — populate an empty directory with the template configuration and metadata, ready to edit.
- **Several versions install side by side.** Each release has its own environment and payload, so an in-flight project can finish on the release it started on. `./PoolSeqFlow list` shows what is installed and `uninstall` asks which.
- **A test suite**, nineteen suites split by what they cost, so a change runs only the cases it can reach: `test/run_tests.sh --changed` picks them from the file you edited. A module ships its own cases inside its own directory.
- **Both conda environments are pinned to exact builds.** `install/environment-analysis.yml` was a hand-written specification and is now an export of an environment the full suite passed against, as `install/environment.yml` already was.

### Fixed

- **FastQC was given up to eight threads and needed two.** Its `-t` counts *files* processed simultaneously, not threads per file, and step 2 hands it one pair. Measured on a pair of 2M-read files, `-t 2` is 1.93× faster than `-t 1` while `-t 4`, `-t 6` and `-t 8` are no faster at all — and every thread past the second costs roughly 250 MB of resident memory, twice per sample. On a memory-constrained machine that is the difference between a run finishing and being killed. The documented ladder always said two; the code had drifted.
- **`DepthProfile` declared one of the three files it publishes**, so the depth histogram and the depth report were outside Nextflow's tracking and outside the skip that avoids rebuilding them.
- **Two data-loss defects in `atomic_mv.sh`**, both found by reading rather than by a failure: moving a directory onto an existing one could lose a file that only the destination had.
- **`snpEff`'s configuration file is settable through `parameters.config`** rather than fixed, and multiple annotation databases are supported.
- **The step 7 intermediates are no longer published.** `<name>_sort_fp_dq.vcf` and the split SNP and INDEL VCFs had been landing in `Output/VCF/` since 1.0; the called VCF and the annotated one are what a run keeps.

### Removed

- `params.gff`, `params.dir.scripts`, `params.dir.output.temp`, and `rgTagsFile` with `rgTagsPath`. `migrate_config` reports each under `No longer used`. There are no legacy fallbacks anywhere in the pipeline: a parameter that is gone is handled at migration and nowhere else.

### Commits

- (922c3b3) Manual is mostly moved to github pages
- (f9b3437) Version check is added.
- (85fbe74) Merge checks added
- (b7f95eb) pipefails added
- (a52da7f) pipefail added, atomic move implemented on reference file
- (a57e01b) Copy check added to BuildSnpEff
- (78f85c1) Raw filename check is enforced
- (15832fe) RGTags column count check enforced
- (513d417) VerifyAll now publishes the results in the output folder.
- (163ec6e) Log management improved, older logs are now retained
- (012f0d1) Hyphen is now accepted separator for reads
- (dc1e5a1) Combined log of the last run is assembled as a single file
- (afd78b6) Temporary file management improved
- (57251ce) conda env check hardened, rm legacy files explained
- (8902645) atomic move hardened
- (e440fa5) better config migration rules implemented
- (2d26123) bump version is improved
- (7a782a0) pycache is untracked
- (14e847d) version enforcement clarification, version bump fix
- (269d64c) Minor fixes in dictionary counting
- (2318a89) Medium importance fix on snpeff config file, now can be set properly through parameters
- (5d516a8) Support for multicharacter mate tokens added
- (c6d8dda) script hardening for midstream failures
- (372ac66) NextFlow warning sweep
- (5ed5002) Fix for a bug introduced in the previous stage.
- (eb777cf) Test suite added
- (af0d04e) Multiple versions become installable going forward
- (c2e1bf7) Added features to list all installed versions and uninstall all
- (69c8dac) cutadapt min length is clarified, and guards added
- (1e1fdbf) Test suite is being implemented now testing 30 cases
- (81edc1d) Environment creation with new version control is fixed
- (bc3b212) A script for preparing a new version is added
- (1e10c77) projectDir is renamed as storageDir for clarity
- (9ffe284) snpEff improvement for multiple database support, verify env improvements
- (9d8a17b) mainDir and storageDir cannot be same anymore, guards added.
- (2ee0e27) classify_manifest moved to its own script, test suite efficiency improved
- (79efcd2) parameter control automated, override is still allowed
- (9b37dbc) Directory for install is now separate and checked
- (6516431) storage management improvements are being implemented
- (991addf) Install function now installs the wrapper and scripts and multiple versions can be installed
- (2b75a6c) completion checks started to be built
- (cb72804) Dictionary tests are added
- (070fb81) trim paths are fixed for storage management
- (12e12d8) fastqc files, aligned bam, and bai files storage improvements
- (de7e288) rest of the storage management is done
- (065fcc7) clean and reset reworked to address previous changes
- (f38267a) The first half of multi-run work is completed
- (8546b50) Multiple runs from a single data source is added
- (1afb0d7) Process redundancy is resolved
- (3a3a10a) Directory structure clarified
- (6cc24e8) target.dir is removed
- (5cde1a4) make dir is added as a bug fix
- (9f4e647) sharing is implemented
- (048bd33) Environment verification is now aligned with multi-run
- (7f30177) verify environment is now checking parameter changes midway, version change mid-run is blocked
- (360cfbd) dryrun and dryclean added
- (1cd315c) Multiple bug fixes
- (c28fbdc) metadata.csv replaced and expanded rgtags.csv
- (4bdd3aa) per sample poolsize and sensitivity added, metadata addition is complete now
- (f2ec822) docs management streamlined with a master manual.md
- (00da07d) gitignore, gitattributes, and github workflow changes to reflect docs management
- (982e0c4) init project added, uninstall improved
- (7ad02c1) major documentation and comment overhaul
- (cc00833) parameter renaming for clarity, samtools is now cleanBAM and bcftools is variantCall
- (c3a3191) automatic maxDepth calculation added
- (da95a4b) Major commit: Analysis layer arrived, install and uninstall repaired, docs fixed
- (4303166) analysis.nf added to payload items
- (7810c56) Analysis layer foundation is being worked: verify analysis, tests, and config templates are in
- (f5c6135) Analysis output control mechanism
- (c209cce) Minor fixes on analysis related changes
- (abe00fb) the module store landed
- (5fafa80) analysis libraries are being built to allow modular statistical tools design
- (7d65893) analysis wrapper is folded inside the main wrapper
- (b432794) Docs and comments pass
- (4a5f635) Two invocation launch for analysis layer
- (0c82ac9) main.nf verification for each module
- (bf0dcfd) Module development rules added
- (d9886c5) Modules manifest and management subcommands added
- (f4f1104) fixed atomic.mv concurrency issue
- (9567e2a) module analysisPlan fix
- (ebf08a2) analysis writing results safely, intermediate checks, granular move back
- (77fdbd7) atomic_mv fix for multiple failure scenarios, rsync dependency added
- (f4508f5) analysis complete command moves files to storage, the resume copies them back to do the analysis
- (1f1fbcf) clean now cleans staged files, default params are hardcoded for analysis
- (c164ec5) defaults.config is now frame.config and users should not change it
- (e2406fa) provenance, frame and modules versioning
- (9cb22fe) R script is emitted along with results now
- (4c3d394) citations for modules added, test suite fixes
- (e76774a) Comment cleanup
- (aa48373) snpEff reports are both copied now
- (9f9b7da) histogram ceiling is a parameter, archive gate enumerates, glob loops guarded, execution defaults reachable
- (a06c312) analysis lib nf files moved
- (4cb4ae7) the experimental design, module settings, and how a result says to read itself
- (2915346) time variable is now configurable, time series feature added
- (fabdb5c) diploidy, poolsize are recovered from metadata
- (c6544d7) Fixes on derived parameters
- (381541e) F1 basicstats, and the PDF report every analysis carries
- (d674e8f) Split the suite, and run only what a change touches
- (306dd26) phenotype variables pt_ and covariate variables cov_ are added to the metadata
- (f2a7774) Manual and development notes are added
- (e3eb887) allele frequencies, benchmark comparisons added, analysis versioning fixes made
- (15d4c34) experimental design and covariate readjustments
- (12633a6) association analysis, validation of association, tests, reorganization of analysis.config
- (4cb4cff) Comments housekeeping
- (d024dd1) mds landed
- (409aef7) Language corrections for drift
- (d92411e) module store landed, the depth profile bug fixed
- (77cb91e) docs and comments pass
- (fc3d2a1) realease prep, minor fixes
- (e384928) Repo structure is created
- (268f508) Manual check, better metadata
- (12a1eb6) manual updates
- (2b5236f) fastqc now limits the cores to 2
- (abaa496) prep version script now covers analysis
- (ff08f61) Environment upgrade
- (e539333) config migrate prepared, new guards enforce it

---

## [2.2.0] - 2026-08-16

**This release changes results.** `vcffilter.minDP` previously had no effect on the output at all; it now removes sites. Read the first entry under Changed before upgrading a project that has outputs you intend to keep — and expect step 0 to stop your next run, because the analysis parameters have changed. That is the guardrail working; the report names the folders to delete.

Alongside that: a documentation site, an installation check that fails an install rather than letting a half-built environment through, and a release process that publishes a verified download so nobody has to clone the repository to use the pipeline.

### Changed

- **`vcffilter.minDP` now filters, where before it did nothing.** The depth filter was `vcftools --minDP`, which expresses a failed genotype-level test by rewriting `FORMAT/GT` and nothing else — it never touches `AD` or `DP`, and it never removes a site. Because step 7's major-allele normalization sets every `GT` to `./.` before that filter runs, and because frequency conversion reads `AD` rather than `GT`, the setting had no path to the output: running the old command with `--minDP 20` and with `--minDP 50` produced byte-identical frequency tables. It is now `bcftools view -e "FMT/DP<N"`, applied before the quality filter. **The test is per site, not per sample: a site is removed if *any* sample falls below the depth**, so the weakest library sets the threshold for the whole cohort. Check `Output/Reports/Coverage/` for your least-covered sample before trusting the default of `20` — on a run with one thin library it can remove most of the call set.
- **`params.vcftools` is now `params.vcffilter`.** The block never mapped to one tool and now genuinely does not: depth filtering is bcftools, quality filtering is vcftools. `./PoolSeqFlow migrate_config` carries your values across to the new names and reports them as `Renamed this release`.
- **Two bcftools parameters were the wrong way round.** `baseQualMin` supplied `mpileup -q`, which is the *mapping* quality minimum, and `varQualMin` supplied `-Q`, the *base* quality minimum. Both default to `30`, so no run changes behavior — but anyone who tuned one was tuning the other.
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

- (2c29d35) Depth filtering fix, and minor config corrections.
- (78ac157) Typo fix, not a functional problem
- (b087cd5) site is added to gitignore
- (8595513) Renaming check is added to the migration script
- (0e63c74) dev files added
- (9687114) Check install status added
- (6b5a549) Release workflow added
- (7aae36e) check install added to workflow
- (aaec06c) Citation fixes
- (d423c8e) Website is finished

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

- (6e18762) Minor fix in help for manual use
- (715f822) Parameter change detection added.
- (f73b33d) workDir and reset fixes
- (0f5666f) Output parameters to a file
- (408efb4) File move process improved
- (dc2ea72) Sample ordering in vcf fixed. NF orders samples first come first serve
- (4a9f89d) Sample ordering in vcf fixed. RGTags guardrails added.

---

## [2.1.0] - 2026-08-15

Resource allocation is now declared to Nextflow rather than only passed to the tools, and there is a helper for carrying an older configuration forward.

### Added

- **`./PoolSeqFlow migrate_config`** — rebuilds `parameters.config` from the current template, backs the original up, carries across every setting whose parameter still exists, and reports what it kept, what is new, what the pipeline now computes for itself, and what it dropped. It refuses to carry a value the template derives, so it cannot reintroduce a stale `snpEff.db` or a hand-set thread count. The report is a starting point: a parameter whose behavior changed while its value still looks ordinary will be carried across, so compare against the template afterwards.
- **Every process declares `cpus`**, so Nextflow schedules against real requirements instead of assuming one core per task. Previously three `Align` tasks each using ~2.2 cores ran concurrently on an 8-core machine with `cpus=1` recorded for each.
- `params.memory`, feeding `resourceLimits` alongside `params.threads`, so one place sizes a run.

### Changed

- **Tools now read `task.cpus`** rather than thread counts baked into option strings, so the number Nextflow reserves and the number the tool receives cannot diverge. Overriding `cpus` in a profile now changes the tool's behavior too.
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
- Major-allele normalization: VCF re-encoded so the major allele is always REF
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

[3.1.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v3.1.0
[3.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v3.0.0
[2.2.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.2.0
[2.1.1]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.1.1
[2.1.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.1.0
[2.0.1]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.0.1
[2.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v2.0.0
[1.0.1]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.1
[1.0.0]: https://github.com/ozankiratli/PoolSeqFlow/releases/tag/v1.0.0
