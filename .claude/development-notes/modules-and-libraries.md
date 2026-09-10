# Modules and libraries are optional, and installed — the rework

**Written 2026-09-10 against the tree at `6d38c88`.** Supersedes `module-optionality.md`, which recorded the audit that led here; that note's findings are all addressed below or listed as still open. v3.0.0 was released the same morning WITH the modules inside it, so everything here describes the release after it.

## The root cause, in one line

Z, 2026-09-10, on seeing that `analysis/modules/` was both the git source directory and the install store: ***"That was the whole problem."***

Every symptom traced to that: the three modules shipped in the tarball because they were sources sitting in the install path; `modules list` reported them `installed` because the store contained them; the analysis environment carried their dependencies because they were release components. **One cause, four symptoms.**

## The layout now

| | |
|---|---|
| `modules/<name>/` | module sources, tracked, `export-ignore`d from releases |
| `modules/lib/<name>/` | library sources, same |
| `modules/repo/` | the published catalogue and tarballs |
| `analysis/` | the frame ALONE — `lib/nf/`, `lib/rmd/`, the entry pieces |
| `analysis/modules/` | THE STORE. Gitignored, empty in a checkout, empty in a fresh install |
| `analysis/modules/lib/` | the library store, under a name no module may take |

**The repo path and the install path deliberately differ.** A module's frame import is `'../../lib/nf/plan.nf'`, correct from the store and meaningless from `modules/<name>/`. I first "fixed" that by moving the store to `$INSTALL/modules/` so the two matched — **wrong**, because the store would then land on the sources in a checkout install. Z caught it. `00_static` lints modules in an assembled store layout instead.

**The published URL did NOT move** when `modules-repo/` became `modules/repo/`. `MODULE_INDEX_URL` compiles into v3.0.0 and asks for `/PoolSeqFlow/modules-repo/` for as long as that release exists. `build_docs.py` and `publish-module.sh` each carry two constants — source directory and published path — with a comment saying why.

## Libraries

Eleven files in `analysis/lib/R` + three `.cpp` became **five libraries**, grouped by what a module must take together:

`n_eff` (n_eff, pool_n_eff, harmonic_mean) · `chunk_ranges` · `allele_frequencies` (+cpp) · `site_diversity` (+cpp) · `nei_distance` (nei_distance, add_distance, mean_distance, +cpp)

**Measured, not assumed:** no library calls another. Every apparent dependency was a comment reference. Z's correction stands anyway — ***"They are standalone now. They can be used by other modules as we increase the size. Don't make assumptions."*** — so the manifest carries `libraries` regardless and resolution is transitive.

**Two files had no consumer and moved to `test/tools/`**, on Z's rule *"If only test suite is using it it should be in test suite not here"*: `split_counts.R` and `pool_sensitivity.R`. Neither is dead — `split_counts` is the **oracle** the vectorized and compiled paths are checked against (mutating its split character fails 19 of 140 checks), and `pool_sensitivity` duplicated `poolSensitivity()` in `analysis/lib/nf/pools.nf`, which is the one modules actually read off `target.pools`.

**`libraryFiles()` and `compiledFiles()` are gone from every `main.nf`.** The frame resolves both from the manifest — `moduleLibraryFiles(name)`, `moduleCompiledFiles(name)` — so the list exists once. `00_static:707` used to police the duplicate; there is no duplicate now.

## Packages: declare everything

Z: ***"Modules declare everything including doFuture, ggplot2 and data.table."*** And the rule that makes it safe, in Z's words: *"to uninstall take a diff between the uninstalled package and union of all installed packages + analysis base environment."*

**That was a live bug.** `uninstall_module` computed `going = mine − others` with **no baseline subtraction**, so a module declaring `r-ggplot2` would have stripped ggplot2 out of the shared environment on its way out, breaking the frame and every module beside it. Now `going = mine − (others + baseline)`, with `baseline_packages()` reading the shipped `environment-analysis.yml` — the shipped file, not the live environment, which has module additions merged in and cannot say which packages are the release's own.

