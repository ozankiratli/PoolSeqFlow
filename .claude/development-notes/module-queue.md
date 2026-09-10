# The module queue — the plan from v3.1.1 onward

**Written 2026-09-10, against the tree at `8b4f0ca` "Version bump 3.1.1".** This is the plan as it was decided that day, not a document kept current. Z's cadence: **one module per week**.

The plan it replaced covered E1–E8, F0–F3, E5b and E7, and every line of it had landed. Nothing of that is repeated here; `git show` is the detail and the notes beside this one are the reasoning.

## A week ends in a publish, not a release

**This is the whole reason the module system exists and I argued past it twice before Z stopped me.** Z, 2026-09-10: *"I don't know why are you pushing so hard on this we made the modules this way so we don'r make new releases every time."*

The argument I built was half right and the conclusion was wrong, which is worth recording because the half that is right is a real constraint. `manualAnchors()` in `analysis/lib/nf/outputs.nf` resolves the manual as `${installDir()}/manual/PoolSeqFlow-manual.md` — the copy inside the **user's own installation**, which `.gitattributes` ships in the release tarball and which is frozen at whatever release they installed. The website is never consulted. So a module whose manual section exists only on `main` has no anchor a v3.1.1 user can resolve, and `checkModuleOutputs()` **refuses while the DAG is built** rather than merely rendering a dead link.

From that I concluded a module publish had to ride with a release. **It does not.** `checkModuleOutputs()` already accepts `url` in place of `anchor`, and the branch exists for exactly this case — its own error message says so: *"a url is for a module published separately, whose section is not in it."* Three lines below the check I was quoting.

**So the rule is: a module published between releases declares site URLs on its outputs.** `docs.yml` triggers on both `manual/**` and `modules/repo/**`, so the page, the tarball and the catalogue row deploy in one push, and any v3.1.x installation can install it the same afternoon. The three modules already published keep their anchors, because their sections shipped with the release that carries them. A release still happens on its own timetable — when the pipeline changes, or to fold accumulated module sections into the shipped manual — and nothing in a week waits for one.

**The lesson, which is the reusable part:** I let a mechanism I had just finished reading drive a cadence decision, instead of asking what the mechanism had been built for. The escape hatch was in the same function.

## The queue

Dependency order, not priority order. Thirteen modules.

**Now**, all reading `depths` and needing nothing new in the frame: `fst` · `pca` · `sfs` · `correlation` · `trajectory` · `cmh` · `selection` · `drift` · `haploblocks`.

**After a per-position depth track**: `callable` · `theta` · `sweep` · `scan`.

Z added positive selection as **two** modules rather than one: `selection` — per-allele *s* with an interval, from the trajectory under an N_e-aware model — early, and `scan` — a composite windowed genome scan — last. They answer different questions for different designs, and one of them needs a time series most projects do not have. Forcing them into one module would gate half of it behind that design.

**The depth track goes last deliberately.** It is a pipeline change and not a module: per-position depth from the **capped** BAMs step 6 actually piles up, `bgzip` + `tabix`, into `Analysis/Main`. Putting it at the end keeps the weekly cadence unbroken for nine weeks and lets the track land in a settled layer. The measurements that size it, and the two design errors not to repeat, are in `callable-sites.md` beside this note.

**`histograms` is not a substitute for the track**, and this is easy to get wrong because the class exists and looks like it would do. It is `samtools stats` COV rows: genome-wide, **per library** rather than per pool, taken from the **ready** BAM rather than the capped one the calls came from, and with no zero bin, so genome length is not recoverable from it. A denominator built on it describes a different read set than the numerator — the exact error the reverted `CallableSites` made.

## Two shape questions the roster raised, both left open on purpose

**`selection` and `drift` may collapse into one module.** An interval on *s* that excludes zero **is** the drift test, so the Wright–Fisher/N_e library belongs to whichever is built first and the second may turn out to be a table rather than a module. If `drift` survives it will be because it answers per-site *"is this more than drift"* genome-wide where `selection` answers per-allele *"how strong"*. Decide it while designing `selection`, not before.

**`scan` reads another module's output, and the frame cannot express that.** `needs` names artifact classes produced by pipeline steps and `checkModuleNeeds()` refuses anything else; there is no class for *"what `fst` published into this results folder"*. Three shapes are possible and none is chosen: `scan` recomputes everything itself and depends on no module; the frame grows a class for a module's own published tables; or `scan` reads `target.results` directly and declares the dependency in `gates` with nothing verifying it. **Settle it before `theta` is built** — whichever it is decides whether the modules before it publish tables meant to be consumed or only read.

## Week 1 is `fst`, and one thing about it is already settled

**Read the DEPTH table, not the VCF.** `vcf2pooldata` is poolfstat's documented entry point and it is the wrong one here. `needs: ["vcf"]` resolves through `artifactClasses()` to `Output/VCF/<name>.vcf`, which is the **raw step-6 call set** — no false-positive filter, no depth or quality filter, and in the original reference encoding rather than major-allele normalized. Only the raw call set and its snpEff annotation survive a finished run; every VCF step 7 produces is consumed and deleted. So a module built on `vcf2pooldata` would compute FST over a different site set than `basicstats`, `association` and `mds`, silently and with nothing in the output saying so.

Building `pooldata` from the depth table instead keeps the site set identical to every other module, and makes the one real difference — poolfstat is biallelic — a declared gate rather than an invisible one. **Unverified as of this note:** whether poolfstat exposes a usable matrix constructor taking `refallele.readcount`, `readcoverage`, `poolsizes` and `snp.info`. That is the first thing week 1 checks, because a no would force the design back onto the raw call set.

`fst` is also the first module to declare `url` outputs, so it carries one-off work the rest of the queue inherits: `00_static: every declared manual anchor exists` checks `anchor` and goes quiet on a `url` module, and wants a companion asserting each declared `url` resolves to a heading in the manual here — which is what the site is built from. That is `gates-that-stopped-checking.md` arriving on schedule, and it was predicted rather than discovered, which is the first time that has happened.

## Measured while planning: an abandoned constraint

The superseded plan carried *"The catalogue stays header-only — shipped modules live in the payload, and `analysis/modules-index.tsv` is for separately published ones. No dependency or license column is added to it in 3.0.0."* Z flagged it as possibly abandoned and asked for a measurement. It is abandoned three ways over:

- **`analysis/modules-index.tsv` does not exist.** No tracked file by that name; the catalogue is `modules/repo/index.tsv`, published at `/modules-repo/`.
- **No module ships in the payload at all.** `modules/` is export-ignored, so `basicstats` is installed from the catalogue like any third-party module.
- **The catalogue did gain columns** — `kind`, `frame`, `environment`.

Only *no license column* survived, and it is now worth reopening rather than keeping: a user choosing what to install learns the terms only after the tarball is down and the manifest is read. Columns are matched by name, so adding one is additive and needs no `#!index-format` bump.
