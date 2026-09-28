# What walks `Data/`, and what only filters it

**Written 2026-09-27, against the tree at `b96bfca` plus uncommitted work, after 3.2.0 shipped.** 3.2.0 made reads findable in subfolders of `Data/` by changing one glob, and its CHANGELOG says hidden folders "are not searched". Half of that is true. The half that is not is a cost rather than a wrong result, which is why the code was left as it is - and why the claim outlived the review.

## Two walks over the same directory, under two rules

**Step 0 genuinely prunes.** Three `find` invocations, at [`0_verify_environment.nf`](../../scripts/0_verify_environment.nf) lines 363, 537 and 591, all of the shape:

```sh
find ${dataDir} -mindepth 1 -name '.*' -type d -prune -o ${readPattern} -print
```

A dot directory is never entered. `-mindepth 1` is load-bearing: the data root itself may sit under a dot - a project under `~/.local` would otherwise find nothing.

**The read channel does not prune. It filters afterwards.** [`2_trim_reads.nf:25-26`](../../scripts/2_trim_reads.nf):

```groovy
channel.fromFilePairs("${variant.reads}", checkIfExists: true)
    .filter { _id, files -> !hiddenBelow(dataRoot, "${files[0]}".toString()) }
```

`.filter` is a channel operator. It sees what `fromFilePairs` has already emitted, so the glob has walked everything the pattern can reach - dot directories included - before one match is discarded.

**The two agree on the outcome and disagree on the cost.** No sample under a hidden folder reaches the pipeline either way. But `p.reads` is `"${p.dir.data}/**${p.readPattern}"` and `**` is depth-unbounded, so on NetApp storage - where `.snapshot` is exposed read-only inside directories and holds a copy of every file per snapshot - the walk pays for every copy and then throws it away. Step 0 does not pay.

## The claim that shipped

The 3.2.0 CHANGELOG's Added section reads *"Hidden folders are skipped. Anything beginning with a dot is not searched."* True of step 0, false of the channel. It was written while the filter was being added and describes the intent rather than the mechanism.

**Z's ruling, 2026-09-27: a released CHANGELOG's text is not edited.** The section had already shipped under the `v3.2.0` tag, so an in-place correction would make the repository and the published release disagree in silence. Only a mechanical ASCII conversion was applied to that file (em dash, arrow and multiplication sign, verified as byte-exact apart from those three substitutions). The correction belongs in a later release's own section, which is why it is recorded here in the meantime.

## A third divergence, and it is not about dot folders

**Symlinks.** No `find` in `scripts/` is invoked with `-L`, so step 0 does not descend into a symlinked directory. The channel's glob passes only `checkIfExists: true` - no `followLinks: false` - so Nextflow's walker follows them.

Measured 2026-09-26 with `Files.walkFileTree` and `FileVisitOption.FOLLOW_LINKS` against the composed pattern: with `Data/link -> <project root>`, the walk entered `link/work/ab/` and matched a file there, which is the exact name shape Nextflow stages into `work/`. `hiddenBelow()` does not reject it, because such a path has no dot component. A cycle back into `Data/` was reported once as `FileSystemLoopException` and the walk then continued and finished, so a loop is not a runaway.

Not observed on a real project. Recorded because the two walks are easy to assume identical, and step 0's pair check - the thing that now refuses a missing mate - cannot see what the channel would find through a symlink.

## What this is not, and the reasoning is the point

A remote out-of-memory failure on a collaborator's cluster (reported 2026-09-25, 3.2.0, an installed release) looked exactly like this walk's fault, and was not. Recording the refutation because the shape of this code invites the mistake:

- **The glob never ran.** The workflow body reaches `readPairChannel` at [`poolseqflow.nf:128`](../../poolseqflow.nf), after `VerifyEnvironment(` at :102 and `BuildDictionaries(` at :113. Nextflow logs one `<< taskConfig executor` line per process, 1:1 and never cached; a local full run logs 36. The failing run logged **one**. It died creating process 1 of 36, ten lines of body before the glob.
- **The magnitude was wrong regardless.** Measured: 1,000,000 retained `java.nio.file.Path` objects cost 119 MB, about 125 bytes each. Exhausting the 32 GB that JVM was granted needs on the order of 10^8 paths; a cold NFS walk sustains 10^3 to 10^4 entries per second, so the 38 seconds available yields 10^4 to 10^5.
- **The whole pipeline runs in 128 MB of head heap.** Measured by sweeping `NXF_OPTS=-Xmx` against the committed fixture: 128m completes all 36 processes and writes all four reports; 64m dies with none configured; 16m will not start a JVM. So "PoolSeqFlow needs more memory" was never the answer to anything.

That failure is still open at this note's date and belongs to a different subject. Every frame it produced is inside `java.lang.invoke` - `LambdaForm.compileToBytecode`, `InvokerBytecodeGenerator`, `IndyInterface` - which is Groovy's invokedynamic machinery rather than any data structure of ours, and the same install failed to *compile* Nextflow's own static report template in 30 seconds on a run with zero tasks. See [[someone-elses-machine]] for the class.

## The change not made

**Bounding the walk instead of filtering its output.** The filter cannot do it: a channel operator runs after the walk completes, so the cost is already paid by the time it is reached. It would have to be bounded at the source, in the `fromFilePairs` call.

It was not done because it fixes a cost and not a result, and because the failure that raised the question turned out to be something else. Two things to know before doing it:

- **`**` matches across directories including none. `**/` matches only the nested ones** and would silently stop every flat project, which is every project before 3.2.0. `{,**/}` is unparseable by Nextflow. The composed pattern is actually `***` - `**` from the code plus the leading `*` of `readPattern` - and the JDK glob matcher treats that identically to `**`, measured.
- **The case that proves it already exists and had to be moved to earn that.** `test_hidden_folders_are_excluded_from_the_read_channel` in `04_pipeline` plants `Data/.snapshot/nightly/` copies and **runs step 2**, because a case that runs only step 0 passes with the channel's filter deleted outright - measured, it did. That vacuous version is the same failure as [[gates-that-stopped-checking]]: the assertion was aimed at the half that was never changing.
