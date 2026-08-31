# Installed modules

One directory per module, named exactly as the module is named. Each holds at least:

| File | What |
|---|---|
| `manifest.json` | `name`, `version`, `contract`, `summary`, and optionally `needs` and `gates` |
| `main.nf` | the module's own Nextflow pipeline |

A module is a pipeline in its own right. It imports what it wants from `analysis/lib` by relative path and is launched directly; nothing in the frame includes it, so a module that is absent, or one whose directory has been removed, costs the others nothing.

**Import only the workflows you call.** An import you never use still couples you to it — a library workflow that is renamed or removed breaks every module naming it, called or not.

## What a `main.nf` starts from

```groovy
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/plan.nf'

workflow {
    analysisPlan('mymodule', ['frequencies']).targets.each { target ->
        // target.classes.frequencies.dir  - where the published tables are
        // target.results                  - the folder this analysis writes to
    }
}
```

`analysisPlan` takes the module's own name and the artifact classes it cannot run without, and returns one target per results directory the invocation covers. It recomputes the pipeline's own partition of the runs, so two runs that produced the same tables are one target and are analysed once.

A module ships no configuration. `PoolSeqFlow analysis` assembles it — the installation's `analysis/defaults.config`, then the project's `analysis.config`, then `<module>.config` — and `defaults.config` carries what the pipeline gets from `nextflow.config`, which Nextflow does not read for a module: `bin/` on the task PATH, conda, and the resource ceiling.

## Rules

Follow these and a module written by anyone runs beside the ones shipped here. Most of them exist because of a failure that has already happened once.

### The shape

1. **`main.nf` is required, and the directory name must equal the manifest's `name`.** A directory holding a manifest and no `main.nf` is refused while the DAG is built — before the results folder is cleared — and it stops **every** invocation, not only yours. A directory holding no manifest at all is passed over in silence, so a half-finished install is harmless.
2. **Import the library by a literal relative path**, `'../../lib/plan.nf'`. An interpolated include path is rejected both by `nextflow lint` and at runtime, and the literal resolves in a checkout and in an installation alike because a module sits at `analysis/modules/<name>/` in both.
3. **Import only the workflows you call.** An unused import still couples you: a library workflow that is renamed or removed breaks every module naming it, called or not. Import breadth is coupling breadth.
4. **Report your own version.** `manifest.json`'s `version` is the module's, and it moves on the module's timetable — never the pipeline release's. That separation is the reason modules are installed separately at all.

### Declaring what you read

5. **The `needs` in your manifest and the list you pass to `analysisPlan` must be the same list.** The verification runs `analysisPlan(module, needs-from-the-manifest)`; your `main.nf` runs `analysisPlan('yourname', [...])` with its own. If the two disagree, the check that ran covers a different set of artifacts from the one you then read.
6. **`contract` is the published-table contract you speak** — `freq-1` today. It is bumped only when a column's name or meaning changes, which has not happened since the project's first commit.

The classes `needs` may name:

| Class | What | Produced by |
|---|---|---|
| `frequencies` | `*_freq.tsv`, one row per allele | step 7 |
| `depths` | `*_depth.tsv`, one row per site, counts in REF-then-ALT order | step 7 |
| `vcf` | the called VCF | step 6 |
| `bams` | `*_ready.bam`, cleaned and indexed | step 4 |

### Reading a published result

7. **Never write into the results tree.** Copy what you need out of it; a module that moves a published artifact damages the run that produced it. The pipeline's results are inputs and nothing else.
8. **Key on header names, never on column position.** Sample column order was non-deterministic before v2.1.1, so a module that counts columns reads some projects wrongly and every one of them silently.
9. **`TOTAL_AD` holds a depth-weighted frequency, not a count.** The name is inherited and wrong. Read it as what it is.
10. **Take the results directories from `analysisPlan`, never from directory names.** It recomputes the pipeline's own partition, so two runs whose tables are the same file are one target and are analysed once. Parsing `Shared_2` out of a path is guessing at what the plan already knows.

### Configuration

11. **Every setting you add lives inside the `analysis` scope.** A new **top-level** `params` key makes every analysis run refuse: it reaches the recorded manifest, and the identity check reads it as a parameter the results were not produced with.
12. **A module ships no configuration file.** `PoolSeqFlow analysis` assembles the three layers; you document the settings your module reads, and the user writes them into `<module>.config`.

### Writing your own results

13. **Write to a temp location and move in on success.** `bin/atomic_mv.sh` is on the task `PATH` and stages through a `.part` name for exactly this. A results folder that already holds an analysis is refused, so a crashed run that left a partial folder makes that folder name unusable for good.
14. **Publish a real copy or a real move, never a symlink.** `cleanup = true` is set for analysis runs, so the work directory is removed on success and a symlinked result becomes a dangling link.
15. **Emit the script that produced each result** into the folder beside it. A result nobody can regenerate is the reproducibility gap this whole layer exists to close.

### Assumptions

16. **If your statistic assumes something, refuse when it does not hold, and name the assumption.** A gate that silently passes is the failure mode; a gate that stops the run with `diploidy = 3, and this estimator assumes 2` costs a user one minute. Declare it in the manifest's `gates` as well — the frame carries that field, and enforcing it is currently the module's own job.
17. **A decision is yours to state, not the library's to have made.** Where a shared derivation needs a choice — a missing-site policy, say — take it as a required argument with no default, print it in what you write, and **key the intermediate's filename on it**: `freqmatrix_pairwise.tsv`, never `freqmatrix.tsv`. Shared intermediates are reused by name, so a name that omits the decision hands the next module your assumption while its report claims its own.
18. **Print your assumptions on what you write.** A figure that leaves the project must carry the conditions it was computed under.

### Testing

19. **Make the statistics callable without starting Nextflow.** A Nextflow run costs about 21 seconds of startup, flat, so anything provable by calling a function directly should be a unit test of that function rather than an end-to-end run.

## Where they come from

This directory is empty in a fresh installation. Modules are installed separately from the pipeline, into this release's own installation, so a module installed for one release is never picked up by another.
