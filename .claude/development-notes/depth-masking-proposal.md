# Masking shallow cells instead of dropping sites, and the association defect it exposed

**Written 2026-10-05, against `dev` at `d76ba2f` plus uncommitted work** (the `dropZeroDepth` off-branch fix to `FMT/DP<minDP & FMT/DP!=0`, the `run_tests.sh` conda-hook fix, and the release-ordering changes). Nothing described here was built when this was written; the last two sections record what was. Every factual claim below was measured by one agent and reproduced by an independent adversarial verifier on VCFs each wrote separately; the transcript is at `~/.claude/projects/-home-tholian-Nextcloud-GitHub-PoolSeqFlow/7de5ecd1-0266-4a1d-aeb2-69c4394fc0c5/subagents/workflows/wf_22eb7ad1-d8d/`.

## The proposal, Z, 2026-10-05

Today one pool below `minDP` removes a site for every pool, so the shallowest library sets the cohort's threshold. Z proposed masking instead: every cell below `minDP` becomes unmeasured, and a site survives if enough pools remain measured.

| site | depths | after masking at minDP 20 | measured pools |
|---|---|---|---|
| 100 | 25,30,40,35 | 25,30,40,35 | 4 |
| 200 | 0,30,40,0 | 0,30,40,0 | 2 |
| 300 | 25,30,5,10 | 25,30,0,0 | 2 |
| 400 | 0,30,5,10 | 0,30,0,0 | 1 |
| 500 | 20,30,5,25 | 20,30,0,25 | 3 |

With a minimum count K of measured pools: K=1 keeps all five, K=2 keeps 100,200,300,500, K=3 keeps 100,500, K=4 keeps 100. Z proposed K as a new parameter, default 2, alongside a renamed `dropZeroDepth`.

## Selecting sites is one expression

bcftools 1.24 counts passing samples inside an expression with `N_PASS()` (and `F_PASS()` for a fraction), documented in its installed man page. `bcftools view -i 'N_PASS(FMT/DP>=minDP & FMT/DP>0)>=K'` reproduces every set above exactly, and `COUNT()` gives the same sets. Two traps, both silent:

- **`&&` and `||` inside `N_PASS` are not per-pool.** At minDP 20, `N_PASS(FMT/DP>=20 && FMT/DP>0)` counts 4,2,4,3,4 where the true count is 4,2,2,1,3, so K=3 also keeps 300 and 400. The same holds for `||`: today's ON expression uses `||`, so a count ported from it would be wrong. A case asserting K=3 keeps exactly 100 and 500 on these depths catches it.
- **The floor alone counts an unread pool as measured at minDP 0.** `N_PASS(FMT/DP>=0)` is 4 everywhere. The `& FMT/DP>0` term is what the `|| FMT/DP==0` term does in today's expression.

bcftools accepts any K without complaint: K=5 on four pools keeps nothing, K=0 and K=-1 keep everything, all exit 0.

## Masking is new code, and it has to reach the depth table

**Every module reads the DEPTH table, and nothing reads the frequency table's numbers.** The depth table is `FORMAT/AD` printed by `bin/createDepthFile.sh:48` before `bin/depth2freq.awk` runs. A site filter alone, with no mask, hands every module a 5-read pool as a measured frequency (site 300 publishes that pool at 0.6/0.4). So the mask has to rewrite `FORMAT/AD`, and `FORMAT/DP` with it.

No bcftools route does that reliably. `filter -S` and `+setGT` change GT only, and `MajorAlleleToRef.py:84` has already set every GT to `./.`. `+fill-tags` rewrites `FORMAT/DP` but refuses `FORMAT/AD`, and a comparison inside its expression turns every cell missing. A `query -i ... -F '0,0'` followed by `annotate` reproduces the example but fails silently with exit 0 on two cases: a site where every pool is shallow stays unmasked, and a three-allele site gets a two-value AD that makes `MajorAlleleToRef.py` exit 1. A text pass works: an awk mask writing one 0 per allele (counted from the ALT column at the point of masking) and DP 0 reproduced the example exactly and ran cleanly through step 7's own scripts, publishing `0,0` in the depth table and NA on every allele row of the frequency table.

## The association defect, which exists today

