# Releasing PoolSeqFlow

Everything happens on `dev` until step 6. Steps 6 to 11 happen on `main`. Step 12 brings `main` back.

---

## 1. Read the manual, top to bottom

In document order, not by concept. Verify every claim against the code -- the existing text is not evidence, and this has caught something on nearly every page.

Live preview while you work:

```
dev/scripts/serve_docs.sh        # http://127.0.0.1:8055/PoolSeqFlow/ , regenerates on save
```

```
dev/scripts/check-manual-parameters.sh
```

Writes two scratch files into `.tmp/release-review/` and audits the parameters:

 - `commits.md` -- every commit since the last tag, in the form `bump-version.sh` will prepend to the CHANGELOG
 - `manual.diff` -- the manual as published with that tag against the manual now, which is what has never been read in a release pass
 - `parameters.txt` -- every settable key, whether the manual names it, and which file declares it

Every settable parameter must be named, with what it is, what it does, and how to set it. Silence on stdout means every key is named, which is not the same as documented: `parameters.txt` is the list to read the manual against.

Remove `.tmp/release-review/` when the read is done.

Version-dependent prose is stale here: the bump is step 7. Note those passages and re-read them after it.

## 2. Update, prove and freeze both conda environments

### Update, prove and freeze

```
dev/scripts/prep-version.sh <new-version>
```

 - solves **both shipped files** (`install/environment.yml` and `install/environment-analysis.yml`) into scratch environments, which is the baseline a user installs from rather than whatever is installed here
 - runs `conda update --all` in each
 - **moves any module pin the update left behind, and bumps that module with it**, before the suite, so the suite runs on what will ship
 - runs the **full suite**, and if it passes,
 - reads what each environment requires of its host and exports both files
 - then proves the files it wrote: `check-exported-floor.sh` solves each from nothing and reads its floor, and `check-module-packages.sh` puts the module pins through a baseline built from the new file

The scratch environments are removed on every exit. `--no-cleanup` keeps them, to reproduce a failure against. The conda package cache is left alone.

Then read `dev/logs/prep-<version>-<timestamp>/`, including the per-environment table of what moved.

**A moved pin is a module change.** There is one version a pin may name -- whatever the shared analysis environment holds -- so when the update moves a package, `prep-version.sh` rewrites the pin in every manifest declaring it and bumps that module's version. Read those edits in the diff with the environment files: they are uncommitted like everything else here, and every module whose version moved is republished at step 11. A package version that changes what a module computes is the thing to look for.

**Raising the host floor takes three things together**: a line in the manual's Requirements, a move of `HOST_GLIBC_FLOOR` in `export-environment.sh` (`2.28`), and a CHANGELOG entry naming the machines that lose support. The floor is never raised to make a solve pass.

**Skippable when nothing has drifted**, which is an hour. Export both to a scratch path and diff -- the second argument is what keeps this off the shipped files:

```
dev/scripts/export-environment.sh PoolSeqFlow-<version> /tmp/a.yml
dev/scripts/export-environment.sh PoolSeqFlow-<version>-analysis /tmp/b.yml
diff /tmp/a.yml install/environment.yml && diff /tmp/b.yml install/environment-analysis.yml
```

Identical both ways and the freeze still holds. Run the two proofs anyway: they answer a question about the files, which no diff does:

```
dev/scripts/check-exported-floor.sh
dev/scripts/check-module-packages.sh
```

### Read both diffs

```
git diff install/environment.yml install/environment-analysis.yml
```

Classify before reading line by line:

 - a version that moved
 - a build string that moved on its own (a conda-forge rebuild, usually `libgcc`)
 - a package added
 - a package **removed** -- stop on these

The first pinned export of `environment-analysis.yml` shows a large *added* count that is not new software: a hand-written spec names what you ask for, an export names what you get.

## 3. Prepare the configuration migration

Double check that `bin/config_migrate.sh` is ready for this release. List what this release did to the parameter set, then for each one:

 - **renamed** -- a line in `renamed()`, or it reads as one DROPPED plus one NEW and the user silently gets the template default
 - **meaning or format changed** -- a line in `reformatted()`, so the template value wins
 - **added, and its absence would change behavior** -- resolve its default in `nextflow.config`, below the include and guarded by `containsKey`
 - **added** -- a note under "Read these before your next run", giving the default and what to write for the other value
 - **its default moved** -- nothing to do here, and that is the point: an existing config keeps its own value, so an upgrading project goes on behaving as it did while a new project behaves differently from the same reads. `config_migrate.sh` must not change an analysis setting, so the CHANGELOG is the only place a user can learn it

If this release renames `storageDir`, move the marker in `config_is_current()` with it.

Then read the report a migrating user would see:

```
dev/scripts/check-migration.sh
```

**Read `Kept your value` as carefully as the rest.** It is where a moved default shows up, written as `template -> yours`, and it is the one block that looks like nothing happened.

Also run the language sweep before the merge:

```
dev/scripts/americanize.py          # report; --fix rewrites the safe ones
```

`catalogue` and `analyses` are **not** errors and the script says so. Read every risky hit by hand.

## 4. Run the analysis version gate

```
dev/scripts/check-analysis-versions.sh --release
```

**Must pass.** Commit anything outstanding under `analysis/` first, and not on a shallow clone: `--release` treats a question it could not answer as a failure rather than a skip.

Bump whatever it names behind:

