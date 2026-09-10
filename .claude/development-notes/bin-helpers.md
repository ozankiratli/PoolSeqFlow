# The `bin/` helpers

**Written 2026-08-31, against the tree at `7d65893`.** The helpers themselves are unchanged; the citation chain below gained a BibTeX front end since, and the analysis layer a citations file of its own.

Small programs the pipeline shells out to. Several exist because logic in a Nextflow process costs a JVM start to test, while a script in here is unit-testable in milliseconds — that cost model is the single biggest influence on what lives here.

Not all of `bin/` is covered here. `cap_depth.awk` and `depth_cutoff.py` are in `depth-cutoff.md`, and `config_migrate.sh` in `config-migration.md`. **`MajorAlleleToRef.py` has no note anywhere**, which is a gap worth closing: it re-polarizes every site on cohort totals, which is why a distance or a frequency from a six-pool run is not the same quantity as one from a twelve-pool run.

## `atomic_mv.sh` — why staging exists

The work directory and `storageDir` are normally on **different filesystems**, so `mv` is a copy followed by an unlink rather than a `rename()`. A job killed mid-copy leaves a truncated file at the destination — and the pipeline's skip logic only asks whether a file **exists**, so the next run treats that fragment as a completed step.

Staging through a `.part` suffix avoids it: the cross-filesystem copy lands on a name the skip logic cannot match, and the final step is a rename *within* the destination filesystem, which is atomic. Either the artifact is complete and correctly named, or it is not there at all.

**The trailing slash is the caller's intent, never inferred from `[ -d "$DEST" ]`.** Inference cannot tell "put it in this directory" apart from "a directory is sitting on the artifact's name" — and the second is a collision that has to fail. Obeying it silently would bury the artifact one level down under a name the skip logic still matches, so the step would look complete on every later run.

**It has no lock.** That is safe only because the variant analysis fixes the shape up front: one task per (variant, stage, key), so nothing races for a path. Never make sharing depend on a check-then-act existence test. Two concurrent callers would stage through the same `${DEST}.part`, and one's EXIT trap would delete the other's staged copy between its two `mv` calls.

## `find_artifact.sh` — why it exists

Artifacts **move during a run**: a step writes its output to the working volume, and it is promoted to permanent storage once the step consuming it has succeeded. A skip check therefore cannot ask a single directory whether its work is done — the honest question is "is it in permanent storage, or still waiting to be promoted, or neither".

Roots are given permanent-first. If an artifact exists in both, the promoted copy is the finished one and the other is residue from a move that did not complete. That is **reported** rather than passed over, because a stale copy silently winning would go on winning for every later run.

**Both roots take the same relative path**, which is the whole reason the working tree mirrors the output tree exactly instead of inventing its own layout — it makes the lookup one path against N roots rather than a translation between two schemes.

Exit codes are three-way on purpose: 0 found, 1 absent *silently* (the ordinary answer on a first run), 2 usage mistake. A caller has to be able to tell "absent" from "you called me wrong".

## `classify_manifest.sh` — why CHANGED, ADDED and REMOVED are distinguished

A **CHANGED** value means the user altered a setting and the outputs on disk were produced with the old one. **ADDED** and **REMOVED** mean the set of parameters itself moved, which is what a release does — the outputs predate the parameter existing, so there is no earlier value to conflict with.

A plain `diff` shows both as a pair of `+`/`-` lines, which is why every release that introduced a parameter used to fail every existing project and tell it to delete its results.

**Since the version block landed, that distinction no longer changes any verdict** — a release change is refused outright before this runs, so every kind of difference fails. It still decides how the difference *reads*.

Writing this as a unit-testable script rather than inline in the process **found a real bug**: the inline version silently skipped lines without `=`, which hides a key and can make a real change look like none. Its edge cases — a value containing `=`, an empty value, no trailing newline, an unparseable line — are milliseconds in the helpers suite and a JVM start each end to end.

## `parse_multirun.py` and `parse_metadata.py` — why Python

