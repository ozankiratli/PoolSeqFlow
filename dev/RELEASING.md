# Releasing PoolSeqFlow

The order to do a release in, what each step must show, and what bites.

**This is a living procedure, not a record.** Correct it when a release teaches you something; it is not dated and it does not describe a particular version. `.claude/development-notes/` is where the dated records go.

Everything happens on `dev` until step 4. Steps 4 to 10 happen on `main`. Step 11 brings `main` back.

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

It builds the baseline, installs what the modules published from this repository declare, and checks a module cannot move a version another module or the release itself is running on. It found on its first run that `--freeze-installed` does **less** than its name suggests: it refuses to change a package the solve reaches on its own, but a package named on the command line it installs at the version asked for, downgrading what is there.

Every check must say `ok`. A failure here is a compatibility problem between this release and a module, and it is settled by publishing, not on a user's machine.

### Prove the frozen environment installs on an older host than this one

```
./PoolSeqFlow analysis install
dev/scripts/check-host-floor.sh
```

**This is the step v3.1.1 did not have, and a cluster found what it missed.** The analysis environment carries a compiler, because every module builds its hot path on the user's machine, and a compiler is built against a particular glibc. `conda update --all` takes the newest build of everything *this* machine can install, so `sysroot_linux-64` climbs to the maintainer's own glibc unless something says otherwise — v3.1.1 shipped `sysroot_linux-64=2.39`, which declares `__glibc >=2.39`, and no host below that could solve it. It installed perfectly here and nowhere older.

`prep-version.sh` now pins the floor into the scratch environment before it updates, and `export-environment.sh` refuses to write a file that breaks it, so this should pass without incident. Run it anyway: those two guard the package whose *version* is the glibc it targets, and **every other package carries its constraint in conda metadata instead**. `libsanitizer=16.2.0` requires `__glibc >=2.17` and nothing in the string `16.2.0` says so. This reads `conda-meta/*.json` in the installed environment, which is where the real constraints are, and reports the highest lower bound anything actually imposes.

It needs the environment to exist, which is why it comes after an install rather than instead of one. A dry-run solve cannot substitute: measured 2026-09-21, `conda env create --dry-run --json` returns no `depends` key at all — 0 of 190 records carried one.

If it refuses, the floor is a release decision and not a solve artifact. Raising it drops machines, so it takes a line in the manual's Requirements, a move of `HOST_GLIBC_FLOOR` in `export-environment.sh`, and a CHANGELOG entry saying which machines just lost support.

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

The release commits — the version bump and the CHANGELOG — are made on `main` after this, so `main` briefly holds the merge at the old version. That state is never tagged, so it costs nothing, and it keeps release-only commits off `dev` until step 11.

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

It rewrites the version in the wrapper (header comment and `VERSION=`) and in `nextflow.config`'s manifest, and prepends a CHANGELOG section listing every commit since the last release tag. It does not commit, tag or push — it prints those commands.

**It does not touch a module or library manifest, and must not.** No module ships inside a release, so a module's `"environment"` is the oldest release its author says it needs — moved when its needs move, by whoever maintains it, not by a release bump acting on its behalf. `dev/scripts/bump-analysis-version.sh module <name>` is what moves a module's own version when you change it.

## 7. Run the full suite

**Install the new version first, and name both environments.** The suite is worthless without them and says so only in the skip count:

```
./PoolSeqFlow install
./PoolSeqFlow analysis install
dev/scripts/check-host-floor.sh

TEST_CONDA_ENV=$HOME/.local/opt/miniconda3/envs/PoolSeqFlow-<version> \
TEST_ANALYSIS_ENV=$HOME/.local/opt/miniconda3/envs/PoolSeqFlow-<version>-analysis \
    bash test/run_tests.sh
```

On `main`, at the new version, with the frozen environments. This is the run that matters — everything before it tested a version string that is no longer the one shipping. The install is also what proves the files frozen at step 2 actually describe an installable environment, which nothing else checks.

**The environments are named after the version, so step 6's bump renames them out from under the suite.** Naming both explicitly, as above, is what makes that a non-event — and since 2026-09-23 discovery also handles it: `find_release_env()` takes the environment matching the wrapper's own `VERSION` and warns on stderr when it has to settle for another, so a tree at the new version can no longer measure the old environment in silence.

That was found the hard way. Discovery globbed `$HOME/.conda/envs/PoolSeqFlow-*` only, which finds nothing when conda keeps its environments under its own `envs/` — as miniconda does — so a machine with all four environments installed produced a full run in which every module case skipped for "no conda environment" and the run still reported success. The glob also took whatever sorted first, which is the oldest environment present. Both are fixed in `test/run_tests.sh`; the explicit names stay here because a release run should state what it measured rather than discover it.

**A skip is a hole, not a pass.** `555 passed, 0 skipped` is the number. Read the skip list, never the count alone:

```
bash test/run_tests.sh 2>&1 | grep SKIP
```

**Check the counts against the previous run, not only the exit status** — cases passed *and* cases skipped. A filter that matches nothing also reports success, and a skip is how a case that should have run says so quietly.

**Lint without `modules/`**, at zero errors and zero warnings:

```
nextflow lint analysis analysis.nf dryrun.nf poolseqflow.nf scripts
```

`nextflow lint .` cannot pass: a module's `main.nf` imports the frame as `'../../lib/nf/plan.nf'`, which resolves from the store it is installed into and not from `modules/<name>/`. `00_static` lints the modules, in an assembled store layout.

## 8. Write the CHANGELOG

`bump-version.sh` already generated the commit list under `### Commits`. **Write the release notes ABOVE that heading, never over it** — the commit list stays as the record of what landed.

What the notes owe a reader, beyond the commits: anything a user has to *do*, anything whose meaning changed, and every parameter that is gone or is now computed.

