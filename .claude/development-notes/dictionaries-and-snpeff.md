# Step 1 — dictionaries and the snpEff database

**Written 2026-08-31, against the tree at `7d65893`.** Step 1 itself is unchanged. One sentence below leans on a rule in `atomic_mv.sh` that the `77fdbd7` overhaul narrowed, corrected in place.

`scripts/1_build_dictionaries.nf`. The one step whose artifacts were shared between runs before multi-run existed.

> **For the manual, not here.** That dictionaries live under `mainDir/Reference/Dictionaries` and are **reused across projects** is user-facing — it is why a second project against the same genome starts fast, and why `reset` does not delete them.

## Why step 1 groups runs, and why it is not part of the variant model

Dictionaries live under `mainDir/Reference/Dictionaries`, and runs **share** `mainDir` — so two runs naming the same reference resolve to exactly the same output paths. Left alone under multi-run they would both build it, at the same time, into one place. `atomic_mv.sh` has no locking, so that is a **race**, not merely duplicated work.

This is therefore not an optimisation and does not belong with the sharing work: threading runs through step 1 without grouping them would have broken something that already worked.

`dictionaryKey()` groups on **output paths**. `dictionarySettings()` **throws** when two runs on one key disagree, rather than quietly splitting them — "build it once" would otherwise hand one run a dictionary built to the other's settings, which is the silent-wrong-result failure this project keeps finding. Reported rather than resolved: which of two conflicting settings should win is the user's decision and there is no safe default.

Resource settings are deliberately absent from that comparison — heap size and core counts change how long the build takes, not what it produces, and a shared dictionary cannot have per-run resources anyway.

`dictionaryRuns()` deliberately **merges** runs that disagree about `annotate`: one database serves them all, and a run that does not annotate is not harmed by its existence. Splitting that group would have two of them build concurrently into one directory.

## Three bugs this file's shape is the fix for

### The snpEff marker was not keyed by genome

The marker lived at the top of the snpEff folder, so a single top-level file answered *"has any database been built here?"* when the question is *"has THIS genome's database been built?"* Building against a second reference found the marker, skipped the build, and inherited the first genome's database. The failure did not surface until **step 8**, after alignment and calling, as `Genome download failed!` — snpEff falls through to `-download` when the config names a database it cannot find. Every index file in this step was already keyed by reference name; this was the one artifact that was not.

A project built by an earlier release has its marker in the old place, so the first run after upgrading rebuilds once. Deliberate: the old marker records that *a* database was built, not which genome it was for, so it cannot be adopted without guessing.

### The reference had to be gzipped, and nothing said so

`gunzip -c` was unconditional, so a plain `reference.fasta` died with *"not in gzip format"* — while nothing anywhere required the `.gz`: not step 0, and not the template, whose own `referenceFa = referenceFile.replace('.gz', '')` reads as though a plain name is expected to work. The GFF has always accepted both, which is exactly what made the asymmetry invisible.

It is **copied rather than symlinked** in the uncompressed case, so what lands under `Dictionaries` is a real file either way and `atomic_mv.sh`'s guarantee still holds. That costs one copy of the genome — which the gzipped path has always cost too.

### `ls | wc -l` as an existence test

`CreateBwaIndex` counted output lines from `ls ${referenceDir}/*.bwt` and friends chained with `&&`. Wrong twice over: an unmatched glob makes `ls` exit non-zero, so on a first run the whole substitution fails and takes the task with it once `pipefail` is on; and `*.bwt` matches an index built for a *differently named* reference, so the check could pass while the `ln -s` below still had nothing to point at. Now each of the exact five files is tested individually.

## Publishing the database and its marker as one directory

The marker is what every later run reads to decide the database is usable, so it must not be able to appear beside a half-written one. Writing it **inside** the staged directory and moving that directory atomically makes "marker present" mean "database complete". It used to be a second atomic move after a non-atomic `cp -r`, so a kill in between left a partial database and no marker.

**The unit is the genome's directory, not `data/`** — and that is what makes it possible at all. Several genomes share `data/`, and `mv` of a directory onto an existing directory *nests* it rather than replacing it, so publishing `data/` wholesale could only ever have been the merge that `cp -r` was doing.

A database with no marker is incomplete by definition — exactly what a kill during an earlier publish leaves — so it is discarded rather than merged into. `atomic_mv.sh` refuses a destination directory with anything in it, which is the same rule seen from the other side.

It refused *every* existing directory when this was written. The `77fdbd7` overhaul made `rename(2)` the only writer, and `rename(2)` replaces an existing **empty** directory rather than refusing it — pinned by `test_atomic_mv_replaces_an_empty_directory`. A half-written database is never empty, so the argument above is unaffected; only the rule it cites is narrower than it was.

## Two snpEff invocation traps

- **`-c` must name the config explicitly.** Without it snpEff finds a config in the working directory only when it is called exactly `snpEff.config`, and otherwise silently falls back to the one bundled with the install — which has no entry for this genome, so the build dies with `Property: '<db>.genome' not found`. That made `params.snpEff.config` a parameter that broke the run if it was ever changed from its default.
- **The config is merged, not replaced.** It sits next to the shared `data/` directory and snpEff reads every entry, so it has to name every genome built here. A plain `cp` left it holding only the most recently built one, making every earlier genome unannotatable even though its database was still on disk.

## Channel details

- Step 0's completion arrives as a **pure ordering barrier**: nothing in this step reads it, and it is `val` rather than `path` because N runs each publish a report called `0_verify_environment.txt`, and staging N files of one name is a collision for no purpose.
- **`annotate` filters the channel**, rather than an `if (params.annotate)` that could only read the base config and would have built for every reference or none.
- **`UngzipReference`'s output is not re-exported.** It is consumed inside the workflow by the two index builders; re-exporting published a channel `poolseqflow.nf` has never read, in any release. `BuildSnpEffDb` does not want it either — it runs *alongside* `UngzipReference` and copies the reference the user placed.
