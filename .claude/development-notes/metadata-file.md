# The sample metadata file

**Written 2026-08-31, against the tree at `7d65893`.** Two more reserved prefixes have arrived since and the parser now documents seven kinds of column, not three; `diploidy` is `ploidy`; and "a design column is free to edit" has acquired a caveat the analysis layer created. All noted in place.

> **For the manual — all three are there now** (verified 2026-08-31), including the factor of two in the threshold and the freedom to edit design columns. Kept here as the statement of what the file is *for*:
> 1. **`RG_Sample` merges rows into one VCF column** — two lanes of a pool become one column whose depths are added. This changes what a number *means* and is the single most consequential thing in the file.
> 2. **`param_poolSize` sets a pool's detection limit**, `s = 1 / (2 * ploidy * poolSize)` — the smallest allele fraction that pool can produce. A reader interpreting a frequency table needs it.
> 3. **Design columns never affect results**, so they can be added and edited freely. Worth stating positively; it is the reason the file exists.

`metadata.csv`, the file the user authors to say what their samples are. Read by `bin/parse_metadata.py`, projected by `scripts/metadata.nf`, consumed by steps 0, 2, 4, 6 and 7.

## Why it replaced RGTags.csv

`RGTags.csv` was a SAM header fragment: its columns were raw `@RG` tags and nothing else fitted in it. Everything a pool-seq experiment actually needs recorded — which population a sample belongs to, which timepoint, which replicate, how many individuals went into the pool — had nowhere to live, so people encoded it in the `DS` field or in the sample name. E3a replaced it with a file the user writes for themselves. The analysis layer (E4) is the consumer the design columns exist for.

## One parser, one parsed structure

`resolveParameters()` runs the parser once and attaches the rows to every run map as `run.metadata`. Nothing else parses the file, and that is the point of `scripts/metadata.nf` existing at all.

Before it, the file was parsed in **three** places: `head`/`awk`/`IFS` in step 4, a naive `split(',')` in step 6, and a third in the divergence analysis. Two of those already mis-read a quoted value containing a comma — and a description field is the likeliest place in this pipeline to find one. Step 4's version was worse than wrong-on-quotes: it projected *every* non-empty column into an `@RG` tag, which worked only while every column was a tag. A design column would have gone into the BAM header as an invented tag.

It also let `RepairRGTagsLineEndings` be deleted outright. That stage existed only because the consumers read raw bytes; Python's `csv` handles CRLF natively, and nothing reads the file at task time any more. That closed a standing complaint — *step 0 rewrites a file the user wrote* — rather than documenting it. `03_pipeline` asserts its task count is 0 so nothing reintroduces it.

## The three projections are one mechanism asked three questions

They have to be, or the pipeline could share an artifact between two runs while telling the user their metadata had not changed.

| Question | Answered by |
|---|---|
| What does a step's artifact depend on? | `stepIdentity()` in `variants.nf` |
| What invalidates results that already exist? | the change guard in step 0 |
| What does a task actually need? | the `@RG` line, the column order, the adapters |

A design column appears in none of them, which is what makes it free to add and edit.

**That is true of the pipeline and no longer true of the analysis layer.** `exp_`, `pt_` and `cov_` columns are what a module builds its published design from, and `metadataGuardLines()` still projects `RG_*` and `param_*` alone — so a design column edited after a run leaves the pipeline's results correct, exactly as this section says, and lets a module publish a design those results were never produced under. The freedom was the point of the file and is worth keeping; what is missing is that nothing records which version of a design column a result was analysed under. See `change-guards.md`.

**Sorted vs file order is the distinction that matters.** `metadataProjection()` sorts, because it answers "are two runs the same for this step". `metadataGuardLines()` does **not** sort, because the guard has to tell a value change from a permutation: tag values live in the BAMs and a reordering leaves them correct, while row order lives in the VCF and nothing else. Step 0 sorts both sides itself to draw that distinction. Adding a `.sort()` to the guard lines would silently collapse the two cases into one.

**Row order is a separate identity from row values.** bcftools names VCF sample columns in the order the BAMs are given; step 6 orders them by `metadataOrder()`, and the frequency tables inherit it. Two files that are permutations of each other therefore *share* step 4 and *diverge* at step 6 — which a single "the metadata file" identity token would get wrong in one direction whichever way it was written.

## Decisions

- **The guard compares a projection, not the file** (Z, 2026-08-28): the `RG_*` columns plus the columns that change a number. Adding or editing a design column is free; a tag value or an adapter still fails the run.
- **`RG_Sample` defaults to `SampleID`** when absent or blank, resolved *in the parser* so every consumer sees the effective row and nothing re-derives it. A second place to derive it is a second place for it to be derived differently.
- **Three reserved prefixes** (Z, 2026-08-29): *"anything that touches the parameters should take a prefix `param_*` like `RG_*`, we control the list."* `SampleID`, `RG_*`, `param_*`, and everything else is the user's. E3a's bare `adapter1`/`adapter2` were renamed to `param_adapter1`/`param_adapter2` under that rule; nothing had shipped, so it was not a migration.

  **Two more prefixes were reserved since, on the same rule.** `exp_` for the experimental design (F0b), then `pt_` for a phenotype and `cov_` for a covariate (F0f) — three rather than one because only `exp_` identifies a series, so a temperature recorded per timepoint under `exp_` would leave every series one point long. The parser's docstring opens **"SEVEN KINDS OF COLUMN"** now: `SampleID`, `RG_*`, `param_*`, `exp_*`, `pt_*`, `cov_*`, and the user's own. Each reserved prefix refuses its own unknown members, and the bare prefix with no name after it is refused by name.
