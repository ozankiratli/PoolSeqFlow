# The change guards

**Written 2026-08-31, against the tree at `7d65893`.** Both guards still work as described. The metadata file has gained columns since, and two of the additions sit awkwardly with what is below — noted in place.

What stops a project from producing results under one configuration and then quietly continuing under another. Two guards, both in `scripts/0_verify_environment.nf`.

> **For the manual — and it is there now** (verified 2026-08-31). The files beside the results, what each one freezes, and what to delete are all documented, and `.poolseqflow_version` is described as *"A mismatch is a hard stop, not a warning"* in two places. This note used to say the documentation asserted the opposite; that was true of the pre-3.0 pages and is not true of the manual.

## The reproducibility guard — one task for the whole project

Z, 2026-08-28: *"Copy the parameters.config and multirun.csv to .parameters.config and .multirun.csv, if they don't exist it is the first run, if they exist they can be compared in terms of what they contain."* And the rule those copies enforce: *"the parameter file being the same with what it was in the beginning and the parameters that are set for each run being kept as they are."*

**Two inputs, compared the way each one has to be:**

| | How | Why |
|---|---|---|
| `.multirun.csv` | **as written** | It is the user's own file, nothing in a release touches it, and every column is a deliberate divergence — so any edit is a change to the run set, full stop. |
| `.parameters.config` | **by resolved value** | It also carries settings that cannot change a number. |

The table being compared as written is also what makes a **regrouping** visible. `Shared_<N>` numbers are assigned in order of appearance, so an edited table can leave `Shared_1` naming a different pair than the one whose results are in it. The table copy sees that directly instead of inferring it from a member list.

For the config, Z, 2026-08-28: *"Ignore resources and paths."* Moving a project to another disk or running it on a bigger node must not invalidate finished results — `mainDir`, `storageDir`, `threads`, `memory`, `cores.*`, `software.*`, `java.*`. That is exactly what `analysisParams()` excludes, so the comparison runs on its output and the raw file is stored beside it as the record of what was actually written.

The two together freeze every run's effective configuration: the base from the config, the per-run overrides from the table. **That is why this needs no per-run task and no per-directory manifest** — both of which it replaced. Two earlier attempts at this were wrong before the right one: a per-run manifest and then a per-directory one.

**The version is a block of its own**, checked first and short-circuiting everything else. Z, 2026-08-28: *"Nobody should ever resume to a pipeline using a different version. That needs a block on its own. Reset and re-run."* The reasoning is a citation argument — *"If they change their version midway, which version will they cite?"* This **reverses** the old rule, under which a version was recorded and never enforced. A project can no longer span two releases, and the whole added-by-a-release classification that existed to let it is gone with it.

## The metadata guard — keyed to the step-6 variant

What it asks is whether the file has been edited since the things that absorbed it were produced: the read group values, which step 4 bakes into each BAM, and the row order, which step 6 turns into the VCF's sample column order. So its answer depends on the **content of two directories**, and two runs may share the file and still have different ones.

Step 6's key is the finer of the two and contains step 4's, so runs sharing it share both artifacts and therefore share one answer.

**Anything coarser breaks the guard itself.** The no-BAMs-and-no-VCF branch treats the situation as "nothing has consumed the file yet" and **records a new baseline** — so a run with no BAMs deciding for a run that has them would adopt the edit while the BAMs on disk still carried the old read groups. Every other wrong existence answer in this pipeline costs redundant work; this one costs the guard.

**The probe looks in four places, not two.** Permanent storage as well as the working volume, and the producing *variant's* directories rather than the member's own. Once sharing was turned on the ready BAMs are promoted to `Output/All_Runs/Ready`, which no member's own `Output/` contains — so a guard looking only there answered 0 on every invocation after promotion and **had already stopped guarding**. That was a real dead guard, found by E1y.

**What it projects, and therefore what it cannot see.** `metadataGuardLines()` writes the `RG_*` columns and the `param_*` columns, one line per sample. Everything else in the file is outside the comparison — which now includes the `exp_`, `pt_` and `cov_` columns the analysis layer reads. The failing branch tells the user *"Columns you added of your own are not compared, so this is a change to something the pipeline acted on"*, which was exactly true when the only things outside the projection were a user's own arbitrary columns. It is now also true of columns the project itself defines: a design column can be rewritten after a run, and a module will publish a design the results were never produced under while the identity check passes. Observed 2026-09-05 and recorded as a risk, not fixed.

## Three kinds of edit, three different remedies

The guard distinguishes them because the fix is proportionate to what the edit invalidated.

| Edit | What survives | What must go |
|---|---|---|
| Row order only | the BAMs — read groups are matched by ID, not position | the called VCF and everything derived from it |
| A tag or adapter value | nothing downstream of cleaning | the ready BAMs too |
| A pool size | the BAMs **and** the called VCF — it is a step 7 parameter | only what step 7 derived |

The pool-size branch was added with E3b. Routing it through the tag branch would have told someone to delete every BAM and realign an entire project to change one number.

**A fourth override column arrived since, and it lands in exactly that trap.** `paramColumns()` holds four now — `param_poolSize`, `param_capMaxDepth`, `param_adapter1`, `param_adapter2` — and `metadataGuardLines()` projects all of them, so a `param_capMaxDepth` edit is seen. But there is no branch for it: it is not a reordering, it is not equal after `drop_size`, so it falls through to *"Read group or adapter values changed… Every BAM carries the old ones."* The capped BAM is transient — built at step 6 from the ready BAM and written to neither root — so changing a cap invalidates the called VCF and step 7's output and nothing before them. The remedy offered is the one the pool-size branch exists to avoid. Observed 2026-09-05, not fixed.

The row-order case is reported as **two orderings, not a line diff** — a diff of a permutation shows the same text as both removed and added, which reads as nonsense. The pool-size case is reported per pool for the same reason: a line diff would print the whole read group twice for every row and leave the reader to spot the one number that differs.

## A portability trap in the pool-size branch

The condition asks whether the two baselines are equal once the pool size field is removed. That was written as `sed 's/\tparam_poolSize=[^\t]*//'` — and **`\t` in a sed PATTERN is a GNU extension**. BSD sed reads it as a literal `t`, without complaining. On macOS the comparison would never hold, the pool-size branch would never be reached, and a size edit would be reported as a read group change — telling that user, and only that user, to delete every BAM.

Replaced with awk, which is portable and was already doing the rendering. `sed -i` without a suffix is also GNU-only but fails *loudly*, which is why the codebase gets away with it elsewhere.
