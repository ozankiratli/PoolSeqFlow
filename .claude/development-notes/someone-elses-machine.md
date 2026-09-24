# Bugs that only exist on someone else's machine

**Written 2026-09-22, against the tree at `af7939b`, during the 3.1.2 cycle.** Four defects in one day, three of them found by running the tool on a cluster and a server rather than on the machine it was written on. The full suite was green for every one of them, and stayed green while they were live.

They are one family: **a fact about the developer's own machine, baked into something that ships.** The suite cannot catch that class, because the suite runs where the fact is true.

## The four

### 1. An environment installable only on the machine that froze it

`install/environment-analysis.yml` pinned `sysroot_linux-64=2.39`, which declares a dependency on the **virtual package** `__glibc >=2.39` - conda's name for a property of the host. The maintainer's machine reports `__glibc=2.44`, so it solved there, every release, invisibly. No cluster below 2.39 could install the analysis layer, which is most of them.

Nothing asked for 2.39: `gcc_impl_linux-64`, `gxx_impl_linux-64` and `binutils_impl_linux-64` all depend on a bare `sysroot_linux-64` with no version constraint. The solver took the newest the host allowed. `conda update --all` would have done it again every release - measured, it still proposes 2.39 today, and the pin in `prepare_env` is what now stops it.

The full account, the four guards and the release-time check are in [[host-glibc-floor]].

### 2. `rehash: command not found`, on every conda call

conda's `profile.d/conda.sh` runs `__conda_hashr` after every activate and deactivate:

```sh
if [ -n "${ZSH_VERSION:+x}" ]; then
    \rehash
else
    \hash -r
fi
```

`rehash` is zsh's name for `hash -r`. The wrapper is `#!/usr/bin/env bash`, so wherever `ZSH_VERSION` reaches a bash script, conda picks a command bash does not have. Measured on the server: `bash -c 'echo $ZSH_VERSION'` printed `5.9`, so something there exports it - zsh does not, and the maintainer's machine does not, which is exactly why it had never appeared.

**NOT FIXED, on purpose. Z's ruling, 2026-09-23.** Three fixes were written and all three were rejected, and the reason they were all wrong is the same: **the wrapper is not what is broken.**

`eval "$(conda shell.bash hook)"` has been line 17 of `PoolSeqFlow` since **v1.0.0**, written by Z alone, and it is unchanged through every release to 3.1.2 - only its line number moved as the header grew. It works, and it is the only way a script gets `conda activate`: a shell function does not cross a process boundary, so a user who has run `conda init` gives their *interactive* shell the function and gives a script nothing. Measured - parent reports `conda is a function`, the child one process later reports `conda is a file` and `conda activate` fails with `CondaError: Run 'conda init' before 'conda activate'`.

**And asking for the bash hook does not get a bash-only hook.** `conda shell.bash hook` emits `__conda_hashr` with the `ZSH_VERSION` branch still in it, at line 20 of its own output. That is conda's, not ours.

So on a machine where something exports `ZSH_VERSION` into a bash process, conda believes a false claim the environment made about itself and calls a command bash does not have. **The correct response is to do nothing**, because correcting another machine's environment is not this tool's business. The noise is cosmetic: the consequence of the zsh branch is that `hash -r` does not run, and the wrapper invokes nothing before it activates, so there is no stale entry to refresh.

The three rejected fixes, and what each got wrong:

- **Suppressing conda's stderr.** Would hide conda's real failures, and the command-table refresh is what conda was actually asking for.
- **`rehash() { hash -r; }` in `lib/wrapper_lib.sh`.** Made a bash script carry zsh's vocabulary to satisfy a claim that was not true. It was also in the wrong place - `wrapper_lib.sh` is sourced at line 96 and the hook is evaluated at line 44, so the function did not exist for the eval that first raised the error.
- **`unset ZSH_VERSION POSH_VERSION` before the hook.** Z: *"You are still making assumptions about the shell. We don't deal with that."* Process-local or not, it is the tool reaching into variables it does not own to compensate for someone else's misconfiguration.