- **Both closed lists are refusals, not filters.** A `param_` or `RG_` column the pipeline did not recognise would be a setting the user has written down, can see in their own file, and that was never applied. The parser also refuses a *bare* `poolSize`/`adapter1` — without that check it would be accepted as design metadata and silently ignored, which is the exact failure the prefixes exist to prevent.
- **The tables exist twice on purpose** — `RG_TAGS`/`PARAM_COLUMNS` in the parser, `rgTagMap()`/`paramColumns()` in `metadata.nf`. The parser must refuse an unknown column before anything runs; the Groovy side must render the tag and act on the parameter. Neither can do the other's job from where it sits. Two cases in `00_static.sh` check they agree, so a tag added to one and not the other fails a test instead of becoming a column that validates and then vanishes from the BAM.
- **No generated intermediate.** Generating an RGTags.csv inside the pipeline was considered and rejected: `rgTagsOrder()` ran at DAG-build time, before any process, so a generated file would have broken first-run column ordering and then tripped the row-order change guard.

## Multi-lane pooling — tested, not reasoned about

Two FASTQ pairs whose rows share an `RG_Sample` produce two `@RG` IDs, two ready BAMs, and **one** VCF sample column carrying both lanes' depth. The frequency table follows the VCF, and the cohort assertion passes because it counts ready BAMs against read pairs, never VCF columns. Verified on the base fixture with `TestSample1`/`TestSample2` sharing `SM: Pool_A` — exit 0, five columns for six pairs, pooled frequencies differing from either lane's.

The shipped template had always done this, so pooling is documented usage rather than an edge case. **Therefore a per-sample override that changes a number is a property of the POOL, keyed by `RG_Sample`, not of the row** — and rows sharing a pool must agree on it or the file is refused. That rule was decided by the experiment run to decide it.

I had previously claimed multi-lane was unsupported. That was wrong: `rgTagsOrder()` orders BAMs by `SampleID` and never touches VCF columns, so more rows than columns is correct and nothing downstream miscounts. The two lists coincide in the fixture, which is why reading the code did not settle it and running it did.

## `param_poolSize`

A pool's size sets its detection limit: `s = 1 / (2 * ploidy * poolSize)` is the smallest allele fraction a pool that size can produce — one chromosome out of all of them — and the false-positive filter drops everything below it. It was one number for the whole VCF until E3b, which judged a pool of 10 at a pool of 100's resolution.

`poolSizeArgument()` renders **sizes, not sensitivities**, because the filter derives `s` itself. That keeps the equation in one place on the per-pool path and puts the number the user actually wrote into the VCF header. Keyed by name rather than column position — see `false-positive-filter.md` for why that is a correctness property and not a convenience.

A blank cell falls back to the global `poolSize`, so a project that sets none of them gets exactly the number it got before the column existed.

## Details stripped from `scripts/metadata.nf`

Held here so the source can stay terse:

- **`metadataColumnsPerStep()` and `stepParameterMap()` are both authored by hand**, and static cases check each against the processes that read them. Step 6 is absent from the metadata map because what it takes is row order, not a column set.
- **`overrideColumns()` feeds the change guard**; `adapterColumns()` feeds step 2 and `poolSizeColumn()` feeds step 7. The split exists so that a pool-size edit and an adapter edit invalidate different things.
- **`rgTagString()` is built at DAG-build time**, not in step 4's shell. The shell version read the CSV header and projected every non-empty column as a tag, which was correct only while every column was one.
- **`sampleTrimOptions()` routes through `resolve_parameters.nf`'s `trimOptions()`** rather than assembling flags itself, so a flag added to the derivation reaches the per-sample path too.
- **A run with no overrides is byte-identical to one from before the columns existed.** That was the inertness requirement for both E3a and E3b.

## `trim_galore.options` pinned, adapters overridden

A run may pin `trim_galore.options` outright rather than letting it be derived. That makes a per-sample adapter unactionable: the pinned string is used verbatim, so the row's adapters would be silently dropped. Step 0 refuses the combination rather than picking a winner — a run whose setting is quietly ignored is worse than one that will not start.

`sampleTrimOptions()` builds through `resolve_parameters.nf`'s own `trimOptions()` rather than assembling the flags a second time, so a flag added to the derivation reaches the per-sample path too. A row that sets neither adapter gets the run's string unchanged, which is what keeps a project with no overrides byte-identical to one from before the column existed.
