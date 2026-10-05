# What `-C` does to a pool, measured on real data

**Written 2026-09-28, rewritten 2026-09-29 against the tree at `c5bacb4` plus uncommitted work.** Raised by a collaborator's 3.2.0 run on a cluster and then measured properly against Z's own *D. melanogaster* project: three pools, whole genome, the release's own option string. The first version of this note was synthetic and said so; everything below replaces it.

`scaleMapQ` reaches every call as `-C`, composed at `scripts/resolve_parameters.nf:85`.

## The parameter has three regimes and the name suggests none of them

Mean pileup depth, Sample1, `2L:5000000-5050000`, every option but `-C` as the release composes it:

| `-C` | mean DP | positions |
|---|---|---|
| 0 | 9.43 | 50,057 |
| 10 | 9.43 | 50,057 |
| **11** | **no output** | **0** |
| **15** | **no output** | **0** |
| **20** | **no output** | **0** |
| 30 | 6.49 | 47,947 |
| 40 | 8.10 | 49,209 |
| 50 | 8.76 | 49,898 |
| 70 | 9.17 | 49,957 |
| 100 | 9.27 | 50,007 |

**At or below 10 it does nothing at all.** Not "less" - nothing. Whole-genome cohort runs at 0, 5 and 10 are byte-identical: 1,854,369 sites each, md5 `5c089144d201c0c9`, zero differing lines. Three independent thirteen-minute runs.

**Between 11 and about 20 every read is discarded.** mpileup emits no records, exits 0, and prints no error. A whole-genome `-C 20` run produced 0 sites in 24 seconds against the usual thirteen minutes, with clean stderr at all three stages.

**From 30 up it is usable and INVERTED**: a higher number is milder. 30 costs 31% of depth, the shipped default of 50 costs about 7% here, 100 costs almost nothing.

So it reads like a scale and behaves like a threshold, with a dead zone below it and a destructive band just above.

## Which value is right, measured

Six whole-genome cohort call sets, all three ready BAMs in one mpileup because that is what step 6 does:

| `-C` | sites called |
|---|---|
| 0, 5, 10 | 1,854,369 |
| 50 | 1,191,066 |
| 100 | 1,723,859 |

**Every site below is scored from the `-C 0` rows**, so both groups are measured under identical pileup settings. This matters: `-C` downgrades any read carrying a mismatch, and an ALT read carries one by construction, so `-C` manufactures the very mapping-quality difference a naive across-setting comparison would read as evidence. `MQBZ` sits at -2.9 to -4.9 on ordinary sites under `-C 50` for exactly this reason, which is why it is not used here.

Grouping every called site by which settings kept it:

| group | n | Ti/Tv | \|SCBZ\| | QUAL |
|---|---|---|---|---|
| kept by both 50 and 100 | 1,178,812 | **1.168** | 0.32 | 212.7 |
| dropped by 50, kept by 100 | 537,942 | **1.015** | 0.49 | 133.1 |
| dropped by both | 137,615 | **0.847** | 1.31 | 81.1 |

A clean gradient, and it decides the question. **The 537,942 sites that `-C 50` discards and `-C 100` keeps look like variants, not artifacts**: Ti/Tv 1.015 against the kept group's 1.168 and the junk group's 0.847, and a clip bias of 0.49 against 0.32 and 1.31. Alignment noise cannot manufacture a transition bias, because eight of the twelve possible substitutions are transversions.

Ti/Tv here is low in absolute terms because this is the RAW step-6 call set, before step 7's depth and quality filters and before the false-positive filter. The bar is not a literature value but the pipeline's own accepted output.

## And `-C 50` biases the frequencies of the sites it keeps

At the 1.18M sites both settings call, the alternate frequency is systematically lower under `-C 50`, across 3.4M sample-cells and all three pools:

| `-C 0` frequency | cells | mean shift | relative | down:up |
|---|---|---|---|---|
| 0.00-0.05 | 455,309 | +0.0099 | +39.8% | 0.01:1 |
| 0.05-0.10 | 32,267 | +0.0014 | +1.9% | 0.47:1 |
| 0.10-0.25 | 510,945 | -0.0012 | -0.7% | 0.70:1 |
| 0.25-0.50 | 854,152 | -0.0302 | -8.1% | 2.00:1 |
| **0.50-0.75** | **741,897** | **-0.0808** | **-12.9%** | **4.05:1** |
| 0.75-1.01 | 831,971 | -0.0470 | -5.3% | 5.88:1 |

**Rare alleles are untouched** - below 0.10 essentially nothing moves down, so the detection limit the false-positive filter rests on is safe. **The damage is where the pool is most non-reference**, peaking at a 12.9% relative compression around 0.5-0.75. A true frequency of 0.60 publishes as about 0.52.

