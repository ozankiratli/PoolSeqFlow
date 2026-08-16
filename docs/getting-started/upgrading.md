# Upgrading

`parameters.config` belongs to you and is never touched by an update. That is the right default — an update should not silently change your analysis settings — but it has a consequence: after pulling a new version, your file can be **missing parameters the newer code expects**, and nothing detects this.

## The failure it produces

Step 0 verifies successfully. A later step then fails with:

```text
.command.sh: line 17: null: command not found
```

An absent parameter interpolates as the literal string `null`, so the error names no parameter and points at a generated script. If you see this, your config predates the code.

!!! tip "Back up before you pull"

    `parameters.config` is no longer tracked in git, so an update that removes it upstream can take your copy with it. Copy it aside before `git pull`, not after.

## The assisted route

```bash
./PoolSeqFlow migrate_config
```

This backs your file up, rebuilds it from the current template, carries across every setting whose parameter still exists, and reports what happened to each one:

| Report | Meaning |
|---|---|
| `Kept your value` | The parameter still exists and your setting was carried over |
| `Renamed this release` | The parameter was renamed and your value followed it to the new name |
| `Now computed by the pipeline` | This release derives the value; yours was ignored |
| `Format changed this release` | The value's meaning or format changed, so the template's wins |
| `New in this release` | The template has a parameter your file did not — review the default |
| `No longer used` | Your file had a parameter this release does not use |

**Treat the result as a starting point, not an answer.** Migration can only recognise a parameter that still exists *and still means the same thing*. A parameter whose behaviour changed while its value still looks like an ordinary number or string is carried across and is silently wrong. Always compare afterwards:

```bash
diff parameters.config parameters.config.template
```

## The manual route

Every release adds parameters, and rebuilding by hand is often the safer choice — it is the only way to be certain you have actually looked at the new ones:

```bash
cp parameters.config parameters.config.bak        # keep your settings
cp parameters.config.template parameters.config   # start from the current schema
diff parameters.config.bak parameters.config      # see what changed, then re-apply yours
```

## Which release to watch for

The **Nextflow 26 / Trim Galore 2.x** release is the disruptive one. It adds `params.software.unzip`, `params.trim_galore.autodetect` and the whole `params.cores` block, none of which exist in an older file. It also:

- renames trimmed-read outputs, and
- derives the SnpEff database name from the GFF filename.

Both change the filenames the resume logic looks for, so **previously completed trimming and annotation steps are redone** on the first run after upgrading. That is expected; the earlier outputs are not deleted, so budget disk for both until you clear the old ones.

## After upgrading

A new release may add parameters that count as analysis-affecting, in which case step 0 will stop the next run and report that the parameters have changed since your existing outputs were produced. That is the guardrail working — it means the new setting could change results, and the pipeline will not mix old outputs with new ones in the same folder. The report names the folders to delete.

See [The run refuses to mix settings](../concepts/design-decisions.md#the-run-refuses-to-mix-settings) for what is and is not tracked, and the [Changelog](../reference/changelog.md) for what each release changed.
