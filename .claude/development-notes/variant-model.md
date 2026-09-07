# The variant model — how work is shared between runs

**Written 2026-08-31, against the tree at `7d65893`.** The model is unchanged and every function named here still exists. Two entries in `stepParameterMap()` have moved since — step 5 gained one, and step 7's is spelled differently — and one forward-looking clause about `members.txt` did not come true. All three are corrected in place.

`scripts/variants.nf`. A multi-run table usually describes runs differing in a few late parameters — one reference at three filtering settings — and running each from the reads costs hours to produce byte-identical intermediates. This file works out, once and before anything runs, which runs agree up to which step.

> **For the manual, not here.** One thing in this file is user-facing science: **what `Output/All_Runs/`, `Shared_<N>/` and `<RunID>/` mean**, and that only divergence gets a name. A person reading a results tree needs it. `members.txt` inside a `Shared_<N>` directory is the other half. Everything below is development history.

## The unit is a variant, not a run

A variant is a parameter set that one or more runs share at a given step — a node of the divergence tree. It carries exactly what a process needs, so a process still takes `tuple val(x), ...` and reads `x.dir.*` exactly as it did when `x` was a run; only what `x` *means* changes. A run is then a path from the root of the tree to a leaf, and runs appear only at the **edges**: step 0 validates each run's own configuration, and publishing sends a variant's outputs to each of its member runs.

**Z reframed this twice while it was being planned, and both corrections shrank it.**

### It is an analysis, not a deduplication (Z, 2026-08-26)

The obvious alternative is to hash each step's inputs and group by the digest. It produces the same partition, but it makes the digest do two jobs — identity *and* location — and the second is where the cost sits: hashes in paths, a content hash that races step 0's own CRLF repair, GString-vs-String key mismatches, and a "leader" that moves when the CSV is reordered. Comparing parameter values for **equality** needs none of it. There is no hash anywhere in the file.

### Steps EXPAND, they never fan back

Every fan-back the expansions replaced was a `join`, and a join drops an unmatched key *silently*. The only cardinality check that existed sat inside a `.map{}` reached only by keys that had already survived one — so a run lost during fan-back produced no VCF, no tables, no promotion, and reported SUCCESS.

An expansion enumerates its children from the plan, so the arity is decided before anything runs and nothing can be dropped. `assertEveryRunProduced()` asserts it anyway rather than trusting it, because the failure it guards against is silent and the check costs nothing.

## Sharing was built switched off, and the switch is still there

`sharingEnabled()` returned false for two whole stages on purpose: the rewiring was built and proven inert first — old and new code over one fixture, nothing moved — so that when task counts finally did change, the change was unambiguously that one line and not the refactor underneath it. The suite's three-run table fell from 233 tasks to 112 when it was turned on.

**It is now `return true` and nothing else,** so `variantKey`'s `if (!sharingEnabled())` branch — which prefixes the run id and forces every run into a singleton variant — is unreachable. Whether that is a kill switch worth keeping or dead code worth deleting has not been decided. It is cheap to keep and it is the one lever that isolates "the partition is wrong" from "the wiring is wrong", which is the failure this file exists to guard against.

## `stepParameterMap()` is the whole correctness risk

Name too few parameters and two runs share an artifact one of them did not ask for — reads trimmed to someone else's settings, with nothing downstream able to tell.

It is **authored rather than derived**, because it has to be reviewable, and a static case re-extracts it from the source and fails if any step reads a parameter its entry does not declare. Authoring alone drifts; extraction alone is fragile, since a regex cannot see an indirect read. Both.

`artifact` refines the partition permanently: once what a step passes on differs, everything after it differs. `publish` affects only what that step writes for you to look at, so it splits that step's own side outputs and the branch rejoins immediately.

It deliberately disagrees with `analysisParams()` in one place: `dir.subpath.*` **is** included here, because it is half of an artifact's identity even though it cannot invalidate a result. The two lists answer different questions — "what invalidates a result" versus "what makes two results the same" — so they are allowed to disagree, but only on purpose.

Entries worth their reasoning:

- **Step 2's `fastqc.options` is `publish`, not `artifact`.** It is FastQC over the *clipped* reads, run after cutadapt, for a report nothing consumes. Trim Galore's own FastQC — whose zips `ClipReads` really does read — takes `--fastqc_args` instead.
- **`threads` is deliberately NOT an identity** anywhere. It is a resource, it changes no byte of output, and including it would redo an entire analysis because someone asked for more cores.
- **Step 5 read no analysis parameter at all** when this was written, so it could never be a branch point. **E2 inverted that.** Step 5 now decides each sample's depth cap, so it declares `capBAM.maxDepth` as `artifact` — the cap refines what the step passes on — and `capBAM.histogramMax` as `publish`, which changes nothing it writes but makes runs sharing the step agree on it, since a ceiling too low for one sample fails all of them. Note the same parameter is *excluded* from `analysisParams()`, which is the disagreement two paragraphs up being used on purpose.
- **Step 7 declares `poolSize` and `ploidy` directly**, not only through the derived sensitivity: with per-pool sizes the filter computes each pool's threshold from them, so a run changing ploidy alone would otherwise be told it could reuse the filtered VCF. `diploidy` was the name when this was written. `poolSize` stands beside it because a sensitivity pinned by hand would otherwise let two runs of different pool sizes share one results directory.
- **Step 8 declares `annotate`** even though `8_annotate_variants.nf` never reads it. The reader is `variants.nf` itself — `variant.executes = (step != 8) || (variant.annotate as boolean)` — and `poolseqflow.nf` then filters on `.executes`. It belongs to step 8's identity because it decides whether the step runs *at all*.

