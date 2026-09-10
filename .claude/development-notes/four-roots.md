# The four roots

**Written 2026-08-31, against the tree at `7d65893`.** The module store and its subcommands landed later the same day and widened the `analysis` contract recorded below. The four roots themselves are unchanged.

A run stands in four directories, and confusing any two of them is a real failure mode. Checked by `CheckDirectories` in step 0, and assumed by the wrapper, the config template and every promotion.

> **Two manual defects this note raised, both since fixed** (verified 2026-08-31). The manual described `mainDir` as node scratch, and nowhere said the two storage roots must be different paths. Both are corrected: it now refuses the two roots being one path, in four places matching `CheckDirectories`, and says explicitly that `mainDir` has to survive between runs. All four roots and the difference between them is the first thing a user needs, and the manual covers it.

| Root | What it is |
|---|---|
| the installation | holds the code. One copy serves any number of projects. |
| the launch directory | where you ran the command, and where `parameters.config` was read from. |
| `mainDir` | the fast working volume. |
| `storageDir` | permanent storage. |

## The correction that started the campaign

`mainDir` is a **per-project working directory, not the checkout**. `dir.scripts` and `dir.bin` encoded the wrong model from the first working version in March 2026: they pointed at the source tree, which conflated "where the code is" with "where this project's work happens". Everything in the four-roots block (E1j–E1n) follows from unpicking that. Of the two names, only `dir.bin` still exists — `dir.scripts` is gone, so grepping for it finds nothing.

## Why the rules are what they are

**`mainDir` and `storageDir` are two tiers, not two names for one place.** Outputs are written to the working volume and promoted to permanent storage once whatever consumes them has succeeded. Pointing both at one directory makes every promotion a no-op that moves a file onto itself, and makes `clean` and `reset` — which treat the two roots differently — impossible to reason about. So they must differ.

**Neither storage root may BE the installation.** The installation is a tool: one copy serves any number of projects, it is replaced wholesale on upgrade, and from 3.0 it may be read-only and shared. A project working directory kept inside it would be destroyed by an upgrade and would make two projects impossible; permanent storage kept inside it would take the results and their provenance with it.

**Compared as resolved paths.** A string comparison passes happily on `/data/x` versus `/data/x/`, versus `/data/y/../x`, versus a symlink to the same directory — each of those is the same directory with a different spelling.

**Containment is warned about, not rejected** (Z). One root inside another is harmless in itself — the managed subdirectories still do not collide — but the lifetimes differ sharply enough to be worth saying out loud. The check that actually matters for collisions is that no two computed directories in the `dir` block resolve alike, and that belongs where the block is built.

**`mainDir` must be durable.** It holds the configs, `Data/` and `Reference/` — the only irreplaceable things in a project. The pre-3.0 documentation describing it as node scratch is wrong from 3.0 on.

## The tiering problem this solved

On a cluster with node SSDs and a SATA archive, the pipeline never used the fast disk: every `dir.*` resolved to `storageDir`, so `mainDir` held only `work/`, which holds symlinks. Z raised it alongside "run the same reads against several references", and the two turned out to share one root cause — which is how storage tiering and multi-run became one block of work.

## The one contract amendment that held, and the one that did not

Z, 2026-08-24 wanted both avoided, to keep the wrapper at exactly one subcommand:

- **The install prefix is an environment variable** (`POOLSEQFLOW_PREFIX`), not a flag. **This held.**
- The analysis layer was given a wrapper of its own rather than a flag-taking subcommand. **REVERSED, 2026-08-31.** Z merged it back into `./PoolSeqFlow`, and the contract IS amended: every subcommand takes no arguments except `analysis`, which takes exactly one. The separate executable is deleted. (It shipped briefly as `PoolSeqFlow-analysis`; the `PoolSeqFlow-analyze` spelling this note used never existed at all.) See `analysis-wrapper.md`.

**And it widened again the same evening.** The module store arrived in `d9886c5`, so `analysis` no longer takes exactly one word: a module run is `analysis <module> [nocpp]` and the store is `analysis modules install <name> [<version>]`. The amendment that survives is the *shape* — the top-level subcommands still take nothing, and everything variable hangs off `analysis`. `usage_analysis` in the wrapper is the current statement of it.

## The wrapper's install prefix, and why it is an environment variable

`POOLSEQFLOW_PREFIX` chooses where `install` puts things; `~/.local` by default, because it needs no privileges and is already on PATH for many users.

**An environment variable rather than a `--prefix` flag.** The wrapper takes exactly one subcommand and rejects everything else, and that contract was worth keeping. `make install PREFIX=...` has the same shape.

**When neither is given, an installed wrapper works it out from its own stamp.** A payload always sits at `<prefix>/opt/PoolSeqFlow-<version>`, so two components back is the prefix. That is what makes `list` and `uninstall` correct without the user having to remember which prefix they installed into — otherwise both would look under `~/.local`, find nothing, and report that nothing is installed while several copies sat elsewhere. A wrapper run from a clone has no stamp and falls back to the default, which is the case where a prefix is being chosen rather than recalled.

**`PAYLOAD_ITEMS` must match what `git archive` produces**, which `.gitattributes` defines by exclusion — so installing from a clone and from a download deploy identical trees. A static case checks the two agree, so a file added to the release without being added here fails a test rather than going missing from every install.

**`POOLSEQFLOW_HOME`** overrides the pipeline a wrapper uses, for running a checkout without installing it. It wins over the deployed stamp, so a developer can point an installed wrapper at a working copy.

**The conda environment is named after the release** (`PoolSeqFlow-<version>`) and the pipeline is installed under the same name, so each version runs against its own pinned tool set and an old result stays reproducible. `conda env create -n` overrides the `name:` key in `environment.yml`; without it every release lands in one environment again, which is the bug the versioned name exists to end.
