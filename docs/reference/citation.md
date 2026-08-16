# Citation & License

## Citing PoolSeqFlow

The installed copy will print its own citation, with its version filled in:

```bash
./PoolSeqFlow cite
```

Use that rather than copying from here — it knows which version you have, and this page does not.

## Which DOI to use

Zenodo issues **two kinds of DOI**, and the difference matters.

| DOI | What it identifies | Use it for |
|---|---|---|
| [10.5281/zenodo.19245611](https://doi.org/10.5281/zenodo.19245611) | **All versions.** Always resolves to the newest release | Referring to PoolSeqFlow as a piece of software — a related-work mention, a README, a link |
| A version DOI, one per release | **One specific release**, frozen | **Reporting results.** This is the one a methods section needs |

!!! warning "Cite the version you ran, not the newest one"

    Results depend on which release produced them. Filters, defaults and parameter names have all changed between versions — `vcffilter.minDP` went from having no effect to removing whole sites, and sample column ordering changed in 2.1.1. A paper citing the current release for numbers produced by an older one is describing a method it did not use.

    Find your version with `./PoolSeqFlow version`, then open the [all-versions record](https://doi.org/10.5281/zenodo.19245611) and pick that version from the **Versions** list to get its DOI.

## Reference

> Kiratli, O. L. Z. (2026). *PoolSeqFlow: A Nextflow pipeline for allele frequency analysis from pooled Illumina sequencing data* (Version *x.y.z*) \[Computer software\]. <https://doi.org/10.5281/zenodo.19245611>

```bibtex
@software{kiratli_poolseqflow,
  author  = {Kiratli, Ozan L. Z.},
  title   = {PoolSeqFlow: A Nextflow pipeline for allele frequency
             analysis from pooled Illumina sequencing data},
  version = {x.y.z},
  year    = {2026},
  doi     = {10.5281/zenodo.19245611},
  url     = {https://github.com/ozankiratli/PoolSeqFlow}
}
```

Replace `x.y.z` with the version you ran, and swap the DOI for that version's own.

## Citing the tools it runs

PoolSeqFlow orchestrates other people's software, and a methods section should credit it. The pipeline's own results depend directly on these:

| Tool | Used for |
|---|---|
| Nextflow | Workflow execution |
| FastQC | Read quality metrics, and the composition table driving clipping |
| Trim Galore | Adapter and quality trimming |
| Cutadapt | Composition-aware clipping |
| BWA | Alignment (`bwa mem`) |
| SAMtools | BAM processing, duplicate removal, filtering |
| BAMtools | Alignment statistics |
| BCFtools | Variant calling, normalisation, filtering |
| VCFtools | Depth/quality filtering and SNP/INDEL splitting |
| SnpEff | Variant annotation, if enabled |

Exact versions are pinned in `install/environment.yml`, and the versions for the current release are listed under [Requirements](../getting-started/index.md#requirements).

## License

PoolSeqFlow is licensed under the [Apache License 2.0](https://github.com/ozankiratli/PoolSeqFlow/blob/main/LICENSE).

The tools it invokes carry their own licenses, which are not affected by this one.

## Contact

**Ozan L. Z. Kiratli**

- GitHub: [@ozankiratli](https://github.com/ozankiratli)
- Issues: [github.com/ozankiratli/PoolSeqFlow/issues](https://github.com/ozankiratli/PoolSeqFlow/issues)
- Website: [ozankiratli.github.io](https://ozankiratli.github.io)
