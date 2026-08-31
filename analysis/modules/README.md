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

A module ships no configuration. `PoolSeqFlow-analysis` assembles it — the installation's `analysis/defaults.config`, then the project's `analysis.config`, then `<module>.config` — and `defaults.config` carries what the pipeline gets from `nextflow.config`, which Nextflow does not read for a module: `bin/` on the task PATH, conda, and the resource ceiling.

## Where they come from

This directory is empty in a fresh installation. Modules are installed separately from the pipeline, into this release's own installation, so a module installed for one release is never picked up by another.
