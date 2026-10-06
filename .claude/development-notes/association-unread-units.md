# Association over the units a site was read in

**Written 2026-10-05, against `dev` at `7419281` plus uncommitted work**: the change described here (`association` `20261005.001`), the moot `dropZeroDepth` off-branch fix, the `run_tests.sh` changes, and `depth-masking-proposal.md`, which records how the defect was found.

## What was wrong

One unit with no reads at a site made that site's enumerated `perm_p` exactly 0. `fit_alleles()` zeroed the NA weight, so the fit itself was sound, but `permutation_p()` built `center` from the raw weights: every rearranged statistic came out NaN, the identity was never counted, and `fdr_p` followed to 0 while lowering every other site's adjustment. The published `association-20260910.004` carries the same code.

Two more places shared the blind spot. `roll_up()` summed a unit's pools without `na.rm`, so one unread pool blanked a unit of several. `dispersion_of()` took its moments over every unit, so a pool unread at every site, a failed library, made theta NA, and a run estimating dispersion then tested nothing.

## The obvious fix is wrong

Zeroing the unread units and keeping the one global permutation reports p-values below what the site supports. Every rearrangement moves residuals across all n units, so a read unit is handed an unread unit's zero in most of them, and the null is built from residuals the site never had. It reported p below 1/m! at sites read in m units. The comment over the per-site rearrangement said this during the build and moved here in the comment pass.

## What it does now

Each site is rearranged among the units it was read in. `tally()` groups a bin's sites by the set of units read. For each global rearrangement, a group read in M takes the residuals of M's units in the order they appear in that rearrangement, and an unread unit keeps its own zero. The order M's units take inside a uniform permutation of all n is a uniform permutation of M, and across the n! enumerated rearrangements each of M's m! orders appears exactly n!/m! times, so the enumerated p is the exact m-unit test. By the same argument a sampled p is an unbiased estimate of that test, and the verification below measured it so. A bin in which every site is read in every unit takes the original single expression.

Around that, `permutation_p()` zeroes weights that are NA or not positive and the frequencies under them, as `fit_alleles()` does. `roll_up()` makes a unit the n_eff-weighted mean of its pools read at the site, with weight and frequency NA when none were. `dispersion_of()` estimates theta per site over the units read there, skips a site read in fewer than two, and is NA only when no site has two, which is a run with nothing testable anyway; the weights are then left as they are. A site whose read units all carry one phenotype value has no slope and is not tested, which `spread_of()` decides on the stored values.

## Decided by Z, 2026-10-05

**At least three measured values to test a site.** A site read in fewer than three units is not tested. Its row in `association.tsv` stays, with `n_observed`, and `S`, `perm_p` and `fdr_p` NA; BH runs over the tested sites only, as it already did. Z first said "eliminate"; asked whether that meant dropping the row, Z answered "don't test them", and the row stays because the manifest documents the table as one row per site, always complete.

**A unit of technical replicates is the mean of its lanes that were read**, by `rowSums(..., na.rm = TRUE)`. Z: "Rowsum looks correct."

**NA for what does not exist.** The first build gave a unit with no read pool weight 0, which `na.rm` in `roll_up()` makes of an all-NA row, and `mean_weight` then averaged the 0 in: 33.4 at `chr10:500`, read in 2 of 6, where the two read units average 100.25. Z: "NA for non existant is correct." A unit with no read pool now has weight NA, and every aggregate over units leaves it out. `mean_weight` is the mean over the units read at the site. `max_leverage` is the largest over them, and NA where there is no slope to carry. A line that also dropped unread units from that maximum, on the reasoning that `pmax()` with `na.rm` would turn a one-unit site into 0, was reverted: run against the case, removing it changed nothing, because whenever the read unit's leverage is NaN every unread unit's is NaN too (0 times an infinite term), and when it is finite a 0 never wins. `depth_phenotype_cor` correlates the phenotype with each unit's mean weight over the sites it was read at, and a unit read nowhere drops out. That is the rule `basicstats` took for its depth summaries on 2026-09-29.

## What an untested row shows

Measured on the corpus with `chr10:500` read in 2 of 6 units: `S`, `perm_p` and `fdr_p` NA, `mean_weight` 100.25 over the two units read, and `max_leverage` 1 and `zero_variance` 1, both true of two points on a line. A site read in one unit, or in units that share one phenotype value, has no slope, and both are NA there. Its alleles do not appear in `association_alleles.tsv`, because selection by `reportBelow` and `reportTop` passes over an NA p, so the NA written into their `b1`, `se`, `t` and `p` is not visible in any published table today.

