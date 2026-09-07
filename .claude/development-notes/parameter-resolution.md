# Parameter resolution

**Written 2026-08-31, against the tree at `7d65893`.** `resolve_parameters.nf` is unchanged — every function named below still exists and still does what is described. `diploidy` is `ploidy` since, corrected in place.

`scripts/resolve_parameters.nf` — what the pipeline computes when you have not set it yourself, and how one run's parameters are built from a multi-run row.

> **For the manual, not here.** The user-facing rule is worth stating plainly in the parameter reference: **a parameter you set is used exactly as written; one you leave commented out is computed; and a value you set feeds whatever is computed from it.** Pinning `cores.samtools` moves `cores.javaGc` with it, so pinning one thing never strands what depends on it. Also user-facing: any parameter may be varied per run, including the derived ones — but pinning a derived value costs the link back to what it was derived from, which step 0 reports.

## Why the computation moved out of parameters.config

**Config interpolation is eager and per-file.** A scope block assigns its own values and evaluates its own derivations in one pass, so an override aimed at something *inside* a scope arrives after the derivation has already been computed from the old value.

Measured against the real config, not assumed:

| Override | What actually happened |
|---|---|
| `bcftools.maxDepth` → 5000 | `bcftools.mpileupOptions` still emitted `-d 2000` (the scope is `variantCall` since `cc00833`; the behavior is unchanged) |
| `trim_galore.quality` → 15 | `trim_galore.options` still said `-q 25` |

No warning, exit 0 — the run reports the value you asked for and uses the old one.

Overriding a **top-level** parameter has no such problem: `poolSize` really does re-derive `filterFalsePositives.sensitivity`, and `threads` really does re-derive the cores ladder. That is why parameters whose only inputs are top-level — the reference paths, `sensitivity`, `snpEff.db` — are still computed in the config file, where they read better.

## Two Nextflow mechanics this depends on, both verified

- **Writing into an existing scope (`params.cores.trim = 4`) is visible everywhere**, because scope blocks are ordinary maps shared across modules. Creating a new **top-level** key from inside a module is **not** — it is visible only within that module, and processes see null. So every scope written here must already exist in the config file, which is why each carries its keys commented out rather than being absent.
- **Absence is the signal, not emptiness.** `containsKey` distinguishes "not set" from "deliberately set to nothing", and an empty string is a legitimate value — it is what `trim_galore.adapterOptions` holds whenever adapter autodetection is on.

`resolveParameters()` is called once, first thing in the entry workflow, so it runs before any process script is evaluated and before `analysisParams()` builds the change-guard manifest — which therefore records the values actually used, whether set or computed.

**The analysis layer imports that same `analysisParams()`** rather than defining its own projection: `analysis/modules.nf` calls it and subtracts the module's own prefixes. So the pipeline's change guard and a module's identity check are the same list of settings asked at two moments, and cannot disagree about what a run was configured with.

## The duplication with parameters.config

`deriveRunPaths()` is **a second copy of logic that also exists in parameters.config**, and there is no way around it: config interpolation runs once at parse time against one set of values, and a run changing `referenceFile` needs `referencePath`, `reference` and `snpEff.db` to move with it. The config's copy cannot be dropped either — `nextflow config -flat` is how the wrapper learns the paths that `clean` and `reset` delete, and it only ever sees the config.

The duplication is held together **by a test rather than by care**: for a single run the function must reproduce exactly what the config computed. Drift fails a test instead of silently sending one run's output somewhere else.

## Core counts

- `coreLadder()` is the largest power of two at or below `threads`, capped at 8, which is where the published scaling for these tools flattens out.
- `trimCores()` costs Trim Galore on its **full footprint**, not its worker count: `--cores N` runs N+4 threads (N workers + 2 decompressors + 1 batcher + 1 writer) for any N ≥ 2, while `--cores 1` bypasses the pool and is genuinely single-threaded. So it picks the largest N whose N+4 still fits.
- `samtools -@` counts **additional** threads, so 0 means one core and 1 means two. `-XX:ParallelGCThreads` is a total, not an increment.

## Traps encoded here