`stepFolders()` is deliberately **wider** than `stepParameterMap()`: that map names the folders holding the artifact a step passes on, while this also names side outputs nothing consumes — the unpaired reads, the trim reports, step 5's coverage. Someone opening `Shared_1` sees all of them. Step 5 declares no output at all (both reports are written by absolute path), so it would be invisible here if this were derived rather than authored.

## Step 1 is not part of the analysis

Its artifacts are keyed by reference **name** and live under `mainDir`, so several genomes coexist and a later project reuses them — they are not keyed by what produced them. That is why `dictionaryKey` groups on output paths and `dictionarySettings` **throws** when two runs on one key disagree, rather than quietly splitting them. `dictionaryRuns` deliberately **merges** runs that disagree about `annotate`, because one database serves both; splitting that group would have two of them build concurrently into one directory.

So what the chain needs from step 1 is not an input digest but the identity of the artifact it will find there — split in two, because one identity over-splits. `referenceIdentity()` is what steps 3 and 6 read; `snpEffIdentity()` is what step 8 reads. Two runs differing only in `gffFile` must not redo alignment and calling.

## `stepDependencies()` is not "the step before"

The pipeline branches after calling. Step 6 reads the ready BAMs from step 4, not step 5's reports; step 8 reads the called VCF from step 6, exactly as step 7 does, so a run differing only in a step-7 filter still shares annotation. Walking `2..k` linearly gets both wrong — which is how it was written first, and what dumping the partition for a real table exposed.

One dependency per step is enforced with a throw. A step reading two independent artifacts would have to JOIN them, and a join dropping a key silently is what this design exists to avoid.

## Keys, groups and destinations

- **The storage root is part of every key.** Two runs whose `storageDir` differ have no directory in common to put a shared result in, so they must not group — prefixing the key makes that automatic rather than a refusal. Verified: a table where one run points elsewhere leaves it alone in its own tree at every step while the others share.
- **The lead member is the lowest RunID**, not the first table row, so reordering the CSV cannot change which run's map a shared variant carries — which would orphan the previous invocation's artifacts under a different root and recompute everything.
- **One results tree** (Z, 2026-08-27). A run no longer gets its own storageDir. The group number is per distinct *member set*, not per step: groups nest or are disjoint, so one member set is one group however many steps it owns, and `Shared_1` holds everything that group produced.
- **A single run is none of these** — nothing to be distinguished from — so its tree stays where it always was, and `Utilized/` stays unsuffixed. No synthetic key when there is only one run.

**Where a skip check looks**: permanent storage first, so a promoted artifact outranks a residue copy; then the variant's own working root; then its ancestors', because a step reading a *shared* artifact reads it from the root of the variant that produced it. Two runs sharing step 2 and diverging at step 3 is the whole case — the trimmed reads are under the step-2 variant's root, which neither step-3 variant would otherwise search.

## Promotion gates

The gate is keyed by the **producing** step's branch. Once a producer is shared its consumers may not be, so releasing on the first consumer to finish would delete a file another still needs.

The count is arithmetic, not a runtime reference count: the structure is a tree, so a consuming step's variants partition their parent's members and how many there are is known before anything runs. `groupKey` carries that number so each group is released as soon as *its* consumers are in — waiting for the channel to close would hold every artifact on the working volume until the slowest run finished, which is the opposite of what promotion is for.

## Decisions

- **A publish-only disagreement inside a group is refused** (Z, 2026-08-27). Publish parameters must not split the artifact partition, but they cannot split the step's own outputs either: two step-2 variants feeding one step-3 variant is a MERGE, and the expansion model exists so that cannot happen. Same shape as `dictionarySettings()` throwing.
- **`members.txt` is a record, not a guard.** What stops a table edit from mixing two groupings in one directory is the stored copy of the table itself. This exists because Z asked for the grouping to be recoverable from the results, and because the analysis layer will want it.

  **The analysis layer did not want it.** It recomputes `variantPlan()` rather than reading what the pipeline left on disk — the same reasoning as the first half of this entry, one level up: a record can be edited after the fact, and a recomputation cannot disagree with the run it describes. `members.txt` stays what its first sentence says it is, and `dry-run.md` carries the same corrected prediction from the other end.
- **The partition is reported before compute is spent.** A wrong parameter map is the failure this design risks and it is silent, so step 0 states the partition where it can be disagreed with rather than leaving it inferred from which directories happen to exist.

## Traps encoded in this file

- **Plain Strings, never GStrings**, in any channel key. A GString on one side of an operator and a String on the other matches nothing, silently. This project has been bitten before.
- **`runToken()` exists because a null key matches nothing, silently.** A single run has no RunID at all, so it travels as the literal `-`.
- **Recursion, not a self-referencing closure.** The strict parser rejects `def f; f = { ... f(...) }`. It also rejects both `for` forms, which is why `dig()` uses `.each` with a reassigned capture.
- **`values()` is an unmodifiable view** and `unique()` sorts in place, so `publishConflicts()` calls `toList()` first or it throws `UnsupportedOperationException`.
- **An exception inside an operator closure reaches Nextflow wrapped in an `InvocationTargetException` whose own message is null** — the user sees "Unexpected error" and a line number. Verified, not assumed. That is why `assertEveryRunProduced()` prints its diagnosis to stderr first and throws only to fail the run.
