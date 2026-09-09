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

---

## Covariate adjustment as a layer-wide question — Z, 2026-09-07

Deferred out of F2 deliberately, and not because the arithmetic is hard. The arithmetic is settled: weighted Frisch–Waugh–Lovell reproduces `lm(f ~ y + z, weights = w)` to twelve significant figures provided the degrees of freedom come from the full model, and the permutation scheme that works with covariates was measured — permute the RAW phenotype and re-residualise at each site, where permuting the already-residualised one runs at twice its nominal rate. `association-math.md` holds both.

### Why it is not an F2 setting

Z, 2026-09-07: *"this requires a constant discussion where we would need covariate analysis in the whole analysis layer and then design tools to address it after we have a much more complete set."*

A covariate is not a property of one test. If `association` adjusts for a covariate and `mds` does not, two published folders from one project disagree about what the data was, and a reader has no way to see it. The same question reaches diversity, FST, every trajectory statistic — each needs its own answer to *what does adjusting mean here*, and several of those answers are not "put it in the model" at all.

So the decision is that the layer gets one answer, not that F2 gets one first. The frame already declares covariates and their scales and prints them; what it does not do is fit them, and nothing should until there are enough modules to see the shape of the problem.

### What already exists to build on

`analysis.metadata.covariates.<column>` gives a scale; `analysis.design.covariates` says which may enter a model, each entry carrying `inDesign`; module rule 17e says to fit only those. The declaration side is done and shipping. Only the use side is deferred.

### What it would break

Every degree of freedom counted so far. `df = n_observed − 2 − q` over units means a timed design of three units cannot fit a single covariate — that refusal has to be loud rather than a column of NA, and it is a design being honest rather than a defect. And a covariate correlated with the phenotype changes what a published effect size means, which is a manual problem before it is a code problem.

### Where it sits

After the roster is fuller — F4 onwards, once there are enough modules that "what does this layer do about covariates" has a real answer instead of one module's opinion. Z, 2026-09-07, on the interim: *"since the results and metadata will be aligned, the user might be able to handle it themselves."*

---

## Plotting as a published, re-runnable script — Z, 2026-09-08

The idea, in Z's words: *"What we can do is maybe move the plot code outside of mds (and all modules), print the code and let the user make the plot they want to make by manually editing the code. We output the scripts anyway."*

Raised while deciding whether `mds` should take a color palette setting. The answer to that was no — how many levels a variable has, whether it is ordered, and whether a reader needs the categories distinguishable or merely grouped are properties of the experiment, and every way of getting a palette wrong is quiet. This is the idea that makes the refusal generous instead of merely restrictive.

### What it would buy

**It ends a settings surface that otherwise grows forever.** `mds` already carries `colorBy`, `shapeBy` and `dimensions`; `basicstats` carries `chromosomes` for its depth panels; `association` carries `chromosomes` again plus `reportBelow` and `reportTop`. Every one of those exists because a plot needed a decision made for it, and the next request is always another one — facet by this, log that axis, drop that pool, order the levels my way. A script the user owns answers all of them at once and adds no setting.

**The escape hatch is already half there and nobody can use it.** Each module publishes its own `.R` beside the result with the shared library folded in, so the plotting code ships today. What stops anyone editing it is that re-running it recomputes everything: for `mds` that is the whole distance matrix over every depth table. A plot script reading the published TSVs would redraw in seconds.

**It puts the choice where the knowledge is.** A palette is the clearest case, but the same is true of axis limits, label placement and which sequences are worth a panel at all.

### What it would break, and this is the part that decides the shape

**The PDF report is built from the PNGs.** `analysis/lib/rmd/report.Rmd:54` walks the published files and embeds every `.png` it finds. A module that publishes no figure contributes none, and the report every analysis carries — F1's, and one of the reasons the analysis layer is worth running at all — becomes a page of tables.

So the version that survives is **not** "modules stop plotting". It is: the plot becomes a standalone script that reads the published TSVs, and the module runs it once. The default figure still exists, the report is unchanged, and the script beside it is re-runnable against `mds.tsv` without recomputing a distance. Z's idea, with the report constraint folded in.

