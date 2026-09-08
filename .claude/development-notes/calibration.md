# What was measured against a known truth, and the four things it changed

**Written 2026-09-07, against the tree at `15d4c34` plus the uncommitted `analysis.design` scope move. `dev/validation/` and `analysis/modules/association/` are both new — the harness exists, the module does not.** That order is the point: these are measurements taken while the design was still free to change, and three of them changed it.

The harness is `dev/validation/calibrate.R`, four sections, twenty-seven seconds for the cheap three. `dev/validation/README.md` says how to run it and what discipline makes a number there evidence. This note is what the numbers said.

## Why it is not in `test/`

`test/` asserts exact values over eleven hand-computed sites and fails when one moves. That answers *is the arithmetic what we said it was*. A false-positive rate is a rate, a power curve is a curve, and the limit where an assumption stops holding is found by pushing until it breaks — so the assertions here are distributional, the replicate counts are in the hundreds of thousands, and a run is minutes rather than seconds. Nothing here gates a commit.

**The generator never calls `analysis/lib/R/`.** Every draw is `rbinom` and arithmetic. Had the simulation used our own `n_eff` to build its read counts, a wrong `n_eff` would cancel on both sides and the harness would report agreement to twelve figures while being wrong about the world.

## `n_eff` is exactly the variance of a two-stage pooled draw

A pool of `n_chrom` chromosomes at true frequency *p*, sequenced to depth *d*, is two samplings — which chromosomes entered the pool, then which of those the reads found. Conditioning on the first and adding the variances gives `Var(f) = p(1-p)(n_chrom + d - 1)/(n_chrom·d)`, which is `p(1-p)/n_eff` exactly.

**Measured over 54 cells at 200,000 replicates each, the largest deviation is 2.87 standard errors** — what you expect as the maximum of 54 standard normals. The form `n·d/(n + d)`, also in circulation, misses by **27.81**. So the comment in `n_eff.R` saying the −1 is not a slip is now a measurement. The grid reaches `n_chrom = 100` by three routes — ploidy 1×100, 2×50, 4×25 — and they agree, which is what ploidy-generality looks like when it is exercised rather than asserted.

## The closed-form p is calibrated under its own assumptions, which was not what I expected

Across nine cells at 200,000 null sites each — depths 30, 100 and 1000 against frequencies 0.05, 0.25 and 0.50 — the weighted *t* rejects at 0.0494 to 0.0515 for α = 0.05, 0.0085 to 0.0103 for 0.01, and 0.00090 to 0.00142 for 0.001. Including depth 30 with a 5% allele, where the frequencies are nearly discrete.

**So the argument for publishing a permutation p is not that the parametric one is miscalibrated in the ordinary case.** It is exactness at multiallelic sites where the union bound measured 38% inflated, the floor being visible so six pools cannot claim p = 1e-9, and robustness when the assumptions fail. Only the first two were established before this; the third is what the last two sections went looking for.

The far tail is **not** measured. At 200,000 sites the α = 1e-4 column counts tens of events, and that tail is exactly where four degrees of freedom get extrapolated. It wants a deep run of its own.

## The permutation p is conservative over discrete counts, by a factor worth printing

Over the exhaustive 720 relabellings at six pools, no cell rejects more often than its α. **At depth 30 with a 5% allele it runs at 0.36 of the α it was asked for** — 0.0036 against a nominal 0.01. Shallow reads of a rare allele put identical counts in several pools; tied relabellings then give tied statistics, and every tie counts toward the p-value.

That is the test being safe, not broken, so the gate on it is one-sided. But a user who asks for 0.01 and gets 0.0036 is owed the number, and it belongs in the manual beside the floor.

## Clustered pools: rule 17c is right about the df and incomplete about the fit

Six units of two pools, identical sites, five estimators differing only in what they believe about how many independent observations are in front of them. Dispersion is the between-unit variance as a fraction of `p(1-p)`; the first row is the control, where the units are interchangeable and every column must read its α.

