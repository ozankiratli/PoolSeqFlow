# Releasing PoolSeqFlow

The order to do a release in, what each step must show, and what bites.

**This is a living procedure, not a record.** Correct it when a release teaches you something; it is not dated and it does not describe a particular version. `.claude/development-notes/` is where the dated records go.

Everything happens on `dev` until step 4. Steps 4 to 9 happen on `main`. Step 10 brings `main` back.

**Two things are not written down here and are checked by the suite instead**: the release archive (`verify-archive.sh`), the docs and citation gates (`build_docs.py --check`, `bib2citations.py --check`), the analysis versions (`check-analysis-versions.sh`) and the version-consistency case all run inside `00_static`. If the suite is green they passed. What follows is only the work the suite cannot do for you.

---

## 1. Read the manual, top to bottom

In document order, not by concept. **Verify every claim against the code before trusting it** — this has caught something on nearly every page, and the existing text is not evidence.

Live preview while you work:

```
dev/scripts/serve_docs.sh        # http://127.0.0.1:8055/PoolSeqFlow/ , regenerates on save
```

What this pass is looking for:

- **A number that moves with every commit.** Case counts, suite counts, file counts, running totals. The fix is to remove the number, not correct it. A count tied to a tag or to a closed list is fine.
- **A warning about a bug that is fixed.** Nothing prompts you to delete one when the bug goes.
- **Developer shorthand in user-facing prose.** "The pipeline will refuse", not "step 0 refuses".
- **A capability written as the only path.** "Each pool *can be set to* get its own", not "each pool gets its own".

**Every settable parameter must be named in the manual**, and for each one: what it is, what it does, how to set it. Re-run the audit after any template change — the extraction and the grep are in `.claude/development-notes/` under the manual pass. A key that lives in `nextflow.config` rather than in the template is invisible to a template-driven audit, so extract from both.

Version-dependent prose is read here in the *old* version's state, because the bump is step 6. Re-read just those passages after step 6 rather than moving this step.

## 2. Update, prove and freeze both conda environments

### Update and freeze

```
dev/scripts/prep-version.sh <new-version>
```

It clones **both** environments — `PoolSeqFlow-<current>` and `PoolSeqFlow-<current>-analysis` — into scratch copies, runs `conda update --all` in each so the tools move as one consistent set, runs the **full suite** against both at once, and exports them to `install/environment.yml` and `install/environment-analysis.yml` **only if that passes**. Nothing is frozen against an environment the suite did not go green on — that refusal is the point of the script.

Three things it refuses before it starts, so none of them costs you the run: a scratch environment left over from an earlier attempt; an analysis environment that is not there (build one with `./PoolSeqFlow analysis install`, or name another with `--from-analysis <env>`); and an analysis environment carrying an installed module's packages, which the export at the end would refuse to freeze.

**Read the Nextflow line if one appears.** Both environments carry Nextflow and `install/environment-analysis.yml` says the analysis one carries the pipeline environment's version. Two independent solves can land either side of a release, so the script reports a divergence and leaves the decision to you.

Read `dev/logs/prep-<version>-<timestamp>/` afterwards, including the table per environment of which packages moved.

### Prove the module packages still solve against what was just frozen

```
dev/scripts/check-module-packages.sh
```

**Real conda, real network, minutes.** It is deliberately not in the suite, which is exactly why it gets skipped — it is on this checklist or it is lost.

It builds the baseline, installs what the shipped modules declare, and checks a module cannot move a version another module or the release itself is running on. It found on its first run that `--freeze-installed` does **less** than its name suggests: it refuses to change a package the solve reaches on its own, but a package named on the command line it installs at the version asked for, downgrading what is there.

Every check must say `ok`. A failure here is a compatibility problem between this release and a module, and it is settled by publishing, not on a user's machine.

### Run `00_static` again, against the files that were just written

```
bash test/run_tests.sh --suite 00_static
```

**`prep-version.sh` runs the suite at `[3/5]` and exports at `[4/5]`, so the files it writes are never seen by the suite that approved them.** The cases that read them — no `name:` or `prefix:` key, no absolute home path, and no package leaving a shipped file — only bite on a run after the export.

### Read both diffs

```
git diff install/environment.yml install/environment-analysis.yml
```

A pin that moved is a change to what every result was produced under. Classify before reading line by line: a version that moved, a build string that moved on its own (a conda-forge rebuild, usually because `libgcc` moved), a package added, a package **removed**. Removals are the ones to stop on, and the first pinned export of `environment-analysis.yml` will show a large *added* count that is not new software — the hand-written spec named what you ask for and an export names what you get, so the transitive dependencies become explicit all at once.

To export one environment by hand, or to ask whether an export would be accepted without writing anything:

```
dev/scripts/export-environment.sh PoolSeqFlow-<version>-analysis
dev/scripts/export-environment.sh --check PoolSeqFlow-<version>-analysis
```

**It refuses to export an environment carrying an analysis module's packages.** Exporting one in that state folds them into the baseline every project installs, where nothing declares them and nothing can remove them — permanently and silently. Uninstall the modules first, or rebuild the environment from the shipped file and export that.

## 3. Prepare the configuration migration

`bin/config_migrate.sh` carries a user's `parameters.config` onto the new template. Two halves:

