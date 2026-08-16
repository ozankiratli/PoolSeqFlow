# Install

Check the [requirements](index.md) first if you have not — in particular that you are on Linux or macOS, and that conda is available.

## 1. Get PoolSeqFlow

=== "Download a release"

    ```bash
    curl -LO https://github.com/ozankiratli/PoolSeqFlow/releases/latest/download/PoolSeqFlow.tar.gz
    tar -xzf PoolSeqFlow.tar.gz
    cd PoolSeqFlow-*/
    ```

    This is the recommended route. The archive is the pipeline only — no documentation sources or CI config — and it extracts into a versioned directory, so you always know which release a working copy came from.

    Verify it if you like: download `SHA256SUMS` from the same release and run `sha256sum -c SHA256SUMS`.

    [All releases](https://github.com/ozankiratli/PoolSeqFlow/releases){ .md-button }

=== "Clone the repository"

    ```bash
    git clone https://github.com/ozankiratli/PoolSeqFlow.git
    cd PoolSeqFlow
    chmod +x PoolSeqFlow
    ```

    Use this if you want to track development, work from a branch, or send a pull request. `main` is not guaranteed to be a released state, and the `chmod` is needed because a clone does not always preserve the executable bit — the release archive does.

## 2. Create your configuration

`parameters.config` holds your own paths and settings, so it is **not tracked in git** — a fresh clone ships `parameters.config.template` instead. Create your copy:

```bash
cp parameters.config.template parameters.config
```

This is deliberately not done for you. The pipeline will not start without the file, so the settings get read rather than inherited.

## 3. Build the environment

```bash
./PoolSeqFlow install
```

This creates a conda environment named `PoolSeqFlow`. It takes a while on first run; subsequent installs reuse the conda package cache.

It then verifies itself, and **fails if anything is missing** — an environment that was created but is short a tool is not an install, and the alternative is finding out partway through step 4, hours in.

## 4. Verify it any time { #check }

```bash
./PoolSeqFlow check
```

```text
Tools

  nextflow       nextflow     OK       26.04.6 build 12646
  samtools       samtools     OK       samtools 1.24
  bcftools       bcftools     OK       bcftools 1.24
  …
  tool list from: params.software in parameters.config

Pipeline helpers

  atomic_mv.sh                 OK
  depth2freq.awk               OK
  …

Configuration

  parameters.config            PARSES

All 21 checks passed.
```

It covers three things:

**Every command the pipeline invokes**, with the version each reports. Once you have a `parameters.config`, the list is read from `params.software` through `nextflow config` rather than assumed — so a command [repointed at a system binary](../configuration/index.md#using-system-tools) is checked as *you* configured it. That override is the setting most likely to be wrong and least likely to announce itself.

**Every helper in `bin/`**, present and executable. `nextflow.config` puts that directory on `PATH` and the process scripts call the helpers by bare name, so a lost executable bit fails mid-run rather than at startup.

**That `parameters.config` parses**, once it exists.

---

## Set up your project directory

PoolSeqFlow expects a specific layout before it will run. The paths are yours to choose; the structure inside them is not.

```text
/path/to/project/            ← projectDir in parameters.config
├── Data/                    ← dataSource
│   ├── Sample1_R1.fq.gz
│   ├── Sample1_R2.fq.gz
│   └── …
├── RGTags.csv
├── reference.fasta.gz
└── reference.gff.gz         ← only if annotate = true
```

Both the reference FASTA and the GFF must be **gzipped**; the pipeline decompresses them itself into `Reference/`.

Copy the read-group template and fill it in:

```bash
cp RGTags.csv.template /path/to/project/RGTags.csv
```

`RGTags.csv` is not optional and it is not only metadata — it decides which FASTQ pairs are treated as the same biological sample, and the order your result columns come out in. Read [Read Groups](../configuration/read-groups.md) before your first run rather than after it.

---

## Next

<div class="grid cards" markdown>

-   **Configure and run**

    ---

    Fill in `parameters.config` and start the pipeline.

    [Quick Start →](quick-start.md)

-   **Coming from an earlier version**

    ---

    Your existing `parameters.config` will be missing parameters the new code expects, and nothing detects that automatically.

    [Upgrading →](upgrading.md)

</div>
