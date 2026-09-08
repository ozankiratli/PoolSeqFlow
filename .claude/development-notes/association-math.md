# F2's math, and the three things that were measured rather than reasoned

**Written 2026-09-07, against the tree at `15d4c34` plus the uncommitted config reshaping. Nothing in `analysis/modules/association/` exists yet** — this is the record of what was settled before any of it was written, so that the module is built against measurements rather than against intuition.

The plan file's F2 section predates F0f and F0g and is superseded on scales, covariates and degrees of freedom by what is below.

## Z's two calls on scales and covariates

- **An ordinal phenotype is fitted linearly on the level index; a nominal one is refused by name.** F0f shipped four scales where the plan covered two. The manual has to say an ordinal slope is *per level-step* and not per unit of anything, because fitting a line asserts the equal spacing that "ordinal" explicitly disclaims.
- **Covariates are fitted as extra predictors**, not reported only. `df = n − 2 − q`.

## The permutation scheme, and the candidate that doubles the false-positive rate

Permuting a phenotype freely stops being valid once covariates are in the model, and there are three plausible repairs. **Measured at six pools with one covariate, 20,000 replicates against the exhaustive 720-permutation null, nominal α = 0.05:**

| scheme | p ≤ .05 | p ≤ .10 | p ≤ .50 | mean p |
|---|---|---|---|---|
| permute the RAW phenotype, re-residualise at each site | 0.0482 | 0.0992 | 0.5072 | 0.4984 |
| **permute the RESIDUALISED phenotype** | **0.0986** | **0.1682** | **0.5794** | **0.4393** |
| Freedman–Lane | 0.0512 | 0.0986 | 0.4968 | 0.4997 |

**The middle one is the natural implementation and it is wrong**, at roughly twice its nominal rate, with the whole p-distribution shifted — a mean p of 0.44 where it must be 0.5.

**The cause is geometric, not confounding.** The observed residualised phenotype lies in the same subspace as the residualised frequency; its permutations do not. So the observed correlation sits systematically high inside its own null. Two controls settle it: making the phenotype **independent** of the covariate gave the same 0.1002, which rules out confounding; and a **constant** covariate made all three schemes numerically identical, which rules out the harness.

**So: permute the raw phenotype and re-residualise it at each site.** It is the cheaper of the two valid schemes — re-residualising one permuted phenotype is a single *n*-vector per site, where Freedman–Lane residualises per **allele**. With no covariates it degenerates to plain label permutation, so there is one code path and not two.

## Weighted Frisch–Waugh–Lovell is exact, so covariates keep the closed form

Verified against `lm(f ~ y + z, weights = w)`: residualising both response and predictor on the covariates and running the simple weighted fit reproduces **b1 and its standard error to 12 significant figures** — provided the degrees of freedom come from the *full* model and not from the residual regression. That is the whole reason covariates do not cost F2 its vectorised closed form. Per-site weights make the residualisation per site, but it stays one small solve per site, independent of allele count.

## Degrees of freedom, and the refusal that falls out of them

`design.units`, per module rule 17c — never `design.series`, and never the column count. F0g made that answer correct for an untimed project too, so **the "pools are the units" fallback that was written down while `units` was empty is dead and must not come back.**

**And the degrees of freedom are not the whole of it: the FIT is on units too.** Collapse each unit's pools onto one weighted value first — weights summed, frequency their weighted mean — and fit those. Re-reading a pool-level statistic against the unit count controls nothing; `calibration.md`, written the same day against measurements this note predates, has the numbers. With covariates, `df = n_observed − 2 − q` counted over units after the roll-up.

**A refusal falls straight out and has to be loud rather than silent:** a timed design of three units gives `df = 3 − 2 − q`, so **any covariate at all makes a repeated-measures design unfittable.** That is the design being honest about itself, not a defect — but it stops a run, so it must say so in one sentence instead of emitting a column of NA.

## The weight belongs to the frequency, never to the label

The plan says to *"permute the phenotype labels with their weights attached"*. **That is wrong.** `n_eff` says how precisely **that pool's frequency** was measured, so carrying it with the label would weight one pool's frequency by another pool's depth. `test/tools/freq_corpus.py` was built the correct way already.

## What the corpus fixes, and what a case may not assert

Committed with the corpus at `e3eb887`:

- **`assocb.smallest_p` = 0.1** — the 3-vs-3 floor, reached by a site whose *t* is literally infinite. The complementary labelling always ties, so 2/20 is the floor and no site in such a design can be genome-wide significant. The quantitative floor is 1/720 and `chr2:550` reaches it.
- **`chr2:550`** is triallelic with |t_REF| = 22.2 against 7.65 for the best alternate: minimising over alternates alone gives p = 0.0016 where maximising over every allele gives 2.4e-5. It is the case that would catch a dropped REF row.
- **`chr1:700`**: weighted t = 5.35 against unweighted 4.74, so a fit that ignores `n_eff` fails it.
- **`chr10:1600` and `chr10:1800`** give identical statistics from 740 alternate reads and from 3.
- **`zero_variance` exists because t and p are not reproducible there.** Two alleles of one perfectly separated site are algebraically one test, but one residual sum lands on exactly 0 and the other on 1e-18, so t is `Inf` against `8e15` — and raising one pool's depth from 20 to 60 moved which site got which. **A case must assert that the module trapped those rows, never that it reproduced their numbers.**
