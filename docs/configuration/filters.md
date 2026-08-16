# Alignment Filters

Step 4 turns a raw BWA alignment into the BAM that variant calling reads. The last stage of that is a filter, and it is the first place a variant can be lost — nothing later in the pipeline can recover a read discarded here.

## The cleanup pipeline

Seven operations, streamed so no intermediate BAM is written:

| # | Operation | Command | Why |
|---|---|---|---|
| 1 | Name-sort | `samtools sort -n` | `fixmate` requires mates adjacent |
| 2 | Fix mate info | `samtools fixmate -m` | Corrects mate coordinates and adds the mate score tag `markdup` needs |
| 3 | Coordinate-sort | `samtools sort` | `markdup` requires coordinate order |
| 4 | Mark and **remove** duplicates | `samtools markdup -r -s` | See [below](#why-duplicates-are-removed-not-just-marked) |
| 5 | Add read groups | `samtools addreplacerg` | Writes the `@RG` string built from [`RGTags.csv`](read-groups.md) |
| 6 | Filter | `samtools view -F … -f … -q …` | The filter proper |
| 7 | Index | `samtools index` | Produces the `.bai` |

The result is written to `Output/Ready/` as `<sample>_ready.bam` with its index.

## The filter

```groovy
samtools {
    filter   = "0xF0C"   // -F : exclude any read with these bits set
    required = "0x2"     // -f : require these bits
    mapq     = 30        // -q : minimum mapping quality
}
```

### `filter` — what is excluded

`0xF0C` is the sum of six flag bits:

| Flag | Value | Excludes |
|---|---|---|
| `0x004` | 4 | Unmapped reads |
| `0x008` | 8 | Reads whose mate is unmapped |
| `0x100` | 256 | Secondary alignments |
| `0x200` | 512 | Reads failing platform QC |
| `0x400` | 1024 | PCR / optical duplicates |
| `0x800` | 2048 | Supplementary alignments |

Secondary and supplementary alignments are excluded because a read that aligns in more than one place would otherwise contribute its bases to several positions. In a frequency estimate that is double-counting, not extra evidence.

### `required` — what must be true

`0x2` requires the read to be **properly paired**: both mates mapped, in the expected orientation, at a plausible insert size. This is a strict requirement, and it is why single-end data does not work with the pipeline as configured.

### `mapq` — the quality floor

This one is not part of either flag word and is easy to overlook. At `30`, reads whose mapping quality falls below the threshold are discarded — meaning reads that could plausibly have come from more than one location in the genome.

For Pool-seq this matters more than usual. An ambiguously placed read still adds a read count wherever it lands, and allele frequencies *are* read counts. A repetitive region that collects mismapped reads produces frequencies that look real and are not.

The cost is coverage. In a repeat-rich or recently duplicated genome, a MAPQ 30 floor can discard a substantial fraction of reads. If your step 5 coverage reports show much less depth than you sequenced for, this is the first thing to check.

| Value | Effect |
|---|---|
| `30` (default) | Strict. Discards anything with meaningful placement ambiguity |
| `20` | Moderate. Common compromise on repetitive genomes |
| `0` | No MAPQ filtering. Only appropriate if you intend to handle mismapping yourself |

## Why duplicates are removed, not just marked

`markdup -r` removes duplicate reads rather than flagging them. Downstream callers usually respect the duplicate flag anyway, so the two are close to equivalent — but removal is the safer default here, and duplicates matter more in a pool than in an individual.

A PCR duplicate is a second read from a molecule that should only be counted once. In individual sequencing that inflates confidence in a genotype you would have called anyway. In Pool-seq it changes the answer: the duplicate adds a vote to one allele, and the frequency shifts. A library with uneven amplification produces a frequency estimate biased toward whichever molecules amplified best.

`-s` prints duplicate statistics into the step's log, which is worth reading — a high duplicate rate is a library-prep signal that no amount of filtering fixes.

## Changing these values

All three are analysis-affecting. Changing any of them means the existing BAMs no longer match your configuration, and step 0 will stop the next run ([why](../concepts/design-decisions.md#the-run-refuses-to-mix-settings)). Clearing it means deleting `Output/Ready/`, `Output/VCF/` and `Output/Frequencies/`.

Because the alignment step itself is unaffected, `Output/Aligned/` is preserved and the re-run starts from BAM cleanup rather than from BWA.

## Verifying what was applied

The `@RG` line written at stage 5 is the record of what this step did with your `RGTags.csv`:

```bash
samtools view -H Output/Ready/<sample>_ready.bam | grep '^@RG'
```

For read counts before and after filtering, compare `Output/Aligned/` against `Output/Ready/`:

```bash
samtools view -c Output/Aligned/<sample>.bam
samtools view -c Output/Ready/<sample>_ready.bam
```

The difference is duplicates plus everything the flag and MAPQ filters removed. The step 5 alignment report (`bamtools stats`) breaks the same numbers down by category.
