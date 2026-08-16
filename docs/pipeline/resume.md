# Resume Logic

PoolSeqFlow implements its own resume strategy rather than using Nextflow's. This page covers how it behaves; the reasoning behind replacing `-resume` is in [Design Decisions](../concepts/design-decisions.md#resume-is-filesystem-based).

## Two directories

| | |
|---|---|
| **`mainDir`** | Where the pipeline executes — `work/`, scratch, symlinks. A compute node's local disk. |
| **`projectDir`** | Where all outputs are permanently written and kept. Network storage, a group volume, a different mount. |

They may be the same path. The split exists to support environments where compute and storage are on different filesystems, which is common on HPC — not to impose that arrangement on people who do not have it.

Outputs are written to `projectDir` and **symlinked** into `mainDir`. Consequences:

- **No duplication.** Large BAMs and VCFs exist in exactly one place on disk.
- **No data movement.** Nothing is copied between filesystems when a run ends.
- **Automatic step-skipping.** Every step checks `projectDir` for its own outputs and skips itself if they are there, regardless of the state of `work/`.
- **Resilience.** The check depends on nothing but the storage the results are already in, so it survives cluster timeouts, reboots and `work/` cleanups.

## There is no `-resume`

This strategy **replaces** Nextflow's `-resume`, and the wrapper never passes that flag. Two reasons it could not work here even if it were passed:

- `cleanup = true` deletes task working directories once a run completes. `-resume` replays task outputs *from* those directories; after a successful run there is nothing to replay.
- Several steps delete their own inputs once consumed. That leaves the upstream task's recorded outputs dangling, which invalidates the cache entry regardless.

So `./PoolSeqFlow run` is both "start" and "resume". `./PoolSeqFlow resume` survives as a deprecated alias and prints a notice.

To start genuinely from scratch:

```bash
./PoolSeqFlow reset
```

This clears `work/`, the Nextflow metadata, and the `Output/`, `Logs/`, `Reports/` and `Reference/` folders in `projectDir`. It also clears `.poolseqflow_params` and `.poolseqflow_rgtags`, which would otherwise fail the next run's consistency checks against outputs that no longer exist. It requires typing `DELETE_MY_ANALYSIS` to confirm.

## What a resumed run looks like

Every process is still submitted. Step-skipping happens *inside* each task, not before it, so a fully resumed run submits roughly one job per process per sample. Those jobs test for a file, create a symlink, copy two log files and exit — but on a scheduler they are real submissions with real queue time.

The log lines to look for are the `COMPLETED` messages that follow a "Found existing" line:

```text
ALIGNING Sample1: Found existing BAM file
ALIGNING Sample1: Found: /storage/project/Output/Aligned/Sample1.bam
ALIGNING Sample1: Creating symbolic link...
ALIGNING Sample1: COMPLETED
```

## Partial-stage resume

Step 7 is a chain of five sub-steps, and each checks for the outputs of every *later* stage as well as its own. If the frequency tables already exist, the earlier sub-steps create an empty placeholder and exit rather than redoing work whose result was superseded. This is why a partially completed step 7 resumes correctly even though its intermediates have been deleted.

## Interrupted moves

A plain `mv` across a filesystem boundary is a copy followed by an unlink. A job killed mid-move would leave a **truncated file under its final name**, which existence-based resume would then accept as a completed step.

All cross-filesystem moves go through `bin/atomic_mv.sh`, which stages via a `.part` file and renames into place. An interrupted move leaves a `.part` that no check looks for, and the step simply runs again.

## What resume does not protect you from

"The output exists" is not "the output is correct for your current settings". A file produced under `poolSize = 50` is indistinguishable from one produced under `poolSize = 100`.

That gap is closed by the step 0 guardrails, which record the analysis parameters and `RGTags.csv` behind a set of outputs and stop the run when either has changed. See [Step 0](steps.md#step-0-verify-environment).

## Cleaning up

| Command | Removes |
|---|---|
| `./PoolSeqFlow clean` | Nextflow work directories — the empty hash-prefix folders `cleanup = true` leaves behind |
| `./PoolSeqFlow reset` | All progress: `work/`, Nextflow metadata, `Output/`, `Logs/`, `Reports/`, `Reference/`, and the two consistency records |

`clean` is safe at any time and does not affect resume — nothing in `work/` is consulted by the skip logic. `reset` deletes results.

!!! danger "Never delete `projectDir` contents while a run is in flight"

    Task working directories contain symlinks *into* permanent storage. Removing the target breaks links that are actively in use, and the failure will not be obvious.
