# Every step lost its log on every failure path

**Written 2026-09-29, against the tree at `85eb380` plus uncommitted work.** Found by Z asking one question about the emptiness guards added the same day: *"The error messages you added in variant call and vcf2freq, do they show up in the last run log?"* They did not, and neither did anything else, in any step, on any failure.

## The defect

Every process ended with the same six lines:

```sh
mkdir -p ${dir_log}
{
    echo ""
    echo "===== run=... | session=... | attempt=... | $(date -Is) ====="
    cat .command.log
} >> ${dir_log}/<name>.log
```

At the **bottom** of the script. Under `set -eo pipefail` any failing command exits immediately, so that block was reached only when the task succeeded. A tool crash, a refusal, an out-of-memory kill: the log was written to `.command.log` in the task directory and never copied out. `Logs/<step>/` held nothing for exactly the runs a person needs a log for.

Nextflow still printed the text to the terminal and `.nextflow.log`, which is why this survived: it looked fine from the console and was empty on disk. On a cluster, where the console is a scheduler's output file somewhere else, `Logs/` is what a person has.

`0_verify_environment.nf` had the fix from the start -- an `archive_logs` function called on both paths, with a comment saying why. Nothing else did.

## What was measured

Four designs, five failure modes, each one a real Nextflow run in an isolated project, counting lines that actually landed in `Logs/`:

| design | success | tool failure (`set -e`) | explicit `exit 1` | SIGTERM | SIGKILL |
|---|---|---|---|---|---|
| **A**, the shipped tail copy | written | **lost** | **lost** | **lost** | **lost** |
| **B**, `trap archive_log EXIT` | written | written | written | written | **lost** |
| **D-merged**, `exec > >(stdbuf -oL tee -a LOG) 2>&1` | written | written | written | written | **written** |
| D-split, a tee per stream | written | written | written | written | written, **reordered** |

Every surviving cell carried the header, the process's own messages **and** tool output (a `bcftools` version line and an `ls` error), so tool chatter is captured in all three of B and D.

**D-merged is the only design green in every column**, and the column that separates it from B is the one that matters most here: a cgroup OOM kill is SIGKILL, which no trap can catch. That is the failure a collaborator hit on an HPC cluster, reporting that the pipeline "is not writing anything to output folder".

D-split was measured only to rule it out. It reorders lines, because two `tee` processes race, and its one advantage -- keeping `.command.err` populated -- Z ruled unnecessary.

## Two hypotheses that were wrong, both mine

**"Removing `>&2` is needed so the message reaches the log."** It is not. `.command.log` is the COMBINED stream. Restored the redirects, re-ran, and the text reached `Logs/` identically. `archive_log` alone was the fix at that point, and the `>&2` removal Z asked for changes only which section Nextflow files it under in the terminal. The redirects are left off because every other `echo` in those scripts writes to stdout.

**"Generalising step 0's `log_message` would fix it."** It would not. `log_message` writes each line to a **task-local** report file, which `archive_logs` moves at the end -- so under SIGKILL it scores **0 lines in `Logs/`**, exactly as the trap does. The shape that survives is writing straight to the `Logs/` path. Z proposed `log_message` and was right about the principle (write as it happens) while that specific mechanism would have measured as nothing.

## The change

21 processes across 10 files. The tail block and the `archive_log` added earlier the same day both removed, replaced at the **top** of each script by:

```sh
mkdir -p ${dir_log}
{
    echo ""
    echo "===== run=... | session=... | attempt=... | $(date -Is) ====="
} >> ${dir_log}/<name>.log
exec > >(stdbuf -oL tee -a ${dir_log}/<name>.log) 2>&1
```

The header and its separating blank line are byte-identical to before, so run-to-run separation inside each log file does not change.

**`9_completion.nf` was already writing its block twice**, on two different paths -- someone had met this problem there and solved it locally. Both copies are replaced by the one prologue.

**Step 0 is untouched.** `log_message`, `archive_logs` and its thirteen `cat .command.log` sites stay, because step 0 is building the verification **report** that ships to `Output/Reports/` as a deliverable a user reads. That is an artifact, not a log, and none of the above applies to it.

## Why nothing blocked it

| checked | result |
|---|---|
| `.command.out` still captured | yes -- `tee` inherits the original stdout |
| the user still sees a failure message | yes -- Nextflow printed it under "Command error:" with `.command.err` empty |
| concurrent tasks appending to one file | no risk: every log name is per-task wherever tasks run in parallel. The four shared names belong to processes that run once |
| log volume | unchanged. The old tail already copied tool output; this writes the same bytes incrementally. Z's real run is 2.1 MB of logs, largest file 523 KB |
| `exec` disturbing anything reading stdin | no: every `read`/stdin use is inside step 0 |
| `dryrun` reusing these processes | no: it includes only step 0's `VerifyEnvironment` and pure functions |
| `stdbuf` availability | pinned in the release environment, coreutils 9.12. Plain `tee` also survived the kill, so `stdbuf` is insurance rather than a dependency |

`04_pipeline` passes 51 of 51 afterwards, which matters because **nine of its assertions read step logs and grep their content** -- the content is unchanged, only the timing is.

## What is still true

**SIGKILL is not fully solved and cannot be.** The tee flushes per line, so what the task had reached is on disk -- but a cgroup OOM kill kills `tee` too, so the final partial line can be lost. There is no design that survives having its whole process group killed; writing incrementally is the best available and it is what this now does.

**`set -eo pipefail`'s reason is unrelated**, and it came up because Z reasoned from it. The recorded reason is in `createDepthFile.sh`: *"pipefail is load-bearing: the SAMPLENAMES pipeline below ends in `cut`, which succeeds whatever bcftools did."* Not about logs.
