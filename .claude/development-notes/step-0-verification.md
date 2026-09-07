# Step 0 — verification

**Written 2026-08-31, against the tree at `7d65893`.** The machinery is unchanged: the keyed checks, the logging rule, `VerifyAll`'s single joined tuple and the three broadcast stages beside it are all still as described. `analysisParams()`'s exclusion list has grown, and the one addition that needed a reason is noted below.

`scripts/0_verify_environment.nf`. Everything the pipeline checks before it spends compute, and the machinery that decides how many times each check runs.

> **For the manual, not here.** The stage list and what each stage reports is user-facing — a person reading `0_verify_environment.txt` needs it. So is the rule that **every step is gated on step 0**: nothing computes while a check is failing.

## A check runs once per distinct value of what it reads

Step 0 used to run every stage once per run, so three runs against one reference produced three `CheckReference` tasks and three identical reports for one file.

Z, 2026-08-27: *"the pipeline first needs to parse out the multi-run csv, and decide on the shape of the pipeline. Then the checks should represent each step that is needed by the pipeline. Otherwise we are creating redundant and confusing log files for people to review and it will be harder to fix."*

So `checkParameterMap()` names what each check actually reads, a check runs once per distinct key, and its verdict is handed back to every run that shares that value.

**It carries the same risk as `stepParameterMap()`, and worse.** Name too few parameters and one run's verdict is used for a run whose value differs — which is more serious here than there, because catching exactly that is what the check is for. A static case re-extracts each process body and fails if it reads anything its entry does not declare.

The names are dotted paths into a **run's own** parameters, read with `dig()`. Never `params`, which is the base configuration rather than what any particular run is using.

Entries worth their reasoning:

- **`CheckReference` and `CheckGFF` are one check per file**, deliberately not step 1's dictionary key, which is a (reference, GFF) *pair*. What this stage asks is whether one file is on disk.
- **`SkipGFFCheck` reads nothing** — its report is two fixed lines — so one task serves every run that does not annotate. The empty list is a statement, not an omission.
- **`CheckData` names `dataSource` as well as `dir.data`**, because the report prints it, and a name that reaches the report is a name that decides the report.
- **`CheckDirectories` names only two of the four roots.** The installation and the launch directory are properties of the invocation and cannot differ between runs.

The **storage root is part of every check key**, for the same reason it is part of `variantKey()`: a check writes a log, and two runs whose `storageDir` differ have no directory in common to put it in. Prefixing makes them never group, rather than needing a refusal.

## Where a step-0 stage logs

Not in a run's own Logs tree. A check keyed to what it validates can answer for two runs out of three, which belongs to neither of their trees — and step 0 runs before any run has results for a log to sit beside. So every stage logs at invocation level. `All_Runs` means "the invocation" in this one place rather than "shared by every run"; the file name says which runs each task answered for. `VerifyAll` is the exception and stays in the run's own tree, because it really is per run.

**One directory per workflow** (Z, 2026-08-28), not one per process. Every log file already carries the step, the stage and the runs it answered for, so a per-process directory repeated what the name said at the cost of a level of nesting in a tree the user is expected to read.

**One writer per file.** Tasks append without locking, which is safe only while no two share a file — and a keyed check runs N times into one directory. Naming the file after the runs it answered for makes collision impossible. The old RGTags repair stage had this wrong since E1t: two runs naming two different tables gave two tasks appending to one file.

## Assembling the report

`reportPerRun()` uses `combine(by: 0)` on the key rather than a join. What is matched is the same string computed by one function on both sides, and every run reaches exactly one task of every check that applies to it. A join would drop an unmatched key silently.

**`VerifyAll` takes ONE tuple, joined on the run.** These used to be nine separate `val` inputs, which Nextflow matches **positionally** — item k of each channel paired with item k of the others. Safe while every stage emitted exactly one report; a silent mismatch the moment there are N, with nothing making run B's reference check line up with run B's trim check. The report would have described a run that never existed.

The three invocation-level stages — `CheckInstalledSoftware`, `CheckRunParameters` and, since E1u, `CheckMultiRun` — stay separate on purpose: they ride **value channels**, which broadcast to every task, which is what is wanted for a check that ran once for the whole invocation.

## `analysisParams()` — what invalidates a result

An **exclusion list on purpose**: a parameter added in a later release is treated as analysis-affecting until someone decides otherwise, which fails safe.

