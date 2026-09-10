# Working on PoolSeqFlow

## Comments: what the code does, never why we chose it

**Every comment clause is either a description of the code below it or a design decision. Descriptions stay, in one line. Decisions move to `.claude/development-notes/` and leave the source.**

The unit is the **clause, not the comment**. The failure mode is a comment that opens with a real description and smuggles a justification in after it:

```groovy
// Deep copied, because the item gains bookkeeping that must not land in a shared run map.
```

The first clause earns its place. The second is a decision and rides in on its back. Write what the code does, stop, then check whether what you were about to add next is a decision.

### Why this matters more than tidiness

**A design decision left in a comment reads to a future session as a current constraint, and it will be argued from against what you are actually being asked for.** Z, 2026-08-30: *"In multiple occasions, the previous design decisions have skewed your interpretation of my asks, we had to spend way too much time on simple tasks."* Stale reasoning in the source is not clutter — it is misinformation with authority. A decision we changed five times is also confusing to a reviewer and must not end up in the source or in the manual.

### The third category, which a binary test will wrongly delete

Not every "why" is a decision. The cut is: **does the code become inexplicable without this, or merely unjustified?**

| | |
|---|---|
| **Inexplicable — keep** | `// The trailing return 0 is load-bearing under set -e.` Without it the line reads as dead code and someone deletes it. |
| **Unjustified — cut** | `// Removed rather than kept as PoolSeqFlow-<new>, so the environment ships built fresh...` A choice among alternatives that all work. |

A constraint that makes an otherwise-pointless line explicable is *what the code does*. A constraint that defends a choice is a decision. Losing this distinction reintroduces bugs — `_sort_fp_dq.vcf` sat in `Output/VCF` on every run since 1.0 because the reason for a deletion's placement was never written down.

### The check

Grep before calling a file done. `dev/scripts/comment-audit.sh` does it:

```
on purpose | deliberately | rather than | because | would otherwise | so that | which is why
```

Each hit is a candidate, not a verdict — some are legitimate. This is a review aid and never a test case: a hard failure would train the next session to reword around the words instead of deleting the decision.

### Three destinations

| Where | What |
|---|---|
| the source | only what a reader needs for the code below: what it does, what it returns, a coupling or constraint invisible from here |
| `manual/PoolSeqFlow-manual.md` | anything that changes what a result **means**, or that a person interpreting output needs. The manual is authoritative; nothing in it is repeated in the source. |
| `.claude/development-notes/` | the record of how it got here. Design churn, alternatives dropped, measurements, who decided what and when. |

**No source file references the notes.** A note is dated and is not updated to follow the code, so a comment pointing at one imports a description of the code as it used to be — the exact failure the rule above exists to prevent. **No source file references the test suite** — the dependency runs tests → scripts, never back. A test may say what it is testing; a script may not say it is tested.

### Mid-feature is not the deadline, but the feature has one

**A comment carrying more than the code below it needs is tolerable while a feature is being built, and is not tolerable when it ships.** Z, 2026-08-31: *"During development of a feature it is fine, but we should not forget about cleaning them at the end of the development."* So a working comment may explain more than it should for as long as the stage is open — and **every stage ends with a pass over the comments it added**, trimmed to what the code needs. Put that pass in the stage's own checklist when the stage starts, or it is the thing that gets skipped.

### Not source, and out of scope

`parameters.config.template`, `metadata.csv.template` and `multi-run.csv.example` **ship to the user and are read while editing**. Their comments are the only help available at the point of use, so this filter does not apply to them. Do not cut them without asking.

### `dev/` and `test/` follow the opposite rule: keep everything but abandoned ideas

**They carry a different role in the project.** Nothing in them ships, nothing in them computes a published number, and neither is read by someone trying to understand what the pipeline does — they are read by someone trying to understand *whether it is right*. There the reasoning IS the content: a measurement with no account of what it measured is a number nobody can act on, and a case with no record of the bug it guards is a case the next session deletes as arbitrary.

So the source filter is **inverted** here. Keep the why. Keep the measurements, the alternatives weighed, the constraint that made a harness awkward, the reason an assertion is phrased the way it is. A `dev/` script that explains its own methodology at length is doing its job.

**The one thing to cut is an abandoned idea** — an approach tried and dropped, described as though it were still how things work. That is the failure the source rule exists to prevent and it is just as damaging here: it reads to a later session as a current constraint. The test is not "is this a decision" but **"does this describe something that is still true?"** A superseded approach whose *finding* still governs the current design is not abandoned — keep it, and say which part is live.

Z, 2026-09-08: *"We keep everything but abandoned ideas. They carry a different role in the project."*

`dev/scripts/comment-audit.sh` therefore does not scan them by default. Name a path explicitly to scan one anyway; every hit there is expected and is not a finding.

## Other standing rules

