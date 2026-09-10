# The analysis commands

**Written 2026-08-30 and revised 2026-08-31, against the tree at `7d65893`.** The module store landed that same evening in `d9886c5` and `complete` on 2026-09-01, so both sections below headed PLANNED are built, and the module dispatch has changed shape since.

It was the first landing piece of E4b, when the analysis layer had a wrapper of its own. **It does not any more** — Z merged it into `./PoolSeqFlow` on 2026-08-31, so everything here is `PoolSeqFlow analysis <command>`. `wrapper.md` covers the wrapper as a whole; this covers what is particular to the analysis half.

## ONE WRAPPER — Z, 2026-08-31

Z: *"we need to get rid of separate wrappers for the tool. It adds unnecessary complexity and redundancy while a lot of things are already shared. The original wrapper already copies the analysis wrapper in the folder `.local/bin` automatically. This means, the analysis wrapper is part of the installation of main workflow any way. So there is no real reason to maintain them separately… A single wrapper has less surface to cover."*

`PoolSeqFlow-analysis` is deleted. `analysis` is the one subcommand that carries a word of its own; every other subcommand still takes none. **The one-argument contract is amended**, which the separate wrapper had existed to avoid — that trade was reconsidered once the shared surface was visible, and the amendment is cheaper than the second executable.

It widened again within hours, and again since: a module run is `analysis <module> [nocpp]`, and the store is `analysis modules install <name> [<version>]`. What survived is the shape — the top-level subcommands take nothing, and everything variable hangs off `analysis`. `usage_analysis` in the wrapper is the current statement of it, and `four-roots.md` records the same widening from the other side.

What the merge removed, and this is the measure of what a second wrapper cost: an entry in `PAYLOAD_ITEMS`, a second entry in `WRAPPERS` and its two symlinks, a second `VERSION=`/`# Version:` pair for `bump-version.sh` to rewrite and for `release.yml` and `00_static` to police, a duplicate `require_install` / `require_project_config` / `require_env`, and its own installation-root resolution and `wrapper_lib.sh` sourcing. Two sections of this note went with them: the argument about which wrapper owns the symlinks, and the dangling-symlink case that only existed because two executables could be provided by different versions.

**The trap the merge created, and closed.** `install/check_analysis_install.sh` read `ENV_NAME` — and the merged wrapper already exports `ENV_NAME` as the *pipeline's* environment, so `analysis check` would have verified the wrong one and reported success over a missing R. It reads `ANALYSIS_ENV_NAME` now, and the comment in it says why the two are apart. Anything else that shares this wrapper's environment needs the same care.

## What `uninstall` offers — Z's contract, 2026-08-30

Z: *"PoolSeqFlow uninstall should show PoolSeqFlow (the legacy one), and the versioned ones. If a versioned one also has Analysis installed, PoolSeqFlow choosing that one … should remove both the main and the analysis together. [analysis] uninstall should only uninstall the analysis layer."*

This forced a change the `-analysis$` filter alone did not make: **the chooser deals in installation NAMES, not version strings.** `installed_versions()` returned bare versions (`2.2.0`), which cannot represent the legacy environment at all — it has no version, so stripping `PoolSeqFlow-` off it produced nothing and it was silently absent from the list. `installed_installations()` returns `PoolSeqFlow`, `PoolSeqFlow-2.2.0`, and the `uninstall` arm derives the version from the name, leaving it empty for the legacy entry, which has no payload.

Two supporting functions rather than inline printing: `installation_note()` decides what is said about an entry, and `list_installations()` renders the list. The prompt and the non-interactive refusal both call the latter, so they cannot drift into describing the same installations differently — which they previously did.

**Write `installation_note()` with `if`, not `&&`.** `[ x = y ] && notes=…` as a whole statement returns 1 when the test fails, and under `set -e` that exits the wrapper. The project has been bitten by this before — `poolseqflow_envs()` carries a `|| true` for the same reason.

## `uninstall` always confirms, and conda is never asked (Z, 2026-08-30)

Z: *"When someone invokes uninstall it should always ask for confirmation to uninstall. Also for `conda remove -n <name>` can we pass `-y`, because someone saying no to that breaks the uninstall."*

