# Installed modules

One directory per module, named exactly as the module is named. Each holds at least:

| File | What |
|---|---|
| `manifest.json` | `name`, `version`, `contract`, `summary`, and optionally `needs`, `gates` and `outputs` |
| `main.nf` | the module's own Nextflow pipeline |
| `citations.json` | the methods and packages your module should be cited with |

A module is a pipeline in its own right. It imports what it wants from `analysis/lib/nf` by relative path and is launched directly; nothing in the frame includes it, so a module that is absent, or one whose directory has been removed, costs the others nothing.

**Import only the workflows you call.** An import you never use still couples you to it — a library workflow that is renamed or removed breaks every module naming it, called or not.

## What a `main.nf` starts from

```groovy
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { PublishResults } from '../../lib/nf/results.nf'

process Analyse {
    input:
    val target          // target.classes.frequencies.dir  - where the published tables are

    output:
    tuple val(target), path('result.*')

    script:
    """
    ...
    """
}

workflow {
    PublishResults(Analyse(channel.fromList(analysisPlan('mymodule').targets)))
}
```

`analysisPlan` takes the module's own name and returns one target per results directory the invocation covers. `PublishResults` takes what you produced for one of them and installs it in `target.results`. The artifact classes it marks required are the `needs` from your `manifest.json`, so you state what you read once and nothing repeats it. It recomputes the pipeline's own partition of the runs, so two runs that produced the same tables are one target and are analysed once.

A module ships no configuration. `PoolSeqFlow analysis` assembles it — the installation's `analysis/frame.config`, then the project's `analysis.config`, then `<module>.config` — and `frame.config` carries what the pipeline gets from `nextflow.config`, which Nextflow does not read for a module: `bin/` on the task PATH, conda, and the resource ceiling.

## Rules

Follow these and a module written by anyone runs beside the ones shipped here. Most of them exist because of a failure that has already happened once.

### The shape

1. **`main.nf` is required, and the directory name must equal the manifest's `name`.** A directory holding a manifest and no `main.nf` is refused while the DAG is built — before the results folder is cleared — and it stops **every** invocation, not only yours. A directory holding no manifest at all is passed over in silence, so a half-finished install is harmless.
2. **Import the library by a literal relative path**, `'../../lib/nf/plan.nf'`. An interpolated include path is rejected both by `nextflow lint` and at runtime, and the literal resolves in a checkout and in an installation alike because a module sits at `analysis/modules/<name>/` in both.
3. **Import only the workflows you call.** An unused import still couples you: a library workflow that is renamed or removed breaks every module naming it, called or not. Import breadth is coupling breadth.
4. **Report your own version.** `manifest.json`'s `version` is the module's, and it moves on the module's timetable — never the pipeline release's. That separation is the reason modules are installed separately at all. The modules published with PoolSeqFlow use **`YYYYMMDD.NNN`** — the day the manifest changed, then a counter from `001` for that day — bumped whenever the manifest is touched and committed with the change. Any version string works as far as the frame is concerned, but `install` picks the newest with `sort -V`, so whatever you choose has to order correctly under it.

### Declaring what you read

5. **`needs` in your manifest is the only place you say what you read.** `analysisPlan('yourname')` looks it up there, and so does the verification that runs before you, so the two cannot disagree about which artifacts were checked.
6. **`contract` is the published-table contract you speak** — `freq-1` today. It is bumped only when a column's name or meaning changes, which has not happened since the project's first commit.

The classes `needs` may name:

| Class | What | Produced by |
|---|---|---|
| `frequencies` | `*_freq.tsv`, one row per allele | step 7 |
| `depths` | `*_depth.tsv`, one row per site, counts in REF-then-ALT order | step 7 |
| `vcf` | the called VCF | step 6 |
| `bams` | `*_ready.bam`, cleaned and indexed | step 4 |
| `histograms` | `*_depth_histogram.tsv`, one per library, genome-wide | step 5 |

A name no class answers to is refused while the DAG is built. Without that it would simply never be checked: a class is marked required by asking whether `needs` contains its name, which cannot notice a name that belongs to nothing.

**`histograms` may legitimately be absent from a sound project**, so weigh whether yours truly cannot run without it. A module that needs them should degrade per library and name the ones it had none for, rather than averaging over the survivors.

### Reading a published result

7. **Never write into the results tree.** Copy what you need out of it; a module that moves a published artifact damages the run that produced it. The pipeline's results are inputs and nothing else.
8. **Key on header names, never on column position.** Sample column order was non-deterministic before v2.1.1, so a module that counts columns reads some projects wrongly and every one of them silently.
9. **`TOTAL_AD` holds a depth-weighted frequency, not a count.** The name is inherited and wrong. Read it as what it is.
10. **Take the results directories from `analysisPlan`, never from directory names.** It recomputes the pipeline's own partition, so two runs whose tables are the same file are one target and are analysed once. Parsing `Shared_2` out of a path is guessing at what the plan already knows.