```
dev/scripts/bump-analysis-version.sh frame
dev/scripts/bump-analysis-version.sh index
dev/scripts/bump-analysis-version.sh module <name>
```

## 5. Run the full suite

```
bash test/run_tests.sh
```

A full run solves **both** `install/environment.yml` and `install/environment-analysis.yml` into a scratch pair, runs against those, and removes them on the way out. 

Only a full run does this. `--fast` and `--suite` resolve this tree's exact version and skip what is not installed, so they stay cheap, and neither ever borrows another release's environment.

## 6. Merge to `main`

Open the merge request, review the diff as a whole, merge.


## 7. Bump the version

```
dev/scripts/bump-version.sh <new-version>
```

Abandoning the cycle after this: `dev/scripts/bump-version.sh --revert` undoes the bump and the CHANGELOG section it added. It refuses once the version has been tagged.

**Then raise the environment floor of every module step 2 named.** A moved pin names a package version only this release's environment holds, so those modules require this release and nothing earlier -- and `environment` in their manifests is what tells a user on the older release to upgrade, instead of letting the install reach conda and fail there.

```
"environment": "<new-version>"      in each modules/<name>/manifest.json
```

**It has to be here and not at step 2.** `analysis/lib/nf/modules.nf` refuses at run time any module whose floor is above the running release, so setting it before the bump makes every one of those modules unrunnable in its own repository:

```text
'mds' v20261004.001 needs the analysis environment of PoolSeqFlow 3.3.0 or newer, and this is 3.2.0.
```

No second version bump is needed -- the module's version already moved at step 2 and nothing is committed yet, and the gate compares committed state.

## 8. Run the full suite

**Install the new version first**, and here that is the point rather than a prerequisite: this step is the only one that measures the environments a user actually receives, instead of a scratch solve of the files that describe them.

```
./PoolSeqFlow install
./PoolSeqFlow analysis install
dev/scripts/check-host-floor.sh

bash test/run_tests.sh
```

On `main`, at the new version. The suite resolves both environments and runs tests on them.

**`0 skipped` and `O failed` are the numbers that matter.** 

If it fails, nothing is published yet: undo the bump, remove what you just installed, and triage on `dev`.

```
dev/scripts/bump-version.sh --revert
PoolSeqFlow uninstall
git switch dev
```

## 9. Write the CHANGELOG

- `bump-version.sh` already generated the commit list under `### Commits`. 
- **Write the release notes ABOVE that heading**.
- Do not remove `### Commits`. They demonstrate the work.

What the notes owe a reader, beyond the commits: 
- anything a user has to *do*, 
- anything whose meaning changed, and 
- every parameter that is gone or is now computed.

Then check the section extracts, because `release.yml` refuses to publish a version the CHANGELOG does not describe. Cheaper here than as a deleted tag:

```bash
dev/scripts/changelog-section.sh 3.1.2
```

## 10. Finish the release

**Pushing the tag is the release.** 
- `release.yml` fires on `v*`, rebuilds and verifies the archive, uses this version's CHANGELOG section as the release body, and publishes with both tarballs and `SHA256SUMS` attached. 
- Nothing to assemble by hand.

```bash
git add -A && git commit -m "Version bump vX.X.X"
git push origin main
git tag vX.X.X
git push origin vX.X.X
```

Watch it at <https://github.com/ozankiratli/PoolSeqFlow/actions>.

Once the workflow has finished, verify what it published:

```
dev/scripts/check-release-archive.sh
```

- fetches the tarball and `SHA256SUMS`, checks them, and installs into a throwaway prefix it discards. 
- **does not re-create the conda environment when one is already there**, because the name comes from the version alone.
- answers whether the archive is complete and deployable. 
- not whether the environment files solve (done with `check-exported-floor.sh` at step 2)

## 11. Publish the modules and libraries this release runs

No module ships inside a release, so a release on its own leaves users with an empty store.

What the tree has that the catalogue does not:

```
dev/scripts/publish-module.sh --list
```

Then each one it names, module or library alike:

```
dev/scripts/publish-module.sh <name>
```

It writes the tarball and the catalogue row together and commits neither. **Commit them together** -- the site deploys `modules/repo/` wholesale, so a row without its file advertises a download that 404s until the next deploy -- and push, which is what deploys.

**This is after the release, and a pin move is why it cannot move earlier.** A module whose pin step 2 moved names a package version only this release's environment holds, so its `environment` floor is this release, and that floor cannot be written before the version exists. The catalogue carries a row per module version and the wrapper installs the newest row whose floor an installation clears, so everyone on an earlier release keeps the row they were already running and sees the new one as `needs PoolSeqFlow <version>`.

**Read what the moved pin does to the result.** A package version is an input to what a module computes. Step 2 moves the pin because there is only one version it may name, not because the new version is known to compute the same numbers -- so a module whose pin moved is worth a look before it is published, and worth a CHANGELOG line if the answer changed.

## 12. Return to `dev`

Sync `dev` with `main` so the version bump and the CHANGELOG come back, then carry on. The first commits after a release are usually the things this protocol found and deferred.

```
git checkout dev
git merge --ff-only main
```

---

## What to do when a step fails

**Do not work around it on the release branch.** If a gate found something, fix it on `dev` and start again from the step that would notice. If the gate is wrong, fix the gate, and add the case that would have caught what it missed.

**Read the count, not the word.** The most common defect this project has shipped is a gate reporting success over work it did not do. A `--case` filter matching nothing prints `PASS 0 passed`, and it matches the underscored function name rather than the displayed one.