**It is a frame convention, not one module's choice.** `analysis/modules/README.md` is explicit that `basicstats` is the template and a second shape must not be invented, so this lands in all three modules or none. That is what keeps it out of F3.

### The decision it still needs

Whether the published plot script carries its settings substituted in, or reads `options.json` beside it. Substituting makes the script self-contained and editable with no other file; reading keeps one source of truth and means the script and the run cannot disagree. Both are defensible and the answer shapes the template every later module copies.

### What already exists to build on

Every module already publishes its own `.R` and its compiled sources, `PublishResults` already takes whatever lands in `published/`, and `report.Rmd` already discovers files rather than being told about them — so a new `*_plot.R` needs no wiring. `mds.tsv` and `eigenvalues.tsv` are already sufficient to redraw `mds.png` without touching a depth table, and the manual's `mds` section carries a base-R snippet that does exactly that.

### Where it sits

At or just before **E5b**, which is already the pass that makes the three modules read well beside one another. Not in F3: it touches `basicstats` and `association`, both committed, plus the report.

---

## A module repository served from the site — Z, 2026-09-09

Z's framing: *"we make a repo with tarballs into the website. The 'official' repo... third-parties would need to make their own repos and additional repos are allowed."*

**Not an index page — a package repository.** The site serves the catalogue AND the tarballs it points at, the way a distribution's archive does. Third parties stand up their own, and PoolSeqFlow can be pointed at more than one. (An earlier draft of this entry described only the index; that was a misreading and the difference is the whole engineering problem below.)

**Deferred deliberately, and the repository stays exactly as it is.** Z, 2026-09-09: *"We won't work on it yet. It might be a future date task (nothing urgent, nobody besides me is developing this yet). No third-party apps for now, but our infrastructure allows expansion."*

### What it would buy

**A published address that does not encode the file's path in the repository.** `MODULE_INDEX_URL` today is `raw.githubusercontent.com/ozankiratli/PoolSeqFlow/main/analysis/modules-index.tsv`, so moving or renaming that file breaks every installed copy. A site URL decouples the two. Neither survives an organization or repository rename, so that is the only stability difference and it is real but narrow.

**A human-readable catalogue.** `modules available` is the only way to see what is published; there is no page. One generator emitting both the TSV the wrapper fetches and the table a person reads is this project's existing pattern, and it makes the two unable to disagree.

**Somewhere for a third-party module's manual fragment to land.** This is the part that matters beyond tidiness: a module published separately declares `outputs[].url` because it has no heading in the shipped manual, and there is nowhere on the site for that page to be. E5b lists this as its one unsolved item. A page per module under the repository section is exactly that place.

### The hard problem: a site deploy replaces everything, and a package repository may not

A published version's bytes have to be identical forever. The catalogue pins them by sha256, and `install <name> <version>` promises the same code every time. A GitHub Pages deploy is a wholesale replacement of build output, so a tarball regenerated on each deploy either breaks its digest — installs start failing — or has its digest regenerated with it, in which case a pinned version silently means something new. That is worse, because nothing reports it.

**Measured, 2026-09-09.** `git archive` is reproducible only from a commit:

| what is archived | mtime it stamps | two builds seconds apart |
|---|---|---|
| a tree — `HEAD:analysis/modules/mds` | **now** | different digests |
| a commit — `HEAD -- analysis/modules/mds` | the commit date | **identical digests** |

The catch is the shape: the installer requires the archive to unpack to `<name>/`, and only the tree form gives that. `git archive --mtime` settles both at once, measured byte-identical across builds and with the right root:

```
git archive --format=tar --mtime="@<commit timestamp>" --prefix=<name>/ <ref>:analysis/modules/<name> | gzip -n
```

`--mtime` is a recent `git archive` flag — present in 2.55 here. A build using it should assert a minimum git version rather than discover its absence as silently drifting digests.

### What the repository is actually FOR, which the note first got wrong

