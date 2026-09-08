# Why the distance is Nei's minimum distance

**Written 2026-09-08, against the tree at `4cb4cff`.** Nothing has overtaken it: F3 was built from these measurements in the same session. The manual is authoritative on what the numbers mean; this is the record of how the statistic was chosen and what was measured on the way.

## The question Z asked

The roster's original formulation was `d(A,B) = Σ_sites Σ_alleles |f_A − f_B|`, which is Prevosti's distance. An earlier session measured that it makes depth the first MDS axis and proposed Nei's minimum distance instead. Z pushed back with a specific alternative, and it is a better one than the roster's:

> *"consider the distances within a site with larger effects and between sites the effect is additive but not A + B. My original idea was to calculate d(AB) = sum( | p(A) - p(B) |) for the site and assume that each site is orthogonal to each other and calculate the sqrt (sum (d(AB) ^2 )) not even average it over the sites."*

L1 within a site, L2 across sites. The question was what makes Nei's better than that.

## The finding: at a biallelic site they are the same statistic

`Σ_j |Δ_j| = 2|Δ|` at k = 2, so Z's per-site term is `d_s² = 4Δ²`, and Nei's raw per-site term is `½(Δ² + Δ²) = Δ²`. Measured over all 15 pairs of a six-pool simulation:

```
Z's D²  against  4 · S · Nei_raw
max relative difference: 3.074e-16
```

So Z's proposal **is** Nei's uncorrected form, up to a global scale that `cmdscale` absorbs. The "each site is orthogonal, accumulate Pythagorean" intuition was right and is exactly what Nei's squared form implements. There was never a disagreement about the geometry.

## What actually separates them, and it is only two things

**1. The correction, which is where the whole benefit is.** Six pools from ONE population, two at 30× and four at 400×, 20 000 sites:

| | Prevosti | Z's form | Nei raw | Nei corrected |
|---|---|---|---|---|
| 30–30 | 0.09660 | 35.21 | 0.015493 | −0.00030 |
| 30–400 | 0.07890 | 28.37 | 0.010058 | −0.00012 |
| 400–400 | 0.05301 | 19.13 | 0.004575 | +0.00002 |
| **shallow:deep** | **1.822** | **1.840** | **3.387** | — |

**Going from mean-of-`d_s` to root-sum-of-`d_s²` moved the depth artefact from 1.822 to 1.840 — it does not help.** Both are linear in the noise scale, so the ratio survives. The correction is the only thing that removes it, and Z's form already does the one thing that makes correction possible: it squares, at the site level, which is the level the correction lives at. It is *Prevosti* that cannot be corrected, because it never squares.

**2. Multiallelic sites.** `(Σ|Δ_j|)² = ΣΔ_j² + 2Σ_{j<k}|Δ_j||Δ_k|`. The cross-terms treat a site's co-segregating alternates as *aligned* while the across-site sum treats sites as orthogonal — inconsistent with the premise Z applied. Measured per site, same mass moved:

| site | Z's per-site | 4 × Nei | ratio |
|---|---|---|---|
| biallelic | 0.16000 | 0.16000 | 1.000 |
| triallelic, shift onto one alt | 0.16000 | 0.16000 | 1.000 |
| triallelic, shift split over two | 0.16000 | 0.12000 | 1.333 |
| tetrallelic, split over three | 0.36000 | 0.24000 | 1.500 |

The cross-terms also have no closed-form expectation, so at k ≥ 3 the correction is unavailable in principle and not merely in practice.

## What was measured about multiallelic sites, including two negative results

Z asked specifically about these. The correction is **k-agnostic** — `Σ_j Var(f̂_j) = h/n` whatever the arity, so the same expression is exact at every k. Residual after correction: 2.08% of the raw bias at k=2, 0.94% at k=3, 1.05% at k=4. **Nothing in the module branches on arity, and this is why.**

Multiallelic sites take more than their share of the distance under both forms — at 5% of sites they carry 7.9% of Z's distance and 6.1% of Nei's; at 15%, 22.3% against 17.8%. Under the null that excess is entirely the higher `h` at those sites, which is exactly what the correction removes.

**Two negative results worth keeping, because both were expected to go the other way:**

- **The over-weighting does not compound the depth artefact.** 1.836 restricted to multiallelic sites against 1.840 over the whole corpus.
- **It does not move the ordination.** Three populations × two pools at Fst 0.03, Procrustes residual between the two forms: 0.00000 at uniform depth, 0.00213–0.00363 with uneven depth, across 0–35% multiallelic. Algebraically real, empirically immaterial once there is any structure to find.

**And one that inverts a premise in the plan.** The plan attributes the negative-eigenvalue trap to L1 not being Euclidean-embeddable. Measured, **Z's form produced zero negative eigenvalue mass in every cell and Nei corrected produced up to 0.59%** — because Z's form is an L2 accumulation which at biallelic sites is squared Euclidean and therefore PSD, and it is subtracting a *different correction per pair* that perturbs the matrix off the cone. True of Prevosti, not of the form we adopted. Both trivial at these magnitudes; the reporting obligation stands but the reason for it is different from what was written down.