That is mechanistically what `-C` must do: it penalizes reads carrying mismatches, so the more alternate-allele reads a site has, the more reads are downgraded and the harder the frequency is pulled toward the reference. **It is not a flat offset. It scales with the quantity being measured**, and those frequencies feed `basicstats`, `fst`, `association` and `mds`.

Whole-genome, `-C 100` shifts by -0.0076 at 1.73:1 against `-C 50`'s -0.0353 at 2.33:1: **4.6 times less bias**.

## Where this leaves the default

The whole curve, every statistic read from the `-C 0` rows:

| `-C` | sites kept | kept Ti/Tv | dropped Ti/Tv | dropped \|SCBZ\| | freq shift | down:up |
|---|---|---|---|---|---|---|
| 30 | 94,681 | **0.608** | **1.090** | 0.45 | +0.0612 | 0.52:1 |
| 40 | 738,393 | 1.190 | 1.036 | 0.54 | -0.0479 | 2.19:1 |
| 50 | 1,178,812 | 1.168 | 0.978 | 0.67 | -0.0353 | 2.33:1 |
| 70 | 1,568,464 | 1.134 | 0.890 | 0.99 | -0.0154 | 1.97:1 |
| 100 | 1,716,020 | 1.113 | **0.848** | **1.34** | **-0.0076** | 1.73:1 |

**`-C 30` is inverted and actively harmful**: the set it KEEPS has Ti/Tv 0.608 while the set it DROPS has 1.090. A setting this harsh only passes a site where nearly every read matches the reference, so what survives is dominated by sequencing error rather than by polymorphism. Anything near the bottom of the usable range is worse than useless.

Above 30 the trend is monotonic and **100 is the best value tested, on every axis**. The set it drops is the most clearly artifactual (Ti/Tv 0.848 and a clip bias of 1.34 against its own kept set's 0.36), it retains the most real sites, and its frequency bias is a twentieth of a percentage point where the shipped 50 costs three and a half.

**100 also beats turning the adjustment off.** It still removes 138,349 sites that are genuinely bad by every statistic here, and `-C 0` keeps all of them. The objection that motivated this measurement is correct; the shipped value is simply set far too harsh.

`-C 0` is not right either: the 137,615 sites both settings reject are genuinely bad, and turning the adjustment off keeps them.

**DECIDED 2026-09-29, Z: the default becomes 100.** `parameters.config.template` carries it, and the analysis above is published in the manual under the filter chain at `#scalemapq-measured`, with the variant-calling settings section pointing at it. The manual's own account is the authoritative one; this note is how it was arrived at.

Two consequences to carry:

- **It moves every published number**, so it moves the version and invalidates existing results directories. A project that has already run will be stopped by step 0's change guard naming `variantCall.mpileupOptions`, which is correct: `scaleMapQ` feeds it and that string is in step 6's artifact identity, so the guard was never going to miss this.
- **Nothing was changed about the dead zone or the destructive band.** A user can still write `scaleMapQ = 15` and get an empty run that reports success. The manual now warns, which is documentation rather than a gate, and the emptiness guard below is still the fix.

## The landmine, and the gate that would catch it

`scaleMapQ = 15` is a plausible edit by someone who thinks they are being gentler than 50. It produces an **empty VCF, empty frequency tables, and a run that reports success**.

Nothing in step 7 refuses an empty VCF or an empty frequency table - grepped, there is no such check. So this is not a hypothetical: a one-character configuration change silently destroys every result, and the pipeline says it worked. See [[gates-that-stopped-checking]]; it is the same family as the missing-mate drop 3.2.0 fixed, and the emptiness guard should be built whatever happens to the default.

## How the measurement was got wrong, three times

Recorded because the failure mode is instructive and cost an hour.

`-C 20` returning zero sites was read as a resource failure on three separate occasions. It was the parameter working at its most severe setting. **The tell was in the first event and ignored: 24 seconds against thirteen minutes.** A crash is slow; an empty stream is fast.

Three command-construction errors produced a table of `-C` values that was non-monotonic and entirely spurious, and it was nearly believed:

- `-r` placed after the positional BAM arguments. bcftools stops option parsing at the first positional, so `-r` and the region became input filenames.
- `"$B"` quoted, collapsing three BAM paths into one argument.
- `2>/dev/null` on all of it, so neither error was visible.

The region spot-checks were discarded entirely and every number in this note comes from complete whole-genome runs.

Two process traps hit in the same hour, both already recorded elsewhere in this project: editing a running bash script (survivable only because `sed -i` renames rather than writing in place, so the running shell keeps the old inode), and `pgrep -f` / `pkill -f` patterns matching their own command line. The second killed the wrapper that was waiting to launch `-C 20`.
