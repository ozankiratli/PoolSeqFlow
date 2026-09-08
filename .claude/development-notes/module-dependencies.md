# The four fields a manifest gained, and where each is enforced

**Written 2026-09-08, against the tree at `409aef7`.** E8's first half: the manifest schema. The conda half — what installing a module does to the shared environment — is not built yet and this note does not describe it. The manual is authoritative on what a user sees; `analysis/modules/README.md` is authoritative on what a module author writes. This is the record of why the shape is what it is.

## What forced it

A module could not declare a dependency at all. `install/environment-analysis.yml` is one hand-written conda spec for the whole analysis layer and a module has no file that feeds it, so the FST module — first in the F4 roster, built on `r-poolfstat` — was not installable at any price. 3.0.0 is the release that opens the store to third parties, who cannot wait for a PoolSeqFlow release to gain a package.

`license` had a second reason. It was already in `association` and `mds` and was doing nothing: `readManifest()` builds its return map from a literal list of keys and dropped every other one at parse time. Adding a field to a manifest was, until now, a way of writing a comment.

## The three shipped modules are GPL, and the argument that they were not was wrong

They carried `Apache-2.0` because that is what was written when the field did nothing. Z asked whether the 2026-09-03 decision had not been GPL. It had not — that decision was *per-module*, with the FST module going GPL because `poolfstat` is — but the question was right for a reason neither of us had checked.

Measured, `Rcpp` is `GPL (>= 2)`. Everything else the three load is permissive: `doFuture` Apache-2.0, `ggplot2` MIT, `data.table` MPL-2.0, `jsonlite` MIT. `optparse` is GPL-2+ and is in the environment, but no module loads it.

I first argued the Apache label survived because the compiled path was optional. **Z corrected that and it is the whole point**: `usecpp: true` is the default in all three `main.nf`, `nocpp` is the opt-out, `r-rcpp` is pinned into `install/environment-analysis.yml`, and `mds.R:52` **stops** when Rcpp is absent rather than falling back. A dependency the default configuration hard-requires is not optional in any sense that a license question cares about.

What was left of the counter-argument — that we ship `.R` and `.cpp` as source and the user's machine does the linking, so no combined work is ever distributed by us — is an argument about *when* the obligation attaches, not about whether the dependency is real. Z's call, 2026-09-08: GPL-3.0-or-later on all three.

`verify` stays Apache-2.0 in `builtinModules()`. It belongs to the frame, runs no R, and installs nothing.

Consequence written down where a user meets it: `README.md` and the manual's License section now say the modules carry their own terms, because the release tarball ships an Apache-2.0 core beside GPL modules. That is ordinary aggregation — separate files, separate works, no linking — but a repository badged Apache-2.0 that ships GPL under it has to say so.

## Why validation splits across two functions

`readManifest()` is called by `moduleRoster()` for **every** directory in the store, and `moduleNames()` — which builds the "Available here:" list in a refusal — calls that. So anything thrown from `readManifest()` takes down every other module too: one bad manifest and you cannot run, or even list, the good ones.

That is the right behavior for a **broken** manifest and the wrong behavior for an **incompatible** one. A manifest missing `license` is an install that did not finish; a manifest asking for a newer frame is a module that is fine and simply does not belong here. So:

- **shape** — field present, `frame` matching `YYYYMMDD.NNN`, `environment` dotted-numeric, every `packages` entry pinned — stays in `readManifest()`, beside the existing `name`/`contract` checks it is indistinguishable from.
- **compatibility** — `frame` against `frameVersion()`, `environment` against the release — is `checkModuleCompatible()`, called from `analysisPlan()` beside `checkModuleNeeds` and `checkModuleOutputs`. It refuses one module and leaves the roster alone.

## The environment check only fires in one of the two halves, and that is enough

`workflow.manifest.version` comes from the root `nextflow.config`, which Nextflow reads for an entry script beside it. `analysis.nf` is at the installation root, so the **verify** half knows the release; a module's own `main.nf` is at `analysis/modules/<name>/`, so the **module** half does not, and `frame.config` deliberately sets no `manifest` block (one there would override the release that `0_verify_analysis.nf` checks the results against).