**`modules/association/association.R` publishes a wrong p-value at every site where a unit is unmeasured, and says nothing.** `fit_alleles` zeroes an NA weight (`:111-112`), but `permutation_p` builds `center` from the raw weights (`:209-211`). A unit at depth 0 has an `n_eff` of NA, so every rearranged statistic is NaN, the identity is never counted, and an enumerated p comes out `reached / count = 0` (`:239`); a sampled one lands exactly on the floor. Reproduced: chr1:250 `perm_p` 0.4 to 0, `fdr_p` 0.627 to 0, an unaffected site's BH p 0.0542 to 0.0406, selected sites 2 to 4, exit 0.

`association.R` is unchanged since `dbc522d` (2026-09-10), and the published `modules/repo/association-20260910.004.tar.gz` carries a byte-identical copy. `.claude/development-notes/unmeasured-cells.md:58` recorded association as safe "by the same route" as basicstats; that checked the fit, not the permutation.

When it is reached:

- committed `dev`: only with `minDP` at 0 and `dropZeroDepth` off
- the uncommitted off-branch fix: with `dropZeroDepth = false` alone, because the fix is what finally publishes zero-depth sites
- the proposal: by default

**So the off-branch fix is correct as a filter and unsafe to ship while association is unfixed.** Before it, `false` dropped the sites it claimed to keep, and that bug was all that stood between a user and false association hits.

Four more association behaviors that masking turns from rare into routine, each reproduced:

- **No per-site minimum.** A site with 2 measured units publishes S 0, `perm_p` 0 and `fdr_p` 0; a site with 3 is tested on one degree of freedom (`df <- observed - 2`, `:134`). The refusal below three units (`:271-276`) counts the design's units, not the site's.
- **`roll_up()` sums without `na.rm`** (`:96-97`). One masked technical replicate drops its whole unit at that site, even when the other replicate was read.
- **Dispersion comes only from fully measured sites.** If none is, theta is NaN, every weight is NaN, and the run publishes all NA with exit 0.
- **`depth_phenotype_cor` turns NA from one masked cell** (`:445`), which is the diagnostic for depth lining up with phenotype. `lambda_gc` drifts with missingness.

basicstats handles unmeasured cells correctly, and its compiled and R paths agree. mds handles them by pairwise deletion and stops loudly when two pools share no site, though its message points at a `distance.tsv` the failed run never writes. The shared libraries handle a depth-0 cell; `harmonic_mean()` returns 0 on any zero by design, and its only callers pass none.

## What the evidence leaves for Z to decide

- **Whether a pool below minDP counts as evidence anywhere.** The false-positive filter runs before the depth filter and counts any `dp > 0` as support (`bin/filterFalsePositives.sh:134`). Masking only at the depth filter published an allele with zero reads in every published pool, admitted on the support of pools then masked. Masking only at the start published a pool below minDP, because the FP filter dropped an allele and `MajorAlleleToRef.py:82` recomputed DP from 21 to 18. Masking at both points avoided both. QUAL has the same exposure, unmeasured: `bcftools call` computed it from every pool's reads.
- **How a masked cell is written.** Zeros work with every consumer but make a pool read 5 times identical to one never read, which reverses the premise of the 2026-09-29 NA work and changes what basicstats' `unmeasured` column counts. A per-allele missing value (`.,.`) keeps them apart and the libraries read it as unmeasured, but `MajorAlleleToRef.py:74` calls `int()` on every AD value, so it only works after the last re-sort, which is the placement that leaks. With today's scripts the two goals cannot both be had.
- **One parameter or two.** `true` is exactly K equal to the pool count; `false` differs from K=1 only at a site where every pool is masked, and only when the mask runs after the FP filter. Two parameters give 2 x N combinations for N behaviors, and the proposed default pair (true, 2) means either the count is ignored or it contradicts `true`.
- **K's default against what the modules need.** K counts VCF columns; association fits units built after `analysis.design.technicalRep`, and needs three per site. A default of 2 is below that, and two replicate pools of one unit satisfy K=2 while reaching association as one unit or none.
- **Whether missingness is informative.** If a pool's depth at a site depends on the allele it carries there (mapping loss on a divergent allele, an indel, copy number), masking removes that pool exactly where its frequency differs, where today's rule removes the site for everyone. Nothing measures what K=2 does to association's calibration or to where mds places a shallow pool, and `dev/validation/calibrate.R` has no missing-cell scenario.
- **The FP filter's threshold under masking.** `MINSAMPLES` is all columns times `sampleThreshold` (`filterFalsePositives.sh:67,73`). With the mask before it, the share of measured pools an allele must reach grows with missingness: ten pools at 0.2 need 2 of 2 at a site with two measured pools, 2 of 10 at a full one.

