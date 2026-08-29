# A real called VCF, for unit-testing the VCF helpers

`called.vcf` is genuine `bcftools call` output, not a hand-written file, and that distinction
has already cost this project one false bug report. `bcftools call -m` emits an overlapping SNP
and indel as **two records at the same position**, never as one mixed multiallelic record — a
structure that is easy to get wrong by hand and that makes `norm -m -` / `norm -m+` look broken
when it is not. Anything testing `bin/filterFalsePositives.sh`, `bin/createDepthFile.sh`,
`bin/depth2freq.sh` or `bin/MajorAlleleToRef.py` should start from this file.

**Where it came from.** A full pipeline run over `test/data/base/` — the same six samples, the
same 20 kb synthetic reference, aligned with bwa and called with the pipeline's own
`bcftools.mpileupOptions` / `callOptions`. It is the `Test.vcf` that run produced, with the
absolute paths in `##bcftoolsCommand` and `##reference` rewritten to relative ones so the
committed file says nothing about the machine that made it. Nothing else was touched.

**What it contains**, and what that means for a test written against it:

| | |
|---|---|
| 135 records, 6 samples | sample columns are named `TestSample1`…`TestSample6` |
| 16 indels, 119 SNPs | both branches of step 7's SNP/indel split have input |
| no multiallelic records | `ALT` never holds a comma, so `norm -m -` is a no-op on count |
| no sample has `DP=0` | a division-by-zero case has to be constructed, not found here |
| lowest non-zero ALT fraction is **0.012048** | this is the number that decides whether a sensitivity bites |

That last row is the one to keep in mind. Sensitivity is `1 / (2 * diploidy * poolSize)`, so
the default `poolSize = 100` gives `0.0025` — below every non-zero fraction in the file, which
is why the default filter drops records on the sample-count clause rather than on sensitivity.
A test that wants a per-pool threshold to actually change the outcome needs a pool small enough
that `s` clears 0.012 — `poolSize = 10` gives `0.025`, `poolSize = 1` gives `0.25`.

**Do not hand-edit it.** Regenerate it from a real run if it ever needs to change, and say so
here. A record edited by hand to make a test pass stops being evidence of anything.