| dispersion | pools df10 | pools df4 | means df4 | perm pool | perm unit |
|---|---|---|---|---|---|
| 0.00 | 0.0471 | 0.0183 | 0.0478 | 0.0491 | 0.0448 |
| 0.02 | 0.1230 | 0.0629 | 0.0493 | 0.1255 | 0.0470 |
| 0.05 | 0.1599 | 0.0916 | 0.0468 | 0.1555 | 0.0427 |
| 0.10 | 0.1895 | 0.1145 | 0.0486 | 0.1895 | 0.0454 |

**Taking rule 17c literally — compute *t* from twelve pools, read it against four degrees of freedom — is wrong in both directions.** 0.0183 when the pools really are independent, 0.1145 when they are not. That is the signature of an adjustment applied to the wrong quantity: it never controls the rate and it costs power when there was nothing to correct.

**Averaging within unit before fitting holds at 0.0468 to 0.0493 across the whole range.** The plan named this as *"the better closed-form route, and the one to build if the unit count bites"*. It bites, and it is not an alternative held in reserve.

**Permuting pool labels is as broken as no correction at all** — 0.1895 against 0.1895 at dispersion 0.10. The plan said "permute the phenotype labels" without saying at what level, and the level is the whole thing. Permuting over units holds flat.

**None of this costs a branch.** At one pool per unit the weighted mean of that pool is its own frequency and the unit weight is its own `n_eff`, so the roll-up is the identity and the unit permutation is the pool permutation. A 3-vs-3 design with no replication runs the same code and gets the same answer. The rule to write is *roll up to units first, always* — the degrees of freedom then fall out of the fit instead of being applied to it.

## The weight model: it is `cor(depth, phenotype)`, and it breaks the permutation p rather than the closed form

Six pools of 50 diploids, ten independent poolings per cell, 10,000 sites each. Concentration is a Dirichlet over how much DNA each individual contributed; `even` is the pool `n_eff` assumes and 1 is uniform on the simplex, which leaves a pool carrying about twice the variance of its nominal size.

| depth pattern | cor(y,d) | perm, even | perm, conc 5 | perm, conc 1 | param, conc 1 |
|---|---|---|---|---|---|
| flat | — | 0.0536 | 0.0487 | 0.0499 | 0.0504 |
| mixed | −0.032 | 0.0333 | 0.0344 | 0.0376 | 0.0591 |
| tilted | 0.458 | 0.0454 | 0.0505 | 0.0503 | 0.0571 |
| aligned | 0.891 | 0.0605 | 0.0575 | 0.0558 | 0.0513 |

**Monotone in the correlation and independent of the pooling skew.** At cor ≈ 0 the permutation test runs conservative at two thirds of nominal; at 0.46 it is calibrated; at 0.89 it is inflated, in all three concentrations, 4 to 7.5 standard errors above α. The parametric column at those same three cells reads 0.0500, 0.0491, 0.0513.

**The thing permuting was supposed to protect against is the thing permuting is worse at.** Weighted least squares handles heteroscedasticity when the weights are right; the permutation null shuffles the phenotype across pools carrying different amounts of information, so the observed high-correlation assignment is compared against a null built mostly out of low-correlation ones.

Uneven pooling is second order. Its worst effect is on the closed form at heterogeneous depth — 0.0591, an 18% inflation — and `flat` is clean at every concentration, which isolates the mechanism to depth heterogeneity and not to skew alone.

## The weights are not what is wrong, and this is the turn the whole campaign hinges on

The obvious repair is a better variance model. The fit asserts `Var(fᵢ) = σ²/n_effᵢ`; uneven pooling leaves the truth at `p(1-p)[(1 - kᵢ/n_chrom)/dᵢ + kᵢ/n_chrom]` for a skew factor `kᵢ ≥ 1`, so the excess is `p(1-p)(kᵢ-1)/n_chrom` — depth-free and additive. Write it as `Var = p(1-p)(θ + 1/n_effᵢ)` and the weight `1/(θ + 1/n_effᵢ)` reduces to `n_eff` where read sampling dominates and flattens toward equal where it does not, so low-and-uneven, deep-and-even and deep-and-uneven become limits of one expression instead of a menu of corrections.