The values in both files are **free text**. `readPattern` defaults to `*_R{1,2}.fq.gz`, which contains a comma; a description field reading `Pop1, replicate 2` is ordinary. Splitting on commas would cut either in half and report a row with the wrong field count — a mistake that looks like a completely different mistake. `csv` implements the real quoting rules.

Both **report every problem at once, with line numbers**: a hand-written table with four mistakes should take one fix-and-rerun cycle, not four.

Both exit **2 for a usage mistake and 1 for a bad file**, so a caller can tell "your file is wrong" from "you called me wrong".

**A blank cell means opposite things in the two files**, which is why they do not share a parser: in the multi-run table it means *inherit*; in the metadata file it means *no value*. That is also why `parse_metadata.py` keeps every column in its output, blanks included, and lets each consumer decide what an empty string means to it.

## An apostrophe in a comment can break the script

`filterFalsePositives.sh` embeds its awk program in a **single-quoted** shell string. Any apostrophe inside it — including one in an awk `#` comment — closes that string and the file stops parsing as shell. Writing *"the VCF's own header"* in a comment there broke it during the 2026-08-30 pass; the existing text at the `-p` error message uses the `'"'"'` dance for exactly this reason.

Never rely on spotting it. `bash -n` catches it instantly, which is why every comment pass ends with a syntax check over all of `bin/`, `install/`, `dev/scripts/` and the wrapper.

## `filterFalsePositives.sh`

See `false-positive-filter.md`.

## `depth2freq.awk` and `createDepthFile.sh`

The existing awk-over-`bcftools query` idiom: bcftools does the VCF surgery, awk touches only numbers. Worth knowing when adding anything numeric to steps 6–7 — it is the pattern the rest of the pipeline already uses.

## Citations, and the two traps in writing them

`install/citations.json` → `bin/write_citations.py` → `CITATIONS.md` + `references.bib`, beside the results. Run by `scripts/citations.nf` once per invocation.

**The chain gained a front end since, and the authored file moved.** `install/references.bib` is what you edit now — its own header says so — and `dev/scripts/bib2citations.py` compiles it into `install/citations.json`, which `00_static` fails on when the two disagree. Editing the JSON is overwritten and caught rather than silently kept. Beware that **`references.bib` names two different files**: the authored input under `install/`, and the per-run output written beside a user's results. An analysis run merges three sources — `install/citations.json` for PoolSeqFlow and Nextflow, `analysis/citations.json` for the layer itself, and the module's own.

**Versions are probed at run time, not read from `environment.yml`.** `params.software` can point a tool at a system installation, and then the pinned version is not what ran. `lib/tool_version.sh` is shared with `install/check_install.sh` so the version a run reports and the version its citations claim cannot disagree.

**`| tee` swallows the exit status.** `python3 … | tee citations.txt` made the task's status tee's, so a Python traceback produced an empty file and a green run — COMPLETED in the trace, the failure only in the log. Write then `cat`. Mutation-tested by pointing `--data` at a nonexistent file.

**A shared `key` deduplicates the bibliography**; `tools: {key: "Display Name"}` lets one entry cover several tools, because SAMtools and BCFtools are one paper (Z's call). Versions are keyed by the DATA key — a display name does not map back to it, which silently lost the versions for `Trim Galore` and `snpEff` until it was fixed.

**Only what the run invoked is listed.** `when: "annotate"` gates SnpEff; citing it on a run that did not annotate would claim a step that did not happen. This is the rule the analysis layer's conditional tools will follow.

**The node is built from `params`, not from a run.** The file describes the *invocation* and belongs at the base `Output/` root, which a run that set its own `storageDir` would not name. `annotate` is the one exception — it is per run, and a tool that any run invoked was invoked. `collect()` over the frequency tables makes one emission however many runs there are, so this is always one task.

**`citations.json` is resolved to an absolute path in the workflow body**, not named inside the process: `projectDir` in a process script is discouraged, and the reference data is part of the installation rather than an input.

**The references have not been verified by Z.** Written from knowledge; the DOIs and page ranges need checking against the papers before 3.0 ships. This covers the *software* citations here. A module's *method* citations are a separate set, live in the module's own `references.bib`, and were verified during F1 — which is where the `n_eff` attribution was found wrong twice before it was right.
