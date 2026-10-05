# Parameter validation, as built

**Written 2026-09-29 and 30, against the tree at `f54a5ae` plus uncommitted work.** The build of what `parameter-validation.md` planned earlier the same day. That note is the design and the reasoning; this is what the code does and where it differs from the plan.

## The shape the plan called for, and it survived

`bin/check_parameters.sh` reads a resolved parameter set and writes **one tab-separated finding per rule that has something to say**:

    LEVEL <TAB> label <TAB> verdict <TAB> detail <TAB> explanation

`FAIL`, `WARN` or `NOTE`. No color, no indentation, no wrapping: every caller formats it the way it formats everything else. Exit status is 1 when any finding is a `FAIL`, so a caller may use the status alone and read nothing. **Silence is the answer for a sound parameter set** -- a healthy project gets one `NOTHING TO FLAG` line rather than nine passes.

**Two callers, one implementation**, which was the whole point:

- `bin/check_project.sh` pipes `nextflow config -flat` into it and renders each level with its own `fail`/`warn`/`note`, folding the explanation under the row.
- `scripts/0_verify_environment.nf`'s `CheckRunParameters` pipes `current_params.txt` into it -- the same resolved set it already records for the change guard -- and logs findings through `log_message`, so they reach the archived report. A `FAIL` sets `STATUS=FAIL` and the run stops there.

**The inline `scaleMapQ` block added to `check_project.sh` earlier the same day is gone**, and its seven cases went with it, as the plan insisted: two copies is how the two sides drift.

## One thing the plan did not anticipate: two input shapes

The callers hold the values differently and neither should have to reformat. `nextflow config -flat` writes `params.<key> = <value>`; step 0 already holds the same set as `<key>=<value>` from `analysisParams()`. The parser reads both.

That also settles which values are available in step 0 without new plumbing. `analysisParams()` excludes paths, resources, `dir.`, `cores.`, `java.`, `software.` and `capBAM.histogramMax` -- and every key these rules read survives it, including `fastqc.memory`, which is not the top-level `memory` that `skipKey` names.

## The rules, and that every threshold was measured

| rule | level | where the number comes from |
|---|---|---|
| `scaleMapQ` below `varQualMin` | FAIL | measured on real pools at six values of `-q`: 12, 15, 20, 30, 40, 50. One below returned zero sites every time |
| `sampleThreshold` above 1 | FAIL | measured against the fixture VCF: 1.5 left 0 of 135 sites |
| `ploidy` or `poolSize` below 1 | FAIL | sensitivity is `1/(2*ploidy*poolSize)`, so below 1 it is infinite or negative |
| `fastqc.memory` carrying a unit | FAIL | the template already says FastQC rejects `2G` |
| `scaleMapQ` at or below 10 | WARN | 0, 5 and 10 are byte-identical to no adjustment |
| `scaleMapQ` under twice `varQualMin` | WARN | at `-C` equal to `-q`, 6% of the sites an unadjusted run called |
| `sampleThreshold` at or below 0 | WARN | the clause asks for nothing |
| `ploidy * poolSize` below 2 | WARN | see below |
| `minDP 0` with `dropZeroDepth` off | NOTE | the one combination that lets an unmeasured cell reach a published table |
| positive `variantCall.maxDepth` with `capBAM.maxDepth` at -1 | NOTE | two ceilings, and the smaller decides |

**`ONE CHROMOSOME` was drafted as a FAIL and corrected to a WARN by measuring.** `n_eff(1, 50)` returns exactly 1, so the unbiased correction `n_eff/(n_eff - 1)` is `Inf` rather than an error: the **pipeline runs and publishes frequencies perfectly well**, and only an analysis degrades. Refusing a run at step 0 for that would be stricter than the thing being protected. The earlier draft's explanation also claimed the analysis layer "refuses such a pool", which it does not.

## An absent key, and the one rule where absence is a value

Z asked whether parameters with defaults were accounted for, and one rule was wrong because they were not.

**`dropZeroDepth` absent is `false`, not unknown.** It is read in a Groovy ternary at `scripts/7_vcf2freq.nf`, so a config written before the parameter existed leaves it `null`, `null` is falsy, and the run builds the no-zero-term expression -- behaving exactly as `false` while nothing says so. The first draft tested `= "false"` and therefore emitted **no finding at all** for a config with `minDP = 0` and the key missing, measured. That is the one combination that cannot tell it is in trouble, and it is precisely the migration hole's real exposure: someone copying an old `parameters.config` into a new project. The test is `!= "true"` now.

**Any later boolean read through a ternary inherits this**, which is why the comment says so rather than naming this parameter.