**θ is estimable and the estimator is good.** Method of moments over sites — the scatter a site shows, less the sampling variance the weights predict, in units of `p(1-p)` — recovers the analytic truth across two orders of magnitude: 0.00194 against 0.00195, 0.01904 against 0.01885, 0.04334 against 0.04455, 0.25987 against 0.24500.

**And re-weighting by it fixes nothing.** At the failing cell, 0.0609 under `n_eff` becomes 0.0622 under the two-term weights and 0.0607 under equal weights. Three weightings, one answer.

The row that explains it is `aligned` with *even* pooling: θ̂ = 0.00008, no excess dispersion at all, `n_eff` exact, **the weights already right** — and the permutation still rejects at 0.0609. Pools at 30×, 200× and 1000× carry different precision. Weighted least squares handles that for estimation, which is why the closed form sits at 0.0500 in the same cell. But a permutation test needs the observations to be **interchangeable**, and unequal variances are not made equal by weighting them correctly.

**So `depthPhenotypeCor` was the wrong repair for the right problem, and the failure is exchangeability rather than variance.**

## Permuting something that is exchangeable

Under the null the residuals about the weighted mean have variance proportional to `1/w`, and `zᵢ = eᵢ·√wᵢ` does not. So move the *z* instead of the labels:

```
z_i  = (f_i - fbar_w) * sqrt(w_i)          equal variance, interchangeable
f*_i = fbar_w + z_sigma(i) / sqrt(w_i)     put back at THIS pool's precision
```

One permutation σ serves every site in a draw, as the label scheme does, so correlation between sites survives into the null and a genome-wide maximum still means something. For a multiallelic site whole pool **columns** move together, which preserves the sum-to-one constraint exactly: a pool's residuals sum to zero across its alleles, so a rebuilt pool's frequencies still sum to one. Permuting alleles independently would not, and would be a different null.

| depth | concentration | cor(y,d) | labels | residuals | resid+θ |
|---|---|---|---|---|---|
| flat | even | — | 0.0536 | 0.0496 | 0.0518 |
| flat | 1 | — | 0.0465 | 0.0461 | 0.0496 |
| mixed | even | −0.032 | 0.0348 | 0.0512 | 0.0506 |
| mixed | 1 | −0.032 | 0.0392 | **0.0621** | 0.0497 |
| aligned | even | 0.891 | **0.0609** | 0.0535 | 0.0509 |
| aligned | 1 | 0.891 | 0.0503 | 0.0474 | 0.0489 |

**`resid+θ` is calibrated in all six cells.** Three things sit in that table and the middle one is the evidence:

- the failing cell is repaired, 0.0609 → 0.0509
- **plain residual permutation breaks in exactly one cell, and it is the cell where the weights are wrong.** Skewed pooling means `e·√w` is not equal-variance after all, so the scheme's own assumption fails — and it fails nowhere else. θ̂ repairs that cell and only that cell, 0.0621 → 0.0497. The mechanism confirms itself rather than a number coming out right
- the label scheme's conservatism at uneven depth, 0.035–0.039, is **sensitivity given away**, not safety

So θ earns its place as what makes the residuals exchangeable, not as a reweighting of the fit.

**No breakdown was found.** Pushing the pooling from even to an effective pool of two individuals out of fifty — θ from 0 to 0.245 — leaves `resid+θ` between 0.0485 and 0.0597 with no trend, excursions consistent with noise at eight poolings. There is no θ threshold for a guard to sit on within any range a real experiment reaches.

## What it costs the floor, and the answer is better than expected

