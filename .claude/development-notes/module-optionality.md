# Modules are optional — the design change, and the audited blast radius

**Written 2026-09-10 against the tree at `91e027f` plus three uncommitted edits.** v3.0.0 was released earlier the same day, *with* the modules inside it. Nothing here is a defect in the released version: v3.0.0 works exactly as shipped. This is about what the NEXT release has to be, and why.

## Z's ruling

Z, 2026-09-10: *"The modules should not ship with the release. That's the whole idea."* And, when the analysis environment came up: *"The whole idea was to make the modules optional."*

Three parts follow from it:

1. **No module ships inside a release tarball.** The store starts empty; every module is installed from the catalogue.
2. **Each module declares its own conda pins** in its manifest, and `modules install` puts them into the shared analysis environment — the E8 machinery, which already exists.
3. **The baseline analysis environment slims** to what the FRAME needs, and stops carrying module dependencies.

## What was actually wrong, stated precisely

**The architecture was never wrong. The data was.**

The per-module conda machinery is built and was proven against real conda on 2026-09-10 by `dev/scripts/check-module-packages.sh` — every check `ok`: a fixture module's pins installed under `--freeze-installed`, R imported them, a second module sharing a pin moved nothing, uninstalling one left the other's packages alive, and the baseline never lost a package. `PoolSeqFlow:786-794` is the deferred install; `:1433` is the reconcile that `analysis install` performs over modules already in the store. Neither is missing anything.

**The three shipped modules declare `packages: []`.** That was TRUE while they shipped inside the release, because the same release shipped a 191-package environment holding everything they need. It became FALSE the moment they were published independently — which happened on 2026-09-09/10. They were never really modules; they were release components wearing a module's shape, and they are the one case that never exercised the machinery built for them.

## The measured package split

Evidence: every `library()`/`requireNamespace()`/`pkg::` reference across `analysis/lib/` and `analysis/modules/`.

| | |
|---|---|
| the frame uses | `jsonlite`, `knitr`, `rmarkdown` — plus `pandoc` and `typst` for the PDF report |
| the modules use | `doFuture`, `ggplot2`, `Rcpp`, and `data.table` (basicstats only) |
| used by nothing at all | `r-optparse`, `r-pheatmap` — pinned since the first guess at the E4c roster |

`foreach` and `future` arrive as `doFuture` dependencies. **The audit corrected two of my assumptions**: `mds` DOES need `ggplot2` unconditionally, and the compiled path needs the conda C++ toolchain, which `r-rcpp` does not pull — so the toolchain placement is part of the split, not incidental.

## The audited blast radius — seven seams, 2026-09-10

A seven-dimension audit with adversarial verification of every blocker and major finding. **Five verifier verdicts, zero refutations or corrections** — the findings below survived independent checking.

### Blockers

- **The clone-install route still ships all three modules.** `.gitattributes export-ignore` governs the TARBALL; `install` copies from a checkout tree where `analysis/modules/*` still exist. "The store starts empty" is false for every user following the manual's clone route. **This is the one I would have missed.**
- **The three published catalogue rows become install-clean, fail-at-first-run.** Their `environment=3.0.0` passes the `version_at_most` check on any later release, their manifests declare no packages, so they install cleanly onto a slim baseline and then die missing `ggplot2`/`doFuture`/`Rcpp`. The `environment` field's semantics assume baselines only ever GAIN packages.
- **`00_static`'s `no package leaves a shipped environment file` cannot legitimately pass a slimmed baseline** — and it is the guard added on 2026-09-09 for exactly the typst class of bug. It compares against the last release tag, so it stays red for the whole dev cycle. `export-environment.sh --allow-removals` is the sanctioned escape for the export; the test needs its own answer.
- **`00_static` asserts every repo manifest's `environment` EQUALS the release version.** With no module shipping, that coupling is backwards — it forces a bump nobody's needs justify.
- **The manual teaches the old design in at least three places**: "Four ship with the release", the `# Shipped Modules` section, and "No module shipped with this release names one \[a package\]".
- **`RELEASING.md` step 6**'s justification for automatic manifest rewriting — "travels in the same tarball as the analysis environment it names" — is exactly the premise being removed.

### Major

- **`bump-version.sh` now writes a wrong claim.** Automatically setting `environment := new release` is right for a shipped module and wrong for an independent one, whose minimum should move only when its needs do. Landed 2026-09-10 at Z's request; the request was correct under the old design.
- **No gate checks that a module's declared packages cover what its R actually loads.** Under-declaration is silent — and the three published tarballs declare NONE. This is the gate that would have caught tonight.
- **The module suites SKIP rather than fail when `TEST_ANALYSIS_ENV` lacks a package**, so a slim environment silently retires the compiled and parallel coverage instead of reporting it.
- **`PoolSeqFlow analysis cite` cites zero R packages today** — a live bug, independent of any of this, in how the cite arm reads `analysis_r_packages`.
- **`analysis check` would report "All checks passed" on an environment missing every module-declared package**, because it only verifies the baseline.
- **The slim baseline list must add `python3` and `rsync`** (the frame invokes both) and probably drop `samtools`/`bcftools`/`htslib`, which the audit found nothing in the frame invoking — verify before acting.
- **Module package arrays must be name-disjoint from the baseline's set**, or `export-environment.sh`'s refusal fires permanently on a name the baseline owns.
- **Two tests fail against the uncommitted wrapper edit**: `02_launcher`'s modules-list case and `test_modules_list_reports_the_store` both plant a store module with no `.source`, which now prints `ships with this release`.
- **`test_an_unknown_module_refuses_before_any_task`** asserts the literal roster `Available here: association, basicstats, mds, verify`, read from the store at runtime — it only holds while the checkout's store has the three.
- **The store README** contradicts the new design in three places, including rule 6e: "Leave the field out when the release's own environment suffices — which is true of every module shipped here".
- **Offline/air-gapped installs regress**, which matters because this runs on HPC clusters: today a cluster user gets three working modules in the tarball; afterwards they need HTTPS to the catalogue AND to each tarball. A `file://` catalogue does not solve it — the rows carry `https` URLs independently of how the index was fetched.

## The uncommitted work, and what to do with it

Three files, all on `dev`, none committed:

- **`.gitattributes`** — `analysis/modules/*/ export-ignore`, keeping `README.md`. **Correct and verified**: `git archive --worktree-attributes` leaves only `analysis/modules.nf` and the README.
- **`dev/scripts/verify-archive.sh`** — `excluded` widened to `analysis/modules/*/`, and the positive assertion strengthened to "no module directory in the archive AND the README is". **Correct**; `00_static` passes at 46 against the working tree.
- **`PoolSeqFlow`** — `module_was_installed()` plus `ships with this release` labels and the uninstall warning. **This encodes the ABANDONED middle design** and should probably be reverted: once nothing ships, everything in the store was installed, and the label distinction is dead weight. It also breaks two tests. `.source` remains a useful marker; the labels built on it do not.

## Sequencing, when this is picked up

The blockers interlock, so order matters. The clone-install path has to be settled before "the store starts empty" is true for anyone. The published catalogue rows need a decision — remove them, or republish at bumped versions declaring their packages — before the baseline slims, or a next release strands anyone who installed one. The two `00_static` gates need their own answers before the slim can be committed at all, or the suite is red for the whole cycle.

Estimated at roughly one working day, about half of it unattended suite and environment runs.
