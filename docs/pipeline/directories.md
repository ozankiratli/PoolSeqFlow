# Directory Layout

## The repository

```text
PoolSeqFlow/
├── bin/
│   ├── atomic_mv.sh              # Cross-filesystem moves, staged and renamed
│   ├── config_migrate.sh         # Backs migrate_config
│   ├── createDepthFile.sh        # Extract AD/DP columns from a VCF
│   ├── depth2freq.awk            # Convert allelic depths to frequencies
│   ├── filterFalsePositives.sh   # Cross-sample support filter
│   └── MajorAlleleToRef.py       # Re-encode VCF with the major allele as REF
├── install/
│   ├── environment.yml           # Pinned conda environment
│   └── check_install.sh          # Verifies an installation (./PoolSeqFlow check)
├── scripts/
│   ├── 0_verify_environment.nf
│   ├── 1_build_dictionaries.nf
│   ├── 2_trim_reads.nf
│   ├── 3_align.nf
│   ├── 4_clean.nf
│   ├── 5_reports.nf
│   ├── 6_variant_call.nf
│   ├── 7_vcf2freq.nf
│   └── 8_annotate_variants.nf
├── docs/                         # This documentation
├── mkdocs.yml
├── nextflow.config
├── parameters.config             # Yours — not tracked in git
├── parameters.config.template
├── poolseqflow.nf                # Workflow entry point
├── PoolSeqFlow                   # CLI wrapper
└── RGTags.csv.template
```

`bin/` is prepended to `PATH` by `nextflow.config`, which is how the helper scripts are callable by bare name inside process scripts.

## What you provide

```text
/path/to/project/            ← projectDir
├── Data/                    ← dataSource
│   ├── Sample1_R1.fq.gz
│   ├── Sample1_R2.fq.gz
│   └── …
├── RGTags.csv
├── reference.fasta.gz
└── reference.gff.gz         ← only if annotate = true
```

Both reference files must be gzipped. The pipeline decompresses them into `Reference/` itself.

## What the pipeline produces

```text
/path/to/project/
├── .poolseqflow_params           # Analysis parameters behind these outputs
├── .poolseqflow_rgtags           # RGTags.csv as consumed
├── .poolseqflow_versions         # Pipeline versions that have run here, oldest first
├── Logs/                         # Per-step .log and .err, mirrored from every task
├── Reference/
│   ├── reference.fasta
│   ├── reference.fasta.{amb,ann,bwt,fai,pac,sa}
│   └── snpEff/
└── Output/
    ├── run_parameters.txt        # Read-only mirror of .poolseqflow_params
    ├── Trimmed/<sample>/         # Trimmed and clipped FASTQs
    ├── Unpaired/<sample>/        # Reads whose mate was discarded
    ├── Aligned/                  # Raw BWA output
    ├── Ready/                    # Cleaned, filtered, indexed BAMs
    ├── VCF/                      # Call sets
    ├── Frequencies/              # The result
    └── Reports/
        ├── Alignment/
        ├── Coverage/
        ├── Fastqc/<sample>/
        ├── Trimming/<sample>/
        ├── 0_verify_environment.txt
        ├── snpeff_summary.html
        └── PoolSeqFlow_pipeline_{report,timeline,trace,dag}.*
```

`mainDir` additionally holds `work/`, which `cleanup = true` empties after a successful run and `./PoolSeqFlow clean` removes.

## What survives a completed run {: #what-survives-a-completed-run }

Several steps delete their inputs once the next stage has consumed them, and the deletion follows the symlink — the permanent copy goes too ([why](../concepts/design-decisions.md#steps-delete-their-own-inputs)). So the contents of `Output/VCF/` mid-run and after a completed run are not the same.

With `vcf.fileName = 'Test'`:

| File | Survives | Notes |
|---|---|---|
| `Test.vcf` | **Yes** | Raw call set from step 6 |
| `Test_sort.vcf` | No | Deleted by the false-positive filter |
| `Test_sort_fp.vcf` | No | Deleted by the depth/quality filter |
| `Test_sort_fp_dq.vcf` | **Yes** | Fully filtered, major-allele normalised |
| `Test_sort_fp_dq_snp.vcf` | No | Deleted by frequency conversion |
| `Test_sort_fp_dq_indel.vcf` | No | Deleted by frequency conversion |
| `Test_annotated.vcf` | **Yes** | If `annotate = true`; annotates the *raw* call set |
| `Test_snp_freq.tsv` | **Yes** | In `Frequencies/` |
| `Test_indel_freq.tsv` | **Yes** | In `Frequencies/` |

Likewise, `Output/Trimmed/<sample>/` keeps only the `_clipped.fq.gz` files after a completed run — the intermediate `_val_1`/`_val_2` files are removed once clipping has used them.

`Output/Aligned/` and `Output/Ready/` are both kept. Nothing deletes a BAM.

## Sizing storage

Rough guidance for planning, per sample:

| Directory | Relative size | Kept? |
|---|---|---|
| `Data/` | Your input | Yours |
| `Trimmed/` | Slightly under input, after clipping | Yes |
| `Unpaired/` | Small | Yes |
| `Aligned/` | Comparable to trimmed input | Yes |
| `Ready/` | Smaller — duplicates and filtered reads removed | Yes |
| `VCF/` | Depends on variant density, not read count | Partly |
| `Frequencies/` | Larger than the VCF it came from — one row per allele, not per site | Yes |

The two BAM directories dominate. If disk is tight, `Output/Aligned/` is the safe thing to remove after a completed run: step 4 has consumed it, and only a re-run from alignment would need it back.

`mainDir` needs far less — the symlink strategy means `work/` holds links rather than copies, with genuine working space needed only for the intermediates of currently running tasks.