**What this costs**: the `rehash: command not found` line comes back on that server. Z accepted that knowingly.

**The general form is still worth keeping**, and it is why this one sits oddly beside the other three in this note. Each of them is a string standing in for a real question, and here the real question is *which shell is this*. The difference is that the other three were our strings, in our code, answering questions about our own behavior - and this one is conda asking a question we have no standing to answer.

**It was visible in one arm and not another for a reason worth keeping.** `uninstall` called `conda deactivate` bare while `uninstall_all` had `2>/dev/null || true`, so the same noise was hidden in one place and shown in the other. That inconsistency is what made it findable - the user could say "during uninstall but not uninstall_all", which pointed straight at the difference. The `|| true` also closed a real hazard: under `set -e` a non-zero `conda deactivate` would have abandoned the uninstall with the environment half removed.

### 3. "`~/.local/bin` is NOT on your PATH" - when it is

The install advice used the usual idiom:

```sh
case ":$PATH:" in *":$bindir:"*)
```

That compares **spellings**, and answers a question about the **filesystem**. Any of these make it say no while every command works: a trailing slash on the `PATH` entry, a `$HOME` that ends in a slash so `$HOME/.local/bin` doubles it, or a home reached through a symlink. `dir_on_path()` now resolves both sides with `cd` + `pwd -P` and compares directories. Tested against all four spellings plus a directory genuinely absent.

**Telling someone to fix a `PATH` that is already correct is worse than saying nothing**, because they then edit a shell profile that was right.

### 4. Three test cases that asked Nextflow a question it answers differently

This is the same disease on the test side, and it cost most of the day.

`03_pipeline:39`, `04_guards:648` and `04_guards:835` asked *"did anything run before the guard stopped it?"* by grepping Nextflow's closing summary for `completed=0`. Nextflow 26.04.6 ships **two renderers in one jar** - verified by reading it, `[PIPELINE]`, `[WORKDIR]` and `[ERROR]` are all strings inside `nextflow-26.04.6-one.jar` - and only the compact one prints that line. It chooses for itself, and it chose differently in two shells of one machine, with the same build 12646, the same JDK, and the same `-ansi-log false` on the command line.

So those three passed for one person and failed for the other, on the same commit, every time. It read as a flaky suite and was not.

**The fix was to stop asking.** A run stopped during configuration leaves `work/` empty, and that is what "nothing ran" means. `tasks_started()` counts it from the filesystem; `03_pipeline` reads the trace for `FAILED` rows instead.

**The first version of that helper was itself vacuous**, and the project's own habit caught it: counting task directories at depth two returned **0 for a run that did everything**, because `cleanup = true` removes the inner directory and leaves the hash prefix. Measured against three real sandboxes - a guard-stopped run had an entirely empty `work/`, while finished runs held 21 and 128 prefixes with 24 and 0 inner directories. Counting at depth one discriminates; depth two cannot.

## Three more, on the test side, 2026-09-23

The same disease in the instrument rather than the product: the suite measured the developer's machine and reported it as the release's behavior. Z found all three by reading a skip list and asking why a case had passed.

**Module cases ran against the system R.** They gated on `have_r` - any `Rscript` on PATH - and invoked a bare `Rscript`, which on the machine in question was `/usr/sbin/Rscript`. So `basicstats computes what the corpus says` validated published numbers against system `data.table` and `Rcpp` rather than the pinned ones. Every release up to 3.1.1 was checked that way. Now `have_analysis_r` and `analysis_rscript`, with `have_r` left only for the base-R library suite.

**Nothing was compiled.** Pointing the cases at the environment's R immediately produced `sh: x86_64-conda-linux-gnu-c++: command not found`. `mds_direct` and `association_direct` never put the environment's bin on PATH, and conda's compiler exists on no other. `basicstats_direct` had handled it all along, with a comment naming the exact failure - the other two never got the same treatment, and the system compiler hid it. **So the compiled-path agreement cases had never once compiled.**

The fix Z asked for is one activation for the whole run, because `PoolSeqFlow analysis <module>` activates and a case that only prepends a bin is testing something else. The analysis environment is the one activated: only one can be, and `_run_entry` serves the pipeline side explicitly.