## The floor is 1/n!

The identity always ties, so a design of n units cannot fall below 1/n!, and a site read in m units cannot fall below 1/m!. Nothing guarantees that the reversal ties: it negates the slope exactly only under a symmetry of phenotype and depths that a real design rarely has. Measured on the corpus, `chr2:550`, read in all six units, reaches 1/720, and `chr1:700`, read in four, reached 1/24 = 0.042. I told Z 2/m! during the build and corrected it.

The module said otherwise, and contradicted itself. The manifest gate that opened "THE SMALLEST P ANY DESIGN CAN REACH" and the comment over `limit` in `association.R` said 2/n! and that four units cannot reach 0.05. `design_floor` was 2/n! while `floor`, enumerated, was already 1/n!, so the comment over them, which says the two differ only when the set is sampled, was false. The manual's `#association-floor` opened with the 2/n! claim and a table to match, then read the two numbers as the floor at similar depths and the reach at differing ones. The per-site message added in this change used 1/m!, so a design of four units was told nothing could be significant while a site read in four of six was not flagged.

**Ruled by Z, 2026-10-05: "1/n! is right. correct the statements."** `design_floor` is 1/n! and, enumerated, equals `floor`. The ranking sentence fires at three units and no longer at four. The manifest gate and the manual's floor section were rewritten: the table starts at three units, a site's own floor is stated, and a paragraph says what ties do. Two test comments and the floors case were corrected; the case now asserts 1/720 and that an enumerated `floor` equals `design_floor`, and a new case runs four units (1/24, tested, no ranking sentence) against three (1/6, the sentence). `dev/validation/calibrate.R` and `lib.R` keep 2/n!, which is right there: they move labels on an evenly spaced phenotype, where the reversal always ties, and their comments now say so. `calibration.md` is a dated note and is left as written.

## Adversarial verification, 2026-10-05

Four agents attacked the change and a fifth checked what they had covered; the transcript is at `~/.claude/projects/-home-tholian-Nextcloud-GitHub-PoolSeqFlow/7de5ecd1-0266-4a1d-aeb2-69c4394fc0c5/subagents/workflows/wf_77aa51c3-634/`. The arithmetic held: partly read sites agree with independent oracles on thousands of values, fully read data reproduces HEAD, the compiled parse, two and three workers and bins of one to four sites publish byte-identical tables with unread cells, the sampled path sits within Monte Carlo error of the exact p (120 end-to-end runs and 1000 in-process calls at 400 draws), and 8000 simulated null sites with each pool unread at probability 0.3 rejected at nominal for sites read in four, five and six units and conservatively in three. The NA-weight ruling moved `mean_weight`, `depth_phenotype_cor`, `design_floor` and the ranking sentence and nothing else, over 127 compared inputs.

What they broke, each fixed and given a case:

- **A site read in three or more units that all carry one phenotype value was tested on rounding.** A weighted mean of one repeated value need not return it (15.1 came back 15.099999999999998), so `sxx` was 5e-28 rather than 0 and the slope over it published `S` near 1e-16 and `perm_p` 1, counted in BH's n and in `lambda_gc`. Unread units are what make such a site reachable. `spread_of()` tests the stored values; such a site is untestable, and its `max_leverage` and `zero_variance` are NA.
- **`max_leverage` 2 at a site read in one unit**, by the same mechanism, at 11.5% of unit and depth combinations on the corpus phenotype. HEAD published NA there, its NA weights propagating, so this was a regression of round 1. NA again, through the same test.
- **No `qq.png` when nothing was tested**, and the frame refuses a folder missing a declared output (`readmeShell()` in `analysis/lib/nf/outputs.nf`). The three-value rule makes such a run ordinary. The figure is drawn with a line saying nothing was tested, and the log says it too.
- **An NA theta took every weight with it.** With dispersion estimated and no site read in two units, `n_observed` was published as 0 where one unit was read. Pre-existing at HEAD. The weights are left as they are and `dispersion` is published NA.
- **The strongest sites published `perm_p` 0**, pre-existing since F2. The tie test was an absolute `seen - 1e-12`, and the identity, rebuilt, lands up to 4e-14 of S away from S, so above S of about 100 it went uncounted and nothing else reached S: 15 of 400 near-linear sites, 2 to 8% of sites with S over 100 in near-collinear tables, 0.38% of realistic fixed-difference binary sites. It contradicted the floor sentence Z had just ruled on. The tolerance is absolute below 1 and relative above it, in the module and in the oracle, and the 15 publish exactly 1/720.
- **Wording.** The new message said "tested site(s) ... ranked, not tested"; the manifest said an unread pool "carries weight zero"; the manual called `mean_weight` an effective sample size under an estimated dispersion too; and the ties sentence named equal depths and an evenly spaced phenotype, where the condition is equal weights and a phenotype symmetric about its mean, and missed the doubling a balanced categorical phenotype gets from the swap of its levels (3 against 3 at equal depths: 72 of 720 tie, so 0.1).
- **Stale floor statements predating today**: in `freq_corpus.py`, 2/20 at chr10:1600 where the corpus publishes 1/720, 4/720 where it publishes 9/720, and "capped at 0.1" where it publishes 6/720; in `calibrate.R`, 1/720 "whatever the phenotype's shape", false for its own flat rows.

