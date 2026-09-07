# The DAG — `poolseqflow.nf`

**Written 2026-08-31, against the tree at `7d65893`.** The nine Nextflow behaviors and the wiring below all still hold. One detail has moved: which variables are declared without `def`, corrected in place.

The entry workflow. What each step is wired to, and the channel traps that shape it.

## Nextflow behaviors this file is built around

Every one of these was learned by getting it wrong.

### A workflow cannot be invoked twice

Nextflow answers *"Process 'X' has been already used"*. Aliasing is the supported way round it whenever the number of call sites is known while the script is read — which is the case here: the DAG's shape is fixed, and only multi-run's N comes from data. Hence one alias per attachment point.

### A `def` local of the workflow body is invisible to a closure

The closure resolves its names against the **script binding**, finds nothing, and dies on `Cannot get property 'dir' on null object`. So a name a closure has to see is declared **without** `def`, deliberately, which makes it a binding variable.

Which names those are has changed since: today it is `plan` and `log_dirs`, and `log_dirs` is the one that proves the rule, because `workflow.onComplete { assembleCombinedLogs(log_dirs) }` is the closure. `run_defs` carries a `def` and is fine — nothing outside the workflow body reads it. The rule is about where a name is read from, not about which names happen to need it today.

### Nothing in an `onComplete` handler may throw

When one fails, Nextflow reports *"Failed to invoke `workflow.onComplete` event handler"* **instead of** the error that actually stopped the run. A fault in the logging replaces the diagnosis with a line about logging.

It cost the multi-run dictionary conflict its entire message once: a GString reaching a String parameter turned a precise explanation into a pointer at this file. That is why the handler does nothing but call one guarded function — anything evaluated in the handler's *argument list* is outside that function's own try/catch, which is exactly where that failure was.

### `combine` spreads a List item

`combine` treats a channel item that is a List as a tuple and spreads it, so combining a `collect()`ed list of N reports produces an N+1 element tuple rather than a pair, and every closure downstream is called with the wrong arity. A scalar cannot be spread — which is why step 1's gate is a `count` and not the reports themselves. Nothing reads the gate's value anyway.

### `combine(by: 0)` versus `join`

`combine(by: 0)` is the cartesian product *within* a key, which is what an implicit value channel used to do for free. `join` matches one-to-one and would leave every sample after the first without an index.

### `groupTuple` versus `collect`

`collect()` waits for every task of every variant and releases them together. Correct, but it holds the last variant's working files until the slowest has finished. `groupTuple` waits for the tables **of this variant**.

### Positional matching is the recurring hazard

With one run there was exactly one of each singleton and implicit value channels broadcast them for free, so "the reference index" and "the sample" could be two separate process inputs. With N of each, positional matching pairs whichever arrived first — and the result is one analysis run against another's reference, which no later check could detect.

So: singletons are combined onto their samples **by key**, and two per-sample channels are joined on the work item **and** the sample.

## Ordering that produces wrong numbers rather than errors

**`runDefinitions()` must be called before `resolveParameters()`.** The first takes each run's copy of the parameters while "absent" still means "the user did not set this". The second destroys that distinction by filling the computed values in, and `fill` will not overwrite — so a run changing an input to a derivation would silently keep the base run's derived value. Reversing the two lines produces wrong numbers, not an error.

## The step-0 gate is the only one the pipeline needs

A shared step must wait for **every** run that shares it, not just the one whose parameters it carries. `VerifyAll` is `errorStrategy 'finish'`, which lets already-submitted tasks complete — so a step gated on one member's report could finish and promote while another member's `CheckRunParameters` was still deciding to fail.

Gating **step 2** covers every step after it, because a variant's members are always a subset of its parent's: a step-2 variant that waited for all of its members has already waited for all of every variant descended from it.

`groupKey` carries the member count with the key, so each variant is released as its own members report rather than when the whole channel closes.

## Sharing was built switched off

While `sharingEnabled()` returned false, every run was its own variant at every step, so each tree was a straight line and this file described exactly the DAG it described before multi-run. That was deliberate: it made the rewiring provable by running old and new code over one fixture and showing nothing moved. **It returns a constant `true` now** — see `variant-model.md` for what that leaves unreachable.

## Promotion attachment points

Each hangs off a step's output **alongside** that output's real consumer rather than in front of it, so nothing upstream changes shape and no value channel can be turned into a queue channel.

The signal is the consuming step **having finished**, not the artifact — several processes take an input purely for ordering and read an absolute path instead, so holding the file proves nothing about who is done with it.

**The gate is keyed by the PRODUCING variant, not the consuming one.** Once a producer is shared its consumers may not be: two runs can share step 2 and diverge at step 3, so two step-3 work items read one set of trimmed reads, and releasing on the first to finish would delete a file the second still needs.

The FastQC zips are the one artifact produced and consumed inside a single step, so producer and consumer are the same variant and there is nothing to gather.

Two artifacts have more than one consuming **step**, so their gates are assembled at the call site:

- **Ready BAMs** — step 5 per sample, step 6 for the cohort. Both are gathered onto their step-4 producer first, which collapses calling to one signal per producer however many step-6 variants read it. `combine(by: 0)` then re-emits each of the producer's samples' own signals, so the result is still one task per sample: the sample identity comes from step 5's side and calling contributes only its completion.
- **The called VCF** — step 7 always, step 8 only where annotation is on. Both shapes can be in flight at once, since a step-6 variant may feed an annotating branch and a non-annotating one simultaneously.

Whether an annotation signal is ever coming is a property of the producer's **children**, not of the producer's own `annotate`: the variant carries its lead member's parameters, and `annotate` is not part of step 6's identity, so the lead cannot answer for the rest.

## The combined log

Each task appends to `Logs/<step>/*_nextflow.log`, one writer per file, so tasks never contend — but a run ends up scattered across dozens of files. By the time `onComplete` runs there are no writers left, so gathering is safe there in a way it would not be mid-run.

Only the current run is collected: every block carries the session id that wrote it, so blocks from earlier runs in the same file are skipped. The combined file is overwritten each run; the full history stays in the per-process logs.

**One combined log per Logs directory, not one per invocation.** Under multi-run each run has its own and the shared work has the project's, so the combined log sits beside the per-process logs it summarises rather than mixing three runs into one file under whichever root happened to be the base.
