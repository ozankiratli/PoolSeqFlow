# Brainstorming — ideas for later releases

**Written 2026-09-01, against the tree at `ebf08a2`.** The rsync entry graduated eight hours later. Integrity-by-hash has not, and one of the things it planned to build on has gone since.

Not a plan and not a decision record. Things worth doing that are too big, too early, or too disruptive for the release being worked on. Each entry says whose idea it was and when, what it would buy, what it would break, and what already exists to build on. Nothing here is committed to.

When an entry graduates it moves to the plan and leaves a line behind saying where it went.

---

## Integrity by hash, everywhere — Z, 2026-09-01

The idea, in Z's words: *"record sha256 of every file created. Then check the existence of the file against a hash especially for resume logic. And instead of creating dummy files we symlink every file that needs to be there. So hash is checked against the real file all the time."*

Three separate changes that only make sense together. Z's own framing: *"This would require a real overhaul of the pipeline. Not for now but maybe for a future release."*

### What it would buy

**Resume currently trusts a filename.** Every step's skip branch asks `find_artifact.sh` whether a path exists and treats presence as "this stage is done". A truncated, half-written or corrupted artifact passes that test, and everything downstream is built on it. This is the same class of failure as the two `atomic_mv.sh` defects — the difference is that those were about how a file gets into place, and this is about whether the file that is already in place is the right one.

**It would make the check total rather than incidental.** `atomic_mv.sh` now proves a cross-filesystem copy byte-identical before it removes the source, but that guarantee ends the moment the move returns. Nothing revisits the artifact afterwards. A recorded hash extends the same guarantee across the whole life of the project.

**It composes with what the analysis layer already does.** `<name>.provenance` beside every intermediate records the identity of the results it was derived from, and a mismatch refuses. That is this idea one level up — the sidecar answers *"were these the right inputs"*, a hash answers *"is this the file we wrote"*. Same shape, same failure philosophy: refuse and name, never silently rebuild.

### What it would break, and this is the hard part

**The dummy files are not a shortcut — they stand where no file exists.** Step 7's skip branches `touch` an empty file when a *downstream* artifact is already present:

```
if [ -f <freq tables> ]; then  touch ${sorted_vcf}          # nothing to point at
elif [ -f <split VCFs> ]; then touch ${sorted_vcf}
...
elif [ -f ${target_sorted_vcf} ]; then ln -s ${target_sorted_vcf} .   # the real thing
```

The last branch already does what Z is asking for. The earlier ones cannot, because **the file they would symlink to does not exist and is not supposed to**: every step-7 VCF is an intermediate, and `_sort_fp_dq.vcf` deliberately does not survive a run. The empty file is there only to satisfy Nextflow's `output:` declaration so the DAG can proceed past a stage whose product has been superseded.

So "symlink instead of a dummy" cannot be done by substitution. It needs the DAG to be able to say *"this output is not required, because a later one exists"* — optional outputs, or a differently shaped channel, or a stage that is not run at all rather than run to produce a placeholder. That is the overhaul Z anticipated, and it is the whole cost of the idea. The hashing is the easy half.

**Reading every artifact costs what the artifacts cost.** Hashing is proportional to total bytes written, and the BAMs dominate. Cheap at write time, where the data is already in hand; expensive if a resume re-hashes everything before deciding what to skip.

**A hash record is new state that can go stale and can refuse a run.** It needs the care `.poolseqflow_params` gets — and the same question about what happens when it disagrees.

### What already exists to build on

- `bin/atomic_mv.sh` computed a digest of the artifact on the cross-filesystem path and threw it away, so recording it there was nearly free and would have covered every promoted artifact. **That foundation is gone.** Since `77fdbd7` it verifies with `diff -qr` and computes no digest at all, so this idea has to add the hashing rather than capture something already paid for. The cheap half of it got more expensive because of a change made for an unrelated reason.
- The analysis layer's `.provenance` sidecar: the file-format precedent, the placement precedent (beside the artifact, so it survives a granular move), and the refusal wording.
- `bin/find_artifact.sh` is the single choke point every skip check goes through. It is where "is it there" would become "is it there and is it right".