**No module is downloadable today, at any version.** The catalogue has zero rows and nothing hosts a tarball; the three shipped modules arrive inside the release and that is all. An earlier draft of this entry said multiple versions "already work" because the catalogue format carries a version column and `install <name> <version>` pins on it — that is the format being *able to express* it, not the thing existing. Z, 2026-09-09: *"nobody can download a different version of any module today."*

So the repository is not a convenience over an existing mechanism. **It is what would make module distribution exist at all, and multiple versions and backwards compatibility with it** — someone on an older pipeline being able to fetch a module version that still runs there. Z: *"it changes if we have a repo. We can start having backwards compatibility and all."*

**Publishing has to be a deliberate act.** Deriving the set of published versions from git history was raised and rejected — Z, 2026-09-09: *"I don't want you to derive it from the history."* Every intermediate version bump would become a published release, including ones made mid-development and never meant to leave. Whatever marks a version as published, it is something a person does on purpose.

A module's own repository does not have this problem, because the module is at the root there and the commit form gives the right shape directly. It is only the first-party monorepo case that needs the re-rooting.

**Size and bandwidth are not a concern.** A module is a handful of text files, tens of kilobytes; Pages' limits are measured in gigabytes.

### What it would break, and the one bug it would ship with

**`.github/workflows/docs.yml` has a `paths:` filter** — `manual/**`, `mkdocs.yml`, `CHANGELOG.md`, `build_docs.py`, itself. `analysis/modules-index.tsv` is not on it. Wired naively, adding a module row would not rebuild the site, the catalogue would silently stay stale, and the symptom is a module that cannot be installed with nothing saying why. One line, easy to miss.

**Publishing a module becomes a merge plus a site deploy** rather than a merge alone. Still not a release, so the property that matters — a module appearing without a PoolSeqFlow release — survives.

### Two facts that bound when this can be decided

**The URL becomes permanent at 3.0.0.** No released version has the module system: v2.2.0 carries neither `MODULE_INDEX_URL` nor `analysis/modules-index.tsv`. So 3.0.0 is the first release that will ever read a catalogue, and from then on every released copy has the address compiled into its own `lib/wrapper_lib.sh` and asks for it forever. Changing it later means serving both addresses indefinitely. **Keeping the raw URL is therefore a decision with a permanent consequence, not a deferral of one.**

**`POOLSEQFLOW_MODULE_INDEX` substitutes, it does not add.** `module_index_source()` is `${POOLSEQFLOW_MODULE_INDEX:-$MODULE_INDEX_URL}` — one value. So "additional repositories are allowed" is true of the *shape* and not yet of the code: today you can point a machine at a different catalogue, not at several at once. Several would need a list, a precedence rule for a name published in two of them, and a decision about whether a row may be shadowed. None of that is written.

What third-party repositories need beyond that is nothing: `fetch_url` already takes any URL, the digest already makes the host a question of integrity rather than trust, and `#!index-format` already refuses a layout this release cannot read. A third-party repository is a catalogue and some tarballs at an address — the download machinery is done.

### What already exists to build on

The catalogue's two headers already separate layout from content — `#!index-format` is refused on, `#!index-version` never is, precisely so a release can read a catalogue newer than itself. `fetch_url` already takes a URL, a path or `file://`. The digest in each row already makes the URL's host a matter of integrity rather than trust. And the site is already generated wholly from one source, which is the pattern a repository section would follow.

### Where it sits

After 3.0.0, and nothing about it is urgent while Z is the only person developing modules.

**One thing gets harder by waiting, and the cost of getting it wrong is bounded.** `MODULE_INDEX_FORMAT="1"` compiles into every released copy and `require_module_index_format` is an exact-match refusal, so catalogue columns added later — `frame` and `environment`, which is what would let the repository hand an older pipeline a version that still runs on it — are unreadable by 3.0.0. The consequence is not data loss or a broken install: a 3.0.0 user who wants a module published later is told to upgrade. That may simply be acceptable for the first release of the module system, and it is Z's call rather than a deadline anyone has to meet.