## The constant, derived rather than ported

The plan flagged this as the one unverified item, on F1's lesson about `n_eff`. It is now derived and unit-tested:

`D_m = (J_X + J_Y)/2 − J_XY` expands to `½ Σ(x−y)²` — verified at k = 2, 3, 4. The unbiased homozygosity estimator `(n·Σx² − 1)/(n − 1)` equals `Σx² − h/(n − 1)`, verified at three effective sizes. `J_XY` takes no correction because the two pools are sequenced independently. Both are cases in `test/tools/r_lib_tests.R` under `nei_distance`, with the arithmetic written out beside each.

**Why the code is written in the `J` form rather than as `½Σ(f_A − f_B)²`:** they are the same number, but the correction attaches to `J` and not to the difference, so the `J` form makes it obvious that there are two subtracted terms and not three.

## A residual the manual states rather than hides

The correction slightly **over**-corrects at shallow depth. Over 12 replicate simulations, mean residual −1.24e-4 at 30–30 against −0.09e-4 at 400–400, with 10 of 12 replicates putting the shallow pair *below* the deep pairs. Residual spread 1.15e-4 against a raw spread of 1.09e-2 — the artefact is down ~95× — but it runs the opposite way, so shallow pools come out marginally too **close** rather than too far. That is the conservative direction. It is the `n_eff` approximation showing through and is largest where `n_eff` is smallest.

## Rcpp, and the number that justified it

Z: *"for the distance calculations we should definitely use Rcpp."* Measured by `dev/scripts/bench-compiled-paths.R` at 3.2M sites, scaled to 100M, six pools: **710 s vectorized against 22 s compiled, 32×.**

That ratio is not the parsers' ~10× and should not be averaged with it. The vectorized form makes one `rowsum` pass per *pair*, so what compiling removes is interpreted call overhead growing with the square of the pool count, where the parsers grow with the site count in memory traffic. The consequence for the manual: `mds` is the one module whose statistic costs about as much as reading the table for it — 675 s parse + 710 s distance vectorized, against 69 + 22 compiled.

## Where the code lives, and why the first answer was wrong

I argued for module-local placement on a versioning argument: anything under `analysis/lib/` bumps `analysis/frame.version`, so F3's arithmetic moving would re-stamp provenance for `basicstats` and `association`. Z overruled it:

> *"I think we should move distance calculation to the lib. I think it is for our peace of mind and ease of bug fixes later too. I don't think we are planning to use the distance now, but we might in the future for other types of analysis that are not planned or thought out at the moment."*

The better argument for the library is one neither of us made first: **in `analysis/lib/R/` the arithmetic is covered by `08_analysis_rlib`, which is `cost: static` and runs in three seconds with no JVM.** That is the fastest loop in the project and the right home for a numeric kernel. The version churn is real and is the smaller cost.

So `nei_distance.R`, `add_distance.R` and `mean_distance.R` are library files (one function each, per that directory's rule) and `nei_distance.cpp` sits with the other two compiled forms. `ordinate()` and `axis_shares()` stayed in the module: they are what `mds` makes of a distance matrix, not the distance.

## Questions that were settled by precedent rather than re-argued

- **The `*` spanning deletion.** It reaches the SNP table and its frequency is depth-dependent in a way an ordinary allele's is not, and a site carrying it is multiallelic by construction — so it lands in exactly the bucket that gets extra weight. `basicstats` already ruled: it is one allele of the site like any other, and dropping it would renormalise the site to something no pool was sequenced at. `mds` carries the same gate rather than inventing a second answer.
- **Pools, not units.** Rule 17c collapses to units because degrees of freedom come from units. An ordination is not a test and has no degrees of freedom, and two pools of one unit landing apart is the thing an ordination is read to see. `mds.tsv` carries the unit as a label so a reader can tell which points should have coincided.

## Two implementation traps, both found by building it

- **`D_m` is a squared distance and `cmdscale` squares what it is given.** `cmdscale(D_m)` ordinates a quartic; `cmdscale(sqrt(D_m))` hits `NaN` on the negative entries the design deliberately does not floor. `ordinate()` double-centres directly, which is what `cmdscale` does internally, needs no square root, and is what lets the "not floored at zero" promise be kept. `test_the_coordinates_reproduce_the_distance_matrix` is the guard.
- **`n_eff` is exactly 1 at depth 1, whatever the pool holds** — `n·d/(n + d − 1)` with `d = 1` is `n/n`. So the correction divides by zero at any single-read site, and since observed `h` is 0 there it arrives as `0/0`. Made an explicit NA and a dropped site. The same expression is 1 for `n_chrom = 1` at *every* depth, which is a single haploid individual and is refused at load.

Related: `depth-cutoff.md` for how depth reaches a published number elsewhere, and `calibration.md` for the corpus this module's expectations were added to.
