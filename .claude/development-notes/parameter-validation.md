# Parameter validation: a plan, not a build

**Written 2026-09-29, against the tree at `85eb380` plus uncommitted work. PLANNED, for before the next release cycle.** Z's call, after the `scaleMapQ` / `varQualMin` measurement showed that a setting can be individually reasonable and fatal in combination, and that the pipeline had nothing anywhere that would say so.

## What is missing

**`scripts/0_verify_environment.nf` validates no parameters at all.** It checks the environment, the tools, the files and the tables. It does not check a single value in `parameters.config`, and `vcffilter` and `mpileupOptions` appear nowhere in it.

So every settings mistake is caught in one of three ways, all worse than step 0:

- **By a runtime guard**, minutes or hours in. `capBAM.histogramMax` in step 5, and as of this cycle the three emptiness refusals in steps 6 and 7.
- **By `PoolSeqFlow check project`**, which is optional and which many users will never run.
- **Not at all.** Which was the case for everything until this cycle.

## The rule for what belongs here

**Validate what produces nothing, or what silently changes what a number means. Never validate what merely produces fewer sites.**

`minDP = 20` against `minDP = 5` is a scientific choice and the pipeline has no business having an opinion. `scaleMapQ` below `varQualMin` produces an empty run, and `minDP = 0` with `dropZeroDepth = false` changes the published tables from "every cell measured" to "some cells are NA" - which every analysis module leans on. Those are not preferences.

This is the existing house rule read strictly: *fail loudly or document; never automate away a decision*. Validation is the loud failure. It does not remove a knob and it never picks a value.

## The catalogue, as far as this session established it

Detectable from the configuration alone, so they belong in step 0:

| setting | the wrong value | what happens now |
|---|---|---|
| `variantCall.scaleMapQ` vs `varQualMin` | below `varQualMin` | every read discarded, empty VCF, empty tables. **Measured at six thresholds** |
| `variantCall.scaleMapQ` | 1 to 10 | no adjustment at all, whatever was intended |
| `filterFalsePositives.sampleThreshold` | above 1 | every site removed. **Measured: 1.5 leaves zero of 135** |
| `filterFalsePositives.sampleThreshold` | 0 | the cross-sample filter is inert |
| `vcffilter.minDP` | 0 with `dropZeroDepth = false` | NA cells reach the published tables; the no-missing-cell guarantee the modules rest on is gone. Carried from the release triage as "`minDP > 0` is not validated" |
| `ploidy` | 0 or negative | `sensitivity` is infinite or negative and the false-positive filter is meaningless |
| `poolSize` | 1 | `basicstats` refuses a pool of one chromosome, four steps later |
| `variantCall.maxDepth` | a small positive number | mpileup's ceiling silently undercuts the per-sample cap step 5 measured |
| `capBAM.maxDepth` | a small positive number | caps nearly every read away, and it is not `-1` so nothing measures it |
| `fastqc.memory` | `'2G'` | FastQC rejects it. The template says "as a plain number" and that is the only defense |

Needs runtime data, so it belongs in the step that computes it rather than in step 0:

| setting | why step 0 cannot see it |
|---|---|
| `cutadapt.min_length` | cutadapt applies `-m` after the `-l` that `ClipReads` computes per sample, so whether it discards every read depends on a number that does not exist yet. **The template already documents this as "discards every read and exits 0"** |

`capBAM.histogramMax` is already guarded at runtime in step 5 and wants nothing here.

## The design point that matters: do not write the rules twice

`bin/check_project.sh` has to make the same judgements step 0 makes, and a project told one thing before a run and another during it is worse than either alone. This project already has the pattern for that - `00_static` asserts *"the per sample parameter table is the same on both sides"* and *"both sides agree on what a package spec may be"*.

**So the rules live in one place, and both callers read it.** The shape that works: a shell helper, because `check_project.sh` is bash and step 0 runs a shell script, and both can call the same thing where neither can call a Groovy function.

    bin/check_parameters.sh   reads the flat config, prints a verdict per rule, exits non-zero on a failure
      <- bin/check_project.sh      in its configuration section
      <- scripts/0_verify_environment.nf   through log_message, so it lands in the archived report

One implementation, one set of cases in `03_helpers` at static cost, and both callers exercised by the suites that already cover them.

**This supersedes the ad-hoc check added to `check_project.sh` this cycle.** The `scaleMapQ` / `varQualMin` verdict is currently written directly into that script with seven cases in `02_launcher` behind it. When the helper is built, that block moves into it and the cases move with it - **do not leave two copies**, which is exactly how the two sides drift.

## What it reads

Both callers need the **composed** values, not the raw settings, for the same reason the `check_project.sh` block already does: a project that pins `variantCall.mpileupOptions` by hand makes `scaleMapQ` and `varQualMin` inert, and judging the settings it was not built from reports a problem that does not exist. `nextflow config -flat` is the source, `-C` and `-q` are read out of the composed string, and an option string carrying neither is reported as unjudged rather than guessed at.

Step 0 already has the parsed configuration, so it needs no second parse.

## Sizing

Medium. The helper is the small part. What it carries: a rule per row of the catalogue above, each with a message naming the setting and what to do; two call sites; cases for the helper at static cost plus one through step 0; the move of the existing block out of `check_project.sh`; and a manual section - the troubleshooting page at `#empty-result-refusals` is where it belongs, since the refusals and the pre-run verdicts are two halves of one story.

**It is not a release blocker and it is not a module.** It goes in before the release cycle opens, because a release is when the manual is swept and these messages are user-facing text.
