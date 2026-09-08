# Validation

Measurements of whether the numbers the analysis layer publishes mean what they claim, taken against data simulated from a known truth.

## This is not the test suite

`test/` asserts exact values over eleven hand-computed sites: every count is written out, every expectation is derived by a plain Python loop, and a case fails when one number moves. That answers *is the arithmetic what we said it was*.

This directory answers a different question — *does the method behave* — and it cannot be answered by any exact value. A false-positive rate is a rate; a power curve is a curve; the limit at which an assumption stops holding is found by pushing on it until it breaks. So the assertions here are distributional, the replicate counts are in the hundreds of thousands, and a run takes minutes rather than seconds. Mixing the two would make the suite slow and make its failures ambiguous.

Nothing here runs in `run_tests.sh` and nothing here gates a commit. **What ships is the chapter written from these numbers**, not the harness.

## The discipline that makes it worth running

**The generator never calls `analysis/lib/R/`.** It draws with `rbinom` and arithmetic and nothing else.

This is the whole reason a measurement here is evidence. If the simulation drew its read counts using our own `n_eff`, a wrong `n_eff` would cancel on both sides and the harness would report agreement to twelve figures while being wrong about the world. The library is on trial; it does not get to write the exam.

The same rule holds for every section added later: the truth is constructed from first principles in the harness, and only the thing being judged comes from the library.

## Sections

| section | what it answers |
|---|---|
| `n_eff` | Is `n_eff` the variance of a two-stage pooled draw? Everything the analysis layer weights rests on this one identity |
| `parametric` | How often does the closed-form weighted *t* reject a site that has no association at all? Reported and never gated — these numbers are the evidence, and a gate would turn them into a test result |
| `permutation` | Does the published p reject at the rate it was asked for? Gated one-sided: over discrete counts a permutation test is legitimately conservative, so rejecting below alpha is safe and rejecting above it is not |
| `units` | Pools that are not independent. Five estimators over identical sites, differing only in what they believe about how many independent observations there are |
| `weights` | The weight model itself being wrong — uneven pooling, and depths that line up with the phenotype. Averaged over many poolings, because how badly one arrangement misleads a fit is itself a draw |
| `dispersion` | Whether a better variance model repairs any of that. It does not, and the row that shows why is the one where the weights were already right |
| `exchangeable` | Permuting the standardised residuals instead of the labels, with and without the estimated θ that makes them exchangeable |
| `breakdown` | How far that carries, from even pooling to an effective pool of two individuals, looking for the value a guard should sit at |
| `floor` | What the residual scheme does to the smallest p a 3-against-3 design can reach. Both schemes enumerated exhaustively, so the answer is exact |
| `arity` | Whether the site statistic is fair to sites of different allele counts, against the two alternatives the design rejected |
| `power` | What the thing can actually see. Every other section measures when it lies, and a test that never rejects never lies |
| `pools` | The same questions swept over the number of pools, because six is not a general claim |

## The two scripts

`calibrate.R` judges our arithmetic against our own idea of the truth. `external.R` judges it against BayPass, which shares none of our code and none of our statistics — and scores both against the sites that were planted rather than against each other, since two different statistics on two different scales cannot agree numerically and it would mean nothing if they did.

Both source `lib.R`, which holds every generator and estimator they share. They fit and permute identically or neither result says anything about the other, so nothing is defined twice.

```
Rscript dev/validation/external.R analysis/lib/R /tmp/bp 1200
```

BayPass is `g_baypass` on the PATH, and it lives in an environment of its own:

```
conda create -n poolseqflow-validation -c conda-forge -c bioconda baypass
conda activate poolseqflow-validation
```

**Not in the analysis environment**, and not in `install/environment-analysis.yml`. Nothing an analysis runs calls it — no module, no test, only the script above — so shipping it would put a Fortran binary into every user's environment for one command run once per release. It would also be the only line in that file no analysis touches, which is what E8's package manager exists to notice: the analysis environment matching its own record is the guarantee, and a hand-added package is exactly the mismatch it reports.

`external.R` checks for it and stops with the install line if it is absent, so a machine without it gets a sentence rather than a crash.

Run one section, or all of them:

```
Rscript dev/validation/calibrate.R analysis/lib/R
Rscript dev/validation/calibrate.R analysis/lib/R n_eff
Rscript dev/validation/calibrate.R analysis/lib/R n_eff 500000
```

The third argument is the replicate count per cell; it defaults low enough to run in seconds and high enough to separate the hypotheses. Every run prints the seed it used and is reproducible from it.

Base R only, like the library — no packages to install, and it runs under either conda environment or a bare `Rscript`.
