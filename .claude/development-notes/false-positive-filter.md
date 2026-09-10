# The false-positive filter

**Written 2026-08-31, against the tree at `7d65893`.** The mechanism and the contract are unchanged. `diploidy` has been renamed `ploidy` since, and the parameter names below are updated to the live ones; the old name survives only in `config_migrate.sh`, which maps it forward.

`bin/filterFalsePositives.sh`, called from step 7. The only place in the pipeline where a per-sample number decides which variants survive, so a mistake here is a wrong **result** rather than a failed run — nothing downstream looks odd, the frequency tables are simply computed over the wrong set of sites.

> **For the manual, not here.** `s = 1 / (2 * ploidy * poolSize)` is the smallest allele fraction a pool of that size can produce — one chromosome out of all of them — so anything below it is noise rather than a rare allele. A reader interpreting a frequency table needs that, and needs to know it is now **per pool** rather than one number for the whole VCF.

## Choosing the mechanism, 2026-08-29

The threshold used to be uniform: `COUNT(FORMAT/AD[:1]/FORMAT/DP[:] >= s) >= MINSAMPLES`, one `s` for the whole file — so a pool of 10 was judged at a pool of 100's resolution.

Four mechanisms were measured on a real 135-record, 6-sample VCF (now `test/data/vcf/called.vcf`), with `sampleThreshold = 0.8` and pools 4–6 shrunk to one individual so per-pool and uniform genuinely differ — **118 records versus 102**:

| | Correct? | Cost | Residue | Binds by |
|---|---|---|---|---|
| M1 — annotate a FORMAT tag, filter, strip | yes, 102 | +5 processes, 2 temp files, tabix index | tag must be stripped | column position |
| M2 — boolean summation of subscripted clauses | **no — 0 records, silently** | | | |
| M3 — awk → `INFO/FPKEEP` → `view -i` → `annotate -x` | yes, 102 | +5 processes, 2 temp files, tabix index | 3 `##bcftools_*Command` lines naming FPKEEP survive the strip | column position |
| **M4 — in-stream awk** | yes, 102 | **+1 awk in the existing pipeline** | none | **sample name** |

**M2 is the finding worth keeping.** It parses and returns zero records with no error at all. The bcftools expression engine will accept an expression it evaluates differently than you expect, which is also the argument against trusting M1's three-vector arithmetic — that one does work, verified, but it is trusted rather than seen.

**Name-binding is why M4 wins on correctness, not just cost.** M1 and M3 bind each threshold to the sample's column *position*, and this pipeline deliberately treats the metadata file's row order as a separate identity from its values — precisely because order decides the VCF's columns. A positional binding is one permutation away from applying the wrong pool's threshold and silently changing which variants survive. Measured: the same sizes assigned to samples 1–3 instead of 4–6 give **99** records, not 102. Matching on the VCF's own sample names cannot do that, and lets the filter **refuse** a column it was given no size for — which no positional mechanism can.

M3 was the front-runner before the measurement. Z confirmed M4 after seeing the comparison, noting it crosses the recorded constraint *"bcftools does all VCF surgery; awk only touches numbers"* — though the two awk passes already in the script rewrite the ALT column, which is more invasive than dropping a line.

## The contract

`-p "Name=count,..."` carries **sizes, not sensitivities**, with `-d <ploidy>`. That keeps the equation in one place on the per-pool path and puts the number the user actually wrote into the `##PoolSeqFlowPool` header line. `-s` remains the flat default for anyone running the script by hand, and `-p` without `-d` is refused rather than defaulting to 2 — a wrong ploidy silently halves or doubles every threshold.

Verified byte-identical to the pre-E3b filter when every pool is the same size.

## Provenance that does not survive

The `##PoolSeqFlowPool` header lines record what was applied per column — but **every VCF step 7 touches is transient by design**, so they never reach a published file. The durable record is `.poolseqflow_metadata`, which carries `param_poolSize` because it is a guarded column. Putting the sizes somewhere that survives would mean a header on the frequency tables, which is an E4 question about the TSV contract.

**E4 answered it, and not that way.** No header was added to the tables. The analysis layer recomputes the figures onto its own target instead: `analysis/lib/nf/pools.nf` holds `poolSensitivity(ploidy, size)`, and a module reads `size`, `ploidy`, `nChrom` and `sensitivity` per pool off `target.pools`. What makes the recomputation safe rather than a second opinion is that **step 7's identity names the pool sizes and the ploidy**, so a results directory can only ever hold runs that were filtered under both.

## Testing

Fifteen cases in the helpers suite, each mutation-tested: `>=`→`>`, the zero-depth guard, the FORMAT lookup and the strict refusal each break exactly one case. The exact-boundary case uses `chr1:8105`, where `TestSample2` has AD=1 and DP=72 — a fraction of exactly 1/72, which is exactly the sensitivity of a pool of 18, since `1/(2*2*18)` is the same division. With the sample threshold at 1.0 every pool must pass, so that one sample decides the record: pool 18 keeps it, pool 17 drops it. That is what proves the comparison is `>=` and not `>`.

**`pipefail` is what matters in this script.** Its real work is one long pipeline whose last stage is awk, and awk succeeds on empty input — so without it every bcftools in the chain could fail while the script exited 0, emitting an empty VCF that the caller publishes to permanent storage, where the existence-based skip logic reuses it on every later run.