The label scheme's floor is combinatorial: at 3-against-3 there are `choose(6,3) = 20` assignments, the complementary one always ties because swapping every label negates *t* and leaves |t| alone, so nothing scores below 2/20 = 0.1. That is the property that makes it structurally impossible for six pools to produce a genome-wide significant site. Residual permutation has 6! = 720 rearrangements and an arithmetic floor of 1/720, which looked like giving that away.

Enumerated exhaustively, both schemes, binary phenotype:

| depth | scheme | attainable | smallest reached | FPR .05 | FPR .10 |
|---|---|---|---|---|---|
| flat | labels | 0.0500 | 0.10000 | 0.0000 | 0.0910 |
| flat | residuals | 0.00139 | 0.10000 | 0.0000 | 0.0910 |
| aligned | labels | 0.0500 | 0.10000 | 0.0000 | 0.1057 |
| aligned | residuals | 0.00139 | 0.00556 | 0.0524 | 0.1027 |

**At equal precision the residual scheme reproduces the label scheme exactly** — same smallest p, same rates, to four figures. With equal weights *t* depends only on the two group means, so rearranging residuals within a phenotype group changes nothing and the 720 collapse to the same 20 distinct values, ties included. The design-based guarantee survives untouched wherever it applies.

**The extra resolution appears only when the pools carry unequal precision, and it is calibrated there** — FPR 0.0524 at α = 0.05. A deep pool's frequency genuinely does carry more information than a shallow one's, so the finer granularity is earned rather than assumed. What a reader must be told is that a smaller p in an unbalanced design partly reflects the imbalance, which is a disclosure and not a defect.

## Arity, where the design departs from what other tools do

`S = max|t|` over every allele of a site, read against a null built from the same site — same *k*, same alleles, same sum-to-one constraint. Nothing is bounded, so nothing is corrected.

| k | residual p | min over all × (k−1) | min over alternates × (k−1) |
|---|---|---|---|
| 2 | 0.0463 | 0.0494 | 0.0494 |
| 3 | 0.0513 | **0.0684** | 0.0488 |
| 4 | 0.0450 | **0.0640** | 0.0499 |

**Exact at every arity**, and the selection rate relative to biallelic is 1.00×, 1.11×, 0.97× — no enrichment of multiallelic sites at the top of a table.

**The union bound inflates by 1.37× at k = 3**, which independently reproduces the 38% recorded before this harness existed. And **dropping the reference is calibrated** — it is not a false-positive problem at all, which is why it survived testing once. It is a power problem, and the power section is where it shows.

## Power, which none of the above was evidence of

A test that never rejects never lies, so every section above is only half an argument.

| depth | slope | labels | resid+θ |
|---|---|---|---|
| flat | 0 | 0.0415 | 0.0454 |
| flat | 0.04 | 0.2145 | 0.2037 |
| flat | 0.08 | 0.6517 | 0.6751 |
| flat | 0.14 | 0.9651 | 0.9316 |
| mixed | 0 | 0.0339 | 0.0439 |
| mixed | 0.04 | 0.1834 | **0.2121** |
| mixed | 0.08 | 0.5074 | **0.5223** |
| mixed | 0.14 | 0.9524 | 0.9153 |

At even depth the two are equivalent. At uneven depth `resid+θ` recovers the sensitivity the label scheme's conservatism was costing, in the mid-power range where the difference decides a finding.

**At very large effects the residual scheme is slightly weaker** — 0.9153 against 0.9524 — and the reason is structural rather than incidental: the residuals are taken about the null model, so at a strong alternative they carry the signal, and permuting them builds a null that is itself inflated. It matters little where both are above 0.9, and it is a real property to state rather than discover.

And the triallelic site the multiallelic decision exists for, where both alternates rise and the reference falls by their sum:

| slope | max over all | min over alternates × 2 | min over all × 2 |
|---|---|---|---|
| 0.04 | **0.4668** | 0.3337 | 0.5854 |
| 0.08 | 0.9408 | 0.8646 | 0.9871 |