- **`fill()` takes a computed value, not a closure.** The strict parser rejects invoking a closure-typed parameter. Harmless because every expression is pure and the calls are ordered so anything one reads is already filled.
- **Plain recursive functions, not self-referencing closures.** `def walk; walk = { ... walk(...) }` fails with "`walk` is not defined".
- **`deepCopy` has to be deep.** Scope blocks are shared maps: a shallow copy would leave every run writing into one `cores` and one `trim_galore`, so the last row parsed would silently decide the settings for all of them.
- **`setDotted` guards `parts[0..-2]`** — a top-level column like `poolSize` has no scopes to walk into, and `[0..-2]` on a one-element list is a *negative range* rather than an empty one.
- **Types are preserved from the config.** Everything arrives from CSV as a string, and a `poolSize` of `"50"` divides differently from `50` — `sensitivity` is `1.0 / (2 * ploidy * poolSize)`, so this is integer-vs-string, not cosmetic. When the key is being created there is nothing to copy a type from, so a digit string becomes an Integer — otherwise `task.cpus` gets a String and the process fails somewhere far from here.
- **`-q` is mapping quality and `-Q` is base quality** in the mpileup options. They are not interchangeable and were once supplied to each other.

## The row is applied twice, on purpose

Between the two passes the derivations run. So a row setting an **input** to a derivation gets the derived value recomputed — setting `poolSize` moves `sensitivity` with it — and the second pass is what makes a row that sets a **derived** value directly win anyway. Both are required: any parameter may be varied, including the computed ones, because benchmarking needs it.

`runDefinitions()` **must** be called before `resolveParameters()`. Afterwards there is no way to tell a value the user pinned from one we filled in, and `fill` refuses to overwrite a key that is already there — so a run changing an input to a derivation would keep the base run's derived value and quietly use the old setting. The copy has to be taken while "absent" still means "not set".

## `knownParameterNames()` is not a whitelist

Any parameter may be varied between runs; there is deliberately no list of permitted ones. This is the set of names that **are** parameters, so a column naming something else can be refused rather than quietly doing nothing. A run whose setting is silently ignored is worse than one that will not start.

Derived from the live `params` map rather than written out, so a parameter added to parameters.config is varyable the moment it exists. The derived names are unioned in because the template leaves them commented out — they do not exist in `params` until `resolveParameters()` fills them.

## Missing versus malformed

`metadataRows()` splits the two deliberately:

- **Missing is not an error here.** Absent is the ordinary state of a project someone has not finished setting up, and step 0 exists to say so in context, in a report kept beside the results. So it returns an empty list and lets the run reach the stage with the good message. Nothing computes in between: every step is gated on step 0.
- **Malformed throws.** `parse_metadata.py`'s message is already the best available — every problem at once, with line numbers — and throwing puts it in front of the user seconds after they start the run. The multi-run table gets the same treatment for the same reason; it runs while the DAG is being built, before step 0 executes, so the message has to stand on its own.

Both shell out rather than parsing in Groovy, because the Python parsers handle CSV quoting that `readPattern` needs (its default contains a comma) and are unit-tested at a millisecond a case.

## A run no longer gets its own storageDir (Z, 2026-08-27)

It used to default to `${storageDir}/${RunID}`, which gave every run a complete parallel tree — and once work is shared there is no such thing as one run's complete tree, so the parallel trees described something that had stopped being true. There is one storage root now, and `deriveRunPaths()` names the run *inside* `Output/` and `Logs/`.

A `storageDir` column still works; it just means that run's results are somewhere else entirely. Two runs not sharing a storage root cannot share a results directory, so sharing between them is refused rather than resolved.

**`dir.utilized` keeps its per-run suffix, and that matters more than it looks.** It hangs off `mainDir`, and runs *share* `mainDir`. Without the suffix every run writes `Utilized/VCF/Test.vcf` to one path, and the second run's skip check finds the first run's file and symlinks to it — the whole VCF chain silently reused across runs that differ.

`dir.logs` is per run and not merely per project because log files are named for the step and the sample: three runs sharing one Logs tree would put three writers on one file, and one-writer-per-file is what lets tasks append without locking.