### Configuration

11. **Every setting you add lives inside the `analysis` scope**, in a sub-scope named after your module. `moduleSettings('yourname', [chromosomes: [], minReads: 2])` takes your whole scope's defaults and returns the whole scope, with a key the defaults do not have refused by name. Ask for the scope once and read the map; there is no per-key call with a fallback, because one could not refuse anything — a misspelling would take the default and your module would produce nothing with nothing said about it. A **top-level** `params` key is caught and named where it is written: it reaches the recorded manifest, and the identity check would otherwise read it as a parameter the results were not produced with and refuse every analysis in the project.
12. **A module ships no configuration file.** `PoolSeqFlow analysis` assembles the three layers; you document the settings your module reads, and the user writes them into `<module>.config`.

### Writing your own results

13. **Publish through `PublishResults`, and never write into `target.results` yourself.** Hand it the target and everything you produced for it; the whole analysis moves into the folder under one rename, so the folder is only ever absent or complete. A module that installs its results one file at a time leaves a half-populated folder when it fails partway, and refuse-if-populated cannot tell that from a collision — so its own folder name becomes unusable for good.
14. **What you hand it must be real files.** `PublishResults` dereferences what Nextflow staged for exactly this reason: `cleanup = true` is set for analysis runs, so the work directory goes on success and a symlinked result becomes a dangling link. Anything you write anywhere else is yours to get right the same way.
15. **Emit the script that produced each result** into the folder beside it, in the same set of files you hand `PublishResults`. A result nobody can regenerate is the reproducibility gap this whole layer exists to close, so this one is **enforced, not asked**: publishing an analysis that carries no `*.R`, `*.r`, `*.Rmd`, `*.rmd`, `*.sh`, `*.py` or `*.jl` fails the run, names what you did produce, and publishes nothing. The folder is left exactly as the verification cleared it, so the retry is not refused.

15b. **Carry your own `citations.json`. It is required, like `manifest.json` and `main.nf`.** Every published analysis gets `CITATIONS.md` and `references.bib` written into its folder, in the same rename as the result. The frame contributes PoolSeqFlow, Nextflow and R; **the method your module implements and the R packages it uses are yours to declare**, because you are published separately and the frame cannot hold a list of citations for modules that do not exist yet. At the very least, name the libraries you call — a user cannot credit a package they never learn they depended on. The shape is `analysis/citations.json`'s, one entry per reference, keyed however you like; an entry naming `"r_package": "vegan"` has its version asked of R at run time rather than taken from what the environment pins, so it stays correct if someone repointed it. A directory without the file is refused at DAG-build time, before the verification clears a results folder, exactly as a missing `main.nf` is, and `modules install` refuses an archive that lacks one.

15c. **Declare an `outputs` entry for every file you publish, and say where it is explained.** Each is `{"file": "design.tsv", "summary": "one row per pool", "anchor": "the-experimental-design"}` — `file` may be a glob, `summary` is the one-line description the reader gets, and `anchor` names a heading of the manual this release ships. A module published separately has nowhere in that manual to point and gives `"url"` instead, in full. The frame renders one `README.md` from every module's declarations plus what every analysis carries anyway, so a folder found months later says how to read itself and no module invents its own way of saying it. Two things are checked for you: an `anchor` no heading answers to is refused before your module starts, and a `file` you declared and did not publish fails the publish with nothing written. **This is where a number that is not a measurement gets said to be one** — a bound, an estimate with an assumption behind it, a figure whose meaning changes with a setting. A table cell cannot carry that sentence and a `summary` plus a link can.

### Sharing what you derive

16. **Anything another module could want goes in `Analysis/Main`, through `publishIntermediate`.** It writes the provenance record and then the file, which is the invariant everything else reads: an intermediate that is there is one whose provenance can be read. It is one call rather than two so that the order is not yours to get wrong.
17. **Call `RestoreIntermediates` before you read one.** `PoolSeqFlow analysis complete` moves `Analysis/Main` to permanent storage, and the restore brings back the ones you name, a file at a time. It refuses anything derived from results the project no longer holds — a pipeline re-run leaves the identity check with nothing to object to and every intermediate under it stale, and the record beside each one is what sees that. An intermediate that is nowhere is the ordinary answer on a first run: derive it.

### Assumptions

17b. **Take the time axis and the series from `analysisPlan`, never from the metadata.** `target.design.time` carries the column, the kind, the unit, and one level per distinct value with an `index` and a `position`; `target.design.series` carries the pools of each series in time order, and `design.roles` says which key columns name a condition, a biological replicate and a technical one. Both are resolved once, by the frame, under settings the user declared — so every module in a project orders time the same way. **`position` is `null` for a categorical axis**, and that is the test: a rate per unit time is meaningless there, so check it rather than assuming an axis you can regress on. Anything worth knowing that is not an error is in `target.design.warnings`, which the verification report and the published README both render; read it if your output should repeat any of it.