The suite could not fail on most of round 1, measured by running mutants of the module through its own cases: the new message, the shortcut for a fully read bin, grouping sites by how many units read them rather than which, the dispersion arithmetic, the weighting inside a unit, BH's n, and the warning the allele-row mask suppresses. Each now has an assertion. The oracle gained `--units`, `fdr_p` and theta, and the cases compare every site against it.

Not fixed, and left to Z:

- A depth table holding exactly one site stops `association.R` at `colnames<-`: the weight matrix collapses to a vector. Pre-existing and unrelated.
- Enumeration is capped at eight units whatever the budget, which the manual now says. With nine or more and `permutations` above n!, a sampled p can fall below 1/n!.
- Dropping the ranking sentence at four units leaves the default output less cautious than HEAD's. Under BH an `fdr_p` of 0.05 needs about 83% of tested sites at the floor at four units, 17% at five and 2.8% at six.
- The m-unit test assumes that which units were read at a site is unrelated to what they carry. A pool unread because of its own genotype breaks that, and no gate says so.

## Verification

`freq_corpus.py --association-from <depth table>` is the oracle: plain Python that leaves out a pool with depth 0 at each site and enumerates the read units' own m! rearrangements directly, so it shares neither code nor the induced-order construction with the R. The corpus files it writes, `expected.tsv` included, are byte-identical to HEAD.

On the corpus with sites read in 6, 5, 4, 3 and 2 units, R and the oracle agree at all 14 sites. Each fix, reverted alone, fails its case:

| reverted | what the case saw |
|---|---|
| the per-site rearrangement and the zeroing | `perm_p` 0 at the partly read sites |
| the three-value rule | the 2-unit site published `S` = 0 |
| `na.rm` in `roll_up()` | `n_observed` 2 and `S` NA where a unit kept one read pool of two |
| `dispersion_of()` | theta NA and nothing tested, with one pool unread everywhere |

**`assert_close` in `test/lib/analysis.sh` could not fail on a missing value.** It compared through awk, which reads `NA`, `NaN` and `Inf` as 0, so "expected 0, got NA" passed, and the three-value revert passed under it. It now requires those tokens to match literally. Another entry for `gates-that-stopped-checking.md`.

Suites, with `TEST_CONDA_ENV` at `PoolSeqFlow-3.2.0` and `TEST_ANALYSIS_ENV` at `PoolSeqFlow-3.1.1-analysis`: association, basicstats and mds in full, 39 passed; `--fast` 401 passed, 0 failed, 234 skipped, every skip `(--fast)`; `00_static` 52 passed; `check-analysis-versions.sh` clean. Those ran before the comment pass, which changed no code line: the non-comment lines of `association.R` are identical before and after it, and the file parses.

After the rulings and the verification's fixes: association 15 passed, `00_static` 52 passed. The corpus files `freq_corpus.py` writes, in both of its modes, are still byte-identical to HEAD's, through the oracle's rewrite onto units. Each guard was reverted alone in a copy of the module and run through the suite's own cases from a stand-in `REPO_ROOT`, so the repository file never changed: 21 of them, and each failed the case meant to catch it, while round 1 as it stood fails all seven of the cases this work touched. A 22nd mutant passed, which proved a line redundant: the allele p-values computed over every site rather than the tested ones, since the t-ratio is already NA where untested and `pt()` returns NA for NA without warning. The line was simplified, and removing the mask itself now fails the case on its warning.

## Not exercised

The suite's cases run enumerated and one worker; `test_both_paths_through_the_parse_agree` now parses two partly read sites both ways. The sampled path, several workers and several bins with unread cells were run by the verification above and are not in the suite. Not run anywhere: the frame on a run that tests nothing, which was read from the code and not driven through Nextflow; real data with zero-coverage cells; a missing-cell scenario in `dev/validation/calibrate.R`; and more than 20,000 sites.