**Always** is the whole point. Three paths previously reached removal with no question at all: the single-installation fast path, the versioned wrapper (`PoolSeqFlow-2.2.0 uninstall`), and the chooser — where *picking which* was silently treated as agreeing to the removal. The confirmation sits after the HAVE_ENV / HAVE_ANALYSIS_ENV / HAVE_PAYLOAD checks, so it can list exactly what exists and will go, and it is skipped only when none of the three is present.

The wording follows `uninstall_all`'s, including `if ! read -r CONFIRM` → abort. **This makes `uninstall` unattendable**, exactly as `uninstall_all` already was. A CI job that ran `PoolSeqFlow-2.2.0 uninstall` will refuse rather than proceed unasked; that is the intended trade and it is stated in the manual.

The `-y` half is a real bug, not tidiness: `conda env remove` prompts, and a user answering no left the wrapper carrying on to delete the payload and report success over an environment that was still there. A static case now greps for a `conda env remove` without it, since the next call site added will not have anyone remembering this.

## An analysis environment is not a version — a real bug, found 2026-08-30

`installed_versions()` built its list by stripping `PoolSeqFlow-` off environment names, so `PoolSeqFlow-2.2.0-analysis` parsed as a version called **`2.2.0-analysis`**. With one release installed plus its analysis environment, `choose_version_to_uninstall` counted two, skipped the single-version fast path, and:

- non-interactively, `PoolSeqFlow uninstall` **refused outright** — "2 versions of PoolSeqFlow are installed" — where before it just worked;
- interactively, it prompted and offered `2.2.0-analysis` as something to remove.

Reproduced against the launcher harness before fixing, not reasoned about. The list now filters `-analysis$`.

**Why nothing caught it:** every existing analysis-env case invoked the *versioned* wrapper, which returns early from the `basename $0` branch and never reaches the chooser. The whole chooser path was untested with an analysis environment present.

## The interactive prompt had never been tested, and testing it broke the runner

`choose_installation_to_uninstall` takes a different branch when `[ ! -t 0 ]`, so a herestring reaches the *refusal*, never the prompt. Every existing case tested the refusal. Covering the selection needs a pty.

**`script(1)` is the obvious way and it silently truncates the suite.** With `script -qec` driving one case, `run_tests.sh` stopped after that case: 18 of 49 reported, no failure, no stderr, exit 0, and the summary printed normally — so it read as a passing 18-case suite. The runner feeds its loop `while read -r fn; do … done < <(comm …)`, and `script` reads its caller's stdin as well as its own redirect, draining the remaining test names. A heredoc on `script` does not prevent it. Isolated reproductions did *not* show this, which is why it took bisecting the suite to find.

`test/tools/on_a_tty.py` replaces it: `pty.fork`, write the answer, drain the master, exit with the child's status, and **never read fd 0**. Under 60 lines and the failure mode cannot recur.

The lesson generalises: **a truncated suite that reports a smaller number of passes looks exactly like a passing suite.** Nothing in the harness notices that fewer cases ran than exist. A guard comparing the discovered count against the reported count would have turned this from a bisect into a message.

## Bare words, not flags — REVERSED 2026-08-30 by Z

It shipped for about an hour as `--install` / `--uninstall` / `--version`. **Z reversed it the same day**: *"we keep the way we use the wrappers consistent. We either add `--` to PoolSeqFlow or lose it from analysis, I say lose it from analysis."*

The argument for flags was the module namespace: a bare `mds` puts every module name in the same argument position as the machinery verbs, so flags would keep the two disjoint for good. **That argument was correct and lost anyway**, because one rule across the CLI is worth more than a namespace collision that will never happen. The words reserved out of the module namespace are `install`, `check`, `uninstall`, `version` and `cite`; nothing in the E4c roster comes near any of them, and if one ever did the fix is renaming a module, not the CLI.

Worth keeping from the reversal: **a consistency argument beats a correctness-in-the-abstract argument when the abstract cost never materialises.** The flags version was defensible on its own terms and still wrong for this project.

## The wrapper keeps no module list

The module name is passed straight through as `nextflow run analysis.nf --module <word>`. The wrapper never validates it beyond its *shape*, because the word names a file.

**`analysis.nf`'s roster is the single authority on what modules exist**, mirroring the main pipeline's step 0. A second copy of the list in the wrapper would drift, and drift silently: the wrapper's copy would refuse a module that works, or accept one that does not exist and let Nextflow produce the error instead.

The price is that a typo starts a JVM before being refused — about 21 seconds. Accepted; the alternative is the drift.

