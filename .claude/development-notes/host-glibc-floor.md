# The glibc floor — a shipped environment that only installed on the machine that froze it

**Written 2026-09-21, against the tree at `d4c4028`.** Reported by Z from a cluster: `PoolSeqFlow analysis install` failed with `nothing provides __glibc >=2.39 needed by sysroot_linux-64-2.39-hc4b9eeb_6`. v3.1.1's analysis layer could not be installed on any host below glibc 2.39, which is most HPC, and every gate in the project passed.

## What it was

`install/environment-analysis.yml` pinned `sysroot_linux-64=2.39=hc4b9eeb_6`. That package declares `__glibc >=2.39` — a dependency on a **virtual package**, conda's name for a property of the machine rather than of anything installable. So the file described a requirement on the host, and the requirement was whatever the host that produced the file happened to have.

The maintainer's machine reports `__glibc=2.44`. It solved there, every release, invisibly.

**Only the analysis environment had the 2.39 problem**, and the reason is a design decision rather than an accident: every module offers a compiled hot path and builds it on the user's machine rather than shipping a binary, so the environment carries a compiler, and a compiler is built against a particular glibc's headers. The pipeline environment holds finished programs and no sysroot at all.

**But the pipeline environment was never floor-free either**, which is what the first draft of this note and of the manual both said. `rsync` is in both files and requires `__glibc >=2.28`. So before the fix the pipeline environment needed 2.28 and the analysis environment needed 2.39, and afterwards both need 2.28.

**Z's observation is what settled the causality**, 2026-09-21: *"I could install PoolSeqFlow but not analysis to the cluster."* That brackets the machine. `rsync` is in both environments, so if it had been the obstacle the pipeline install would have failed too — it did not. The cluster therefore clears 2.28 and not 2.39, which is consistent with RHEL 9 at glibc 2.34. **The failure was `sysroot_linux-64=2.39` and nothing else**, exactly as the error said, and `rsync` is an unrelated lower bound that happened to surface later. Worth recording because the two were briefly conflated here: the package that sets the *declared floor* and the package that *broke the install* are different, and only the second one is the defect.

## Nothing asked for it

Measured before choosing a fix. `gcc_impl_linux-64`, `gxx_impl_linux-64` and `binutils_impl_linux-64` all depend on a **bare** `sysroot_linux-64` with no version constraint, and conda-forge publishes 2.12, 2.17, 2.28, 2.34 and 2.39. The solver was free to take the newest the host allowed and did; `conda update --all` in `prep-version.sh` would have done it again every release.

`libsanitizer=16.2.0` requires `__glibc >=2.17,<3.0.a0`, and measuring a surviving environment showed conda-forge's whole base stack — `libgcc`, `libstdcxx`, `python`, `openssl`, `numpy` and twenty others — sitting at exactly `>=2.17`. So 2.17 is not a conservative choice, it is where the ecosystem already is, and the sysroot was pinned there.

**The floor was set to 2.17 on that reasoning and it was wrong**, because the reasoning was about the toolchain and the floor is about the whole environment. See *What the release-time check found* below: the answer is 2.28, and it is forced rather than chosen.

## The fix is two packages and it was proved surgical before it was written

Rather than guessing build strings, the two host-dependent pins were relaxed in a scratch copy and `conda env create --dry-run --json` was left to choose. The solve returned **190 packages against the shipped file's 190**, with exactly two moved and nothing added or dropped:

| | was | now |
|---|---|---|
| `sysroot_linux-64` | `2.39=hc4b9eeb_6` | `2.17=h0157908_18` |
| `kernel-headers_linux-64` | `6.12.0=he073ed8_6` | `3.10.0=he073ed8_18` |

The build hash is worth noting: `conda search` listed 2.17 builds as `h4a8ded7_*`, and the solver picked `h0157908_18`. A hand-written pin taken from the search listing would have been wrong.

**A lower floor costs nothing and reaches more machines.** Code built against sysroot 2.17 runs on glibc 2.17 and everything after it, so raising the floor is the only direction that loses anything.

## What the release-time check found, on its first real run

`check-host-floor.sh` was written against a fixture environment and then run for the first time against a freshly installed `PoolSeqFlow-3.1.1-analysis`. It refused:

