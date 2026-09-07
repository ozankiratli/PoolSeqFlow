# The dry run

**Written 2026-08-31, against the tree at `7d65893`.** `dryrun.nf` is unchanged. One forward-looking clause about `members.txt` did not come true and is corrected below.

`dryrun.nf` and the preview it builds. The wrapper side — vetting the directory before `rm -rf`, why that one is the risky one — is in `wrapper.md`.

## Why it is a separate entry point AND a flag

Two halves of one job, and both are needed:

- **A separate entry point, not `-entry` on `poolseqflow.nf`.** The strict parser refuses `-entry` outright. `dryrun.nf` is what stops the pipeline running.
- **`params.dryRun` on top of it.** The flag is what tells step 0's stages to record *nothing*. An entry point without the flag would stamp the project's baseline from a preview — a real `.poolseqflow_params` for results that will never exist. So the workflow body refuses to start when the flag is absent, rather than assuming the wrapper set it.

## Everything the dry run is lives in one file, process included

The one place the pipeline departs from *entry points at the top, processes in `scripts/`*. It is deliberate: nothing else will ever include `DryRunTree`, and splitting it would put half of a self-contained feature somewhere it has no neighbours.

## The tree comes from the plan and nothing else

Every path in the preview is one a process will actually write to, because they are enumerated from the variant plan rather than from a template of the layout. A preview cannot therefore describe a layout the run will not produce. Same reason `sharedMemberFiles` and `sharingGroups` are *included* from `variants.nf` rather than reimplemented: the preview writes exactly the members file a real run would write, in exactly the directories it would write it in, and the preview and step 0's partition report cannot disagree about the grouping.

The results tree is enumerated in full. The working volume and the logs get one entry per directory rather than a mirror of their contents, because those trees are built and emptied while the run is in flight — a preview of them would be a preview of a moment.

What it enumerates is what the **pipeline** writes. `Analysis/` comes from a separate invocation with its own entry script and is not previewed here.

## No directory is ever marked as "already exists"

Tried and rejected. By the time anything can look, Nextflow has already created `workDir` and the session-reports directory, and step 0 has written its report — so a listing marked from disk reports that most of the tree exists, **when what put it there was the preview itself**. The question a reader actually has is whether the *project* has run before, and `.poolseqflow_version` answers exactly that. So the preview reads the stamp and says so in one sentence, and marks nothing.

## Flattened root names

A storage root becomes one directory in the preview — `home_user_2026_experiments_pool_store` — so that a deeply nested project does not open onto ten levels of empty directories.

Flattening is **not injective**, so two roots can collide. That is a label problem, not a layout one, so it is disambiguated with a numeric suffix rather than by refusing to preview. Roots are named in path order so the legend is stable and the suffix always lands on whichever root sorts later; the count of roots already sharing a base name *is* the suffix, so no loop is needed.

**A path belongs to the DEEPEST root containing it.** `mainDir` and `storageDir` are allowed to nest — only identity between them is refused — and attributing a contained root's tree to the outer one would file the results under the working volume.

If a planned directory falls under neither root the preview **throws** rather than dropping it. A preview that quietly omitted a directory would show a layout the run does not produce, which is the one thing it must never do.

## The tab-separated handoff, and the empty-field trap

The Groovy side passes `entries`, `roots` and `members` into the script block as TSV heredocs, read back with `IFS=$'\t'`. Descriptions contain spaces and commas and paths may contain either, so tabs are the only safe separator.

**A tab is an IFS *whitespace* character**, which means two in a row collapse into one and every field after an empty one shifts left. So the root's own entry carries `.` as its relative path rather than an empty string. This was a real misalignment before it was understood.

The nested `while read` loops each redirect from their own file, so the inner one cannot consume the outer one's stdin.

`printf '%s\n' $who` writing `members.txt` is **unquoted on purpose**: the names split back onto one line each, which is the format a real run writes.

**The clause that used to follow — *"and the analysis layer will read"* — did not come true.** `members.txt` is a record, rewritten every run, and nothing under `analysis/` reads it. The analysis layer recomputes `variantPlan()` rather than parsing what the pipeline left on disk, which is the better answer for the reason this file already gives about marking directories from disk: a record can be edited after the fact, and a recomputation cannot disagree with the run it describes.

## Labeling folders by step

A folder can belong to several steps — `VCF/` is written by 6, rewritten by 7, annotated by 8 — so the steps that fill a folder are accumulated across variants rather than taken from the first one seen. Each folder is labeled with the steps that fill *it*, not with its group's whole step list.

Descriptions resolve **first-wins**: the specific entries are added before the general ones, so a general entry can never overwrite a folder's own line.