### Open questions, none of them answered

- **Sidecar or manifest?** A `.sha256` beside each artifact travels with it through a granular move between roots, the way `.provenance` does. One manifest per run is easier to read whole and harder to keep true across two roots.
- **When is it checked?** Every resume, or only when asked? Re-hashing a 30 GB BAM set to decide what to skip would cost more than some of the steps it skips. A cheap pre-filter — size and mtime — with the hash as the tiebreak is the obvious compromise and needs thinking about.
- **What happens on a mismatch?** The layer's habit is refuse-and-name. Rebuilding silently would be the opposite of the point, but refusing means a corrupted artifact needs a documented way out.
- **Do hashes join the recorded manifest** the change guard compares, or stay separate? They describe the outputs, not the settings, so probably separate — but then there are two records beside `Output/` with different rules.
- **Does this replace `-resume`, or sit beside it?** Nextflow's own resume already hashes task inputs. This is about artifacts that outlive the work directory, which Nextflow does not track.

### Where it sits

After 3.0.0. It touches every step's skip branch, which is the highest-traffic code in the pipeline and the part with the least margin for a wrong change. Not to be started in the same release as the analysis layer.

---

## Try Strelka2 as a caller — Z, 2026-09-05

Prompted by Pinto, Sousa & Silva 2026, *Variant calling in genomics: a comparative performance analysis and decision guide*, PLOS ONE 21(2):e0339891, `10.1371/journal.pone.0339891`. Seven callers on human WGS (NA12878, ~50×): GATK, FreeBayes, DeepVariant, samtools, Strelka2, Octopus, VarScan2.

**What it says.** On whole genome, **Strelka2 has the highest precision (0.8326) and the best F1 (0.9009)**; Octopus has the best recall (0.9838) at a heavy compute cost; DeepVariant led on a chromosome-20 subset but **could not finish the whole genome** within their compute budget. samtools is reported as fast and low-memory — *"short runtimes and low memory usage, making it highly efficient"* — which is an efficiency result, not an accuracy win.

Z had already eliminated DeepVariant and Octopus on speed, independently, and this supports that. **Strelka2 was never tried and should be.** Z, 2026-09-05: *"there is strelka2, I never tried it but we should give it a shot… it is important we try it for this purpose."*

### The measurement this needs is not the one in the paper

The benchmark is **individual genotype calling against a truth set on one diploid human**. This pipeline does not want genotypes, it wants allele frequencies from a pool, and the two are not the same question — precision and recall on a genotype call say nothing directly about the bias in a frequency estimated from allele depths. A caller that wins on F1 could still be worse here if its `AD` handling is worse.

So a trial has to measure **what this pipeline actually reads**: the per-allele depths, on pooled data, against a known composition. The right shape is the corpus method used for the depth cutoff — build pools of known composition, call them with both, compare the recovered frequencies to the truth rather than comparing the callers to each other.

### What it would break

- **Strelka2 does not emit the same `FORMAT` fields.** Everything after step 6 reads `AD` — `depth2freq.awk`, `MajorAlleleToRef.py`, the false-positive filter. If Strelka2's output does not carry per-allele depths in the same shape, this is a converter and not a swap.
- **It is a germline caller built around diploid genotype models.** The same objection that applies to any genotype-first tool applies here: pooled samples are not diploid, and a model that assumes they are may be doing something unhelpful to the counts even when the counts are the only part being used.
- **A second caller is a second identity.** Step 6's identity names `variantCall.*`; a caller choice would have to join it, or two runs using different callers would share a results directory.

### Where it sits