```text
  promised floor: __glibc >= 2.17
  read 190 package records
  actual floor:   __glibc >= 2.28

  REFUSED: this environment cannot be installed on a host below glibc 2.28,
  but the release promises 2.17. Imposed by:
      rsync  (__glibc >=2.28,<3.0.a0)
```

**This is the entire argument for the script existing, made on the day it was written.** `rsync` carries its constraint in conda metadata, not in its version, so no amount of reading `environment-analysis.yml` could see it — the static case had passed, correctly, over a file whose real floor was 2.28.

Measured across both environments: of 134 packages in the pipeline environment, 100 declare `__glibc >=2.17` and exactly one declares more; of 190 in the analysis environment, 121 and one. The one is `rsync`, in both. And every `rsync` build published on conda-forge — 3.4.3 and both 3.4.4 builds — requires 2.28, so there is no lower build to fall back to.

**So 2.28 is forced, not chosen.** Dropping to 2.17 would mean removing `rsync`, and `bin/atomic_mv.sh` stages every promoted artifact with it. Z's call, 2026-09-21: hold at 2.28. The cluster in use is RHEL 9 at glibc 2.34, and the machine below 2.28 is CentOS 7, end of life since June 2024.

**`rsync` decides the floor; `sysroot` broke the cluster.** Keeping those apart is the point — a floor is the highest bound anything imposes, and a defect is a bound that moved for no reason. Only the second one was a bug.

## Why four guards and not one

Z, 2026-09-21: *"Possibly both and more. Because when we prepare the release, we upgrade conda. It needs to change. We are pinning this library for now but more might come later."* The sysroot is one instance of a class — any package constraining a host virtual package freezes a property of the build machine into a file that ships everywhere — and the release cycle's update step keeps producing new instances.

One number, declared in `export-environment.sh` and written into both files' headers, read by four things:

1. **`export-environment.sh` refuses** to write a file that breaks it. Checked on the generated content, one line before the `mv`, so it answers about the file that is about to exist rather than about something adjacent to it.
2. **`00_static`** refuses to ship one. Cheap, textual, needs no network — this is the case that would have caught v3.1.1.
3. **`prep-version.sh`** writes `sysroot_linux-64 <=<floor>` into the scratch clone's `conda-meta/pinned` **before** `conda update --all`, so the solver never proposes the raise. Stated up front rather than corrected afterwards: a correction would be a second solve that can itself fail, and it would automate away a decision that belongs to a person. Only where the package is already present, so the pipeline environment cannot gain a sysroot from a pin written on its behalf.
4. **`check-host-floor.sh`**, at release time against a real installed environment.

### The fourth one exists because the second cannot be enough

`00_static` checks the one package whose **version is the glibc it targets** — `sysroot_linux-64=2.39` says `__glibc >=2.39` in its own name, so a text file is enough to see it. Every other package carries its constraint in conda metadata instead: `libsanitizer=16.2.0` requires `__glibc >=2.17` and nothing in the string `16.2.0` says so. A release that picks up such a package with a higher bound ships this defect again with the static check passing — which is [[gates-that-stopped-checking]] exactly, a gate still running and no longer aimed at the thing.

So the general answer needs the real constraints, and an installed environment has them: every package writes `$PREFIX/conda-meta/<dist>.json` carrying its own `depends`. Reading those is exact, offline and instant.

**Measured, and it is why the check needs an install rather than a solve:** `conda env create --dry-run --json` returns name, version, build string, channel and platform per package and **no `depends` key** — 0 of 190 records carried one. The solve says what would be installed, never what any of it requires.

## What this cost to find, and what would have found it sooner

Nothing in the repository stated a glibc minimum. The manual's Requirements table said "Linux or macOS", so a RHEL 8 user read that and reasonably expected it to work. It now names the floor, explains why only the analysis layer has one, and the Troubleshooting table carries the `__glibc` error text so the message a user actually lands on is searchable.

The release protocol froze the environment on one machine and never asked whether the result was installable anywhere else. Step 2 now installs and runs `check-host-floor.sh`, which is the first time the protocol asks a question about a machine other than the maintainer's.

**The pattern, stated so it is recognizable next time: a check that runs on the machine that produced the artifact can only ever confirm that machine.** The suite, the lint, the archive gate and the static cases were all green, and all of them were green about a file that worked here.