**The dispatch is two Nextflow runs now, and the roster has moved.** A module run is `analysis.nf --module <word>`, which checks the project and clears the results folder, and then `<store>/<module>/main.nf`, which produces the results — a module is a pipeline of its own, so it names itself and `--module` is not passed on. A module the frame provides has no directory and the first run is all of it. The roster itself lives in `analysis/lib/nf/modules.nf`, which a module reads too. The claim above survives all of it: the wrapper still keeps no list, and still validates only shape.

**`complete` — planned when this was written, built 2026-09-01 in `f4508f5`.** Moving `Analysis/` to permanent storage sat in the plan file under E4b. It was advertised in the usage line until 2026-08-31 with no arm behind it, so it fell through to the module dispatcher and came back as *"'complete' is not installed"* — and the test that exists to catch exactly that had it excluded by name. It came out of the usage line and out of the exclusion until it was real. The design call held: it runs as `analysis/complete.nf` rather than shell, because promotion in the main pipeline is `PromoteArtifacts` in `9_completion.nf`, a Nextflow process, and the analysis layer's promotion is the same problem, which should not be solved a second way.

**`modules list|available|install|uninstall` — planned when this was written, built the same evening in `d9886c5`.** Until they existed a refusal could not tell a user to run them, so the module refusal named the store directory instead.

## Check order in the module arm

`require_analysis_install` → `require_project_config` → `require_analysis_env`, copied from the main wrapper's `run`.

Standing outside a project is reported before a missing environment. Both orders are defensible — the environment is missing wherever you stand — but matching the pipeline arm matters more than the marginal improvement, and a user in the wrong directory is the commoner case.

**This bit the tests immediately.** `run_analysis_launcher_with_envs` originally built a sandbox with no `parameters.config`, and `test_a_module_refuses_to_borrow_the_pipeline_environment` never reached the environment check at all. The harness now makes its sandbox a project, and the outside-a-project case builds its own bare directory.

## `install/environment-analysis.yml` — IT SOLVES. Risk retired 2026-08-30

The stage's flagged release risk is **resolved**. Z installed it the same day, having loosened `python`, `bash`, `coreutils` and `r-base` to bare names first — pin what you must, let the solver do the rest, then export what it chose. Measured in the built environment:

| | |
|---|---|
| R | 4.4.1 |
| data.table / ggplot2 / pheatmap | 1.18.4 / 4.0.3 / 1.0.13 |
| optparse / jsonlite / Matrix | 1.8.2 / 2.0.0 / 1.7-6 |
| nextflow / samtools / bcftools / htslib | 26.04.6 / 1.24 / 1.24 / 1.24 |

`openjdk` arrives as a nextflow dependency, so the analysis environment can run Nextflow on its own. **A false alarm worth recording:** calling `$ENV/bin/nextflow` by absolute path with an ambient PATH picks up the wrong JVM and reports "please make sure that Java 17 or later is installed". With the environment's own PATH it is fine. Anything checking this environment must run with it *active*, never by absolute path — which is what `check` does.

**Still to do before v3.0.0:**

1. `dev/scripts/export-environment.sh PoolSeqFlow-<version>-analysis` to replace the hand-written spec with an exact-build export. The script routes an `-analysis` name to the right file and writes the pinned header over the "NOT YET PINNED" one. Not done yet because the versions move again at the release bump anyway.
2. **`dev/scripts/prep-version.sh` still only handles the pipeline environment.** It clones `PoolSeqFlow-<version>` into a scratch env, updates, runs the suite, exports. The analysis env needs the same or a release ships a stale pin.

The package list was a first guess at what the E4c roster needs. It has been revised since: F1 added `r-rcpp` for the compiled path a module may offer, `r-dofuture` for binned per-site work, and `r-rmarkdown`, `r-knitr`, `r-png` and an explicitly named `pandoc` for the PDF report every published analysis carries. Base R still covers more than expected — `cmdscale` (MDS), `prcomp` (PCA), `mantelhaen.test` (CMH), `p.adjust` (FDR) and weighted `glm` (phenotypic association) are all in `stats`. What is actually pulled in is `data.table` for the table sizes, `ggplot2`/`pheatmap` for figures, `optparse` for the module CLIs and `jsonlite` for the provenance sidecars.

`samtools`/`bcftools`/`htslib` are duplicated from the pipeline environment on purpose: the analysis layer derives per-position depth from BAMs in `Analysis/Main`, and an environment that has to borrow the pipeline's is not opt-in.