`doFuture`, `ggplot2`, `data.table` and `Rcpp` **stay in the baseline** — Z: *"Rcpp should remain in the frame. I settled this one before."* Modules declare them anyway. A library declares `r-rcpp` only if it ships a `.cpp`.

## The catalogue

Gained a **`kind` column** (`module` | `library`), additive and matched by name, so an older release ignores it and an empty value means `module`. `available` lists modules only; a library is never asked for by name.

**Every positional consumer had to move with it** — six `read` destructurings, an awk filter, and a `sort -k2,2Vr` that was then sorting by kind instead of version. Thirteen cases failed and pointed straight at them. **The columns are matched by name; the consumers destructure positionally. Adding a column is not free.**

## Bugs made and caught while building this

- **`def LIBRARY_DIR = 'lib'` at the top level of a `.nf`** — the strict parser allows only declarations there. It is `libraryDirName()`.
- **`git log -1 --format=%ct <tree>`** returns nothing: a tree has no commit and no date. `--mtime="@"` made tar substitute a nonsense year. `publish-module.sh` now **refuses** rather than publishing something unreproducible — which is why publishing must follow a commit.
- **A `sed 1,/^-->$/d`** whose anchor was not at line start deleted the entire release-notes boilerplate. Caught by reading the output; the new case mutation-tests exactly that.
- **`select-tests.py` listed files from the git index**, so a moved file still counted as a source. I masked it by staging before noticing. It now lists only what exists.
- **My own `every catalogue row` case went vacuous** for the positional reason above — and the `rows > 0` guard I had put in it made it **skip loudly** instead of passing.

## What is still open

