# Releasing PoolSeqFlow

The order to do a release in, what each step must show, and what bites.

**This is a living procedure, not a record.** Correct it when a release teaches you something; it is not dated and it does not describe a particular version. `.claude/development-notes/` is where the dated records go.

Everything happens on `dev` until step 6. Steps 6 to 11 happen on `main`. Step 12 brings `main` back.

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

Version-dependent prose is read here in the *old* version's state, because the bump is step 8. Re-read just those passages after step 8 rather than moving this step.

## 2. Update both conda environments

```
dev/scripts/prep-version.sh <new-version>
```

It clones the current environment, runs `conda update --all` so the tools move as one consistent set, runs the **full suite** against it, and exports it **only if that passes**. Nothing is frozen against an environment the suite did not go green on — that refusal is the point of the script.

> **NOT BUILT YET: `prep-version.sh` covers the pipeline environment only.** The analysis environment has to be updated by hand until it takes both, and `export-environment.sh` needs a target-file argument to export the second one. This is E7a.

This step is steps 2, 3 and 4 of the old plan in one command. Read `dev/logs/prep-<version>-<timestamp>/` afterwards, including the table of which packages moved.

## 3. Prove the module packages still solve

```
dev/scripts/check-module-packages.sh
```

**Real conda, real network, minutes.** It is deliberately not in the suite, which is exactly why it gets skipped — put it on the checklist or lose it.

It builds the baseline, installs what the shipped modules declare, and checks a module cannot move a version another module or the release itself is running on. It found on its first run that `--freeze-installed` does **less** than its name suggests: it refuses to change a package the solve reaches on its own, but a package named on the command line it installs at the version asked for, downgrading what is there.

Every check must say `ok`. A failure here is a compatibility problem between this release and a module, and it is settled by publishing, not on a user's machine.

## 4. Freeze the environments

`prep-version.sh` exports the pipeline environment for you when its suite run passes. The analysis environment is exported separately until step 2's gap is closed:

```
dev/scripts/export-environment.sh PoolSeqFlow-<version>-analysis
```

**It refuses to export an environment carrying an analysis module's packages.** Exporting one in that state folds them into the baseline every project installs, where nothing declares them and nothing can remove them — permanently and silently. Uninstall the modules first, or rebuild the environment from the shipped file and export that.

Read the diff on both `install/environment*.yml` before committing. A pin that moved is a change to what every result was produced under.

## 5. Prepare the configuration migration

`bin/config_migrate.sh` carries a user's `parameters.config` onto the new template. Two halves:

- **The migration itself.** Every dropped parameter is handled here; there are no legacy fallbacks in `.nf` files. Check the migration report's categories are right — a knob that is merely commented out in the new template is *not* a parameter that is gone, and the report must not say it is.
- **The user who never runs it.** Someone upgrading without migrating has to end somewhere better than a confusing failure. This is a separate piece of work from the migration and it is easy to forget because the migration itself passes its tests.

Also run the language sweep before the merge, because a large prose pass is where drift enters:

```
dev/scripts/americanize.py          # report; --fix rewrites the safe ones
```

`catalogue` and `analyses` are **not** errors and the script says so. Read every risky hit by hand.

## 6. Merge to `main`

Open the merge request, review the diff as a whole, merge.

The release commits — the version bump and the CHANGELOG — are made on `main` after this, so `main` briefly holds the merge at the old version. That state is never tagged, so it costs nothing, and it keeps release-only commits off `dev` until step 12.

## 7. Run the analysis version gate

Three versions cover the analysis layer and nothing in the pipeline forces any of them to move: `analysis/frame.version` (the frame config and everything under `analysis/lib/`), the catalogue's `#!index-version`, and each module's own manifest version.

```
dev/scripts/check-analysis-versions.sh --release
```

`--release` is stricter than the everyday run in one way that matters: **it refuses to answer when it cannot, rather than answering wrongly.** It stops on a shallow clone and on uncommitted changes under `analysis/`, and it treats a comparison it could not make as a failure.

Mid-development a version is legitimately behind, which is why the plain run only reports and why none of this is in the test suite.

`release.yml` runs this on every tag, so a tag pushed without it is refused before anything is published. Running it by hand here is how you find out before the tag rather than after.

## 8. Bump the version

```
dev/scripts/bump-version.sh <new-version>
```

It rewrites the version in the wrapper (header comment and `VERSION=`) and in `nextflow.config`'s manifest, and prepends a CHANGELOG section listing every commit since the last release tag. It does not commit, tag or push — it prints those commands.

**THEN UPDATE THE SHIPPED MANIFESTS, OR THE NEXT STEP FAILS BY DESIGN.** Every module shipped inside a release declares `"environment"` as the release whose analysis environment it was built against, and `00_static` asserts that equals `nextflow.config`'s version exactly:

```
analysis/modules/*/manifest.json    "environment": "<new-version>"
dev/scripts/bump-analysis-version.sh module <name>     # each one, since its directory changed
```

The failure names the module and both versions. That is deliberate: a script that rewrote the manifests along with the version would remove the one moment where a person looks at what each module claims about its environment.

## 9. Run the full suite

```
bash test/run_tests.sh
```

On `main`, at the new version, with the frozen environments. This is the run that matters — everything before it tested a version string that is no longer the one shipping.

**Check the counts against the previous run, not only the exit status.** A filter that matches nothing also reports success. `nextflow lint .` must be at zero errors *and* zero warnings.

## 10. Write the CHANGELOG

`bump-version.sh` already generated the commit list under `### Commits`. **Write the release notes ABOVE that heading, never over it** — the commit list stays as the record of what landed.

What the notes owe a reader, beyond the commits: anything a user has to *do*, anything whose meaning changed, and every parameter that is gone or is now computed.

## 11. Finish the release

- Commit, tag, push the tag.
- The GitHub release from the tag.
- **Zenodo mints a DOI for the version.** The citation machinery points at the all-versions DOI and tells a user to pick their version from it, so the version record has to exist for the citation the release prints to be answerable.
- Verify the published archive installs from scratch on a machine that has never had it.

## 12. Return to `dev`

Sync `dev` with `main` so the version bump and the CHANGELOG come back, then carry on. The first commits after a release are usually the things this protocol found and deferred.

---

## What to do when a step fails

**Do not work around it on the release branch.** Everything here is either a gate that found something or a gate that is wrong. If it found something, fix it on `dev` and start again from the step that would notice. If the gate is wrong, fix the gate — and add the case that would have caught what it missed, because a gate nobody trusts is worse than no gate.

**A number in a message is worth reading twice.** Two of the defects this project has shipped were a gate reporting success over work it had not done.