Then check the section extracts, because `release.yml` refuses to publish a version the CHANGELOG does not describe, and this is the extractor that writes the release body. Cheaper here than as a deleted tag:

```bash
dev/scripts/changelog-section.sh 3.1.2
```

## 9. Finish the release

**Pushing the tag is the release.** `release.yml` fires on `v*`, rebuilds and verifies the archive, uses this version's CHANGELOG section as the release body, and publishes with both tarballs and `SHA256SUMS` attached. Nothing to assemble by hand.

```bash
git add -A && git commit -m "Version bump v3.1.2"
git push origin main
git tag v3.1.2
git push origin v3.1.2
```

Watch it at <https://github.com/ozankiratli/PoolSeqFlow/actions>.

- **Zenodo mints a DOI for the version.** The citation machinery points at the all-versions DOI and tells a user to pick their version from it, so the version record has to exist for the citation the release prints to be answerable.
- Verify the published archive installs from scratch on a machine that has never had it:

```bash
V=3.1.2
cd "$(mktemp -d)"
curl -LO "https://github.com/ozankiratli/PoolSeqFlow/releases/download/v$V/PoolSeqFlow-$V.tar.gz"
curl -LO "https://github.com/ozankiratli/PoolSeqFlow/releases/download/v$V/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS
tar -xzf "PoolSeqFlow-$V.tar.gz"
cd "PoolSeqFlow-$V"
cp parameters.config.template parameters.config
./PoolSeqFlow install
./PoolSeqFlow analysis install
./PoolSeqFlow check install
```

## 10. Publish the modules and libraries this release runs

No module ships inside a release, so a release on its own leaves users with an empty store. Publishing is what makes the modules installable, and it is separate on purpose: a module moves on its own timetable, and one published tomorrow is installable into this release without re-releasing anything.

```
dev/scripts/publish-module.sh <name> [ref]
```

It builds the tarball into `modules/repo/`, reads `kind`, `contract`, `frame`, `environment` and `summary` out of the thing's own manifest, appends the catalogue row and bumps `#!index-version`. It takes a module or a library by name and finds it in `modules/` or `modules/lib/`.

**Publish from a commit.** The script refuses a source with no commit timestamp, because the tarball's reproducibility depends on it — archiving a tree stamps *now* and two builds of one ref stop matching. So this comes after the release is committed, not before.

**The tarball and the row it advertises go out in one commit.** The site deploys `modules/repo/` wholesale at the published address `/PoolSeqFlow/modules-repo/`, so a row committed without its file advertises a download that 404s until the next deploy.

**A published version is never rewritten.** Somebody may have installed it and its checksum is in the catalogue. Change means bumping the version and publishing that; `00_static` checks every row's file exists and its checksum matches.

## 11. Return to `dev`

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

---

## Post-release triage

Things this protocol worked around rather than fixed. Each has a note saying what the workaround is, so a release is never blocked on one — and each is a gate that is weaker than it reads, so none of them should sit here long.

**`run_tests.sh` reports success over cases it never ran.** Measured on 2026-09-10: a full run said `549 passed, 3 skipped` and exit 0, and the three that skipped — the PDF report, the compiled hot path, and the compiled-and-parallel agreement — are among the least trivial in the suite, F1's Rcpp worker bug having been caught by the combination of compiled *and* parallel and by nothing else. On 2026-09-23 the same shape was far worse: every module case skipped, and the run still exited 0.

**The two discovery defects behind those particular runs are fixed** — `conda info --base` returning a plugin's error on stdout, and a glob that looked in one directory and sorted to the oldest match. The item itself is not, because the next thing to go wrong will also end in a skip. What the suite should do is **refuse**, the way `check-analysis-versions.sh --release` refuses rather than answering: asked for a full run, a suite that cannot find the environment its cases need should say so and exit non-zero. `--fast` and `--cost static` legitimately skip those, so the refusal belongs to the unfiltered run alone.

Until then the workaround is step 7's and it is a person remembering: name both environments, and read the skip count. The header now prints both environments it resolved, so a run that found neither says so in its first two lines.

**A release step that shells out to `conda` cannot assume `conda` works.** On a machine where the shell function is set up for an interactive shell of a different family, a non-interactive `bash -c 'conda env list'` fails with `__conda_exe: permission denied` — and `env_exists()` in `prep-version.sh` is `conda env list | grep -qxF`, so a broken function reads as *the environment is not there* and the script refuses a release that had nothing wrong with it. A misconfigured plugin is the milder version of the same thing: `anaconda-anon-usage` prints an error line on every invocation while conda still works, which is noise in a log that a person is being asked to read carefully.

The workaround is to `source <base>/etc/profile.d/conda.sh` before running anything that needs conda. What the scripts should do instead is source it themselves, or resolve the real binary and stop depending on the shell at all — and `env_exists()` in particular should tell *conda said no* apart from *conda did not run*, because those are opposite problems wearing the same message.

**Step 2 is skippable when nothing has drifted, and the protocol should say how to know.** Its expensive half updates and re-freezes both environments; when the last freeze already describes them, that work produces an identical file and an hour of nothing. The check is two exports to a scratch path and a diff:

```
dev/scripts/export-environment.sh PoolSeqFlow-<version> /tmp/a.yml
dev/scripts/export-environment.sh PoolSeqFlow-<version>-analysis /tmp/b.yml
diff /tmp/a.yml install/environment.yml && diff /tmp/b.yml install/environment-analysis.yml
```

Identical both ways means the freeze still holds and the update-and-export cycle is redundant. **`check-module-packages.sh` is not part of that skip** — it asks a different question, whether the modules' own pins still solve against the frozen baseline, and a module's manifest can change on a day the environments do not.
