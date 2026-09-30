# Covering `vcffilter.dropZeroDepth`, and the fixture that cannot hold the case

**Written 2026-09-29, against the tree at `ad85fb1` plus uncommitted work.** `dropZeroDepth` shipped in `8d0447c` with no case anywhere setting it to any value. Three things needed asserting and they turned out to be governed by three different mechanisms, which is the reason this note exists.

## The three mechanisms, which are not one mechanism

Before writing anything I assumed a single "is the parameter tracked" property. There are three, and each needs its own case:

| what | where it lives | what covers it |
|---|---|---|
| step 7 **reads** the parameter and **declares** it | `stepParameterMap()` in `scripts/variants.nf:44` | `00_static`'s `step parameter map covers what each step reads`, which already existed |
| the parameter is **analysis-affecting**, so flipping it stops a project | `analysisParams()` in `scripts/0_verify_environment.nf:20` | new case in `05_guards` |
| the **expression** it builds is the right way round | the ternary in `scripts/7_vcf2freq.nf:257` | new case in `04_pipeline` |

**`analysisParams()` is an EXCLUSION list**, and that is the part that misled me: *"Everything not named here counts as analysis-affecting."* So the change guard fires on `dropZeroDepth` whether or not `stepParameterMap()` mentions it. Measured: deleting the parameter from `variants.nf:44` leaves the `05_guards` case passing. The first draft of that case carried a comment claiming it proved the map was read, which was simply false.

What DOES break the guard case is an edit to the exclusion list -- `vcffilter.` added to `skipPrefix`, or the key added to `skipKey`. Verified by adding it: all five assertions fail. That is a plausible mistake rather than a theoretical one, because `capBAM.histogramMax` is already excluded there on deliberate and correct reasoning.

## The behaviour case is not achievable in this fixture

The thing worth asserting is a site dropped at `true` and surviving as `NA` at `false`. It needs a cell where one sample has no reads, and **the fixture cannot hold one.**

Every sample carries about 75x across the whole 20 kb reference -- measured from the raw VCF of a real run, mean DP 75.2, 75.0, 76.6, 65.1, 57.1 -- and no sample has `DP=0` at any of the 135 called sites. `test/data/vcf/README.md` says the same of the called VCF it was cut from.

**Thinning one sample was tried and fails in an instructive way.** Read names are a sequential fragment index and both mates are written in step, so truncating the two files to the same count keeps every pair intact -- that part works. At 250 pairs the result is not low coverage, it is **none**:

```
[M::mem_pestat] skip orientation FF as there are not enough pairs
[M::mem_pestat] skip orientation FR as there are not enough pairs
samtools markdup: Read pairs 0 should be greater than duplicate pairs 0
```

bwa cannot estimate an insert size distribution from 250 pairs, so nothing is flagged properly paired, and step 4's `0x2` required flag discards every read. Mean DP for that sample: **0.0, at all 135 sites.**

This is the trap `test/tools/make_fixture.py`'s own docstring warns about, in a different dress: *"it gave every fragment the same length, which left bwa with a zero-variance insert size distribution, which meant every indel-bearing pair fell outside the proper-pair window and was discarded by the 0x2 filter in step 4."*

**And the two requirements are in direct conflict.** bwa needs thousands of pairs to pair-estimate; a zero-depth cell needs almost none locally. No amount of tuning the thinning reaches both.

The shape that satisfies both is a sample with a **regional** coverage gap: many pairs, concentrated in part of the genome. That is an option in `make_fixture.py` restricting one sample's fragments to a sub-region, plus a committed fixture of its own beside `base/`, about 2 MB. **Not built.** The toggle is redundant above `minDP 1`, so nothing a default run publishes depends on it. Recorded in `test/README.md`'s known gaps so the thinning route is not attempted again.

## What was built instead, and what it cost

Step 7 now logs the filter it applied -- `Depth Filtering VCF, excluding FMT/DP<20 || FMT/DP==0` -- which makes the ternary assertable and is worth having for anyone reading a log.

The case then **rides the existing multi-run** rather than adding a pipeline run. `runs.csv` gained a `vcffilter.dropZeroDepth` column with `false` on the `plain` run, which already diverges at step 7 through `poolSize`, so no sharing group moved and no other case's numbers changed -- the toggle is redundant at `minDP 20`, which is exactly why it is safe to set on a run whose output other cases assert. Cost: zero extra pipeline runs.

Inverting the ternary fails both of its assertions.

## A red test found on the way, and why nobody was sent to look

Running `05_guards` in full -- owed because the multi-run fixture is shared -- turned up a failure that had nothing to do with this work. The case `run definitions resolve each kind of divergence` expected the DERIVED `mpileupOptions` for a run that sets only `maxDepth`:

    RUN depth variantCall.mpileupOptions=-B -C 50 -q 30 -Q 30 -d 4000 ...

`-C` is the template's `scaleMapQ`, which that row does not set. **It moved from 50 to 100 in `eedf598` and this expectation did not**, so the case had been failing in the committed tree from then until now.

**The routing is why it went unseen.** `dev/scripts/select-tests.py parameters.config.template` returned `01_migrate` alone -- yet `write_sandbox_config` at `test/lib/sandbox.sh:115` builds EVERY sandbox from that template, so `04_pipeline`, `05_guards`, `06_dryrun` and `10_analysis_verify` all depend on it and **none of the four declared it**. The selector derives its graph from imports and cannot see a file read inside a `sed`; `test/README.md` says exactly that about the half which must be declared by hand.

So both halves are fixed: the expectation, and the four missing `# covers:` lines. The selector now returns all five suites for a template change.

The `pinned` row's own `-C 50` was left alone deliberately. It is a literal that must survive verbatim, and now that it differs from the default it can no longer pass by coincidence -- a better test than it was.

This is the family `gates-that-stopped-checking.md` is about, in its purest form: nothing was broken by the change, the checker was simply never asked.

## Two things this session's earlier work did for itself

**The emptiness guard caught the pathological fixture.** The first attempt did not fail obscurely: `dropZeroDepth = true` on a sample with no coverage removed every site, and the step-7 refusal added hours earlier stopped the run and named the filter. Without it the run would have published a header-only table and reported success.

**The new logging is what diagnosed the thinning.** Four steps' logs from a FAILED run showed exactly where 250 read pairs went. Under the design that shipped the same morning, those logs would have been empty, because the copy at the end of each script is never reached when a task fails.