**Dropping the reference costs 40% of the power** at the effect size where power is decided. The third column is higher only because it is mis-sized — the same union bound measured at 1.37× its nominal rate above — so it buys detections with false positives and is not a comparison at matched size.

## Three corrections to the harness, and one of them is a trap the module inherits

**`count/B` is not a permutation p-value.** The raw fraction can return 0, and no permutation p can be 0 — the observed labelling is always one of the labellings. On data satisfying every assumption of the model it rejected at 0.0569 against a nominal 0.05 at B = 300. **The valid form is `(1 + count)/(1 + B)`, and a module that samples permutations rather than enumerating them inherits this directly.** An enumerated null needs no correction: the observed labelling is already in the set being counted. Probed to be sufficient — exhaustive 720 gives 0.0508, sampled 300, 1000 and 3000 give 0.0466, 0.0517 and 0.0508.

**A binomial margin over sites is too tight, because sites are not independent trials.** Every site inside one run shares a phenotype and the same permutation draws. At 100,000 sites that margin called the harness's own control a failure. The gate now uses the spread measured across independent poolings, which assumes nothing about what happens inside one.

**A nuisance drawn once is a realisation and not a measurement.** The first version of the weight section drew each pool's contribution vector once per cell, so a row said what happened to one pooling. The same cell read 0.0716 at 10,000 sites and 0.0521 at 50,000, and the difference was which vectors the stream handed out — not sampling error on the rate. Every cell is now averaged over ten poolings, and the spread across them is reported beside the mean, because a study is one draw from that spread rather than the average of ten.

## Six pools is not a general claim, so the number of them was swept

Depths in ascending blocks over a phenotype that rises with the pool index, pooling held even so the two schemes differ only in what they permute.

| pools | floor | null labels | null resid+θ | power labels | power resid+θ |
|---|---|---|---|---|---|
| 4 | 0.0833 | 0.0155 | 0.0000 | 0.0306 | 0.0004 |
| 6 | 0.00278 | **0.0611** | 0.0481 | 0.1530 | 0.1366 |
| 8 | 0.00005 | **0.0578** | 0.0486 | 0.2260 | 0.2190 |
| 12 | — | **0.0566** | 0.0520 | 0.3625 | 0.3512 |
| 20 | — | 0.0496 | 0.0512 | 0.5886 | 0.5945 |
| 30 | — | 0.0503 | 0.0514 | 0.7904 | 0.7979 |

**The label scheme's failure is a small-design problem and it decays with n** — 0.0611, 0.0578, 0.0566, 0.0496, 0.0503. By twenty pools it is gone: more pools means the null averages over more assignments and the observed one stops being special. So the whole exchangeability failure lives exactly where pool-seq lives, six to twelve pools, and disappears where nobody would have worried.

`resid+θ` is calibrated at every n from 6 to 30 and matches or beats the label scheme on power throughout.

**Four pools is not an analysis.** The floor is 2/4! = 0.083, so α = 0.05 cannot be reached by relabelling at all, and the power column is incoherent — 0.0306 one way and 0.0004 the other. That is a refusal.

**And the n = 4 row exposes a trap the module has to keep avoiding.** The label scheme shows 0.0155 there, which should be impossible against a floor of 0.083. It happens because the harness *sampled* 150 draws from a set of only 24 orderings, and `(1 + r)/(1 + B)` then reaches below the true floor by luck alone. **Sampling a permutation set small enough to enumerate silently breaks the floor guarantee**, so enumerating when the set fits is a correctness requirement and not an optimisation, and it wants a case that would notice if someone changed it.

At a slope of 0.04 with even depth, power runs 0.17 at six pools, 0.28 at eight, 0.46 at twelve, 0.75 at twenty, 0.91 at thirty. Uneven depth costs roughly a fifth throughout. That table is what a researcher wants before they spend money.

