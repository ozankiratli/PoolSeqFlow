# Design Decisions

PoolSeqFlow departs from stock Nextflow practice in several places. Each departure was made for a reason, and each one costs something. This page states both, so you can tell whether a behaviour you are seeing is a bug or the design working as intended.

---

## Configuration is a file, never a flag

**The decision.** Every setting lives in `parameters.config`. The `./PoolSeqFlow` wrapper accepts a single subcommand and rejects any further argument. There is no `--poolSize 50`.

**Why.** Two reasons, one about reproducibility and one about correctness.

A run described entirely by a file is a run you can version, diff, publish alongside a paper, and hand to someone else with a guarantee they will get the same numbers. Once any setting can come from the command line, the file stops being a complete record and the shell history becomes part of the method.

The correctness reason is sharper. Nextflow passes `--param` values as **strings**. So this:

```bash
nextflow run poolseqflow.nf --annotate false    # do not do this
```

sets `annotate` to the string `"false"`, and Groovy evaluates any non-empty string as true. Annotation stays switched on, no warning is printed, and the only symptom is that step 8 runs when you asked it not to. Written in the config file:

```groovy
annotate = false
```

it is a real boolean and behaves as expected. This class of failure is silent and type-dependent, and the only reliable fix is to remove the path that creates it.

**What it costs.** Sweeping a parameter across values means editing a file between runs rather than scripting a loop over flags. For a parameter sweep, copy the project directory or keep several config files and swap them into place.

---

## Resume is filesystem-based

**The decision.** Every step checks whether its own outputs already exist in `projectDir`, and skips itself if they do. This replaces Nextflow's `-resume` entirely; the wrapper never passes that flag. `./PoolSeqFlow run` is both "start" and "resume".

**Why.** Nextflow's cache lives in `work/`. It is invalidated by anything that removes or changes those directories, which for this pipeline is routine:

- `cleanup = true` in `nextflow.config` deletes task working directories once a run completes. `-resume` replays task outputs *from* those directories, so after a successful run there is nothing left to replay.
- Several steps delete their own inputs once the next stage has consumed them — the trimmed reads are removed after clipping, and each VCF is removed after the next filter produces its successor. That leaves the upstream task's recorded outputs dangling, which invalidates the cache entry regardless.
- On HPC, jobs hit walltime, nodes reboot, and scratch is purged on a schedule. A cache that lives in scratch does not survive the failure modes that actually interrupt long runs.

A check for "does this output file exist in permanent storage" survives all of that, because it depends on nothing but the storage the results are already in.

**What it costs.** Two things worth knowing.

Step-skipping happens *inside* each task rather than before it, so a re-run still submits every process to the scheduler. Those jobs exit almost immediately — they test for a file, create a symlink and copy two log files — but they are real submissions. Expect roughly one short job per process per sample on a fully resumed run.