- **Never `git push`.** Z publishes; nothing else does, for any reason.
- **Never `git commit` unless asked**, and a commit instruction covers only the work that existed when it was given. Do the work, leave it uncommitted, say what changed in prose, stop. The uncommitted tree is the review surface — never build a diff artifact or a summary page as a substitute.
- **Use the `Edit` tool for file changes, never a script that rewrites a file.** Z reviews side by side in the IDE diff view as it lands. Announced mechanical renames via `sed` are the one exception.
- **No hard wrapping in markdown.** One paragraph is one line, in every `.md`.
- **American English, everywhere.** Prose, comments, identifiers, user-facing output. The repository was swept on 2026-09-08 and `dev/scripts/americanize.py` is what finds a regression; run it before a release. Matching the surrounding file is the usual reason a Britishism appears, so it spreads from whatever it lands next to — which is why the sweep is a tool and not a habit. Two things are NOT errors and the script says so: `catalogue` is current American English and is this project's name for a specific thing, and `analyses` is the plural of `analysis` far more often than it is the British verb.
- **Fail loudly or document; never automate away a decision.** Compute the default, never remove the knob.
- **Never point anything at `Project/`** — real data, hours of compute, tens of GB. The test sandbox's `guard_path` refuses anything outside `TEST_TMPDIR` and anything inside the repository.
- **No legacy fallbacks in `.nf` files.** A dropped parameter is handled by `bin/config_migrate.sh`.

## Verifying a comment pass

Not one line of code may change. Per file, diff the non-comment lines against `HEAD`. For Python, a docstring is not a `#` comment and the line count misleads — prove it with an AST comparison that strips docstrings.

Then lint and `bash test/run_tests.sh --fast`, which is under a minute. Check both counts — files linted, cases passed — against the run before it rather than only the exit status: a filter that matches nothing also reports success. Neither number is written down here, because both move with every file added.

**Lint the tree without `modules/`**, and expect zero errors and zero warnings:

```
nextflow lint analysis analysis.nf dryrun.nf poolseqflow.nf scripts
```

`nextflow lint .` **cannot pass and is not the command.** A module's `main.nf` imports the frame as `'../../lib/nf/plan.nf'` — correct from `analysis/modules/<name>/`, where it is installed, and unresolvable from `modules/<name>/`, where it is written. The path is right and the tree is wrong for it, so linting from the repository root reports one `Invalid include source` per import on every module. **`00_static` is what lints them**: it assembles a store layout in a sandbox and lints that, which is the only place those imports resolve.

## What to run while building

**Write the cases for a step as you build it, and run only those.** Z, 2026-09-01: *"We really need to prepare test cases for each step we're building. And only test those. We will run the full suite before we publish a release. Right now it is blocking the development."*

```
bash test/run_tests.sh --suite 07_analysis --case citation
```

`--case` matches any part of a case name and filters at dispatch, so the suite's fixtures are still built by the cases that define them. Three cases in under a minute against ten for the suite they live in — which is the difference between checking a change and avoiding checking it.

**The full suite belongs to a release**, not to a step. `--fast` is the cheap sweep when a change reaches beyond its own step — the wrapper, packaging, a shared library — and a whole `--suite <name>` is for when the step *is* that suite.

| you changed | run |
|---|---|
| `bin/` | `05_helpers` — except the three `check_*.sh`, which are `02_launcher` |
| `PoolSeqFlow`, install/uninstall, the check scripts | `02_launcher` |
| `bin/config_migrate.sh`, the templates | `01_migrate` |
| step 0, parameter resolution, the change guards | `04_guards` |
| wiring, channels, promotion, a step's script | `03_pipeline` |
| `dryrun.nf`, `dryrun`/`dryclean` | `06_dryrun` |
| version strings, packaging, syntax | `00_static` |
| a module library under `modules/lib/` | `analysis_rlib` — no JVM, 3 seconds |
| `analysis/lib/nf/`, the frame | the analysis seam you touched: `analysis_frame`, `analysis_plan`, `analysis_verify`, `analysis_design`, `analysis_time`, `analysis_series`, `analysis_modules`, `analysis_results` |
| a module | `--suite <module name>`; its cases travel with it under `modules/<name>/test/` |

`--fast` runs everything that does not start a JVM; what it skips is `03_pipeline`, `04_guards`, and the pipeline halves of `06_dryrun` and the analysis suites.

**`bash test/run_tests.sh --changed` picks the suites for you**, from what each suite declares it runs expanded through the include graph. `dev/scripts/select-tests.py <file>` shows the reasoning without running anything. It errs wide — a change to `test/lib/` or to the selector selects everything — so a narrow answer is trustworthy and a wide one is only expensive.

**Every suite declares what it may cost** — `static`, `jvm` or `pipeline` — in a `# cost:` line in its own header. `--cost static` is the set that completes with nothing installed: `00_static`, `01_migrate`, `02_launcher`, `05_helpers`, `08_analysis_rlib`. `--fast` is a different axis and still a case-level switch, so the two compose.

**`--suite` and `--case` accumulate and match by name, not by number.** `--suite analysis_time --suite analysis_series` runs both, and `--suite analysis` runs all nine. Every run prints the scope it selected, so a narrowed run cannot be mistaken for a full one; renumbering a suite therefore costs nothing, because nothing addresses one by its number.

A template's comments are checked differently again: the **commented-out parameter assignments are knobs, not commentary**, and `grep -vE '^\s*//'` hides them from the settings diff. Count them separately. `parameters.config.template` has 14 commented lines that look like assignments, and they are two different things: **6 are knobs** you can uncomment as they stand — `fastqc.options`, `trim_galore.adapterOptions`, `trim_galore.options`, `cutadapt.options`, `bwa.options`, `variantCall.mpileupOptions` — while the **other 8 are the `cores` block**, where the right-hand side describes how each value is derived rather than being a value. Do not cut either, and do not count them as one thing.