It takes the run's own effective parameters rather than the global `params`. Called once per run against `params`, it would write N identical manifests describing the base config — so every run would record settings it did not use, and the guard would never fire.

Exclusions with a reason:

- **`dataSource` is deliberately NOT excluded.** It names the subdirectory the reads come from, so two datasets under one `storageDir` are two different analyses. While it *was* excluded, both passed the check and the second run reused the first dataset's trimmed reads, because step 2 keys its skip test on the sample id alone. Nothing recorded which data produced a set of outputs.
- **`runId`** names where results go, not what they are. It is also the one key that does not exist in parameters.config at all, so leaving it in would add a line to every manifest and fail the change check on every project upgrading into 3.0.
- **`dryRun`/`dryRunDir`** describe the invocation, not the project. Leaving them in would make every dry run report the parameters as changed — the one thing a preview must not do.
- **`metadata`** is the parsed file carried in every run map. The metadata guard compares its own projection; flattening it here would put the whole file in the manifest, so adding a design column would fail the *parameter* check.

**The list has grown since, and almost all of it needs no reasoning.** What was added is the paths and resources Z ruled out from the start — `mainDir`, `storageDir`, `threads`, `memory`, the resolved `*Path` and `reference`/`gff`/`reads` names, and the `dir.`, `cores.`, `java.` and `software.` prefixes — none of which can change a number. One addition is a genuine setting and carries its reason in the source: **`capBAM.histogramMax`** bounds how deep step 5 *looks* while measuring a sample's depth, not what it decides, so moving it cannot move a cap and cannot invalidate a result.

**The stored copies are refreshed only on a clean pass.** `.poolseqflow_params`, `.parameters.config` and `.multirun.csv` are rewritten under `[ "$STATUS" = "PASS" ]` and nowhere else. Refreshing them on a failure would overwrite the baseline with the very values that failed against it, and the run after that would compare current against current and pass — the guard fires exactly once and then never again. The same applies to `record_baseline()` in the metadata check, which is why that function is the only writer of `.poolseqflow_metadata`.

## Traps encoded here

- **`findNameExpr()` cannot use a bracket class.** `{1,2}` → `[1,2]` happens to work only because each alternative is one character. `{R1,R2}` → `[R1,R2]` is a class matching a single character out of `R`, `1`, `,` or `2`, so it matches no real FASTQ — the check finds nothing and **passes vacuously** while the run has no data. Expanding the group into one `-name` per alternative is exact for any length.
- **The sample-ID split takes its mate token from `readPattern`**, never assuming `_R1`/`_R2`. Step 2 keys every sample off `Channel.fromFilePairs`, which derives the prefix from the glob and accepts any `{1,2}` scheme, so this check has to agree with it or it rejects valid layouts.
- **The mate token must be separated from the sample name.** Without a separator the split is guesswork: `Sample11`/`Sample12` read equally as one sample's two mates or as two samples.
- **`CheckInstalledSoftware` is handed the union of every run's software settings**, not `params.software`. A table may name a different binary for one run, and a check reading only the base config would pass while that run's tool was missing.
- **`drop_size()` is awk and must stay awk.** It strips one tab-separated field from a guard line, which sed would do in one expression — except that `\t` in a sed *pattern* is a GNU extension. BSD sed reads it as a literal `t`, so the expression silently matches nothing and every project on macOS reports its pool sizes as changed on the first run after an edit elsewhere.
- **`any_exists()` tests one candidate at a time on purpose.** The obvious `ls a b >/dev/null` is wrong in the same direction as the sed trap: `ls` exits non-zero when *either* operand is missing, so a project that has BAMs but no VCF would be read as having neither, and the guard would re-record the baseline instead of comparing against it.

## Stage 9, the multi-run table

Parsing and syntax live in `bin/parse_multirun.py`, for a correctness reason first: the values are parameter values, and `readPattern` — exactly the sort of thing people vary — defaults to `*_R{1,2}.fq.gz`, which contains a comma. Splitting on commas would cut it in half and report a row with the wrong field count, as a completely different mistake. Second reason: a script is unit-testable in milliseconds, while a check written here costs a JVM start.

**From E1u this is not the first gate.** The runs have to exist before the DAG can be built, so `resolve_parameters.nf` validates the table earlier still and an unusable one stops the invocation before any task is submitted — including this one. What is left here is the part worth having in the durable record: what the table expanded to, and what it detached from its derivation. The FAIL branches are a backstop, and because the stage can be run on its own.
