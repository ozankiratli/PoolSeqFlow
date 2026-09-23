# Development notes

Why PoolSeqFlow is built the way it is. This is the home for everything that used to live in the source as commentary: decisions and who made them, what was tried and rejected, what a choice was measured against, and the traps that produced a wrong answer once already.

It is not user documentation — that is `manual/PoolSeqFlow-manual.md`. It is not an explanation of what the code does — that stays in the code. It is the reasoning a person needs before they *change* something, and the reason we moved it here is that the two kinds of writing had grown into each other: files where the argument for a design outweighed the description of it, and a developer had to read three paragraphs of history to find out what a function returned.

## These notes are dated

**Every note records the code as it stood when it was written, and says so at the top.** Later work moves things and a note is not rewritten to follow it: these are the record of how the project got here, not a second manual to keep in sync.

So a present-tense description inside a note describes the code *at that note's date*. `manual/PoolSeqFlow-manual.md` is the current answer and always is — where the two disagree, the manual is right and the note is history.

**Two files are exceptions and both say so at the top.** This index, and `shell-and-nextflow-gotchas.md` — a reference that is appended to as traps are found, with per-entry dates, rather than a record of one moment. Both are kept current.

## The rule

**It lives in `CLAUDE.md` at the repository root now, not here.** That file loads into every session; this one does not, which is why the rule was broken twice in a session that had it written down. Read `CLAUDE.md` for the current wording — the clause-level test, the tell-words, the third category, and the exclusions.

In short: every comment *clause* is either what the code does or why we chose it. What it does stays, in one line. Why we chose it comes here.

## The three destinations

| Where | What |
|---|---|
| **The source** | Only what a reader needs to understand the function below: what it does, what it returns, a contract or coupling they cannot see from here. |
| **`manual/PoolSeqFlow-manual.md`** | Decisions that matter **scientifically** — anything that changes what a result means, or that a person interpreting output needs to know. The manual is the project's real documentation and is what the published site is generated from. |
| **Here** | The record of how it got here. Design churn, alternatives tried and dropped, what a thing used to be, measurements behind a choice, who decided what and when. |

The manual is the one to keep watching. *"Pool size sets the detection limit"* is science and belongs in the manual. *"We tried three bcftools mechanisms and the second one silently returned zero records"* is development history and belongs here. A decision we changed five times is confusing to a reviewer and must not end up in either the source or the manual.

**No source file references these notes**, and no source file references the test suite. Both point the wrong way. A note is dated, so a comment pointing at one imports a description of code as it used to be — which is the exact failure the rule above exists to prevent. And the dependency runs tests → scripts: a test may say what it is testing; a script may not say it is tested.

## Where this lives

**Tracked and public** (Z, 2026-09-05). They were untracked while the public form of them was being decided; that decision is made, and it is that how PoolSeqFlow was built should be as readable as what it does. The manual's development section is written from these notes and points back to them.

`export-ignore` keeps them out of release tarballs, on the rule `.gitattributes` already sets for `dev/`: a downloaded release carries the pipeline and the manual, so tracking these costs a user nothing.

## Layout

One file per subject, not per source file — the reasoning crosses file boundaries far more than the code does. A note names the source it applies to; a source file does not generally point back, except where a tripwire comment says "see the notes on X".