## `check` and `cite`

Z: *"We will build both check and cite."*

### The R package list has exactly one home

`install/environment-analysis.yml` is the authority, and `analysis_r_packages()` in `lib/wrapper_lib.sh` reads it:

```sh
sed -n 's/^ *- *r-\([^=]*\).*$/\1/p' "$ENV_FILE" | grep -vx base
```

The `[^=]*` matters: the file is unpinned today (`r-data.table`) and will be an exact-build export tomorrow (`r-data.table=1.18.4=r44h...`). Both parse.

**Do not hand-write a second list.** The first design here was an explicit `R_PACKAGES` list in the checker plus a `00_static` case asserting it matched the yml — a guard against drift that could instead be made impossible. Deriving it removes the guard and the drift together.

**conda's name is not R's name.** `r-matrix` provides `Matrix`, capital M, and `library(matrix)` fails. Rather than keep a mapping table, both `check` and `cite` recover the real name case-insensitively from `rownames(installed.packages())`. Verified against the live environment: all six resolve, `Matrix` included.

### `cite` asks R, it does not carry a list

`citation()` and `citation(pkg)` are R's own machinery and every CRAN package ships the record. So `PoolSeqFlow analysis cite` prints the actual installed versions and the authors' preferred form, and a package added to the environment appears with no code change. `--vanilla` so a user's `.Rprofile` cannot alter the output.

It **degrades rather than refuses** when the environment is absent: the software citation always prints, and the R half says why it is missing. Refusing would make `cite` unusable exactly when someone is writing up work done on another machine.

### The citation text lives in `lib/wrapper_lib.sh`

`poolseqflow_citation()` plus `CONCEPT_DOI`. Both `cite` arms call it, so the DOI and the "cite the version you actually ran" argument exist once. Verified by diffing `./PoolSeqFlow cite` against the **deployed pre-refactor 2.2.0 copy** — byte-identical, which is a real before/after rather than a self-comparison.

The DOI still exists twice: here and in `install/citations.json`, which the per-run `CITATIONS.md` is built from. Collapsing those would mean parsing JSON in the wrapper without a guaranteed `jq`. Left as two, noted here.

## What was NOT done, and why

- **`install/check_install.sh` was left alone**, and `check_analysis_install.sh` is a separate script rather than a mode of it. The pipeline checker resolves its tool list through `nextflow config` from `params.software`; the analysis layer has no such block, and its interesting checks are R packages, which the pipeline knows nothing about. Sharing `lib/tool_version.sh` gets the useful commonality — identical version reporting — without forcing one script to serve two contracts.
- **`list` shows `PoolSeqFlow-<version>-analysis` as a flat entry.** Z ruled this fine (2026-08-30): it is cosmetic grouping, not a correctness bug.
- **`.gitattributes` gives `analysis/` nothing**, which is correct — it must NOT be `export-ignore`d, and it is not. Verified: `git archive HEAD` carries the directory. It has two entries since, both narrow and neither touching the directory itself: `analysis/modules/*/test/`, because a module's cases travel with the module, and `analysis/modules-index.tsv`, because a frozen copy of the catalogue inside a tarball would be a second answer to what can be installed.

## AMENDMENT 2026-09-09 — item 2 of "Still to do before v3.0.0" is built

**`dev/scripts/prep-version.sh` now prepares both environments.** It clones `PoolSeqFlow-<current>` and `PoolSeqFlow-<current>-analysis` into `PoolSeqFlow-update` and `PoolSeqFlow-update-analysis`, updates each, runs the full suite with `TEST_CONDA_ENV` and `TEST_ANALYSIS_ENV` pointed at both, and exports both only if it passes. `--from-analysis <env>` names a different source. Item 1 above is unchanged and is still done by the release itself: the first pinned `environment-analysis.yml` is what step 2 of `dev/RELEASING.md` writes.

Three things settled while building it.

**The suite finds an analysis environment by globbing `PoolSeqFlow-*-analysis` and taking the first with an `Rscript`.** That is whichever name sorts first, not the one being prepared, so the scratch environment has to be named explicitly through `TEST_ANALYSIS_ENV` — a glob would have tested the release environment and exported the scratch one, silently.

