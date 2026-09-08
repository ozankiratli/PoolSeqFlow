# What makes two pools one unit

**Written 2026-09-07, against the tree at `e3eb887` plus the uncommitted F0g change.** The rule below is Z's, given the same day. The defect it fixes had been in the tree since F0d (`2915346`).

## The defect

`designSummary()` computed `roles`, `units` and `conditions` inside `if (checkTimeSettings(...))`. They are not derived from time — they were merely *written* there, because the whole block arrived with the time-series work. A project with no time course therefore reported:

```
UNITS      : []      CONDITIONS : []      ROLES : [condition:[], biological:[], technical:[]]
EXPERIMENTAL DESIGN:       6 pools from 6 libraries
EXPERIMENTAL DESIGN:           exp_cage (3 levels), exp_lane (2 levels)
TIME VARIABLE:         none - no time column, so nothing is a trajectory
```

Three cages sequenced on two lanes, and the report never mentions that `exp_lane` might be a technical replicate. Degrees of freedom come from `design.units` (module rule 17c), so the commonest design there is — a one-off comparison — handed every module a zero it could not tell from an unanswered question.

**Why it survived.** `12_analysis_design` had 29 cases and not one of them touched units, conditions or roles; every case that did lived in `14_analysis_series`, behind a `timeVar` block. The untimed path was never asserted on, so it was never wrong out loud.

**The time-series half was sound and is unchanged.** Verified before touching anything, by running the 16-pool replicate fixture through `designSummary()`: 8 series, 2 units, 1 condition, 4 technical — identical before and after.

## Z's rule

> *"RG_Sample is the key metric if pools are separate or combined. And I think if there is a second technical replicate column, we identify it in technicalRep parameter. If lanes are technical replicates we need to treat them as such. These decisions should always come from the user's declarations. I say we limit the experimental design to biological replicate and technical replicate assignments by the user. It is the ultimate source of knowledge the pipeline can get."*

So: **`RG_Sample` has already decided what was merged before the analysis layer sees anything. Two pools are two independent units, and the only thing that can make them one material again is a column named in `technicalRep`.**

## The formulation, and the two that did not work

The rule has to be a partition, which rules out the obvious statements of it.

**"Group pools by the condition and biological columns"** merges three control pools that carry only `exp_treatment` into one unit. Z's 3-vs-3 design would then have 2 units where it has 6, and F2's permutation floor of 2/20 assumes 6.

**"Two pools are one unit when they agree on the condition and biological columns AND differ in at least one technical column"** is not transitive. With `technicalRep = ['exp_lane']` and pools A/L1, A/L1', A/L2: the first merges with the third, the second merges with the third, and the first two do not merge with each other. No partition exists.

**What works** is to give the untimed case the same shape the timed case already had. The timed path rolls up *series*, and two series can never share a key — so with `technicalRep` empty each series is already its own unit. Generalise the atom:

| | the atom | rolled up by |
|---|---|---|
| timed | a series | dropping the technical columns |
| untimed | a pool | dropping the technical columns |

`designMembers()` returns one or the other. `unitsOf()` then groups members by the condition-plus-biological key and, **within each group**, buckets by the technical key:

- every member has its own technical key → one unit (they are repeats of one material)
- every member shares one technical key → one unit per member (nothing tells them apart, so nothing merges them)
- partly one and partly the other → **refuse**, because no partition exists

The second case is what `technicalRep = []` degenerates to, and it is why an undeclared project gets one unit per pool. The third is unreachable when there is a time axis, because series keys are unique; it is the untimed twin of the existing "two pools at one timepoint in one series" refusal and offers the same remedies.

## The settings split

`by`, `biologicalRep` and `technicalRep` describe the experiment and were living in `analysis.metadata.series`, which asserted that an experiment without a time course has no design. They moved to `analysis.metadata.design`. `analysis.metadata.series` keeps `incomplete` alone — only a time axis can leave a trajectory ragged.

Z had picked `analysis.design` when asked; it became `analysis.metadata.design` because every sibling setting lives under `analysis.metadata`, and a top-level scope would collide with a module named `design` — the collision `paths.nf` keeps the nesting for.

**Corrected the same day, by Z, and my reason was wrong.** A module's settings live at `analysis.modules.<name>`, one level below the frame's own scopes, which is exactly what stops a module named `design` reading a frame setting — so there was never a collision to avoid. It moved to a top-level **`analysis.design`**, with `series` nested inside it, on Z's call: *"I think design should move out of metadata (after metadata) but inherit series inside it."*

That gives three scopes with a real distinction, and it is worth stating because it decides where a future setting goes:

| scope | question it answers |
|---|---|
| `analysis.metadata` | how the file is **read** — what a blank means, how a date parses, what scale a column carries |
| `analysis.design` | what the file **describes** — which pools are independent, which repeats are which |
| `analysis.modules.<name>` | what **this analysis** does with either |

`series` sits inside `design` rather than beside it because a series is what a time axis makes of the design, not a thing of its own. `timeVar` stays in `metadata`: it says how the time column is *parsed and ordered*, which is reading.

