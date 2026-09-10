# Promotion — moving artifacts from the working volume to permanent storage

**Written 2026-08-31 at 15:18, against the tree at `7d65893`.** Everything about promotion itself still holds — five attachment points, five rows in the table, the same gates. One thing below describes `atomic_mv.sh` as it was for another seven hours: the staging fix landed the same evening and the reasoning is corrected in place.

`scripts/9_completion.nf`.

> **For the manual, not here.** The user-facing shape: outputs are written to `mainDir/Utilized/`, which mirrors `Output/`'s tree exactly, and move to `storageDir/Output/` once nothing needs them any more. Each byte crosses between the two volumes **once**, at the point where it stops being working data and becomes a result. That is what makes the fast disk worth having, and it is why `mainDir` must be durable rather than scratch.

## Why it is one file

*"Was this file really moved, and is the source gone"* is the question that decides whether a result exists, so every answer to it should be readable in one place. The alternative — a move at the end of each step's own module — spreads the same three lines across eight files and makes a missing one invisible.

## Why it wires at several points and not one terminal node

A single node at the end of the DAG would hold roughly 2.5–3× the raw data on the fast volume until the run finished, which is the opposite of the point. Trimmed reads can go as soon as alignment succeeds; alignments as soon as cleaning succeeds. The fast volume is released as the run proceeds.

## Three constraints, all established by probing

1. **Promotion cannot be driven off a staged input.** Six process inputs in this pipeline are pure ordering barriers rather than real reads — the process names an absolute `params.*` path in its script and never touches the staged copy. For those, "the consumer has the file" is a scheduling fact, not a data-flow one. So promotion is triggered by a completion **signal**, never by receiving the artifact.
2. **It is the LAST consumer that matters, not "the" consumer.** `Test.vcf` has two — step 7 always, step 8 whenever `annotate` is true — with no ordering between them. So a trigger can be parameter-dependent, and anything assuming one consumer will delete a file another step is about to read.
3. **Cardinality is fragile.** This module attaches as an **additional consumer** of an existing channel, alongside the real consumer and never in front of it. Nothing upstream changes shape, so there is nothing to flip. That mattered most while every singleton rode an implicit value channel, where inserting an operator would have turned it into a queue channel and silently reduced N tasks to 1 with the run still reporting success.

## Why the artifact→gate table is written out

Nextflow's own dependency graph cannot answer this, and all three limits were found by probing:

- it **asserts dependencies that are not reads** (the six ordering barriers above);
- it **misses reads that are never declared** — `VerifyAll` and `CheckMetadataFile` take `val` for files and then read them by absolute path into other tasks' work directories;
- it **describes one session**, while an artifact's lifetime here spans runs. This pipeline resumes by looking at the filesystem, `-resume` is unused, and `cleanup = true` removes the work directories behind it.

The table grows **one row per stage**, each landing with the change that makes it true. A stage with no row yet returns null and is recorded without moving anything. A stage **not in the table at all is an error**, not a no-op — a mistyped name would otherwise promote nothing, silently, on every run from then on.

`subpath` is relative to both roots: `Utilized/` and `Output/` differ only in their root, which is what makes promotion a move between two spellings of one path.

## What enters Utilized, and what does not

**Something enters `Utilized` exactly when it will be read again.** Artifacts with no consumer at all — unpaired reads, trim reports, the FastQC htmls, both step 5 reports — are never "an output that becomes an input", so they are written straight to `storageDir`.

Row-by-row reasoning:

- **Trimmed reads** are step 3's only input and nothing after step 3 reads them, so a sample's alignment succeeding releases that sample's reads. The `*_val_*` reads in the same directory are deliberately absent: `ClipReads` deletes them outright, so they never become a result.
- **The FastQC zips** are working data by the same rule — `ClipReads` unzips them to work out its clipping bounds — but their gate is `ClipReads` finishing rather than alignment, which is why they are a row of their own. The htmls are not here: nothing reads those.
- **Aligned BAMs** live in a flat directory rather than per-sample, so the key selects the *file* instead of the folder. That is why `subpath` and `patterns` are both resolved against the key.
- **Ready BAMs** are the first artifact with two consumers — step 5 for reports, step 6 for calling — so the gate is both, assembled at the call site. The index travels with its BAM: nothing reads the index by name, both step-5 processes just expect it beside the file, so promoting one without the other would leave a BAM that looks complete and is not.
- **The called VCF** also has two consumers, the second conditional. This is the one place where "the step that consumes it" is not a single step.