Both halves call `analysisPlan()`. The check skips a release it cannot read rather than guessing, which costs nothing: the verify half always runs first, always knows, and always refuses before the module is launched. The frame half of the check reads a file and works in both.

Measured alternative not taken: passing the release down through `frame.config` as a params key. It would reach the recorded manifest, and the identity check reads a new top-level key as a setting added since the results were produced — every analysis in the project would then refuse. That is the trap rule 11 of `analysis/modules/README.md` names, and it applies to the frame just as it does to a module.

## Why a package spec is `name=version` and nothing else

The regex is `[a-z0-9][a-z0-9._-]*=[A-Za-z0-9][A-Za-z0-9._+]*`, which refuses four things, each for its own reason:

| refused | why |
|---|---|
| `r-poolfstat` | unpinned. What an analysis ran on would be a property of the day it was installed |
| `r-poolfstat=3.0.0=r44hb79369c_0` | a build string names one platform's build, so the manifest cannot install on another OS |
| `r-poolfstat>=3.0` | a range is the same problem as no pin, spelled more confidently. Note it contains exactly one `=`, so "one `=`" was never a sufficient test and the whole spec has to be matched |
| `conda-forge::r-poolfstat=3.0.0` | the channel set is the release's decision. A module choosing its own channel is a supply-chain decision made by whoever published the module |

Z, 2026-09-03: *"Set together to work together."*

## `environment` is checked for equality on a shipped module and as a minimum everywhere else

The field is a **minimum** — the oldest release whose analysis environment holds what the module needs — and a third-party module sets whatever is true of it. A module that ships **inside** a release is installed with that release's environment and no other, so for those the minimum is the release exactly, and `00_static` asserts equality against `nextflow.config`'s `manifest.version`.

That is also the mechanism that makes E7b's version bump safe. All three shipped manifests say `2.2.0` today because that is what this tree is. When E7b bumps to 3.0.0 the static case fails by name and whoever bumps updates them. A script that rewrote the manifests along with the version would have hidden the one moment where a human should look at what a module claims about its environment — and `bump-version.sh` would then also owe each module a version bump of its own, since `check-analysis-versions.sh` watches those directories.

`frame` is a minimum in both cases: `00_static` only asserts it is not newer than `analysis/frame.version`. Frames bump on most days and a module's floor should not follow.

## The conda half: one reader, and where the guarantee actually lives

### `--freeze-installed` does less than the plan assumed, and the release gate is what found out

The plan called it "precisely 'these packages install or the install fails, and nothing else moves'". **It is not.** `--freeze-installed` refuses to change a package the *solve reaches on its own*; a package **named on the command line** conda installs at the version asked for, downgrading what is there.

Measured, on the first run of `dev/scripts/check-module-packages.sh`: a fixture pinning `r-glue=1.8.0` against a baseline holding `r-glue=1.8.1` **downgraded it and reported the solve as a success**. That is exactly the failure the design exists to prevent — a module quietly moving a version every other module, and the release itself, computes against.

So `conda_install_packages` reads what the environment holds and refuses a disagreeing pin before conda is asked. The same pin at the same version is not a disagreement: two modules needing one package at one version is the reason the environment is shared at all.

**This is the case for the release gate existing.** No amount of reading conda's documentation produced it; a stub could never produce it; and every launcher case passed with the hole wide open, because they assert on command lines and the command line was correct. The gate ran once and found it.

It also caught its own fixtures: `r-glue` was in the baseline, which made four of its checks meaningless — the install was a version change rather than an addition. It now asserts its fixtures are absent from the baseline before using them.

**`conda remove` cascades, and the direction matters.** Measured against the real environment: `conda remove -n <env> --dry-run --json r-pheatmap` names only `r-pheatmap`, so conda takes **dependents** and not orphaned dependencies. Every name a plan adds beyond the ones asked for is therefore something that depends on one of them and belongs to a module still installed — which is why the rule is "refuse on any collateral at all" rather than a subtraction. `--force-remove` is the wrong tool: it would leave a broken environment.

