# What macOS support would actually take

**Written 2026-09-23, against the tree at `6e12735`, during the 3.1.3 cycle.** Z asked whether the new tab completion would work on a Mac. It would not, and neither does anything else, although the manual had claimed macOS since before v3.1.0. Z's call the same day: **drop it for now, correct the claim, and plan it properly** - *"It is real work. I'm still fixing the backend. I need to get this to become more stable before we start working on MacOS."*

This note is the sizing, so the next attempt starts from measurements rather than from a survey.

## The claim that was wrong

Five places said macOS was supported, including the Requirements table and `README.md`. One said more than that: the analysis-environment section claimed the compiler is *"GCC on Linux, clang on macOS"*, describing a per-platform behavior the shipped file cannot have. All six now say Linux, and `#### Why not Windows` became `#### Why Linux only` (keeping the `#why-not-windows` anchor, which one row links to).

**This is the glibc bug one level up.** That was a single pin excluding older Linux; this was a whole platform the documentation promised. Same cause, recorded in [[someone-elses-machine]]: it has only ever been installed on one machine.

## The three blockers, in the order they bite

### 1. The environments cannot solve at all

`install/environment.yml` pins `ld_impl_linux-64`. `install/environment-analysis.yml` carries **12** `linux-64` pins - `sysroot_linux-64`, `gcc_impl_linux-64`, `gxx_impl_linux-64`, `kernel-headers_linux-64` and the rest of the toolchain. Those package names exist for `linux-64` by construction and for no other platform, so `conda env create` fails before anything else is reached.

**This arrived with the pinned exports.** A hand-written spec names what you ask for and solves per platform; an export names exactly what one machine got. The reproducibility that makes the export right is the same property that makes it single-platform.

So macOS needs its own exported files - and **two of them**, because conda treats `osx-64` and `osx-arm64` as different platforms. Each has to be exported on that hardware and verified there. That is the part that cannot be done from here.

### 2. Three GNU-only idioms in the shipped wrapper

| | |
|---|---|
| `PoolSeqFlow:86` | `readlink -f` - `-f` is a GNU extension; it fails at startup, before dispatch |
| `PoolSeqFlow:178` | `sort -V` - BSD `sort` has no version sort |
| `PoolSeqFlow:359` | `sed -i "..."` - BSD requires a backup suffix, `sed -i ''`, and errors without one |

Only the completion was fixed, because it was being written that day: `lib/poolseqflow-completion.bash` follows symlinks a hop at a time with plain `readlink` and a loop guard. That is better code on Linux too, so it stayed.

### 3. The suite itself has to run there

Proving macOS support means running the suite on the Mac, and the suite is not portable either. Found without looking hard: `stat -c` in `run_tests.sh` and `02_launcher`, `find -printf` in `04_pipeline`, GNU `sed -i` in `04_pipeline`, `05_guards` and `06_dryrun`. There will be more - a full audit was started and stopped when the decision was made.

**And the filesystem differs.** APFS is case-insensitive by default, so any two fixtures differing only in case are the same file there.

## What else to think about before starting

- **`check-host-floor.sh` reasons about `__glibc`**, which does not exist on macOS - conda uses `__osx`. It needs to know which platform it is checking rather than assuming.
- **`export-environment.sh` and `prep-version.sh`** write and validate one pair of files. They would need to know about three platforms, and a release would not be exportable from one machine.
- **Every module compiles its hot path on the user's machine.** So the analysis environment needs a working clang toolchain pinned for each macOS platform, not just R.
- **`bash 3.2`.** macOS ships the 2007 GPLv2 bash as `/bin/bash`. The wrapper's shebang is `#!/usr/bin/env bash`, so it would take whatever is first on PATH - conda's newer bash if an environment is active, the system one otherwise. Worth deciding deliberately rather than discovering.

## The honest summary

Not a flag and not an afternoon. It is: three sets of pinned environment files instead of one, a release process that can export them, three wrapper fixes, an unknown number of suite fixes, and a machine to verify all of it on. Nothing here is hard; it is just genuinely a platform port, and the pinning that makes this project reproducible is exactly what makes it one.