- **Nothing is published.** The three module tarballs carry `20260910.001` manifests with no `libraries` and no `packages`; the repo is at `.002`. The five libraries have never been published. `RELEASING.md` step 10 is the procedure.
- **The JVM and pipeline tiers have never run against this layout.** `moduleLibraryFiles()` resolving a module's libraries at run time is new code exercised only statically. Z: *"we should not run the full suite until we are done with the work today."*
- **The tarball extract/install/check step** (Z's step 3) is unbuilt. A spec exists and came back with four blockers including two vacuous assertions; it needs rewriting, not applying.
- **The docs pass is partial.** The manual's roster, modules section, package paragraph, store-wipe paragraph and library references are corrected; `modules/README.md` gained a libraries section and rule 6e was inverted; `RELEASING.md` gained step 10. **An exhaustive read of the manual was still running when this was written** — the directory-layout diagram and the Upgrading section are known to be untouched.

---

# The follow-up pass, 2026-09-10, against `6d38c88` plus the working tree

Written when the question "can we publish now?" was asked. The answer was no, and finding out why turned up a class of defect the rework had left behind everywhere.

## Publishing had to wait, and the frame version is why

**v3.0.0 compiled `MODULE_INDEX_COLUMNS="name version contract frame environment url sha256 summary"` — no `kind`.** It matches by name, drops what it does not know, and reads all eight rows as modules. Two gates then stand between a v3.0.0 user and a module built for the release after it: `contract`, which is `freq-1` on both sides and passes, and `frame`.

**`analysis/frame.version` was still `20260908.003`** — the exact value v3.0.0 shipped — after `analysis/lib/R/` and `analysis/lib/cpp/` were deleted out from under it. So the frame gate passed too, and publishing then would have offered every v3.0.0 user a `.002` module that installs cleanly, brings no library (v3.0.0 has no `install_library`), and dies at run time on a `moduleLibraryFiles()` its frame does not define. `install/environment-analysis.yml` is byte-identical to v3.0.0, so `environment: 3.0.0` is honest and cannot refuse anything: **the frame version was the only gate, and it was open.**

Now `20260910.001`, with all eight manifests declaring it — modules at `.003`, libraries at `.002`. `check-analysis-versions.sh` had been reporting `BEHIND` the whole time; nothing was reading it because it is a release gate rather than a suite case, which is correct and is also how it sat unnoticed for a day.

## THE CLASS: a glob pointed at the install store passes over nothing

`analysis/modules/` is gitignored and empty in a checkout. **Every script and case that still globbed it kept working, kept exiting 0, and checked nothing.** Nine of them, and two were release gates:

| | |
|---|---|
| `check-analysis-versions.sh` | the per-module version loop — **zero modules examined**; a release could ship any manifest unbumped |
| `export-environment.sh` | half of the guard the plan calls *"the sharpest trap in the whole feature"* |
| `check-module-packages.sh` | the only real conda solve of the modules' own pins, asking it of an empty set |
| `bib2citations.py` | `--check` said *"every citations.json matches (2 files)"* — three module bibliographies unread |
| `00_static` ×5 | the DOI check, three suite-list loops, the manifest-anchor glob |
| `07_analysis_frame` | asserted the three modules **ship**, which the rework inverted |
| `08_analysis_rlib` | the no-package grep, which printed `grep: ... No such file` and passed |
| the three module suites | `cat analysis/lib/R/*.R` — **0 passed, 6 failed** in `basicstats` once actually run |

**The suite agreed with the bug rather than catching it.** Both version fixtures in `00_static` planted their `demo` module *into the store*, so the gate found it there and the case went green over a loop that finds nothing in reality. A fixture that matches the defect is worse than no fixture: it is a standing assertion that the wrong thing is right.

Guards added so it cannot repeat quietly: a `ghost` module planted in the store that must never be reported, a `helper` library that must be, a `seen > 0` count in the frame's tracked-files loop, and a `fail_case` when `modules/lib` is missing. Each mutation-tested.

## Two defects in shipped code, found while fixing the gates

**`module_packages()` and `module_libraries()` did not terminate their last line.** `store_packages` runs one per module and concatenates, so the last spec of one manifest and the first of the next arrive as **one token** — `r-shared=2.0r-shared=2.0`, `chunk_rangesn_eff`. `cut -d= -f1` then keeps the first name and the second is gone from the keep-list, so **`uninstall` removes a package a still-installed module declares.** Reproduced with three modules where the shared package sits at a list boundary: `r-fst` dropped while `gamma` still needed it. Fixed by ending both with `awk -F'"' 'NF > 1 { print $2 }'`, which terminates its records.

It did not bite the three shipped modules, by luck: their library lists overlap enough that every glued name also appears cleanly somewhere else in the `sort -u`. Two modules with a boundary name in common and nothing else would lose it.

**`ANALYSIS_ENV_FILE` was defined in `PoolSeqFlow` and read in `lib/wrapper_lib.sh`.** So `baseline_packages()` returned **nothing** for any `dev/` script that sourced the library on its own — silently, through `2>/dev/null` on an empty path — and an empty baseline subtracts nothing. Now defaulted in `wrapper_lib.sh` beside the function that reads it.

`test_the_keep_list_survives_more_than_one_other_module` in `02_launcher` covers both; the existing case could not, because with a single other module there is no join to get wrong.

## Still open after this pass

- **Nothing is published, and publishing waits for the release.** `RELEASING.md` step 10 already puts it after the version bump, and the frame version is why that ordering is load-bearing rather than tidy.
- **The JVM and pipeline tiers still have not run.** `--fast` is 313 passing, `--cost static` 264 — but every Nextflow half is skipped, and `moduleLibraryFiles()` resolving a module's libraries at run time has still never executed.
- **The tarball extract/install/check step** (Z's step 3) is unbuilt.
- **The docs pass.** The four-way audit finished, 39 agents; the manual's own claims about the shared library are corrected in `analysis/references.bib` and regenerated, but the directory-layout diagram and the Upgrading section are untouched.
