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

**Fixed by defining it rather than by silencing conda.** `lib/wrapper_lib.sh` carries `rehash() { hash -r; }`; the backslash in `\rehash` suppresses aliases, not functions, so that is what runs. Suppressing conda's stderr was the first instinct and was wrong: it would hide conda's real failures, and refreshing the command table is what conda was asking for.

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