More importantly, "the output exists" is not the same as "the output is correct for your current settings". A file produced under `poolSize = 50` looks identical to one produced under `poolSize = 100`. That gap is closed separately, by the guardrails [below](#the-run-refuses-to-mix-settings).

---

## Symbolic links instead of copies

**The decision.** Outputs are written to `projectDir` and a **symbolic link** is placed in the task's working directory pointing back at the permanent file.

**Why.** Pool-seq intermediates are large. A run with a dozen pools moves through hundreds of gigabytes of BAMs and VCFs. Nextflow's default is to publish outputs by copying them out of `work/`, which means every large file exists twice for as long as `work/` survives.

The separation of `mainDir` and `projectDir` exists for the same reason. On HPC, compute nodes usually have fast local scratch while the data must end up on a network-attached volume, and these are different filesystems. Writing results straight to permanent storage and linking back means:

- large files exist in exactly one place on disk;
- no data is copied between filesystems at the end of a run;
- any node that can reach permanent storage can continue the work.

`mainDir` and `projectDir` may point at the same path if you have a single storage location. The split is there to support the constraint, not to impose it.

**What it costs.** Symbolic links, which is why Windows is not supported — including WSL under some filesystem configurations. It also means a task's working directory is not self-contained: deleting `projectDir` while a run is in flight breaks links that are already in use.

---

## Threads are budgeted, not divided

**The decision.** One `threads` value sizes the whole run. Every tool's core count is derived from it through a fixed ladder, and each process reserves what it actually uses.

**Why.** The obvious alternative — divide the available cores evenly among concurrent tasks — assumes tools scale linearly with threads. They do not. Each tool here is quantised to the point where its published scaling flattens out, so extra cores go to another task instead of into diminishing returns.

The sharper reason is that a tool's advertised thread count is not always what it spawns. Trim Galore's `--cores N` runs **N+4** threads: N workers, two decompressors, a batcher and a writer. A process that declares `cpus 4` and then passes `--cores 4` is really using eight. Nextflow decides how many tasks to run concurrently by comparing `cpus` against available resources, so an under-declared task causes oversubscription — the machine ends up running twice the work it thinks it is.

PoolSeqFlow reserves Trim Galore's full footprint and maps back to the worker count in the script, so the declaration and the reality agree. The full ladder is in [Resources](../configuration/resources.md).

**What it costs.** Honest accounting is slower than optimistic accounting on a small machine. At `threads = 8`, a single trimming task reserves all eight cores, so samples are trimmed one at a time. Earlier behaviour ran three concurrently at twelve threads each on an eight-core box — faster in wall-clock, and a 4.5× oversubscription. A request larger than the machine now fails immediately rather than quietly degrading:

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

---

## The run refuses to mix settings

**The decision.** Step 0 stops the run when the analysis parameters, or `RGTags.csv`, have changed since the existing outputs were produced.

**Why.** This is the direct consequence of [filesystem-based resume](#resume-is-filesystem-based). Because a step skips itself when its output file exists, and the file carries no record of what produced it, changing `poolSize` and re-running would leave one `Frequencies/` folder holding tables computed under two different thresholds. Nothing downstream could detect that, and the mixture would be invisible in the output.

Two records are kept in the project directory:

| Record | Covers | Written by |
|---|---|---|
| `.poolseqflow_params` | Analysis-affecting parameters, mirrored to a read-only `Output/run_parameters.txt` | Step 0 |
| `.poolseqflow_versions` | Every pipeline version that has run here. Recorded only — a version change never stops a run | Step 0 |
| `.poolseqflow_rgtags` | The consumed `RGTags.csv`, ignoring line endings and trailing whitespace | Step 0 |

Path, resource and software parameters are excluded — they change where and how fast the work happens, not what the answer is. Anything added in a later release counts as analysis-affecting until decided otherwise, which is the conservative direction to err in.

**What it costs.** You cannot change a threshold and re-run to see the difference in place. The check names the folders to delete, and deleting them is what clears it — that is deliberate, because the alternative is a folder of results you can no longer attribute to a setting. See [Editing RGTags.csv after a run](../configuration/read-groups.md#editing-rgtagscsv-after-a-run).

---

## Moves across filesystems are atomic

**The decision.** All cross-filesystem moves stage through a `.part` file and rename into place, via `bin/atomic_mv.sh`.

**Why.** A plain `mv` across a filesystem boundary is a copy followed by an unlink, not an atomic rename. A job killed mid-move — walltime, preemption, a node failure — leaves a **truncated file under its final name**. Combined with existence-based resume, that is the worst possible failure: the next run sees the file, concludes the step is done, and builds everything downstream on a partial BAM.

Staging through a temporary name and renaming means an interrupted move leaves a `.part` file that no existence check looks for, and the step simply runs again.

---

## Steps delete their own inputs

**The decision.** Once a stage's output is safely in permanent storage, several steps delete the input they consumed — trimmed reads after clipping, each VCF after the next filter produces its successor.

**Why.** Peak disk usage on a Pool-seq run is dominated by intermediates that nobody needs once the next stage has run. Keeping every one of them would roughly multiply the storage requirement by the number of filter stages, for files that exist only to be consumed.

**What it costs.** You cannot inspect an intermediate after the fact without re-running from an earlier point, and it is part of why Nextflow's own cache cannot be used.

Note that this applies to the permanent copies too, not just the scratch ones: the step deletes the file the symlink resolves to. After a complete run, `Output/VCF/` holds the raw call set, the fully filtered VCF, and the annotated VCF if you enabled it — the per-stage intermediates between them are gone. Exactly which files survive is listed in [Directory Layout](../pipeline/directories.md#what-survives-a-completed-run).
