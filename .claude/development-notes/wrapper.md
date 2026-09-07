# The `PoolSeqFlow` wrapper

**Written 2026-08-31, against the tree at `7d65893`.** Everything here still holds — the stamp, the lazy `require_install`, the `env_exists` name-column comparison, both deletion fixes, and what `init` refuses to write. Only the arity amendment below has been overtaken, and it is corrected in place.

The shell script in front of everything. The root model it implements is in `four-roots.md`; this file is about the script itself — the traps it is shaped around, and the things it used to do wrongly.

**Arity, amended 2026-08-31.** It took exactly one word for its whole life, and that contract was load-bearing enough that the analysis layer was given a wrapper of its own to avoid touching it. Z reversed that and merged the two: **every subcommand still takes no arguments except `analysis`, which takes exactly one** — an analysis command, or the name of a module to run. `analysis-wrapper.md` covers that half and what the merge removed.

**It widened again, first the same evening and then further.** A module run is `analysis <module> [nocpp]`, and the store is `analysis modules install <name> [<version>]`, so `analysis` no longer takes exactly one word. What survived is the *shape* rather than the count: the top-level subcommands still take nothing, and everything variable hangs off `analysis`. `usage_analysis` in the script is the current statement of it, and `four-roots.md` records the same widening from the root model's side.

## Why the installed copy is stamped rather than self-locating

`POOLSEQFLOW_INSTALLED_HOME` is written into the deployed copy by `install`, with a `sed` that then verifies its own substitution took. The alternative — having the wrapper resolve its own path at run time — fails on exactly the case that matters: an installed wrapper is reached through a symlink on `$PREFIX/bin`, and **resolving a symlink back to its target is the single most system-dependent step in the whole script**. `readlink -f` is GNU; BSD `readlink` has no `-f` at all. So the source tree's copy falls back to `readlink -f "$0"` (which is fine — a clone is not reached through a symlink) and the installed copy never needs to.

The stamp is a **default, not an override**. `POOLSEQFLOW_HOME` still wins, which is what lets a developer point an installed wrapper at a working checkout without reinstalling.

## Why `require_install` is called per subcommand instead of at startup

`version`, `cite`, `list`, `uninstall` and `uninstall_all` are answerable from the wrapper alone. Refusing them because `poolseqflow.nf` is missing would take away exactly the commands someone reaches for **when an installation is broken** — which is the moment they are most needed. So the check is lazy and each subcommand opts in.

## Why `require_project_config` exists at all

Nextflow does detect the missing include, but what it prints is `ERROR ~ Unable to parse config file`. The real cause is a NullPointerException, and it appears only in `.nextflow.log`. That is not a message anyone can act on, so the wrapper checks for `parameters.config` first and says what to do instead.

## `env_exists` compares the name column only, and this is not hypothetical

`conda env list` prints `<name>  [*]  <path>` per row, so grepping the whole line for a name also matches any **other** environment whose path happens to contain it. The repository directory is itself called `PoolSeqFlow`, so an environment created underneath it matches. Hence `awk '{print $1}'` first, then `grep -qxF` — whole (`-x`) and literal (`-F`), so a name containing `.` or `+` still works.

## What a second environment actually costs

Measured, because the per-version environment scheme is what made the question worth asking. Conda hardlinks most package files from its shared cache, so environments overlap on disk and `du` overstates the cost:

| | |
|---|---|
| total | 1000 MB |
| hardlinked and shared | 696 MB (90% of files) |
| genuinely per-environment | 304 MB (10% of files) |

So a second version costs roughly **300 MB even where every package matches**, plus the full size of anything whose version differs. Note that counting *files* rather than bytes makes the sharing look considerably better than it is.

`require_env` never falls back to another version's environment, and that is the point of the scheme: the pinned tool versions are part of what produced a result, so running this code against a different release's tools would leave the version record naming a release that did not produce the outputs.

## Uninstalling the copy you are running from is safe

On Linux the shell holds the script open, and unlinking an open file keeps its contents readable until the last close — so `remove_payload` deleting its own payload mid-execution works. **Verified rather than assumed**: there is a self-uninstall case in the launcher suite.

The plain `PoolSeqFlow` symlink is re-pointed at the newest remaining version, or removed once none remain. A dangling symlink on PATH is worse than an absent command: it fails far less clearly.

## `nf_config_value` is the only path oracle, and both roots resolve through it

Resolved through Nextflow rather than by parsing `parameters.config`, because values are interpolated — `workDir` is built from `mainDir` — and text matching gets them wrong. The installation is named explicitly on the command line because that is where `nextflow.config` lives, while the current directory supplies `parameters.config`. **Verified that both resolve correctly from a project directory**: `${launchDir}` entries come from the project, `${projectDir}` entries from the installation. What it cannot do is name per-run directories; see `promotion.md`.

## Two deletion bugs the current shape is the fix for

**`clean` deleted Nextflow's history silently.** `rm -rf .nextflow*` used to sit *below* the if/else that reports on `workDir` rather than inside it. A project whose `workDir` could not be resolved was therefore told only that the work directory was being left in place — while `.nextflow*` was deleted anyway, unmentioned. The deletion was right; the silence was not. Everything that will be removed is now listed before anything is, including that branch.

**`reset` had an `rm -rf` on a user glob.** `$STORAGE/PoolSeqFlow_*` was removed here too, until it was traced: the `PoolSeqFlow_pipeline_{dag,trace,timeline,report}` files have gone to `${params.dir.output.reports}` in every release since 1.0.0, never to `storageDir` itself. The glob therefore **never matched anything this pipeline created**. All it could ever have done is delete a user's own file or directory that happened to start with `PoolSeqFlow_` — undisclosed, and with `rm -rf`. Dropped.

The surviving legacy removals are deliberate and harmless: `$STORAGE/Reports` only exists for projects created before 2.1.0, `$STORAGE/Reference` only for those created before 3.0.0, and the guard files at the storage root only for those created before 3.0. Leaving one of the last would make the next run fail its checks for no reason, or attribute fresh results to an earlier release.

## Why the dry-run preview is the one directory that gets vetted

`dryrun` rebuilds the preview from scratch and `dryclean` removes it, both with `rm -rf` on a path taken from the configuration — so both call `dryrun_is_ours` first. It is the only one of the three roots that sits **in the project** rather than in a storage root, which is precisely where somebody is most likely to have put something of their own. Finding anything that is not an empty directory, a `README.txt` or a `members.txt` is reported and stops the command; the answer is never to delete it anyway.

## What `init` will not write for you

`parameters.config` is copied from the template because it is a settings file edited in place, so the template is the right starting point. `metadata.csv` and the run table are **not** written, only their `.example` copies: both are tables whose entire content is the experiment — which pairs are one pool, which parameters differ between runs — so a copied one would describe somebody else's. See `metadata-file.md`.

`init_multi` flips `multiRun` to `true` only in a config it created this run. Editing one the user has already filled in would be reaching into their settings behind their back, so if the config was already there it says so and asks them to set it themselves.

## `uninstall` asks, and refuses to guess

This wrapper's own version is only the newest **by default**, so silently removing "this version" would sometimes delete the copy most projects are using. One installed version needs no question; several do. With nothing attached to prompt — a script, CI, a hook — it refuses and names the exact command that removes a specific version (`PoolSeqFlow-<version> uninstall`), because guessing here deletes somebody's installation.
