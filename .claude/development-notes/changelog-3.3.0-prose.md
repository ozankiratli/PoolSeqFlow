# The 3.3.0 release notes, kept while the bump is reverted

**Written 2026-10-07 against `main` at `6550cb5`.** The prose of the `## [3.3.0]` section of `CHANGELOG.md` as Z left it, from its heading down to `### Commits`, copied verbatim below.

## Why it is here

v3.3.0 was tagged at `babb475` on 2026-10-07 and never released. `release.yml` stopped at its analysis version gate: `raise-module-floors.sh` had moved the `environment` floor of six manifests (association, basicstats, mds, allele_frequencies, n_eff, nei_distance) from 3.0.0 to 3.3.0, and those edits landed in the version-bump commit, which moved none of their versions. No GitHub release was created, and the tag was deleted locally and on origin.

A review of the new `publish-module.sh --all-pending` then found defects, and Z decided they are to be fixed before releasing: "This is more serious." So the bump is reverted on `dev`, and `bump-version.sh --revert` deletes this section along with it.

The revert does not fix what stopped the release. Raising the floors at the next bump puts the same edit in the same kind of commit, and the gate fails the same way until `raise-module-floors.sh` or the gate changes.

## What to check when it goes back

The next bump writes its own heading, date and commit list, and this prose goes back above `### Commits`.

- The module versions under Analysis modules are the ones prepared for this cycle. A module bumped again before the release carries a new version, and its line has to name that one.
- Anything that lands on `dev` before the next bump and changes what a user sees needs a line of its own. `publish-module.sh --all-pending` is a maintainer tool and does not.

## The section

```markdown
## [3.3.0] - 2026-10-06

**The shallowest library no longer has to decide which sites the whole cohort keeps.** Until now one pool below `vcffilter.minDP` removed a site for every pool. `vcffilter.keepLowDepthAsZero` keeps the site instead and writes that pool's reads there as unread. It is off by default, so nothing changes until you turn it on. 

**Two things to read before upgrading**, both under Changed: the default of `variantCall.scaleMapQ` moved from 50 to 100, and a migrated `parameters.config` keeps its 50; and `init_multi` and `uninstall_all` are now two words.

### Added

- **`vcffilter.keepLowDepthAsZero` and `vcffilter.minSamples`.** With the switch on, every cell below `minDP` (one pool's reads at one site) is written as unread, which the depth table carries as zeros and the frequency table as `NA`, and a site is kept when at least `minSamples` of its cells reach `minDP`. `minSamples` defaults to 2 and runs from 1 to the number of pools with reads; anything else is refused before the run starts. Every read still counts toward deciding that an allele exists, because the false-positive filter runs first; only the cells at the floor count toward measuring its frequency. The manual's depth and quality filter section has the details, including what it does to `TOTAL_AD`.
- **Settings that would make a run produce nothing are refused at step 0**, and `PoolSeqFlow check project` reports the same findings before you run. A `scaleMapQ` below `varQualMin` discards every read, a `sampleThreshold` above 1 removes every site, a `ploidy` or `poolSize` below 1 breaks every detection limit, and a `fastqc.memory` with a unit is refused by FastQC. Settings that work but cost more than they look, or change what a number means, are warned about and the run continues. The manual lists them all.
- **Files saved on Windows.** A `metadata.csv` or `runs.csv` that Excel saved as "CSV UTF-8" is read as it is, and a UTF-16 one is refused with what to save it as instead. A `parameters.config` that begins with a byte-order mark is named by `check project`, with the command that removes it; Nextflow on its own refuses the file over a character nothing displays.
- **Native zsh completion**, with a description beside each command. The installer prints the one line `~/.zshrc` needs.

### Changed

- **`variantCall.scaleMapQ` defaults to 100, where it was 50.** It is the `-C` that lowers the mapping quality of reads with many mismatches. Measured on real pools, 100 removes the sites that are artifacts (Ti/Tv 0.848, nearly four times the soft-clip bias of the sites kept), while 50 removed five times as many and took real variants with them. 50 also lowered the frequencies it kept, by 0.035 on average against 0.008 at 100, and by 0.081 in pools between 0.50 and 0.75. **A migrated `parameters.config` keeps 50**: `migrate_config` carries your value across, as it does every setting that still exists, and reports it under `Kept your value`. Set it to 100 before the first run under 3.3.0. The manual has the full measurements.
- **`init_multi` is `init multi`, and `uninstall_all` is `uninstall all`.** The old spellings stop with a message giving the new one.
- **A pool with no reads at a site is `NA` in the frequency table**, where it was 0, because a frequency over zero reads does not exist. By default no such cell reaches a table: the depth filter now also drops a site with an unread pool at `minDP` 0, which 3.2.0 kept and published as 0. With `keepLowDepthAsZero` on, `NA` is what an unread cell reads.
- **Every step writes its log as it runs.** A step that fails, or is killed, leaves what it had reached in `Logs/`. Before this, a step copied its log there only at the end, so a failure lost exactly the log that would have explained it. Each attempt starts with a line naming the run, the session and the time.
- **Capping is about seven times faster on real data**, with identical output.
- **A call set or filter that leaves nothing stops the run** and says which settings to look at, instead of finishing as though it had succeeded. Nothing is published from it.
- **Environments.** FastQC 0.12.1 to 0.13.0, Perl 5.32.1 to 5.44.0, pandoc 3.11 to 3.12, R's future and doFuture to their next minor versions, and patch updates beneath them. bwa, samtools, bcftools, cutadapt, Trim Galore and snpEff did not move.

### Analysis modules

- **association `20261006.001`.** Two ways it published `perm_p` 0, which no permutation p can be. A site where any unit had no reads came out 0, and `fdr_p` with it; in 3.2.0 that took `minDP` 0. And the strongest sites in a table, far beyond any rearrangement, failed to count themselves and came out 0 too. Each site is now tested over the units it was read in, and not tested when fewer than three were read. `design_floor` is 1/n!, where it said 2/n!, so four units can reach 0.042.
- **mds `20261006.002`.** A pair of pools averaged over fewer than 30 shared sites is flagged, in `distance.tsv`, on the console and under the plot. In simulation, a distance near 0.02 measured over 30 shared sites is off by about half itself, and real sites are noisier.
- **basicstats `20261006.001`.** A pool's depth summaries cover only the sites it was read at, and `depth.tsv` and `diversity.tsv` count the rest in a new `unmeasured` column. A site with no reads for a pool was averaged in as a depth of 0, and one such site was enough to turn that pool's harmonic depth into 0 and its effective sample size into NA; in 3.2.0 that took `minDP` 0.
```