## One task, one destination

**One promotion task per (producing variant, stage, key), not one per member.** The five attachment points hang off channels carrying variants, so a shared artifact would otherwise get N promotion tasks over one set of files — and that is where `atomic_mv.sh`'s missing lock actually bites: two concurrent callers stage through the same `${DEST}.part`, and one's EXIT trap deletes the other's staged copy between its two `mv` calls.

**That mechanism was replaced seven hours after this was written**, in `f4f1104`: each caller stages through its own `mktemp -d` and `${DEST}.part` no longer exists anywhere. The rule above is unchanged; what changed is how much it is worth. N promotion tasks over one set of files is duplicated work now, not a race that can lose the artifact. `concurrency.md` carries the measurements on both sides of that fix.

**One destination**, which is a property of the results layout rather than of this file. A variant writes to the single directory named for whoever owns it — `All_Runs`, `Shared_<N>` or one run — and every member reads it there, so there is nothing to copy into a second place. This briefly carried a *list* of destinations; the one-results-tree layout made it dead and it went.

## Details that prevent a wrong-sample promotion

- **The key is derived from the completion signal, not from pairing two channels.** Two channels would be matched by arrival order, and a promotion aimed at the wrong sample would delete a file another task still needs.
- **`stage` stays a separate input** because it is a literal at the call site and therefore a value channel that broadcasts. The run travels *with* the key: they are one fact — who released what — and separating them would match them by arrival order too.
- **The source must be GONE, not merely copied.** `find_artifact.sh` reports the first root that has an artifact and the working volume is searched second, so a copy left behind is harmless now and wrong the moment the promoted one is edited, replaced or reset — it would go on satisfying every later skip check.
- **"Already promoted" is the ordinary case; "in neither root" is not.** The gate reported success, so the artifact has to exist somewhere, and the likeliest cause is a wrong subpath in the table.
- **Patterns are quoted** so the loops iterate over the patterns themselves rather than whatever they happen to match in the task directory.

## The consumer-less outputs problem, CLOSED by the one-results-tree layout

This note used to say they were still open: written by their own process to `run.dir.output.*`, which for a shared variant would be the **lead member's** storage and no one else's, so they needed the destination handling promoted artifacts get.

**The layout removed the problem instead.** `variants.nf` gives every variant its own `dir.outputs` — `${variant.storageDir}/Output${owner}`, where the owner is `All_Runs`, `Shared_<N>` or one run — so a consumer-less output written to `run.dir.output.*` lands in the directory that variant owns, whoever its members are. There is no lead member's `Output/` any more, so there is nothing to distribute. Verified in `scripts/5_reports.nf`, whose three reports are exactly this class.

## How the wrapper finds a project's results directories

`clean` and `reset` have to name every directory a run wrote, and under a run table those are `Output/<RunID>`, `Output/All_Runs` and `Output/Shared_<N>`.

**`nextflow config -flat` is the wrapper's only path oracle, and it reports the BASE configuration** — so it cannot name `Output/<RunID>`, which the resolver builds per run.

**So the wrapper asks the disk, and specifically the COPY of the multi-run table that step 0 keeps beside the results.** That copy is written by the pipeline, at a path the wrapper already knows, and it describes the runs that actually produced what is there. Reading the user's own table instead would be a third copy of the rule that decides where results go — the two that already exist are only kept in step by a test — and it would answer wrongly for a project whose table has since been edited or deleted.

**Shared directories are found by their `members.txt` rather than by the table**, because their names are assigned by the divergence analysis and are not in it.

**Both helpers end in an explicit `return 0`.** The script runs under `set -e`, a function's exit status is its last command's, and the last command is a test that is FALSE in the ordinary single-run case — so without it `ROOTS=$(run_storage_roots …)` aborted `reset` silently, before it printed anything at all.

`Utilized_<RunID>` sits beside `Utilized` under mainDir, so the glob prefix is ours and cannot pick up anything of the user's.