After 3.0.0. It is a genuine question rather than a preference, and the corpus that would answer it does not exist yet — building that is most of the work, and it is worth having regardless of what the answer turns out to be.

---

## rsync instead of hand-rolled copy-and-verify — Z, 2026-09-01

> **GRADUATED the same morning, in `77fdbd7`** — eight hours after "not now" was written here. `rsync=3.4.4=hffd6c76_1` is pinned in `install/environment.yml`, unpinned in `install/environment-analysis.yml`, and `rsync` is a slot in `params.software`. `bin/atomic_mv.sh` stages with `rsync -a`.
>
> **The doubt below was upheld, which is the part worth keeping.** The section headed *Where it is weaker* argued that rsync verifies what it wrote against what it read, and would not catch a source that changed mid-copy. The implementation does not rely on rsync's verification at all: it compares the staged copy against the source with `diff -qr --no-dereference` before anything is removed, and the comment above that line — *"THE COPY IS NOT TAKEN ON TRUST"* — is this argument in the code. The two `sha256sum` passes became that one `diff`, and `test_atomic_mv_refuses_a_copy_that_does_not_match_its_source` still guards it.
>
> **`--remove-source-files` was not adopted**, for the same reason: it would delete the source on rsync's own say-so, exactly where the independent check has to sit. The source is removed after the verified rename instead. `--partial` was not adopted either.

Z, raised while `atomic_mv.sh` was being rewritten: *"I'm also starting to lean on rsync solutions, but not sure if it is reasonable to think that all servers have rsync already or not."*

### The availability worry does not apply here

rsync is not in coreutils and a minimal container image often lacks it — so the worry is right in general, and wrong for this project. **PoolSeqFlow ships its own conda environment and already pins the tools it needs**, `coreutils=9.11` and `bash=5.2.37` among them. Whether a server has rsync is not the question; whether `install/environment.yml` has a line for it is. conda-forge carries it, and `bin/atomic_mv.sh` runs inside a task with that environment active.

So this is a dependency decision, not a portability one. The cost is a line in the environment, a name in step 0's software check, and a re-export — the same shape as any other tool the pipeline calls.

### What it would buy

- **`--remove-source-files` implements the invariant directly.** rsync deletes a source file only after it has transferred successfully. That is the exact property the September fix was written by hand to get.
- **Transfer verification is built in**, and would replace the two `sha256sum` passes. *To confirm before adopting*: rsync's whole-file checksum verification is part of the delta-transfer path, and local-to-local transfers default to `--whole-file`, which skips the delta algorithm. Whether the end-to-end check still runs in that mode needs testing rather than assuming — it is the entire reason to switch.
- **`--partial` makes an interrupted transfer resumable**, which for a 24 GB per-position depth file is worth more than it sounds.
- Directories, sparse files (`-S`), ACLs and xattrs (`-AX`), hardlinks (`-H`) — all native, where the hand-rolled version handles them by getting `cp -a` right and hoping.

### What it would not change

**The same-filesystem path still wants `rename(2)`.** rsync always copies; a rename moves nothing and cannot produce a wrong copy. The two-path shape survives either way, and rsync would only ever replace the cross-filesystem half.

### Where it is weaker than what is there now

rsync verifies *what it wrote against what it read*. The current digest compares *the destination against the source as it stands afterwards*, which is a different question and catches a source that changed while it was being copied — reproduced, and the case that guards it is `test_atomic_mv_refuses_a_copy_that_does_not_match_its_source`. rsync would copy a moving source happily and report success. Whether that matters depends on whether a caller can ever hand over a source still being written; in the pipeline the producing task has finished, so it is defensive rather than load-bearing.

### Where it sits

**Not now.** Adding a dependency mid-release touches step 0's software check, `install/check_install.sh` and the pinned export, and the environment is re-exported at E7a anyway. Revisit there: the question is small, the answer is a line of YAML, and the test that settles it is whether local `--whole-file` transfers really do verify.