**Why this arm holds pooling even, which a first pass did not.** Run at Dirichlet concentration 1, the sweep showed the label scheme's failure largely *gone* — and that is not a contradiction of the table above, it is a second effect on top of it. Heavy pooling skew makes every pool noisy, and that noise swamps the depth differences that break exchangeability in the first place. So concentration and pool count interact, and a sweep that moved both would have reported their sum as if it were the effect of n. Pooling is held even here for that reason, and concentration is `breakdown`'s question instead. The interaction is real and is not measured anywhere: nothing establishes how much skew it takes to mask a given depth-phenotype correlation.

## Against an independently written tool

`dev/validation/external.R`, against **BayPass 3.1** (Gautier 2015) — Fortran, Bayesian, MCMC, models population structure through an Ω matrix and returns a Bayes factor. Nothing about it resembles what we do except the question it answers.

**The two are never compared to each other directly.** Different statistics on different scales cannot agree numerically and it would mean nothing if they did. Both are scored against the sites that were *planted*, which neither can see, at 20 pools and 1,200 sites of which 100 carry an effect.

**Biallelic, which BayPass reads natively:** PoolSeqFlow recovers **46%** of the planted sites in its top 100, BayPass **44%**, and the Spearman correlation between our −log₁₀(p) and its BF over all 1,200 sites is **0.764**. Two unrelated implementations of two unrelated statistics, ranking the same genome the same way.

**Triallelic, which its input format cannot express.** BayPass takes two counts per pool, so the site has to be reduced first — and the reduction is the user's choice:

| | both alternates rise together | alternates move against each other |
|---|---|---|
| PoolSeqFlow, max over all | 49% | **23%** |
| BayPass, first alternate | 44% | 16% |
| BayPass, alternates summed | **53%** | 10% |

Random guessing recovers 8.3%. **Neither reduction is right for both shapes.** Summing the alternates is the *best* answer when the reference carries the signal — better than ours, because it is one test where ours pays a small multiplicity cost — and it is very nearly the *worst possible* answer when the alternates carry it between them, collapsing to 10% because summing them cancels the signal outright. Reading one alternate does the reverse, less dramatically.

A genome holds both shapes and nothing in the data says which a site is. **The module is never asked, because it reads every allele** — which is the whole content of the multiallelic decision, now measured against an outside tool rather than argued.

## What the campaign settled, in one place

1. `n_eff` is exactly the variance of a two-stage pooled draw, and the `n·d/(n+d)` form is not.
2. The closed form is calibrated on an ordinary null site and makes impossible claims on a degenerate one. Only the second is a reason to publish a permutation p.
3. Degrees of freedom AND the fit both come from units. A pool-level statistic read at the unit count controls nothing.
4. Label permutation is invalid when precision correlates with the phenotype, and conservative when precision merely varies. It is not the assumption-light test it appears to be: the statistic it permutes is weighted, so it already concedes that pools differ, while the null it builds denies it.
5. The repair is not in the weights. It is to permute the standardised residuals, which are exchangeable, using θ to make them so.
6. That preserves the combinatorial floor exactly where precision is equal, and earns finer resolution only where it is not.
7. `max|t|` over every allele is exact at any arity; the union bound is not, and dropping the reference costs power rather than calibration.

**Which is why the module is model-based, and says so.** Z, 2026-09-07: *"This tool becomes model-based. We detail when to use which model in the manual… if someone has a different use I will sit down and develop it as soon as possible, so they can come to me instead of trying to fit their data into an analysis when it does not fit."* The price of that is that failure gets quieter, so the diagnostics are **published and not merely checked** — a guard that passes tells a reader nothing, while a printed θ̂ says what the model had to absorb on their behalf.

## What is still not established

Everything above is six pools at `n_chrom = 100`, base frequency 0.5, one quantitative phenotype shape apart from the floor section. There is **no sweep over the number of pools**, no covariate arm — so the interaction between weighted FWL and residual permutation is unmeasured — nothing in the far tail below α = 1e-4, and no comparison against an independently written tool. The module implements label permutation as this is written and not the residual scheme.

Those are the next tiers. None of them is done, and the manual cannot claim what they would establish.