## Decided by Z, 2026-10-05, later the same day

The count called K above is the parameter Z named `minSamples`.

- **`dropZeroDepth` is replaced by `keepLowDepthAsZero`, default `false`, with `minSamples` consulted only when it is `true`.** `false` is today's rule exactly -- every pool at or above `minDP` -- for every value of `minSamples`. `true` masks every cell below `minDP` and keeps a site with at least `minSamples` measured pools. Checked against the example: `false` keeps 100 at every `minSamples`; `true` reproduces the K sets above. The working tree's `FMT/DP<minDP & FMT/DP!=0` branch has no counterpart and is moot.
- **A masked cell is written as depth 0 and frequency NA.** Z: *"If the site depth is zero the freq does not exist."* It cannot be averaged in.
- **association drops every site with fewer than 3 measured values**, in addition to the permutation fix.
- **Missing-cell scenarios are to be added** to the validation harness and the module tests.

- **The mask runs AFTER the false-positive filter.** Z, overruling the recommendation to mask first. The rule this gives: every read counts toward deciding an allele exists; only cells at or above `minDP` count toward measuring its frequency. Under it, the site-800 case above is correct rather than a leak -- an allele detected only in shallow pools, published at 0 in the deep pools and NA in the shallow ones. It also leaves the false-positive filter untouched and puts the mask in the depth filter, after the last re-sort, so depths are final and no second masking pass is needed.

Still open, with a proposed answer: a unit merged from technical replicates keeps the frequency of its measured replicates when one is masked, by summing with `na.rm` in `roll_up()`, rather than being dropped whole. The manual defines `technicalRep` as lanes or runs of the same pool, so the replicates estimate one frequency and losing one changes precision, not the quantity; the `n_eff` weight already carries the lost precision. A unit with every replicate masked gets weight 0 and counts against the three-value rule. Awaiting Z's confirmation.

## Smaller facts, all verified

- **A single-pool project empties step 7 at K=2**, after steps 1-6 have run (126 of 126 sites today, 0 at K=2). The default is out of range there, and those projects run today. Only step 0 knows the pool count (`scripts/metadata.nf:111-121`), and it already refuses a parameter that does not fit the metadata (the adapter block). "Compute the default, never remove the knob" points at a default resolved against the pool count.
- **The rename is free only until v3.3.0 is tagged.** `git tag --contains 8d0447c` prints nothing and the v3.2.0 template has no `dropZeroDepth`, but `origin/main` carries it.
- **The benefit is unquantified on real depths.** `Project/` is off limits and `called.vcf` has no cell below 20 that survives the FP filter (its minimum there is 38). At an artificial minDP 70, today's rule keeps 0 of 122 sites and K=2 keeps 119.
- **Testable without a new fixture.** At minDP 65-70, `test/data/vcf/called.vcf` yields sites with every count of measured pools from 1 to 6, so the mask and K can be tested at static cost. `test/tools/freq_corpus.py` raises `ZeroDivisionError` on a zero cell (`harmonic()`, `:261`), and `assert_close` (`test/lib/analysis.sh:147`) passes NA against 0, so an association NA case needs both changed first.

## Text that is already wrong, independent of the proposal

- `manual/PoolSeqFlow-manual.md:3303-3318` offers `-i "COUNT(FMT/DP>=20)>=2"` as a one-line swap, which hands sub-minDP pools to every module as measured, and says per-sample blanking belongs in `bin/depth2freq.awk`, which writes only the frequency table no module reads.
- `modules/association/manifest.json:25`, `modules/mds/manifest.json:28` and both `main.nf` headers say a cell with no reads is published as 0; it has been NA since `772db1f`.
- Stale in the working tree after the off-branch fix: `modules/basicstats/test/basicstats.sh:262`, `test/suites/03_helpers.sh:1583-1587`, `test/tools/freq_corpus.py:65-66` and `test/README.md:222-223`, each saying a zero cell needs both minDP 0 and `dropZeroDepth` off.

