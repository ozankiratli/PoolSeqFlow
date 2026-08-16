# Resources

Two values size an entire run:

```groovy
threads = 8          // cores a single task may use
memory  = '24 GB'    // memory ceiling for a single task
```

Every tool's thread count is derived from `threads`. **Do not set the per-tool counts by hand** — they live in the `cores` block, which exists to be computed, not edited.

## The ladder

| `threads` | Trim Galore `--cores` | actual threads | BWA `-t` | cutadapt | FastQC `-t` | SAMtools `-@` | Java GC |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 1 | 1 | 1 | 1 | 0 | 1 |
| 4 | 1 | 1 | 4 | 4 | 2 | 1 | 2 |
| 8 | 4 | 8 | 8 | 8 | 2 | 1 | 2 |
| 12+ | 8 | 12 | 8 | 8 | 2 | 1 | 2 |

Three details explain the shape of that table.

**Tools are quantised to where their scaling flattens.** Each count is the largest power of two at or below `threads`, capped at 8. Past that point the published scaling for these tools returns very little, so the cores are better spent on another task.

**Trim Galore's `--cores N` really runs N+4 threads** — N workers, two decompressors, a batcher and a writer. The ladder picks the largest N whose *full footprint* still fits in `threads`, which is why 4 cores yields `--cores 1` rather than `--cores 4`. The `--cores 1` case is the exception: it bypasses the worker pool entirely and is genuinely single-threaded.

**SAMtools' `-@` counts additional threads**, so `0` means one core and `1` means two.

## How the numbers reach the tools

Each process declares what it needs with the `cpus` directive and passes that same number to its tool as `task.cpus`, so there is exactly one value per task and nothing can drift:

```groovy
process Align {
    cpus { params.cores.bwa }
    script:
    """
    bwa mem -t ${task.cpus} ...
    """
}
```

| Process | Reserves | At `threads = 8` |
|---|---|---|
| `TrimReads` | `params.cores.trimTotal` | 8 |
| `ClipReads` | `params.cores.cutadapt` | 8 |
| `Align` | `params.cores.bwa` | 8 |
| `SortCleanBam` | `params.cores.samtools + 1` | 2 |
| `BuildSnpEffDb`, `AnnotateVariants` | `params.cores.javaGc` | 2 |
| every other step | *(single-threaded)* | 1 |

!!! note "`fixmate` is a deliberate exception"

    Inside `SortCleanBam`, every stage of the streamed pipeline is given `task.cpus - 1` except `samtools fixmate`, which gets `params.threads - 1`. That is intentional: fixmate's algorithm scales further than the sort and markdup stages around it, so it is allowed more of the machine than the task reserves.

This is more than bookkeeping. **Nextflow decides how many tasks to run at once by comparing `cpus` against the resources available**, so an under-declared task leads to oversubscription — the machine runs more work than it thinks it is. Overriding `cpus` in a profile automatically changes what the tool is told, because both come from `task.cpus`.

`TrimReads` is the one place the number is not passed through unchanged. Its reservation is Trim Galore's *footprint*, so the script maps back to the worker count:

```groovy
cpus { params.cores.trimTotal }                  // 8 at threads = 8
trim_cores = task.cpus > 4 ? task.cpus - 4 : 1   // -> --cores 4
```

Reserving the worker count instead would understate the task by four threads. The guard covers `--cores 1`, which is genuinely single-threaded.

## `threads` must fit the machine

Because tasks reserve what they really use, a request larger than the available cores fails immediately rather than quietly oversubscribing:

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

Set `threads` to the cores you actually have — on HPC, the size of one node.

Note the consequence on a small machine. At `threads = 8`, a single `TrimReads` task reserves all eight, so samples are trimmed one at a time instead of three at once. That is slower in wall-clock than running three concurrently at twelve threads each on eight cores — and it is also the only version of that arrangement which respects the machine. See [Threads are budgeted, not divided](../concepts/design-decisions.md#threads-are-budgeted-not-divided).

## `resourceLimits` is a ceiling, not an allocation

`nextflow.config` caps requests using the same two parameters:

```groovy
process {
    resourceLimits = [ memory: params.memory, cpus: params.threads ]
}
```

If a task requests more than this, Nextflow reduces the request before submitting it, which prevents a job that no node can satisfy from queueing forever. It does **not** reserve anything and does **not** limit concurrency on its own — that is what `cpus` does. Set `threads` and `memory` to match the node you are running on.

## Java {: #java }

Two settings govern the JVM tools (FastQC, SnpEff):

```groovy
java {
    heapSize = '-Xmx8g'    // passed via _JAVA_OPTIONS
}

fastqc {
    memory = 2048          // megabytes, as a plain number
}
```

`fastqc.memory` must be a bare number — FastQC rejects `2G`.

`-XX:ParallelGCThreads` is **not** set here. It is applied per process from `task.cpus`, so the JVM always gets the cores that task actually reserved rather than a figure fixed in the config.

## Choosing values

| Situation | `threads` | `memory` |
|---|---|---|
| Laptop or workstation | Physical cores, minus one or two if you want the machine usable | Comfortably under total RAM — one task can use all of it |
| HPC node, exclusive | Cores on one node | Node memory |
| HPC node, shared | Cores your allocation guarantees | Memory your allocation guarantees |
| Debugging a failure | `1` | Generous |

`threads = 1` forces every tool to a single core, which makes a failing run reproducible and its logs readable. It is slow, but it removes concurrency as a variable.

Neither value can change your results — they are not tracked by step 0's parameter guard for exactly that reason. Tune them freely between runs.
