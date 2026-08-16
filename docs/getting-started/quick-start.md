# Quick Start

This page gets a run going. It assumes you have installed the environment and laid out your project directory as described in [Getting Started](index.md).

## 1. Fill in the essentials

Open `parameters.config`. Nine settings need your attention before a first run; everything else has a working default.

```groovy
params {
    mainDir       = "/path/to/working/directory"  // where the pipeline runs
    projectDir    = "/path/to/permanent/storage"  // where outputs are kept
    dataSource    = 'Data'                        // subdirectory of projectDir holding FASTQs
    readPattern   = "*_R{1,2}.fq.gz"              // glob matching your paired FASTQ files
    referenceFile = 'reference.fasta.gz'          // gzipped reference genome
    gffFile       = 'reference.gff.gz'            // gzipped annotation (only if annotate = true)
    poolSize      = 50                            // individuals per pool
    diploidy      = 2                             // ploidy of your organism
    annotate      = true                          // run SnpEff annotation (step 8)
}
```

| Setting | How to choose it |
|---|---|
| `mainDir` | Fast local disk or node scratch. May be the same as `projectDir`. |
| `projectDir` | Where results should live permanently, and where your `Data/`, reference and `RGTags.csv` already are. |
| `readPattern` | Must match **both** mates with a `{1,2}` group. If your files end `_1.fastq.gz`/`_2.fastq.gz`, write `"*_{1,2}.fastq.gz"`. |
| `poolSize` | Individuals in **one** pool, not the total across pools. Sets the minimum credible frequency — see [The Filter Chain](../concepts/filter-chain.md#where-s-comes-from). If pools differ in size, use the smallest. |
| `diploidy` | Ploidy of the organism: `2` for diploid, `1` for haploid, `4` for tetraploid. |
| `annotate` | `false` skips step 8 and makes `gffFile` unnecessary. |

!!! warning "Set these through the file, never the command line"

    PoolSeqFlow rejects command-line parameter overrides, and `./PoolSeqFlow` refuses any argument beyond a single subcommand. Nextflow delivers `--param` values as strings, so `--annotate false` sets the string `"false"` — which Groovy evaluates as **true**, leaving annotation switched on with no warning. [Why →](../concepts/design-decisions.md#configuration-is-a-file-never-a-flag)

`mainDir` and `projectDir` can be the same path if you have one storage location. They are separate to support environments where compute nodes and permanent storage are on different filesystems, which is common on HPC.

## 2. Size the run to your machine

```groovy
threads = 8          // cores a single task may use
memory  = '24 GB'    // memory ceiling for a single task
```

Set `threads` to the cores you actually have — on HPC, the size of one node. Every tool's thread count follows from this one number; do not set the per-tool counts by hand. A request larger than the machine fails immediately:

```text
Process requirement exceeds available CPUs -- req: 12; avail: 8
```

Details and the full ladder: [Resources](../configuration/resources.md).

## 3. Fill in `RGTags.csv`

One row per FASTQ pair. `ID` must match the sample prefix in your filenames.

```csv
ID,SM,LB,DS,FO,PL,PU
Sample1T1Rep1,Sample1T1,Lib1,Pop1_T1_Rep1,FASTQ,ILLUMINA,Unit1
Sample1T1Rep2,Sample1T1,Lib1,Pop1_T1_Rep2,FASTQ,ILLUMINA,Unit1
Sample2T1Rep1,Sample2T1,Lib1,Pop2_T1_Rep1,FASTQ,ILLUMINA,Unit1
Sample2T1Rep2,Sample2T1,Lib1,Pop2_T1_Rep2,FASTQ,ILLUMINA,Unit1
```

Two things this file decides, beyond metadata:

- **`SM` decides what counts as a sample.** Rows sharing an `SM` are merged into one VCF column, and their read depths add together. The four rows above produce **two** columns, not four.
- **Row order decides column order** in the VCF and the frequency tables.

Both are covered in [Read Groups](../configuration/read-groups.md). Getting `SM` wrong is the most common way to end up with results that are valid but not what you meant.

## 4. Run

```bash
./PoolSeqFlow run
```

That is also the resume command. Every step checks whether its outputs already exist and skips itself if they do, so an interrupted run picks up where it left off with no extra flag. There is no `-resume`.

To start genuinely from scratch, use `./PoolSeqFlow reset` first — it requires typing `DELETE_MY_ANALYSIS` to confirm.

## 5. Check the output

```text
projectDir/
├── Logs/
├── Reference/
└── Output/
    ├── Frequencies/   ← the result: <name>_snp_freq.tsv, <name>_indel_freq.tsv
    ├── VCF/
    ├── Ready/         ← cleaned, indexed BAMs
    ├── Reports/
    └── …
```

Start with `Output/Reports/Coverage/` and `Output/run_parameters.txt`. The first tells you whether your depth was truncated by the pileup cap; the second is a read-only record of exactly which settings produced these files.

How to read the tables: [Interpreting Results](../concepts/interpreting-results.md).

---

## Commands

| Command | Description |
|---|---|
| `./PoolSeqFlow install` | Create the conda environment, then verify it |
| `./PoolSeqFlow check` | Verify an existing installation ([what it covers](index.md#3-build-the-environment)) |
| `./PoolSeqFlow run` | Start — or resume — the pipeline |
| `./PoolSeqFlow migrate_config` | Carry an older `parameters.config` onto the current template ([details](upgrading.md)) |
| `./PoolSeqFlow clean` | Remove Nextflow work directories |
| `./PoolSeqFlow reset` | Remove all progress and start fresh (requires typed confirmation) |
| `./PoolSeqFlow version` | Print the installed version |
| `./PoolSeqFlow cite` | Print how to cite this copy, and which DOI to use ([why it matters](../reference/citation.md#which-doi-to-use)) |
| `./PoolSeqFlow uninstall` | Remove the conda environment |

`./PoolSeqFlow resume` still works as a deprecated alias for `run` and prints a notice.