**The refusal to export an environment carrying module packages had to be askable separately.** `export-environment.sh --check` runs that guard and stops, writing nothing. Without it the question was asked at step 4, after the clone, the two solves and the full suite — an hour on the wrong side of an answer the source environment already determined, because the clone inherits its packages.

**Both environments carry Nextflow and nothing was comparing them.** `install/environment-analysis.yml`'s own header says it carries the pipeline environment's version, but the two solve independently and no test asserts it. The script reports a divergence as a warning rather than refusing: it is the suite that says whether a pair works, and a hard refusal here would be a release policy nobody has set.

**The `-analysis` suffix on the scratch name is load-bearing.** `export-environment.sh` decides which file an environment belongs in by matching `*-analysis` against its name, so `PoolSeqFlow-update-analysis` routes itself and needs no output argument.

Found in passing, and fixed: three fixtures in `test/suites/00_static.sh` wrote `modules-repo/index.tsv` into a directory their `mkdir -p` never created. The redirect failed, the catalogue was absent, and `check-analysis-versions.sh` skips its catalogue check entirely when the file is missing — so all three cases passed while covering nothing there. Fallout from the catalogue move in `e384928`, where the old path's parent (`analysis/`) came for free. Measured after the fix: with the file planted, a row changed without the header moving reports `BEHIND: the catalogue changed and its #!index-version did not`; without it, nothing.

## AMENDMENT 2026-09-09 (second) — the unmigrated-config refusal, E7e

**`require_migrated_config` in `./PoolSeqFlow`.** Written against the tree at `ff08f61`.

**What the path actually did before it, measured rather than assumed.** A real v2.2.0 `parameters.config` resolves through `nextflow -C nextflow.config config` with **no error of any kind** — `includeConfig "${launchDir}/parameters.config"` reads the file as given, and only `cores`, `dryRun` and `dryRunDir` have a safety net in `nextflow.config`. Every parameter 3.0 added or renamed comes back empty: `storageDir`, `metadataFile`, `metadataPath`, `ploidy`, `multiRun`, `dir.allLogs`, `dir.allOutputs`. Step 0 then builds `dir_log = "${params.dir.allLogs}/0_verify_environment"`, which becomes `null/0_verify_environment`, so the run starts and writes into a directory named `null`.

**The marker is `storageDir` being assigned, and that is the whole test.** The rename table lives in an awk function inside `bin/config_migrate.sh`; a second copy of it in the wrapper would drift from the first. One fact that cannot drift is better than a list that can: every config for this release assigns `storageDir` because the template does and `migrate_config` writes it, and no 2.x config does because that root was `projectDir`. The old names the message prints — `projectDir`, `diploidy`, `rgTagsFile`, `rgTagsPath` — are advisory only; the refusal does not turn on them.

**The cost of that choice, named so it is not rediscovered:** a release that renames `storageDir` must move the marker with it, or the guard silently passes everything. `02_launcher`'s case is what says so, and `dev/RELEASING.md` step 3 carries the warning.

**Which arms guard, and why it is not all of them.** `run|resume`, `dryrun`, `reset`, `analysis complete` and the module dispatch — what runs the pipeline, runs a module, or acts on either's outputs. Not `migrate_config`, which is the fix and would otherwise be unreachable. Not `clean` or `dryclean`, which read `workDir` and `params.dryRunDir`, and the latter has a default in `nextflow.config` regardless.

**It broke eight fixtures, and the fixtures were wrong.** `run_analysis_launcher_with_envs` wrote `// stub project marker` as a whole `parameters.config` — enough for `require_project_config`, which only tests existence. Those cases are about which environment is chosen, so the marker now carries a `params { storageDir }` block and looks like a current project. A stub that cannot be told from an unmigrated config was the actual defect.

**The manual had a stale paragraph and it was deleted, not corrected.** *"Skip it and the failure is not a clean one. An absent parameter interpolates as the literal string `null`, so a later step dies with `.command.sh: line 17: null: command not found`"* — true until this landed, and exactly the "warning about a bug that is fixed" class `dev/RELEASING.md` step 1 tells you to look for.

**Verified end to end** in a scratch project holding the real v2.2.0 template: `run` refused and named `migrate_config`; `migrate_config` was not refused and wrote a config with `storageDir`; `run` then got past the guard and failed on the template's own `/path/to/working/directory` placeholder, which is the honest error for a config nobody has filled in. Mutation-tested by removing the guard from the `run` arm — the case fails on the placement assertion as well as the message, so moving it later would not pass either.