| File | Subject |
|---|---|
| `metadata-file.md` | the sample metadata CSV, its prefixes, pooling and pool sizes |
| `variant-model.md` | how work is shared between runs; the divergence tree |
| `parameter-resolution.md` | what is computed vs set, and how a run's parameters are built |
| `step-0-verification.md` | the checks, how often each runs, and how the report is assembled |
| `change-guards.md` | what stops a project changing configuration mid-analysis |
| `config-migration.md` | carrying a configuration forward a release: the 2.2.0 → 3.0.0 pass |
| `four-roots.md` | installation / launch dir / mainDir / storageDir |
| `dictionaries-and-snpeff.md` | step 1, and the three bugs its shape is the fix for |
| `promotion.md` | moving artifacts from the working volume to permanent storage |
| `bin-helpers.md` | the small programs the pipeline shells out to |
| `false-positive-filter.md` | per-pool sensitivity, and the four mechanisms measured |
| `depth-cutoff.md` | the per-sample depth cap: three designs, and the corpus that decided between them |
| `callable-sites.md` | the per-window callable track, built and REVERTED: the sizing that now shapes E4b |
| `callable-sites-reverted.patch` | that feature itself, kept whole rather than deleted: what was built, and what rebuilding it would start from |
| `dag-wiring.md` | the entry workflow, and nine Nextflow behaviors learned the hard way |
| `wrapper.md` | the `PoolSeqFlow` script itself: install, uninstall, clean, reset |
| `analysis-wrapper.md` | the analysis commands: one payload owner, the bare-word reversal, `check`/`cite`, and the R environment |
| `bin-and-lib.md` | why the helpers are split into `bin/` (run) and `lib/` (sourced) |
| `dry-run.md` | the preview: why it is its own entry point, and the traps in building it |
| `concurrency.md` | two analysis modules deriving one intermediate: what was measured, and the one line that fixes it |
| `analysis-versioning.md` | when `analysis/frame.version` moves, and the stricter rule that was measured against the history and dropped |
| `module-dependencies.md` | the four compatibility fields a manifest declares, why shape and compatibility are checked in different places, and what a package spec may not carry |
| `experimental-design.md` | what makes two pools one independent unit, why it was gated on the time axis, and the two formulations that are not partitions |
| `association-math.md` | F2 before it was written: the permutation scheme measured at twice its nominal rate, weighted FWL, and what a case may not assert |
| `nei-distance.md` | why F3's distance is Nei's minimum distance: what was measured, and why the sampling correction is the whole benefit |
| `module-optionality.md` | the audit behind the modules rework, SUPERSEDED by `modules-and-libraries.md` and kept for its blast-radius findings |
| `modules-and-libraries.md` | modules and libraries are installed rather than shipped: the root cause Z named, and the rework it forced |
| `check-split-and-layout.md` | splitting `check` into install and project, and the `bin/` `lib/` `install/` `citations/` move |
| `calibration.md` | what `dev/validation/` measured against a known truth: `n_eff` exact, the closed form calibrated, unit means required rather than a df adjustment, and the depth-phenotype correlation that breaks permuting |
| `shell-and-nextflow-gotchas.md` | the traps that produced a confidently wrong answer once: zsh vs bash, `set -e`, awk, the strict parser, channels, config |
| `gates-that-stopped-checking.md` | the failure this project is prone to: a change moves what a checker points at, and the checker keeps exiting 0 over nothing |
| `host-glibc-floor.md` | v3.1.1's analysis environment installed only on the machine that froze it: virtual packages, the four guards, and why a solve cannot answer it |
| `someone-elses-machine.md` | four defects a green suite could not see, because the suite runs where the assumption holds; and the second machine that found three of them in an hour |
| `brainstorming.md` | ideas for later releases: what each would buy, what it would break, and where it sits |
| `module-queue.md` | the plan from v3.1.1: thirteen modules at one a week, published without a release, and the two shape questions the roster raised |

## Reading these against the code

Each note says at the top what it was written against. Two changes cut across many of them and are worth carrying in before you start.

**Two scope renames happened after most of these were written**, in `cc00833`: the option scopes `samtools` and `bcftools` are now `cleanBAM` and `variantCall`. Any note naming `params.samtools.mapq` or `params.bcftools.maxDepth` is describing pre-3.0 code.

**The comment campaign is finished and committed as `7ad02c1`, except `test/`**, whose comments — some 2,500 lines of them across the suite — were never swept. There the filter is different and `CLAUDE.md` says so: a comment recording the bug a case guards *is* its function, and deleting it is how the case later looks arbitrary and gets removed.

## Running a comment pass

**Verification, when a pass runs:** `nextflow lint .` at zero errors *and* zero warnings, the suite, and per file a diff of non-comment lines against `HEAD`. For a Python file the line count misleads — a module docstring is not a `#` comment — so prove it with an AST comparison that strips docstrings. **Run `bash -n` over every shell file too**: an apostrophe written into a comment inside an embedded awk program closes the surrounding single-quoted string and stops the file parsing.

**The templates are not source.** `parameters.config.template`, `metadata.csv.template` and `multi-run.csv.example` are shipped to the user and read while editing, so their comments are the only help available at the point of use. Z ruled on them directly (2026-08-30): *"Too many comments make them unreadable… These are all manual material. The guides should be minimal here."* A template's comments say what a setting **is** and what format it takes; everything explanatory goes to the manual. **What must not be cut is not commentary at all:** the commented-out parameter assignments are the knobs. There are 14 in `parameters.config.template`, and `grep -vE '^\s*//'` hides them from an ordinary settings diff, so count them separately.

**Tooling:** `dev/scripts/comment-audit.sh` lists tell-word clauses and comment blocks of 4+ lines. It always exits 0 and is deliberately not a test case — a hard failure would train the next pass to reword around the words instead of deleting the decision behind them.
