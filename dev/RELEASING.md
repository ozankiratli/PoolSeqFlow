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

The scratch environments are removed on every exit. The conda package cache is left alone.

**Run it with `--no-cleanup`**, and the pair survives for step 5 to reuse. Three full suite runs in a cycle otherwise means three solves of the same two files, and the second of them proves nothing the first did not. It prints the two `export` lines to use; keep them in the shell you carry through to step 5.

Then read `dev/logs/prep-<version>-<timestamp>/`, including the per-environment table of what moved.

**A moved pin is a module change.** There is one version a pin may name -- whatever the shared analysis environment holds -- so when the update moves a package, `prep-version.sh` rewrites the pin in every manifest declaring it and bumps that module's version. Read those edits in the diff with the environment files: they are uncommitted like everything else here, and every module whose version moved is republished at step 10. A package version that changes what a module computes is the thing to look for.

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

Bump whatever it names behind, all at once:

```
dev/scripts/bump-analysis-version.sh --pending
```

It bumps exactly what the gate names, prints each version it moved, and runs the gate again, failing unless it now passes. Commit, then run the gate with `--release` once more. One at a time is `frame`, `index` or `module <name>` in place of `--pending`.

## 5. Run the full suite

```
bash test/run_tests.sh
```

A full run solves **both** `install/environment.yml` and `install/environment-analysis.yml` into a scratch pair, runs against those, and removes them on the way out. **Its last lines must name both as they go**, `removing the scratch environment PoolSeqFlow-suite-<pid>` and the same with `-analysis`. A run that ends without them left the pair installed, which `conda env list` shows; the next full run removes it, and any other pair whose run is no longer running, before it builds its own.

Only a full run does this. `--fast` and `--suite` resolve this tree's exact version and never borrow another release's environment. A case that cannot run because something is not installed fails a `--suite` run, and is skipped only under `--fast`.

**Reuse step 2's pair rather than solving a third one.** If step 2 ran with `--no-cleanup`, it printed two `export` lines; with those set, this run uses them and starts testing at once:

```
export TEST_CONDA_ENV=<the prefix step 2 printed>
export TEST_ANALYSIS_ENV=<the other one>
bash test/run_tests.sh
```

Nothing is lost by it: the files have not changed since step 2 exported them, so a fresh solve would produce the same pair. What this step is actually re-checking is whatever steps 3 and 4 changed.

**Then remove them**, because `prep-version.sh` refuses to start while they exist:

```
conda env remove -n PoolSeqFlow-update -y
conda env remove -n PoolSeqFlow-update-analysis -y
```

## 6. Merge to `main`


```
git add -A && git commit -m "Prep for vX.X.X"
git push
```

Open the merge request, review the diff as a whole, merge.

```
git switch main
git pull
```

## 7. Bump the version

```
dev/scripts/bump-version.sh <new-version>
```

Abandoning the cycle after this: `dev/scripts/bump-version.sh --revert` undoes the bump and the CHANGELOG section it added. It refuses once the version has been tagged.

**Then raise the environment floor of everything this release republishes** -- libraries as well as modules:

```
dev/scripts/raise-module-floors.sh --dry-run      # what it would change
dev/scripts/raise-module-floors.sh
```

Republished means its manifest version moved since the previous tag, which is the same set `publish-module.sh --list` acts on at step 10. Anything in it was proven only against this release's environment, and `environment` is what tells an older installation to upgrade instead of letting the install reach conda and be refused there with nothing explained.

**Libraries are in it for a reason beyond their own pins.** The catalogue resolves a module and its libraries **independently**, each taking the newest row whose floor the installation clears. A republished library left at an old floor could therefore be paired with the *previous* release's module on an older installation. Giving everything republished the same floor makes the release the unit: an installation gets the whole of one or the whole of the other.

`moved-modules.txt` from step 2 is read as a check, not as the list -- anything step 2 recorded moving a pin in must be in the republished set, and a disagreement stops the script.

**It has to be here and not at step 2.** `analysis/lib/nf/modules.nf` refuses at run time any module whose floor is above the running release, so setting it before the bump makes every one of those modules unrunnable in its own repository:

```text
'mds' v20261004.001 needs the analysis environment of PoolSeqFlow 3.3.0 or newer, and this is 3.2.0.
```

which is six failures across the three module suites. The script refuses a version above the one the tree declares, for the same reason.

**It also moves the version of every manifest whose floor it raises**, and prints each one. Those are the versions step 10 publishes, and the ones the release notes give if they name a module's version.

## 8. Run the full suite

On `main`, at the new version. **Two different questions, and the suite no longer answers the second one.**

### The suite, which brings its own environments

```
bash test/run_tests.sh
```

A full run builds a scratch pair from `install/environment.yml` and `install/environment-analysis.yml` and removes them, so it neither needs an installation nor touches one. Expect minutes before the first case. Nothing has to be installed for this.

**It must end in `PASS`.** A case that could not run fails the run, so a `PASS` means every case ran and passed.

### The installation, which is the other question

```
./PoolSeqFlow install
./PoolSeqFlow analysis install
dev/scripts/check-host-floor.sh
```

Whether an install of the new version works, and what the environment it creates requires of a host. `install` verifies itself and fails if anything is missing, so there is nothing to read but its exit.

