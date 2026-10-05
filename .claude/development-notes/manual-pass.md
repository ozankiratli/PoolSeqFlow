# Reading the manual for a release: the four shapes that keep coming back

**Written 2026-09-30, against the tree at `8e8a078` plus uncommitted work.** Lifted out of `dev/RELEASING.md` step 1, where it read as instructions to an agent rather than to Z, who writes the manual and does not need to be told how he writes.

The step itself keeps only what it asks of a person: read in document order, verify every claim against the code, and run `dev/scripts/check-manual-parameters.sh`.

## The four

**A count that moves with every commit.** Case counts, file counts, running totals. **The fix is to remove the number, not to correct it** -- a corrected count is wrong again on the next commit, and nothing will prompt anyone. A count tied to a tag or to a closed list is fine, because both stop moving.

**A warning about a bug that is fixed.** Nothing prompts you to delete one when the bug goes. The Variant Calling page warned that `filterFalsePositives.sh -h` prints a wrong formula long after it printed the right one.

**Developer shorthand in user-facing prose.** "The pipeline refuses", not "step 0 refuses". A reader following the manual has no model of which step is which, and a step number is also a thing that moves.

**A capability written as the only path.** "Each pool *can be set to* get its own", not "each pool gets its own". The manual is read as a promise about what the tool does, so a describable option stated as a default makes the tool sound less configurable than it is -- and advice built on the misreading follows. "Use your smallest pool" and "run separate projects" both survived in several places on exactly this.

## The parameter audit, and the half it cannot do

`dev/scripts/check-manual-parameters.sh` is silent when every settable key is named somewhere in the manual.

**It reads `nextflow.config` as well as the template, and that is the whole reason it exists.** The 2026-08-31 sweep found `dryRun` and `dryRunDir` undocumented because a template-driven audit cannot see a key defined anywhere else; `bwa.options` went the same way, and the whole tool had no row.

**It proves a name appears, not that the manual says what the parameter does.** The requirement is what it is, what it does, and how to set it. A substring match answers none of that, and it is loose on purpose: a short leaf like `align` is satisfied by the word appearing anywhere, and tightening it produces a false positive on every parameter documented in prose rather than as a literal, which is most of them. The commented-out knobs count as settable, because uncommenting one is what a user does.

## What the step no longer says, and why that is right

Step 1 used to point at "the extraction and the grep" in `.claude/development-notes/` **under the manual pass**. No such note existed, no script did it, and no case asserted it -- the step asked for an audit and pointed at a file that was not there. This note is not that pointer restored: the step now carries a command that runs, and a procedure that points into a dated note imports a description of the code as it used to be.