17c. **Degrees of freedom come from `design.units`, never from `design.series`.** A series is one measurable trajectory; a **unit** is one independent biological entity, which is a series with its technical-replicate columns dropped. Two lanes of one cage are two series and one unit. Count units, stratify on units, and if your test needs independent replicates and `analysis.series.biologicalRep` is empty, refuse by name — the frame declares nothing it was not told, so an empty list means the user has not said which repeats are independent, not that there are none. `design.conditions` is the level above: units with the biological-replicate columns dropped too.

18. **If your statistic assumes something, refuse when it does not hold, and name the assumption.** A gate that silently passes is the failure mode; a gate that stops the run with `diploidy = 3, and this estimator assumes 2` costs a user one minute. Declare it in the manifest's `gates` as well — the frame carries that field, and enforcing it is currently the module's own job.
19. **A decision is yours to state, not the library's to have made.** Where a shared derivation needs a choice — a missing-site policy, say — take it as a required argument with no default, print it in what you write, and **key the intermediate's name on it**: `freqmatrix_pairwise.tsv`, never `freqmatrix.tsv`. Intermediates are reused by name, so a name that omits the decision hands the next module your assumption while its report claims its own.
20. **Print your assumptions on what you write.** A figure that leaves the project must carry the conditions it was computed under.

### Testing

21. **Make the statistics callable without starting Nextflow.** A Nextflow run costs about 21 seconds of startup, flat, so anything provable by calling a function directly should be a unit test of that function rather than an end-to-end run.

## Where they come from

This directory is empty in a fresh installation. Modules are installed separately from the pipeline, into this release's own installation, so a module installed for one release is never picked up by another.

```bash
PoolSeqFlow analysis modules available            # what is published
PoolSeqFlow analysis modules install <name>       # newest version this release can read
PoolSeqFlow analysis modules install <name> 1.2.0 # or exactly that one
PoolSeqFlow analysis modules list                 # what is installed here
PoolSeqFlow analysis modules uninstall <name>     # remove one, after confirming
```

`list` and `uninstall` read this directory and nothing else — no environment, no project — so they answer from anywhere. `list` marks a directory that holds a manifest and no `main.nf`, which is the state that stops every analysis run.

`available` and `install` read the **catalogue**, over the network, from `analysis/modules-index.tsv` on the repository's default branch. **A release carries no copy of it** — it is `export-ignore`d — because a module published after a release still has to be installable into it. `POOLSEQFLOW_MODULE_INDEX` points them at a URL or a local path instead, for a mirror inside an institution or a machine with no network.

## Publishing a module

A published module is a **gzipped tarball unpacking to `<name>/`**, with `manifest.json` and `main.nf` inside it, plus whatever else the module needs — its R, its config, its manual fragment. Then one row in the catalogue:

| Column | What |
|---|---|
| `name` | the module's name, and the directory it installs into |
| `version` | its own version, moving on its own timetable, never the pipeline's |
| `contract` | the published-table contract it reads. A release installs only its own |
| `url` | where the tarball is |
| `sha256` | the tarball's checksum |
| `summary` | one line, shown by `available` |

Several rows may name one module. `install <name>` takes the newest version whose `contract` this release speaks; naming a version installs exactly that one, which is what a paper's methods section should say.

The catalogue carries two headers of its own, and they are not interchangeable. **`#!index-format`** is the column layout, checked before a single row is read — the columns are parsed by position, so a release that met a layout it did not know would take the wrong field from each row, and it refuses instead. Bump it only when the columns change, which stops every already-published release from reading the file. **`#!index-version`** is what is in the catalogue, in the same `YYYYMMDD.NNN` form, bumped on every publish; nothing is ever refused on it, because a release has to be able to read a catalogue newer than itself. `modules available` prints it, and `install` records it in the `.source` file beside the module — which is the only record afterwards of which catalogue a module came from.

`dev/scripts/bump-analysis-version.sh index` moves it, and `dev/scripts/check-analysis-versions.sh` refuses a change to the rows that left it behind.

Two rules the installer enforces, so build for them:

22. **The checksum must match before anything is unpacked.** An archive becomes code that runs on someone's machine, so a mismatch stops the install with nothing written. A row whose `sha256` is out of date makes the module uninstallable, not silently different.
23. **The archive must contain `<name>/manifest.json` and `<name>/main.nf`.** An archive that unpacks to a different directory name, or to the files bare, is refused as not a module. Build it as `tar -czf <name>-<version>.tar.gz <name>`.

Installing writes a `.source` file beside the module recording the name, version, contract, URL and checksum it came from, so an installation can account for every module in it.