## Built, 2026-10-05, the same evening

Built on top of the association fix in `association-unread-units.md`, which also records Z's confirmation of the replicate rule ("Rowsum looks correct"). Uncommitted.

`vcffilter.keepLowDepthAsZero` (default `false`) and `vcffilter.minSamples` (default 2) replace `dropZeroDepth`. `false` runs today's expression unchanged, `FMT/DP<minDP || FMT/DP==0`, and the off branch with `&` is gone. `true` runs `bin/mask_depth.awk` in its place, inside the depth filter, after the false-positive filter and major-allele normalization, and `vcftools --minQ` follows either way.

Decided during the build, stated to Z before it started, not ruled on:

- **The mask and the count are one awk pass, not bcftools `N_PASS`.** The cells counted are then the cells left read; the `&&` trap above cannot arise; and bcftools cannot rewrite AD anyway. The awk reproduces the proposal's table exactly at every K, and the called VCF's counts at minDP 65 and 70 against an independent Python count.
- **INFO/AD and INFO/DP are recomputed from the cells as written**, the invariant `MajorAlleleToRef.py` leaves (INFO/AD equals the sum of the samples' AD, INFO/DP its total). `TOTAL_AD` in the depth table then counts only the cells that measured the site, which is Z's rule that only cells at the floor measure a frequency. A site with nothing masked is written byte for byte as it came.
- **`minSamples` defaults to 2 and step 0 refuses it outside 1 to the pool count while masking is on**, in the metadata check beside the adapter refusal, per step-7 run. A single-pool project that turns masking on is told to set 1. With masking off it is not judged.
- **A change to `minSamples` with masking off still trips the parameters guard**, which compares every analysis parameter by exclusion list. Left as it is.
- **The migration drops `dropZeroDepth` and never maps it.** `true` is the new default; `false` has no exact counterpart, because masking also writes a shallow pool as unread. The note for the new key says so when the old one was present.
- **basicstats' gate named `dropZeroDepth`**, so its text changed and basicstats moved to `20261005.001`.

The text says "cell", one pool's reads at one site, wherever it describes the floor, and never "a pool below minDP": Z reads minDP as a property of the site. The manual's step reference lost its table of one-line expression swaps, which handed a shallow cell to every module as measured, and points at the setting instead; the walkthrough explains the mask, under a pinned anchor, `#depth-and-quality-filter`.

Verified: the static suites, 334 passed; in `05_guards` the flip, the absent defaults and the range check, and in `04_pipeline` the multi-run case, where `plain` ran the mask in a real run and published sites. Twelve single-guard mutants of the mask and of the migration note, run through the suite's own cases from a stand-in `REPO_ROOT`, each failed the case meant to catch it: the floor made exclusive, a zero cell counted as read, INFO left uncounted, two alleles assumed, the count off by one, the settings and the FORMAT unchecked, `DP4` taken for `DP`, and the note's four branches.

Still to do, decided by Z and not built: missing-cell scenarios in `dev/validation/calibrate.R`. Not exercised: the mask on real data, and through a whole run, where the fixture has nothing to mask.

## Verified again, and fixed, 2026-10-05, late

A verification workflow ran over the built change (`wf_94855d6e-8d6`, in the same transcript folder as above): four attacks, on the awk, on step 7 end to end, on the wiring and on the documentation, and a critic over all four, every agent on Sonnet 5.5 at Z's instruction. None ran the suite.

The behavior held. The mask equaled a reference written from the specification, byte for byte, on about 100,000 random VCFs and 505,750 exhaustive records under gawk 5.4.1, gawk 5.3.1 (also with `--posix` and `--traditional`) and busybox 1.36.1. Step 7 run stage by stage on `called.vcf` kept 122 sites at minDP 65 and 119 at minDP 70, minSamples 2, equal to independent counts, and at minSamples equal to the pool count the mask path reproduced the bcftools path byte for byte in records and in all four tables.

What it found, and what was done:

- **Step 0 counted the wrong pools.** The refusal compared minSamples with the distinct `RG_Sample` values in `metadata.csv`, but a row with no reads is only a note and gets no VCF column, so minSamples 7 passed for six pools with reads plus one read-less row, and step 7 would have kept no site. It now counts the pools with a sample that has reads, from the listing the sample match uses, and falls back to the metadata's count only where no reads were listed. The manual and the template say "pools with reads".
- **The refusal's case could not fail on the thing it named.** It ran masking off and then on in one project; flipping keepLowDepthAsZero trips the change guard, so with the refusal's `STATUS="FAIL"` replaced by `:` the case still ended in status 1 with both strings present (the critic measured it). It now uses fresh projects: a single-run one with a seventh, read-less pool and minSamples 7, and a multi-run one judging 0, 6, 7 and masking off in one step 0.
- **Values the Groovy could not hold.** A minSamples of ten digits or more died in `as Integer` with a script error, and a double quote in it broke the generated bash. A value that is not a whole number is now reported as such and never written into the script, and one of more than nine digits is refused as above any count.
- **`as boolean` read a quoted `'false'` as true**, in step 7 and step 0 alike, so a config writing the switch as a string masked while its record said off. Both now compare the text. A run-table `yes` still reads as false without a word; that is `setDotted`, older than this change, and left.
- **The mask refused a decimal floor** that bcftools and step 0 accept: minDP 20.0 passed step 0 and the awk exited 2. It now takes one, and a case says 20.0 keeps what 20 keeps.
- **Text that was false as written.** The manual said minSamples is not read while masking is off; an edit to it still trips the parameters guard, which the manual and the template now say. The migration note said `dropZeroDepth = false` kept a site with an unread cell, which held only at minDP 0, and it now says so. Lines stating whole-site removal, or "no reads" as the only `NA`, without the switch were qualified, as was the depth-histogram invariant "in every sample". Two messages said "1 pools" and "at least 1 cells", and the masking-off failure text named minSamples, which that branch does not use. The `bin/` tree gained `mask_depth.awk`.
- **Two facts the manual did not say.** With the mask on, `REF` can rank below another allele in `TOTAL_AD`, because major-allele normalization ranked on every read before the mask: 16 of 104 SNP rows and 3 of 15 indel rows at minDP 70, minSamples 2, on `called.vcf`, and none before the mask. And every `INFO` key other than `AD` and `DP`, `DP4` among them, still counts every read: masked `chr1:657` reads `DP=234;AD=110,124` beside a `DP4` summing to 419. Both are in the walkthrough now.
- **The helper cases let 8 of the awk attack's 18 mutants through.** A key matched by prefix in FORMAT or INFO, and a short cell written without padding or without `.`, are now caught by a case with ADF, ADR and a DPR look-alike on both sides of their real keys, and a cell that stops short of its FORMAT. Left uncaught, and why: ALT `.` counted as two alleles cannot reach the mask, since the false-positive filter drops a record with no second AD value; INFO rewritten at a site with nothing masked, and a trailing `;` lost, change nothing in what bcftools and `MajorAlleleToRef.py` write.

Bite proofs, `bite-mask2.sh` in the session scratchpad: twenty single-guard mutants of the mask and the migration note, each failing the case meant to catch it for the reason it names, and a control passing all ten cases. `bite-step0.sh` ran the refusal case from stand-in copies of the repository with step 0 broken six ways, and each failed it for its own reason: the refusal logging without failing, the metadata's pools counted, no lower bound, the upper bound inclusive, the run left unnamed, and a run judged with masking off. The unmutated case passed in the same session.

Reported to Z and not acted on: `check project` does not apply the minSamples rule, while the manual says it and step 0 apply the same rules from one implementation (`check_parameters.sh` sees only the global parameters and has no pool count, and the adapter-pin refusal has the same shape); with masking on, an mds pair can rest on a handful of shared sites (one pair on 1 of 104 at minDP 70) and nothing warns but the sites column; `modules/mds/manifest.json` and `main.nf` still say a cell with no reads publishes as 0. Pre-existing and found on the way: basicstats exits 1 on a depth table with a header and no rows, which any run with no surviving indel produces; association exits 1 on a table of one site; the changed-parameters report prints `added <key> = ` with no value; the mask is 7 to 13 times slower than `bcftools view -e` (48 pools by 20,000 records, 2.8 to 5.6 s against 0.42 s); mawk and BWK awk were never run; CRLF input loses its carriage return on masked records, which `MajorAlleleToRef.py` makes unreachable.
