# Read Groups

`RGTags.csv` lives in your project directory and carries one row per FASTQ pair. It looks like metadata, and it is — but two of its properties change your results, so it is worth getting right before the first run rather than discovering it afterwards.

```csv
ID,SM,LB,DS,FO,PL,PU
Sample1T1Rep1,Sample1T1,Lib1,Pop1_T1_Rep1,FASTQ,ILLUMINA,Unit1
Sample1T1Rep2,Sample1T1,Lib1,Pop1_T1_Rep2,FASTQ,ILLUMINA,Unit1
Sample1T2Rep1,Sample1T2,Lib1,Pop1_T2_Rep1,FASTQ,ILLUMINA,Unit1
Sample1T2Rep2,Sample1T2,Lib1,Pop1_T2_Rep2,FASTQ,ILLUMINA,Unit1
Sample2T1Rep1,Sample2T1,Lib1,Pop2_T1_Rep1,FASTQ,ILLUMINA,Unit1
Sample2T1Rep2,Sample2T1,Lib1,Pop2_T1_Rep2,FASTQ,ILLUMINA,Unit1
Sample2T2Rep1,Sample2T2,Lib1,Pop2_T2_Rep1,FASTQ,ILLUMINA,Unit1
Sample2T2Rep2,Sample2T2,Lib1,Pop2_T2_Rep2,FASTQ,ILLUMINA,Unit1
```

*Eight FASTQ pairs, four distinct `SM` values — this file produces a VCF with **four** samples: `Sample1T1`, `Sample1T2`, `Sample2T1`, `Sample2T2`.*

## Fields

| Tag | Required | Description |
|---|---|---|
| `ID` | **Yes** | Unique identifier; must match the sample prefix in your FASTQ filenames |
| `SM` | No | Sample / population name — **decides VCF columns**, see [below](#sm-decides-what-counts-as-a-sample) |
| `LB` | No | Library identifier |
| `DS` | No | Description |
| `FO` | No | Flow order (typically `FASTQ`) |
| `PL` | No | Platform (e.g. `ILLUMINA`) |
| `PU` | No | Platform unit |
| `CN` | No | Sequencing centre |
| `DT` | No | Run date (ISO 8601, e.g. `2024-03-07`) |

Empty fields are skipped when the `@RG` string is assembled, so a blank column is omitted rather than written as an empty tag.

**Every `ID` must appear exactly once.** A row is looked up by `ID` and only the first match is read, so a repeated `ID` would silently discard the later rows and give that sample the wrong tags — producing a perfectly valid BAM that nothing downstream could flag. Step 0 refuses to run and lists the offending values.

### Excel on Windows

Saving this file from Excel on Windows writes CRLF line endings, which puts a stray carriage return in the last tag of every row. That previously failed with `Invalid tag 'PU'`, which names nothing useful.

Step 0 now detects it, rewrites the file with Unix line endings, and reports:

```text
RGTAGS LINE ENDING CHECK: FIXED
```

Permissions and ownership are preserved. If the file cannot be rewritten, the run stops and tells you the command to run.

## `SM` decides what counts as a sample

`ID` identifies each FASTQ pair, but **`SM` determines the samples in your variant calls.** BCFtools names VCF columns after `SM`, and any read groups sharing a value are pooled into a single column.

| `SM` values in `RGTags.csv` | Resulting VCF columns |
|---|---|
| `Sample1`, `Sample2`, `Sample3` | `Sample1` `Sample2` `Sample3` |
| `Population1`, `Population1`, `Sample3` | `Population1` `Sample3` |

**Give every pool its own `SM`** when you want them analysed separately. This is what most runs want, and it is the safe default.

**Share an `SM` deliberately** when several FASTQ pairs are really the same biological pool:

- **One pool sequenced more than once** — split across lanes or runs to reach the depth Pool-seq needs. Each run arrives as its own FASTQ pair, but they describe one set of individuals, and the allele frequencies are only correct once the reads are combined.
- **Technical replicates** of the same library that you want treated as one observation rather than compared with each other.

Because merging happens at variant calling, it changes the numbers: read depths add together and each frequency is computed across the pooled reads. Leaving one pool split across two `SM` values instead gives you **two under-powered estimates of the same thing** — which is easy to do by accident, since the FASTQ files look like two ordinary samples.

!!! warning "This interacts with the cross-sample filter"

    Merging changes the sample count, and the false-positive filter requires an allele to appear in a *fraction* of samples. Eight pairs as eight samples require two supporting samples; the same eight merged into four require one. Deciding `SM` is therefore also deciding how strict your filtering is — see [The Filter Chain](../concepts/filter-chain.md#where-m-comes-from).

## Row order decides column order

**The order of the rows in `RGTags.csv` is the order of the sample columns** in the VCF and in the frequency tables. Put the rows in whatever order you want to read your results in — treatment before control, or by time point — and the output follows.

```csv
ID,SM,DS,FO,PL,PU
Sample3,Sample3,Sample3,FASTQ,ILLUMINA,Unit1     # -> first column
Sample1,Sample1,Sample1,FASTQ,ILLUMINA,Unit1     # -> second column
Sample2,Sample2,Sample2,FASTQ,ILLUMINA,Unit1     # -> third column
```

When several rows share an `SM`, the merged column appears where the **first** of those rows sits.

Reordering rows only moves columns; it never changes a value. Nothing else about the file is positional.

This exists because the alternative is worse. `collect()` alone emits BAMs in task-completion order, so whichever sample finished first landed first on the bcftools command line — and three consecutive runs on identical input gave three different column orders. Sorting on the file path is no better, since Nextflow's paths begin with a random work-directory hash. Row order is the only ordering that is both stable and meaningful.

## Editing `RGTags.csv` after a run

Completed steps are skipped by looking for their output files, not by checking what produced them. So once this file has been consumed, editing it does **not** update anything that already exists — the tags are inside the BAMs, and the column order is inside the VCF.

Step 0 records the file the first time it is used and compares against that record on every later run. **If it has changed, the run stops before any work happens** and the report tells you which outputs are now stale:

| What you changed | What it invalidates | Delete and rerun |
|---|---|---|
| A tag value (`SM`, `DS`, …) | The BAMs, and everything called from them | `Output/Ready/`, `Output/VCF/`, `Output/Frequencies/` |
| Row order only | The VCF sample column order | `Output/VCF/`, `Output/Frequencies/` |

Deleting the affected outputs is what clears the check — the edit becomes the new baseline on the next run. Or discard everything and start over with `./PoolSeqFlow reset`.

The record lives in `.poolseqflow_rgtags` in your project directory. Line endings and trailing whitespace are ignored when comparing; row order is not.

Projects whose outputs predate this check adopt their current file as the baseline, with a note to confirm it against the BAM headers:

```bash
samtools view -H Output/Ready/<sample>_ready.bam | grep '^@RG'
```

## Checklist

Before your first run:

- [ ] One row per FASTQ pair, no `ID` repeated
- [ ] Every `ID` matches a filename prefix that `readPattern` will find
- [ ] `SM` shared only where pairs are genuinely the same pool
- [ ] Rows in the order you want your result columns
- [ ] Saved with Unix line endings, or expect step 0 to fix it and say so