Order between the two does not matter, because neither reaches the other. If you run the suite first you can skip installing until you need the commands.

Note for step 11: having `PoolSeqFlow-<version>` installed is what makes `check-release-archive.sh` reuse the environment rather than create one, which its own header records as a limit. Installing here is not free of consequence further down.

### If it fails

Nothing is published yet: undo the bump and the floors and versions step 7 wrote into the manifests, remove what you installed, and triage on `dev`. `bump-version.sh --revert` does not touch a manifest, so the `git restore` is what puts them back.

```
dev/scripts/bump-version.sh --revert
git restore modules/
PoolSeqFlow uninstall
git switch dev
```

## 9. Write the CHANGELOG

**Read what the moved pin does to the result.** A package version is an input to what a module computes. Step 2 moves the pin because there is only one version it may name, not because the new version is known to compute the same numbers -- so a module whose pin moved is worth a look before it is published, and worth a line in these notes if the answer changed.

- `bump-version.sh` already generated the commit list under `### Commits`. 
- **Write the release notes ABOVE that heading**.
- Do not remove `### Commits`. They demonstrate the work.

What the notes owe a reader, beyond the commits: 
- anything a user has to *do*, 
- anything whose meaning changed, and 
- every parameter that is gone or is now computed.

Then check the section extracts, because `release.yml` refuses to publish a version the CHANGELOG does not describe. Cheaper here than as a deleted tag:

```bash
dev/scripts/changelog-section.sh X.X.X
git add -A && git commit -m "Version bump vX.X.X"
git push
```

## 10. Publish the modules and libraries this release runs

`publish-module.sh` builds each tarball from a commit, `HEAD` unless told otherwise, so step 9's commit comes first.

Every module and library, and whether the catalogue has its version:

```
dev/scripts/publish-module.sh --list
```

Its `UNPUBLISHED` names should be the ones step 7 printed. Anything else is a version moved since the last release that was never published, and `--all-pending` publishes that too: look at it before going on.

Then all of it, modules and libraries alike:

```
dev/scripts/publish-module.sh --all-pending
```

On success it prints `Published N:` with the names, then the reminder to commit. With nothing pending it prints only `Everything in the tree is in the catalogue.`, and there is nothing to commit. Before writing anything it refuses a pending module that differs from `HEAD`, a manifest it cannot read, and a name two directories share. If a publish fails it stops and says what it published, what is still pending, and what is in the way of the next run. Fix what it names and run it again; it starts from what is still pending.

Each publish writes the tarball and the catalogue row together and commits neither. **Commit them together** -- the site deploys `modules/repo/` wholesale, so a row without its file advertises a download that 404s until the next deploy. Nothing reaches the site before `release.yml` succeeds at step 11.

```bash
git add modules/repo && git commit -m "Publish modules for vX.X.X"
```

## 11. Finish the release

**Pushing the tag is the release.** 
- `release.yml` fires on `v*`, rebuilds and verifies the archive, uses this version's CHANGELOG section as the release body, and publishes with both tarballs and `SHA256SUMS` attached. 
- Nothing to assemble by hand.

First the analysis version gate, which `release.yml` runs before it builds anything:

```bash
dev/scripts/check-analysis-versions.sh --release
```

It must print `Every analysis version is up to date with what it covers.` If it does not, stop here and fix what it names: failing it here costs a commit, failing it after the tag costs the tag. Only then:

```bash
git push origin main
git tag vX.X.X
git push origin vX.X.X
```

Watch it at <https://github.com/ozankiratli/PoolSeqFlow/actions>. When it succeeds, the Documentation workflow follows on its own and deploys the site from the released commit. When it fails, the site stays as it was: no push and no merge before this point deploys anything.

Once the workflow has finished, verify what it published:

```
dev/scripts/check-release-archive.sh
```

- fetches the tarball and `SHA256SUMS`, checks them, and installs into a throwaway prefix it discards. 
- **does not re-create the conda environment when one is already there**, because the name comes from the version alone.
- answers whether the archive is complete and deployable. 
- not whether the environment files solve (done with `check-exported-floor.sh` at step 2)

## 12. Return to `dev`

Sync `dev` with `main` so the version bump and the CHANGELOG come back, then carry on. The first commits after a release are usually the things this protocol found and deferred.

```
git checkout dev
git merge --ff-only main
```

Then remove what the cycle left behind:

```
dev/scripts/clean-release-scratch.sh
```

It names everything it removes: the suite's kept working directories under `/tmp` and `/dev/shm`, the scratch conda environments of steps 2 and 5 and of any run that was interrupted, and `.tmp/release-review/`. It keeps `dev/logs/` and every installed `PoolSeqFlow-<version>` environment. **It refuses, and removes nothing, while any suite run or release script is still going**; let them finish and run it again. `--dry-run` lists what it would remove.

---

## What to do when a step fails

**Do not work around it on the release branch.** If a gate found something, fix it on `dev` and start again from the step that would notice. If the gate is wrong, fix the gate, and add the case that would have caught what it missed.

**Read the count, not the word.** The most common defect this project has shipped is a gate reporting success over work it did not do. A `--case` filter matching nothing prints `PASS 0 passed`, and it matches the underscored function name rather than the displayed one.