**The activation was then skipped in silence**, because it was found through `conda info --base`, which prints a plugin's load error onto **stdout**:

```
Error loading anaconda-anon-usage: module 'conda.cli.install' has no attribute 'check_prefix'
/home/tholian/.local/opt/miniconda3
```

The variable held that whole string, the `-f` test failed against nonsense, and `|| true` swallowed it. That plugin was already in the triage queue as harmless noise. The hook is now derived from the environment's own path - an env lives at `<base>/envs/<name>`, so the base is two directories up and needs nothing to say so.

**A package could not be made absent.** `basicstats refuses workers it cannot use` hid `doFuture` by pointing `R_LIBS_USER` at a library built without it. Conda R keeps packages in `$PREFIX/lib/R/library`, which **is** `.Library` - always searched, searched last, and removable by no `R_LIBS` variable. Shadowing with an empty directory does not work either: R skips a directory that is not a package. The case could never have tested what it claimed. It now prepends a masking `requireNamespace` to the script `basicstats_direct` concatenates, because the module asks `requireNamespace("doFuture", quietly = TRUE)` and that is what to answer.

**And the shared library was checked against the wrong R entirely.** `08_analysis_rlib` ran under whatever `Rscript` was on PATH, on the argument that the library is base R. Measured: the system carried **4.6.1** and the release ships **4.5.3**. Base R is not one thing - formatting, sort order and `seq` edges move between minor versions.

The first fix preferred the release's R and fell back to the system one, to keep a suite that costs three seconds and no JVM runnable while editing the library. **Z rejected the fallback and was right to.** A fallback is a PASS that does not describe the release, which is the shape of every defect in this note; the convenience argument for keeping it is the same argument that let the others in. `r_lib_section` now uses the release's R or nothing, the cases gate on `have_analysis_r`, and without an environment ten of the eleven skip - the survivor greps the `.R` sources for `library()` calls and never runs R.

`have_r` was deleted in the same change. Once the fallback went it had no callers, which is the tell that it existed only to keep a wrong idea alive.

## Why the suite was green for all of them

Because the suite runs on the machine where the assumption holds. That is not a gap to be closed by more cases - a case asserting "glibc is at least 2.28" would pass here for the same reason the bug did.

**The only instrument that works is a second machine.** All three shipped defects were found within an hour of installing on a cluster and a server, after eleven days of green full-suite runs on the laptop.

## What to do about it

- **`dev/RELEASING.md` step 2 now installs and runs `check-host-floor.sh`**, which reads `conda-meta/*.json` in a real installed environment and reports the highest `__glibc` bound anything imposes. It refused on its first run and named `rsync`, which nothing textual could have seen.
- **Before a release, install on a machine that is not the development one.** That is what found two of these, and it is not yet a step in the protocol.
- **Be suspicious of a comparison where the question is about the filesystem, the environment, or another program's output.** Each of these four was a string test standing in for a real one: a pinned version standing in for what a host provides, a shell detection standing in for which shell is running, a `PATH` spelling standing in for a directory, a printed line standing in for whether work happened.
- **"Passes for me, fails for you" is a difference between the machines, not flakiness.** Treating it as flakiness is what stalled the fourth one for hours. The failure list itself held the answer: every case that read the status line failed, and no others.

## Measurements worth not repeating

- `conda env create --dry-run --json` carries **no `depends` key** - 0 of 190 records. A solve says what would be installed, never what it requires. The constraints live in `$PREFIX/conda-meta/*.json`, so a floor check needs an install, not a solve.
- `conda update --all` on the 3.1.1 analysis environment moves **28 packages**, of which the version-only comparison in `packages-changed.tsv` used to show **3**. It compares `version=build` now: the real count was 26 by name, the rest being rebuilds across the gcc/libstdcxx/libgfortran/libblas stack.
- An exported `ZSH_VERSION` survives into nested bash, so switching shells does not clear it.
- `-q` and `-ansi-log` cannot be combined: Nextflow refuses `Command line options 'quiet' and 'ansi-log' cannot be used together`.