`metadataSetting()` and the new `designSetting()` are now one `frameSetting(scope, defaults, key)`, so the partial-write merge and the unknown-key refusal cannot drift between the two scopes.

**No migration.** `analysis.metadata.series` was added in F0d and is in no release tag, so nothing on disk anywhere carries the old spelling. A 2.x config has no `analysis` scope at all. A `dev` user who wrote one gets the existing unknown-key refusal, which names the keys the scope does have.

## What a module now reads

`design.units` and `design.conditions` each carry their own `pools`, sorted as `design.pools` is, so a module indexes the published columns with them instead of joining back through `design.series` — which is empty when there is no time axis. A unit carries `members` (its series, or its pool); a condition carries `units`.

`design.seriesBy` became `design.keyColumns`, because it is what identifies the design and not only what identifies a series.

## Covariates gained a role too

Z, the same day: *"I think we should also open a covariates parameter under design. automatically detected from metadata but configurable if the user wants to keep or leave some out?"*

Same split as the `exp_` columns: `analysis.metadata.covariates.<column>` says **what the column holds** (its scale), `analysis.metadata.design.covariates` says **what part it plays** (whether a module may fit it). Empty means every `cov_` column that has a declared scale — Z's "automatically detected". An undeclared column cannot be in the set because it has no typed value, and naming one refuses with the declaration that would fix it.

**Every covariate stays in `design.covariates`**, each carrying `inDesign`, rather than the excluded ones being filtered out. The confounding argument the covariate prefix exists for — a reader seeing that the high-phenotype pools were also the warm ones — needs the values of the excluded ones as much as the included ones. The cost is a flag a module could forget to check, which is why it is module rule 17e and why the report marks every line `[in the design]` or `[on the record only]`.

**An exclusion is a warning, not silence.** Leaving a covariate out is as much a decision as putting one in, and neither is visible from the values.

This makes the manual's `#covariates-not-adjusted` section wrong in its old form — *"PoolSeqFlow does not correct any result for a covariate, and will not in 3.0.0"* — because F0f settled that F2 fits them as extra predictors. Rewritten to say what is true at both times: the frame adjusts for nothing, a module says what it fits, and the arithmetic of `n_units - 2` is why the choice is the user's.

## Phenotypes became plural, on the covariate shape

Z, the same day, proposing the shape themselves: `metadata.phenotypes { pt_wingspan { kind = … } pt_wingpattern { kind = …; levels = … } }`.

`analysis.metadata.phenotype` was one scope with a `column` key, which asserted that a project has one phenotype. It is now `analysis.metadata.phenotypes`, an open scope with one block per column — the shape `covariates` already had — so the block name *is* the column and the `column` key is gone. `checkScaleDeclaration()` was already shared between the two, so the four kinds and their level rules needed no new code; `checkPhenotypeSettings`/`resolvePhenotype` became the plural forms of the covariate pair, and gained the same undeclared-column warning.

**Which phenotype an analysis tests against is a module setting**, `analysis.modules.<name>.phenotypes`, and it lands with F2 rather than now: `moduleSettings()` checks a scope against *that module's* declared list, so there is nowhere to put it until the module exists. What the frame does today is resolve every declared phenotype and report all of them.

That retires the rule that a project analyzes one phenotype at a time under its own `folderName`. `folderName` goes back to being only about where output lands.

**One thing measured rather than assumed:** an empty config block reaches `params` as *nothing*, so `pt_wingspan { }` cannot be refused — the frame never sees the key. Recorded in `shell-and-nextflow-gotchas.md`, with a case that asserts the behavior rather than a case that asserts a refusal which cannot happen. The undeclared-column warning is what covers it.

## The report

The roles block moved out of `SERIES:` into a `REPLICATION:` block that prints with or without a time axis, and gained the unit list:

```
REPLICATION:           conditions   exp_treatment
REPLICATION:           biological   exp_rep
REPLICATION:           technical    exp_lane, exp_seqrun
REPLICATION:               1 condition, 2 biological replicates each, 4 technical
REPLICATION:               2 independent units from 16 pools
SERIES:                    8 series over 2 timepoints
```

`SERIES:` keeps only what a time axis adds. The unit count moved to `REPLICATION:` rather than being printed twice.

## What is still undefended, and it is the same gap as before

A technical column left out of `technicalRep` is read as a condition and the unit count doubles. No check can catch it — both readings are internally consistent, exactly as `dd/MM` and `MM/dd` are. Printing every key column under exactly one role is the whole defense, and it is now printed for untimed projects too, which is where it was missing.

## A fixture that describes an impossible state, not fixed here

`test/tools/freq_corpus.py`'s untimed `design.json` claims `time: null` while the corpus metadata has an `exp_time` column. `checkTimeSettings()` refuses that combination — a project with an `exp_time` column and no declared `kind` stops the run — so the frame cannot emit that summary. It is a planted artifact and no module consults the frame for it, so nothing fails; but it is a fixture asserting against a shape the frame never produces, which is the trap hand-written VCFs already sprang once. Reachable only via `timeVar { column = 'exp_something_absent' }`. Left for F2, whose fixture it is.