- **The migration itself.** Every dropped parameter is handled here; there are no legacy fallbacks in `.nf` files. Check the migration report's categories are right — a knob that is merely commented out in the new template is *not* a parameter that is gone, and the report must not say it is.
- **The user who never runs it.** `require_migrated_config` in the wrapper refuses a config from an older release and names `migrate_config`, so this path ends somewhere useful rather than in a step interpolating an absent parameter into a path. **It turns on one marker — `storageDir` being assigned — so a release that renames that root has to move the marker with it**, and `02_launcher`'s `a config from an older release is refused with the fix` is what says so. It guards what runs the pipeline, runs a module, or acts on either's outputs; never `migrate_config`, `clean` or `dryclean`.

Also run the language sweep before the merge, because a large prose pass is where drift enters:

```
dev/scripts/americanize.py          # report; --fix rewrites the safe ones
```

`catalogue` and `analyses` are **not** errors and the script says so. Read every risky hit by hand.

## 4. Merge to `main`

Open the merge request, review the diff as a whole, merge.

The release commits — the version bump and the CHANGELOG — are made on `main` after this, so `main` briefly holds the merge at the old version. That state is never tagged, so it costs nothing, and it keeps release-only commits off `dev` until step 10.

## 5. Run the analysis version gate

Three versions cover the analysis layer and nothing in the pipeline forces any of them to move: `analysis/frame.version` (the frame config and everything under `analysis/lib/`), the catalogue's `#!index-version`, and each module's own manifest version.

```
dev/scripts/check-analysis-versions.sh --release
```

`--release` is stricter than the everyday run in one way that matters: **it refuses to answer when it cannot, rather than answering wrongly.** It stops on a shallow clone and on uncommitted changes under `analysis/`, and it treats a comparison it could not make as a failure.

Mid-development a version is legitimately behind, which is why the plain run only reports and why none of this is in the test suite.

`release.yml` runs this on every tag, so a tag pushed without it is refused before anything is published. Running it by hand here is how you find out before the tag rather than after.

## 6. Bump the version

```
dev/scripts/bump-version.sh <new-version>
```

It rewrites the version in the wrapper (header comment and `VERSION=`) and in `nextflow.config`'s manifest, sets `"environment"` in every shipped module's manifest and moves that module's own version with it, and prepends a CHANGELOG section listing every commit since the last release tag. It does not commit, tag or push — it prints those commands.

**The shipped manifests are part of the bump and no longer a separate step.** A module shipped inside a release travels in the same tarball as the analysis environment it names, so at a release the two agree by construction and there is nothing to decide. `00_static` still asserts `"environment"` equals `nextflow.config`'s version exactly, so a manifest that somehow disagrees still fails the next step — the check is unchanged, only the typing is gone.

A module published **outside** a release is different and is still yours: its `"environment"` is a claim about which release it was built against, and `dev/scripts/bump-analysis-version.sh module <name>` is what moves its version when you change it.

## 7. Run the full suite

```
bash test/run_tests.sh
```

On `main`, at the new version, with the frozen environments. This is the run that matters — everything before it tested a version string that is no longer the one shipping.

**Check the counts against the previous run, not only the exit status.** A filter that matches nothing also reports success. `nextflow lint .` must be at zero errors *and* zero warnings.

## 8. Write the CHANGELOG

`bump-version.sh` already generated the commit list under `### Commits`. **Write the release notes ABOVE that heading, never over it** — the commit list stays as the record of what landed.

What the notes owe a reader, beyond the commits: anything a user has to *do*, anything whose meaning changed, and every parameter that is gone or is now computed.

## 9. Finish the release

- Commit, tag, push the tag.
- The GitHub release from the tag.
- **Zenodo mints a DOI for the version.** The citation machinery points at the all-versions DOI and tells a user to pick their version from it, so the version record has to exist for the citation the release prints to be answerable.
- Verify the published archive installs from scratch on a machine that has never had it.

## 10. Return to `dev`

Sync `dev` with `main` so the version bump and the CHANGELOG come back, then carry on. The first commits after a release are usually the things this protocol found and deferred.

---

## What to do when a step fails

**Do not work around it on the release branch.** Everything here is either a gate that found something or a gate that is wrong. If it found something, fix it on `dev` and start again from the step that would notice. If the gate is wrong, fix the gate — and add the case that would have caught what it missed, because a gate nobody trusts is worse than no gate.

**A number in a message is worth reading twice.** The most common defect this project has shipped is not a broken feature — it is a gate reporting success over work it had not done.

They look alike, and each one is cheap to spot once you know the shape:

- **A filter that matched nothing still says PASS.** `--case "no package leaves"` selected zero cases and printed `PASS 0 passed`; the underscore form selected one. Read the count, not the word.
- **A fixture that failed to set itself up still says PASS.** Three cases wrote `modules-repo/index.tsv` into a directory their `mkdir -p` never created, and the checker skips its catalogue check when the file is absent. The tell was two stderr lines in a run that reported success.
- **A check that asks the developer's machine instead of the release still says PASS.** `have_report_tools` used `command -v typst`, and the maintainer had one; the shipped environment did not.
- **A literal that happens to be right still says PASS.** A case asserted `${EXPECTED_VERSION:-2.2.0}` against a variable set nowhere. Correct until the bump, then a failure that says nothing about what it tests.

**A version bump is when this class surfaces**, because everything before it ran against a tree carrying the old version. That is why step 7 is after step 6 and not before it.