**Atomicity is ordering, not rollback.** `install_module` is download → checksum → unpack → validate files → parse and validate the specs → move into the store → conda install; a failed solve rolls back with `rm -rf "$dest"`, a local directory delete. A rollback `conda remove` would be a second mutation that can itself fail, and conda's own transaction is already atomic.

### The manifest is read twice, and that is a cost paid deliberately

The wrapper is shell reached without a JVM; `readManifest()` is Groovy reached without a shell. Neither can call the other, so `packages` has two readers and the pin rule has two regexes. The alternative was asking Nextflow for the list, which costs a ~22 s JVM start per install and does not work in `deploy_payload` at all — that runs while the analysis environment may not exist.

What keeps them honest is `00_static`: it extracts both patterns from their own files and runs a shared table of seven specs past the shell one. Both patterns must be present and identical, so a change to one that is not made to the other fails by name.

`module_packages` in `lib/wrapper_lib.sh` is the **one** shell reader — `install_module`, `uninstall_module`, `deploy_payload`, `analysis install` and `export-environment.sh` all go through it. `export-environment.sh` sources `wrapper_lib.sh` rather than carrying its own copy, which is also how it reaches the installed store through `install_prefix`.

### `uninstall` degrades where `install` refuses

The plan said both should require the analysis environment. Building it showed that is wrong for `uninstall`: `analysis uninstall` removes the environment and keeps the store, so requiring it to remove a module leaves the user with a store they cannot tidy and no way out but reinstalling the environment. So `install` requires it — a module installed without its packages is broken — and `uninstall` removes the directory either way, saying the packages stayed because there is nothing to take them out of. `analysis install` then reconciles.

### What the stub can and cannot prove

`test/lib/sandbox.sh`'s fake conda logs every invocation, so `02_launcher` proves **which command lines are issued and in what order**: that an unpinned spec is refused before conda is reached, that a module declaring nothing issues no install at all, that a removal reads its plan first, that the store's packages come out before the payload wipe. It cannot prove a solve succeeds — a stub always says yes.

The stub gained a removal-plan answer for this, shaped like real conda's: one key per line, with a `dist_name` beside each `name` so the reader is shown not to pick that up instead. Writing it inline on one line was the first attempt and the sed missed it, which is the useful half of the story — the stub has to imitate the format, not just the content.

`dev/scripts/check-module-packages.sh` is the other half, by hand before a release, against real conda. Z, 2026-09-03: *"there is no real union, we test it here."* Its fixtures are pins rather than module directories: the store side is what `02_launcher` covers, and what this asks is a solver question. F1, F2 and F3 declare no packages — `cmdscale`, `p.adjust`, `pt` and `eigen` are base R — so without fixtures the script would pass by having done nothing.

### The sharpest trap, and it is a dev script

`dev/scripts/export-environment.sh` regenerates `install/environment-analysis.yml` from a live environment. Run after a module install, it would fold that module's packages into the baseline **permanently and invisibly**: nothing would declare them, nothing could remove them, and every project would install them. It now refuses, naming the specs it found and which module declares each.

It looks only for a module's **own** specs. What conda pulled in beneath them is not distinguishable here from what the baseline needed anyway — which is exactly why the answer is to rebuild the environment rather than to subtract from it.

## What the fixtures do about it

`test/lib/analysis.sh` gained `ANALYSIS_MANIFEST_FLOORS` — `"license": "Apache-2.0", "frame": "20260101.001", "environment": "0.0.0"` — interpolated into every fixture manifest. Those are the lowest values either field can express, so no fixture moves when the frame or the release does. `test_a_manifest_missing_a_field_refuses` deliberately does not use it and still asserts on `contract`, which is checked first.

One case installs two bad modules in sequence and has to delete the first before the second: `readManifest()` runs over the whole store, so the second run would refuse on the first module again and the assertion would pass while testing nothing.
