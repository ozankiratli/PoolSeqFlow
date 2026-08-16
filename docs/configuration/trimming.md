# Trimming & Clipping

Step 2 runs in two stages: Trim Galore removes adapters and low-quality tails, then a second pass clips a fixed number of cycles from both ends based on what FastQC measured about base composition. The second stage is unusual and worth understanding before you change its one tunable.

## Stage 1 — Trim Galore

```groovy
trim_galore {
    quality    = 25
    autodetect = true
    adapter1   = ''
    adapter2   = ''
}
```

The assembled command is `--fastqc --paired --retain_unpaired -q 25`, plus adapters and `--cores`.

| Setting | Meaning |
|---|---|
| `quality` | Phred score below which bases are trimmed from the 3′ end |
| `autodetect` | `true` — no adapter is passed and Trim Galore detects it (Illumina, Nextera or smallRNA) |
| `adapter1`, `adapter2` | Used only when `autodetect = false`, and then **both** are required |

`--retain_unpaired` keeps reads whose mate was discarded, in `Output/Unpaired/`. They are not used downstream — step 4 requires properly-paired alignments — but they are kept so you can see what was lost rather than having it disappear.

### When to turn autodetect off

Autodetection samples the first reads of a file and matches against known adapter sequences. Set `autodetect = false` and supply both sequences when:

- your library used a custom or non-standard adapter that will not be recognised;
- the trimming reports in `Output/Reports/Trimming/` disagree between samples of the same library, which means detection is not landing on a consistent answer;
- you need the run to be exactly reproducible against a specific adapter regardless of what the first reads happen to contain.

Setting only one of `adapter1`/`adapter2` is not valid — the option string is built from both.

## Stage 2 — Composition-aware clipping {: #composition-aware-clipping }

```groovy
cutadapt {
    at_gc_error = 0.025
    min_length  = 50     # see the note below - not currently applied
    options     = ""
}
```

Rather than clipping a fixed number of bases, the pipeline reads what FastQC measured and derives the clip points per sample.

### What it measures

In an unbiased library, each cycle should show roughly equal A and T, and roughly equal G and C. Departures at the read ends are a well-known artefact — residual adapter, priming bias, and end-of-read quality decay all show up as a composition skew before they show up as a base-quality failure.

For Pool-seq that matters more than usual. Allele frequencies are read counts, so a systematic bias in which base gets called at a given cycle propagates directly into the frequency estimate. Cycles where composition has not settled are cycles you cannot trust to count alleles.

### The algorithm

For each read file, step 2 parses the `>>Per base sequence content` block of `fastqc_data.txt` and keeps the cycles where **both** ratios sit inside the tolerance:

$$1 - \varepsilon \;\le\; \frac{A}{T} \;\le\; 1 + \varepsilon
\qquad
1 - \varepsilon \;\le\; \frac{G}{C} \;\le\; 1 + \varepsilon$$

with $\varepsilon$ = `at_gc_error`. At the default of `0.025` that is a ratio between 0.975 and 1.025. The first and last qualifying cycle give a usable range per read — `Min1`–`Max1` for R1 and `Min2`–`Max2` for R2 — and the two are combined:

```text
Clip5           = max(Min1, Min2)
readLengthLimit = max(Max1 - Clip5, Max2 - Clip5)
```

then applied symmetrically:

```bash
cutadapt -u Clip5 -U Clip5 -l readLengthLimit -o R1_clipped.fq.gz -p R2_clipped.fq.gz
```

`-u`/`-U` remove `Clip5` bases from the 5′ end of R1 and R2; `-l` truncates both to the same length. FastQC then runs again on the result, so you can check the clipping did what it was supposed to.

### Two deliberate asymmetries

**Both mates get the same treatment.** `Clip5` is the *larger* of the two 5′ bounds and the length limit applies to both files, so R1 and R2 come out the same length. The alternative — clipping each mate to its own measured range — would leave mates of different lengths for no downstream benefit.

**The length limit is the more permissive of the two.** Because `readLengthLimit` takes the `max`, a read whose own usable range ended earlier is kept to the longer mate's length, retaining a few cycles past its own bound. This favours read length over strict adherence to the tolerance. If that trade is wrong for your data, tighten `at_gc_error` — which pulls both bounds in — rather than trying to change the rule.

### When it refuses to run

The clip range calculation fails loudly rather than guessing:

| Exit | Cause |
|---|---|
| `3` | The FastQC table did not have the expected `A`/`T`/`G`/`C` header columns |
| `4` | **No cycle** fell inside `at_gc_error` |

Both produce:

```text
CLIPPING READS <sample>: ERROR: no usable clip range in <file>
CLIPPING READS <sample>: exit 3 = unexpected FastQC header; 4 = no cycle within at_gc_error (0.025)
```

Cycles where T or C is zero are skipped rather than divided by — that division would abort awk mid-pipeline, which plain `set -e` does not catch, and the bounds would be silently derived from a truncated table.

### Tuning `at_gc_error`

This is the only value here you would normally change, and it trades data volume against composition purity.

| Direction | Effect | Risk |
|---|---|---|
| **Tighter** (e.g. `0.01`) | Fewer cycles qualify, so more is clipped from both ends | Exit 4 — no cycle qualifies and the run stops. Shorter reads map less uniquely |
| **Looser** (e.g. `0.05`) | More cycles qualify, so reads stay longer | Retains cycles with real composition bias, which feeds into your frequencies |

Exit 4 on a library that is otherwise fine usually means the tolerance is too tight for its natural composition — GC-skewed genomes will not produce a G/C ratio near 1 anywhere. In that case raising `at_gc_error` is the correct response, not a workaround.

Check the before/after FastQC reports in `Output/Reports/Fastqc/<sample>/` after changing it. The clipped-read report is the one that tells you whether the value you chose did what you wanted.

!!! note "`min_length` is off by default"

    `cutadapt.options` is empty, so no minimum read length is enforced at this stage and changing `min_length` on its own has no effect. The template carries the line ready to uncomment:

    ```groovy
    options        = ""
    // options     = "-m ${params.cutadapt.min_length}"
    ```

    Swap the two and reads shorter than `min_length` are discarded after clipping. This is an analysis-affecting change — existing trimmed output has to be removed before it takes effect.

## What this step writes

| Path | Contents |
|---|---|
| `Output/Trimmed/<sample>/` | `*_val_1.fq.gz`, `*_val_2.fq.gz` (Trim Galore) and `*_clipped.fq.gz` (cutadapt) |
| `Output/Unpaired/<sample>/` | Reads whose mate was discarded |
| `Output/Reports/Fastqc/<sample>/` | FastQC on trimmed and on clipped reads |
| `Output/Reports/Trimming/<sample>/` | Trim Galore reports (`.txt` and, on 2.x, `.json`) |

The trimmed reads are **deleted** once clipping has consumed them ([why](../concepts/design-decisions.md#steps-delete-their-own-inputs)); the clipped reads are what step 3 aligns.
