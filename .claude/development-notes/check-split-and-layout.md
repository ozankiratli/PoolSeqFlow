# `check install` / `check project`, and the directory move

**Written 2026-09-10 against the working tree on top of `6d38c88`.** Z drove this one directly, in a series of short instructions; the reasoning below is what each of them settled.

## The shape problem Z named

`install/check_install.sh` had grown to check three things: the tools, the `bin/` helpers, and whether `parameters.config` parses — resolving the tool list out of `params.software` when a project was present and falling back to a canonical list when it was not. Taking `parameters.config` out of it (Z: *"We changed how install worked entirely. Checking parameters.config is just going to cause confusion"*) left a hardcoded `CANONICAL` list that duplicated the template's `software` block, and left nothing checking a project at all.

Z, on being shown that: ***"It is not the error I'm concerned about it is the shape. The tools were checked against the params.config."***

Moving `params.software` into `nextflow.config` was tried and **reverted** — Z: ***"Tools remain in params.config."*** The answer was two commands instead: ***"We need a separate check install and check project."***

## What each one is

| | |
|---|---|
| `check install` | the tools a release is built to run, **and that each comes from the release's own conda environment**; every helper in `bin/`. Reads no `parameters.config` and needs no project. |
| `check project` | `parameters.config` is current for this release and parses; `metadata.csv` and the run table parse, through the parsers step 0 uses; and every command **as `params.software` names it**. |

**A bare `check` is refused.** Z chose this over keeping it as an alias: whichever one it picked would leave the other unchecked while reporting success. `check` is the second subcommand after `analysis` to carry a word of its own, which the argument block at the top of the wrapper had to be taught — every other subcommand takes none, so `check install` was rejected before reaching its arm.

**`run_check()` is a function and not a nested `case`.** Two suite cases read the wrapper's own case arms and compare them against its usage line; a nested `install)` at the same indentation is read as a top-level subcommand. The top-level usage says `check <target>`, following the `analysis <command>` convention, because a nested `{install|project}` breaks a flat split on `|`.

## The environment check, which is the part that was silently wrong

`check_tool` asked `command -v` and accepted whatever `PATH` returned. **Every tool in `CANONICAL` is pinned in `install/environment.yml`** — verified, all fourteen including `gawk` and `python` — so one resolving from anywhere else means the environment is missing a package and the machine's own copy is standing in, at another version, on this machine only. The run works and reproduces nowhere.

It now compares each resolved path against `CONDA_PREFIX` and reports `OUTSIDE THE ENVIRONMENT` as a failure. When the environment is not active there is nothing to compare against, and the header says so rather than checking `PATH` and calling that an answer.

**`check project` deliberately does NOT apply that rule.** Repointing a tool at a system binary is a thing a project is allowed to do, and that check is where you see the result.

**A fixture that disabled the check under test.** The first version of these cases named the fake environment directory `env` while passing `ENV_NAME=check-install-env`; the script only compares paths when `basename $CONDA_PREFIX` matches `ENV_NAME`, so the comparison was off and both cases passed over nothing. The fixture directory is named for the environment now, and the passing case asserts the `from <prefix>` header line — which appears only when the script decided it knows which environment it is in, and is therefore what stops the case going vacuous again.

## The directory move

Z: ***"We also should move check_install, check_analysis_install and check_projects to bin"*** and ***"install only contains environment yml files. citations and bib file should move to another folder citations."***

```
bin/        every script that is RUN rather than sourced, the three checkers included
lib/        every file that is SOURCED
install/    the two pinned environment files, and nothing else
citations/  the pipeline's own references.bib and the citations.json generated from it
```

`analysis/` keeps its own `citations.json` and `references.bib`, and so does each module — **every separately publishable unit keeps its bib beside it**. The pipeline's pair had no home but `install/`, which is what `citations/` fixes.

Two things the move broke and how:

- **`check_install.sh` enumerates `bin/*` as pipeline helpers**, so it would have reported itself and its two siblings as helpers a run depends on. The three are skipped by name.
- **`07_analysis_frame`'s one-way-dependency case** greps `bin/` for any mention of the analysis layer, and `check_analysis_install.sh` is full of them. It is excluded **by name**, not by pattern, and a second case asserts exactly one file matches `bin/check_analysis*` — otherwise a rename or a second script widens the exclusion silently, since `--exclude` takes a glob and a name matching nothing is not an error.

`citations` was added to `PAYLOAD_ITEMS`, to the pipeline sandbox's copy list, and to `00_static`'s archive case — which now also asserts four **named files** and not only their directories, because a directory traveling empty satisfies every `assert_contains` on a path prefix.

## State when this was written

`--cost static` 272 passing, `--fast` 322 passing, `nextflow lint` 32 files clean, manual 41 pages / 361 anchors, language sweep clean, every analysis version current.

**`dev/scripts/verify-archive.sh` defaults to `HEAD`**, so it passed against the old layout and proves nothing about this one until the move is committed. Re-run it then.