**Every other rule declines to judge a key it does not have, and that is correct.** After resolution an absent key means the project's config never defined it, so there is nothing to compare; inventing a verdict about a parameter nobody set would be worse than silence. A parameter set holding one irrelevant line produces no crash, no spurious finding, and one honest `NOT CHECKED` for the pileup pair.

Two cases cover this: an absent `dropZeroDepth` with `minDP 0` must be reported, and a near-empty set must produce nothing but that one note. The first fails when the rule is reverted to `= "false"`.

`is_num` was also replaced while here. It had a nested parameter expansion meant to reject a lone `.` and was too clever to read; it is a plain character-class test now, with the arithmetic left to awk.

## What is deliberately not in it

**A setting that merely produces fewer sites.** `minDP 20` against `minDP 5` is a scientific choice and this has no opinion on it. The line is: does it make the run produce NOTHING, or silently change what a published number means?

**Anything that needs runtime data.** `cutadapt.min_length` above the `-l` that `ClipReads` computes discards every read and exits 0 -- the template says so -- but the length it is compared against does not exist until the step runs, so it cannot be judged from a configuration.

**Any repair.** Nothing here rewrites a value or picks one. It says what will happen and stops or does not.

## Coverage, and the two places a case could be hollow

- **12 rule cases in `03_helpers`**, static cost, calling the helper directly over the shipped defaults with one assignment replaced. The first of them asserts **silence on the defaults**, which is the case most likely to rot: a rule added with a wrong threshold makes every ordinary run noisy, and a user who sees a warning on a default stops reading warnings.
- **5 wiring cases in `02_launcher`**, against a stubbed `nextflow` so they need no JVM: that `check_project.sh` calls the helper, renders each level, folds the explanation, lets a `FAIL` decide its exit status, and reports the helper's own absence rather than passing over it.
- **3 step-0 cases in `05_guards`**: a FAIL stops the run with nothing published, a WARN does not, and the defaults raise no finding at all. Each uses a **fresh** sandbox rather than the baseline one, because changing a parameter in the baseline also trips the change guard and then one failure has two causes and no way to tell them apart.

**One assertion had to be rewritten and the reason generalises.** It looked for `Raise scaleMapQ above varQualMin` in the step-0 report, and `fold -s` had landed between `Raise` and `scaleMapQ`. **No multi-word phrase is safe to assert against folded output.** It now asserts the deeper indent, which says a wrapped explanation was printed at all and holds however the prose changes.

## What it did to the emptiness cases, the same day

The guards in `empty-results.md` were built hours earlier, and this **pre-empted two of their three cases**: they reached the step 6 and step 7 guards by setting `scaleMapQ = 15` and `sampleThreshold = 1.5`, and both are now refused at step 0 before the pipeline starts. The earlier stop is the better behavior and the guards are untouched, but two cases were left asserting something that no longer happened.

**The shape recurs and is worth naming: a new earlier check makes a later one unreachable by its original route, and the later one still needs a route.**

**The cross-sample guard now has no case at all.** The only configuration that emptied that filter was `sampleThreshold` above 1. Measured while looking for another door: at `sampleThreshold 1.0` with `poolSize 2`, 39 of 135 sites still survive, and sensitivity is not the binding clause at fixture depth. No value step 0 permits empties it. The guard stays, as defense against DATA rather than configuration -- a cohort whose variants are shared by too few pools -- and `04_pipeline` carries a comment saying why a case cannot be written, so nobody writes one that cannot work.

**The call-set guard was rerouted, after two dead ends worth not repeating:**

- `scaleMapQ = 15` is the same failure by a shorter path, and step 0 refuses it.
- `baseQualMin = 60` **does nothing at all**. Measured on the fixture's own ready BAMs: 123 records at `-Q 30` and 123 at `-Q 60`, indels included. A synthetic BAM with uniform Q40 and one variant site had said otherwise, which is the second time in one session a synthetic fixture gave a confidently wrong answer about a bcftools flag.
- `varQualMin = 500` works. No read carries a mapping quality near it, so every read is skipped: 0 records against 123.

**And the case is stronger for needing two settings.** `varQualMin = 500` alone trips the rule here, so `scaleMapQ` goes to 600 to clear it, which is permitted with a warning -- correctly, because that pair does emit records for ordinary data. So the case passes only when BOTH layers work: this check permissive enough to let it through, and the step 6 guard catching what a configuration cannot reveal.

## The selector, again

`dev/scripts/select-tests.py bin/check_parameters.sh` did not select `02_launcher`, because `check_project.sh` calls the helper by full path rather than by bare name and the derived graph cannot see that. Declared in that suite's `# covers:`. This is the third undeclared data dependency found in one day, after `parameters.config.template` and `metadata.csv.template`, and they are all the same shape: the graph reads imports, and a file named inside a string is invisible to it.
