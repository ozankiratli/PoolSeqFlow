# `bin/config_migrate.sh` — the 2.2.0 → 3.0.0 pass

**Written 2026-08-31, against the tree at `7d65893`.** The pass it describes is done and the five DROPPED keys are still five. The template has grown since — 97 live assignments then, 101 now — so the diff figures below are a snapshot of 2026-08-30 rather than a current count.

Done 2026-08-30, the last pipeline-side work before the analysis layer. `change-guards.md` covers what stops a project changing configuration mid-analysis; this covers carrying a configuration *forward* across a release.

It covers `parameters.config` alone. The analysis layer's `analysis.config` is new in 3.0, so a 2.2.0 project has nothing to carry forward into it and `config_migrate.sh` does not touch it.

## How the diff was derived, so it can be redone

Not by reading the templates side by side. Both were reduced to fully-qualified `key<TAB>value` with the same scope logic `config_migrate.sh` itself uses, then `join`ed and `comm`ed:

```sh
git show v2.2.0:parameters.config.template > /tmp/t220.config
# awk that tracks `name {` / `}` depth and emits scope.scope.key<TAB>value
```

**90 keys → 97. 27 gone, 34 new.** Doing it by eye would have missed the two that mattered, because neither shows up as a changed value.

## What the diff said

**Every parameter whose default differs is a `${...}` expression** — the whole `dir.*` tree, `gffPath`, `reference`, `referencePath`, and `mainDir`'s placeholder. Those already take the COMPUTED branch, where the template wins and the user is told. That is most of the diff and it needed nothing.

**One genuine `reformatted()` case: `variantCall.maxDepth`.** 2.2.0 shipped `bcftools.maxDepth = 2000`; the prefix rename would carry it into 3.0, where the knob means something else. Details below.

**One misnamed parameter, left alone: `varQualMin`.** Details below.

## `variantCall.maxDepth` — the value is not the change

In 2.2.0 this was the only depth control in the pipeline: one number, every pileup. From 3.0, step 5 measures a ceiling per sample from its own depth histogram and step 6 applies it to the BAM *before* calling, so `variantCall.maxDepth` is a second ceiling over that one and ships as `0` — which `mpileup` reads as **no limit at all**, measured.

Carrying `2000` forward therefore leaves a project capped at a number the release never chose, on top of a per-sample cap that cannot see it. The prefix rename would have done exactly that silently, which is what `reformatted()` exists to stop.

The report entry alone was not enough — the mechanism moved, not the value — so the epilogue explains it and gives the exact way back: `variantCall.maxDepth = 2000` with `capBAM.maxDepth = 0`. Someone reproducing old numbers needs that, and no report line fits it.

## `varQualMin` is misnamed, and stays that way — REVERTED 2026-08-30

`bcftools mpileup -q` is the **mapping** quality minimum and `-Q` is base quality. 2.2.0 fixed half of this: the CHANGELOG records `baseQualMin` and `varQualMin` being "the wrong way round", after which `baseQualMin` correctly fed `-Q`. But `varQualMin` was left feeding `-q`, so it sets mapping quality under a name that says variant quality — and there is no variant-quality option in `mpileup` at all. The manual documents it truthfully as mapping quality; only the name lies.

It was renamed to `mapQualMin` and **Z reversed that within the hour**: *"Don't the variable name change. I worry that there will be something will be there in the documents stray."*

Worth recording, because the reasoning generalises past this parameter. A rename of a shipped parameter touches the template, `resolve_parameters.nf`, the manual in several unrelated sections, the migration table, and the tests — and the manual is 3000 lines. The cost is not the edit, it is the confidence that nothing was missed, and it buys only a better name for something already documented correctly. **On the eve of freezing the pipeline that trade is wrong**, whatever it would be worth at the start of a release cycle.

The revert also took out machinery: `renamed()` had grown to return a space-separated candidate list, because `mapQualMin` was the first parameter renamed twice and needed both `variantCall.varQualMin` and `bcftools.varQualMin`. With no double rename left, that generality is unused and speculative, so the single-name lookup came back with it. Four lines to add again when a real double rename arrives.

**If it is ever revisited**, the options are: rename to `mapQualMin` (behavior-neutral, the flags already match the manual); or swap the flags so the names become true, which **changes results** for anyone who tuned the two apart. Only the first is safe.

## The KNOB category — 13 of 27 "losses" were not losses

A 2.2.0 config has `cores.*` (eight) and five option strings (`bwa.options`, `fastqc.options`, `trim_galore.options`, `trim_galore.adapterOptions`, `bcftools.mpileupOptions`) as **live assignments**. In 3.0 all thirteen are computed and ship **commented out** in the template — still there, still settable.

Reported as DROPPED they read as gone for good, and the worst thing a migration report can do is send someone looking for a setting that is sitting in their new config. Pass 2 now records commented-out assignments as knobs, and `forward()` maps an old key onto the current scope names (`bcftools.` → `variantCall.`) so `bcftools.mpileupOptions` finds `variantCall.mpileupOptions`.

`DROPPED` is now five: `dir.scripts`, `gff`, `dir.output.temp`, `rgTagsFile`, `rgTagsPath` — all genuinely gone.

## RGTags.csv → metadata.csv stays a DROP, with a message

Tempting to add `metadataFile` ← `rgTagsFile` to `renamed()`. **Do not.** The formats are incompatible, so carrying the filename would point `metadataFile` at a file that cannot parse, and `reformatted()` on top would report it as handled when the user has real work to do.

The script already reads `rgTagsFile` from the *backup* to emit a `mv` for the file itself. So the parameter drops, the file is moved, and the epilogue explains that metadata.csv is not a rename: it decides which rows merge into one pool and can set pool size and sensitivity per sample. Verified before writing it that step 0 fails with `METADATA FILE CHECK: FAIL` when the file is absent (`0_verify_environment.nf`), so the note can say so.

## Traps

**No apostrophes in the awk program.** It is single-quoted inside the shell script, and one `'` in a comment ends it — `bash -n` then fails somewhere else entirely. Cost a debugging round here on the word `key's`, and it is already recorded as a project-wide trap.

**`migrated_value` in the test suite takes the FIRST match.** `maxDepth` is defined in `capBAM` *and* `variantCall`, and `capBAM` comes first in the template. An existing case asserted `bcftools.maxDepth should land in variantCall.maxDepth` while actually reading `capBAM`'s — its `sed` set both to the same number, so it passed either way. `migrated_value_in <scope> <key>` now exists and that case was moved onto `baseQualMin`.
