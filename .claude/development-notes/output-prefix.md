# outputPrefix: one name at the start of every output, and dated report names

Written 2026-10-08, against `dev` at `1b04cb1` plus that day's uncommitted work (`module-reports.md`, `mds-labels.md`). Not updated to follow the code.

## The ask

Z: *"At the top we will add params.outputPrefix = "Test". We will make vcf.filename = params.outputPrefix. Then all the other output files freq depth etc will be correctly named with the prefix. We will add output prefix in front of all analysis outputs. Also the reports coming from analysis should be named [prefix]_[analysis]_report_[datetime as in 20261007-103602].pdf eg. Test_mds_report_20261007-103602.pdf"*

I proposed renaming `vcf.fileName` to `outputPrefix` outright, one setting so the VCF and the analysis files could not disagree. Z ruled against it: *"If someone wants to change VCF name they still should be able to. vcf.fileName should stay in the template."* Z then wrote the template line as `fileName = "${params.outputPrefix}"`, the interpolated form the template's other derived lines use, *"Easier for the end user to change."* My other three points Z accepted: the analysis layer, not each module, applies the prefix (*"is fine as long as we get the end result right"*), and upgrading projects rerunning is *"not a problem"*.

## What was built

**The pipeline side.** `outputPrefix` is the first line of `params`. `vcf.fileName` follows it in the template, and `nextflow.config` fills either for a config that lacks it: `outputPrefix` from `vcf.fileName` and then `'Test'`, `vcf.fileName` from `outputPrefix`. A run table's `outputPrefix` reaches that run's VCF name through `deriveRunPaths()`, which re-derives it unless the global `vcf.fileName` differs from the global `outputPrefix`, which is the same pin test the other derived values use. `vcf.fileName` joined `derivedParameterNames()`. `outputPrefix` joined step 7's artifact identity, so one results directory never holds runs of two prefixes and every analysis target has exactly one; `targetPrefix()` in `plan.nf` throws if that ever fails.

**The check.** `check_parameters.sh` fails an empty `outputPrefix` or `vcf.fileName` and one holding anything outside `[A-Za-z0-9._-]`. It judges only a key the input carries. Step 0 runs that check over the global parameters only, so a run table's `outputPrefix` is not seen there; `targetPrefix()` applies the same rule per results directory, which is where a run-table value would first become a file name in the analysis layer.

**The migration.** `renamed()` maps `outputPrefix` to the old `vcf.fileName`, so an upgrading project's prefix is its existing VCF name and nothing of its gets renamed; `vcf.fileName` then takes the template's derived line, which yields the same name. A note explains it. `pinned()` keeps a literal `vcf.fileName` when the old config already has `outputPrefix`. Without that, the migration's rule that a template-computed line beats the user's literal would undo a deliberately named VCF at every later migration, which is exactly what Z's ruling says must stay possible.

**The analysis side.** `InstallResults` renames every top-level file the module produced to `<prefix>_<name>` right after copying it into the stage, before the README, the citations and the report are written. Code keeps its name: the script extensions the script check already uses, plus `.cpp`, `.c`, `.h`, `.hpp`. So do the frame's own files, `README.md`, `CITATIONS.md`, `references.bib` and the verification record, because they are written after the rename. Manifests keep the names a module writes; `publishedName()` gives the README and the declared-output check the published ones.

**The report name** is `<prefix>_<module>_report_<yyyyMMdd-HHmmss>.pdf`, the time taken once in the `InstallResults` script block from the local clock, so the README and the PDF carry the same stamp. The middle part is the module name, not `folderName`. Both were my calls, stated to Z with the plan.

**Inside the report**, `report_read()` and `report_files()` take the name a module wrote and read the prefixed file; `report_name()` gives a caption the published name, and `report_logical()` takes the prefix off a name a report parses a sequence out of (basicstats' depth plots, association's Manhattan plots). `POOLSEQFLOW_REPORT_PREFIX` carries the prefix and **an unset one stops the report**. Every report from v3.0.0 to v3.2.0 was blank because the folder reached the template as a literal that matched nothing (`module-reports.md`); a prefix that silently defaulted to none would do the same thing again, every section looking for a name the folder does not hold.

## Found on the way

**The manual said changing `vcf.fileName` after a run re-runs the VCF branch beside the old files. Step 0 refuses instead.** `analysisParams()` excludes paths, resources and tool locations and nothing else, so `vcf.fileName` has been in the recorded manifest all along and any change to it fails the parameter guard. The new naming section says what happens. The same now holds for `outputPrefix`.

**Step 0's line after a FAIL finding said the setting "would make this run produce nothing"**, which a name that cannot start a file name does not do; it stops the run partway. Widened, and the manual's quote of it and its level table with it. `fastqc.memory` carrying a unit was already that kind of FAIL.

## Tests

`analysis_render_report` stages the folder as `InstallResults` publishes it, as links named under `Test`, so every report case outside Nextflow reads prefixed files. Its copy of the code rule is a second definition of `InstallResults`'; the cases that publish through Nextflow are what hold the two together.

A third analysis baseline, `prefixed`, sets `outputPrefix = 'Pfx'` and `vcf.fileName = 'Calls'`. Everywhere else both are `Test`, so a frame that took the VCF name would pass every other case. The case checks the config took both substitutions before trusting what it publishes.

The report-name case brackets the run with the clock on either side and requires the stamp between them, which catches a fixed string, a date alone, or UTC on a machine that is not on it.

Module versions were not moved. Z: *"You don't need to bump versions."* Step 4 of the release names what is behind.

Fifteen mutants of the guards above, each killed: eleven without a JVM (the check's empty and absent cases, the migration's rename and pin, `report_read`, `report_files`, `report_logical` and the unset prefix, an mds caption, both reports' plot-name parsing) and four through Nextflow (the prefix taken from the VCF name, a date-only stamp, a script given the prefix, a run's prefix kept from its VCF).

## The review, the same day

Three read-only reviewers went over the change before Z had seen it. What they found, and what changed. **Where this contradicts a section above, this is the current state**; the sections above say what was built first.

**A module never got the default.** A module is its own pipeline and reads no `nextflow.config`, which `shell-and-nextflow-gotchas.md` records and `analysis/frame.config` says in its header; the frame config carried `params.cores` and nothing for `outputPrefix`. A config without the key, which a project that skipped `migrate_config` has, published every file as `null_*`: `"${run.outputPrefix}"` makes a missing key the string `null`, and the name rule accepted it. The verification, run beside `nextflow.config`, saw the right prefix, so nothing looked wrong. The three default lines are now in `frame.config` too, and a fourth analysis baseline, `legacy`, runs a module on such a config.

**The name rule was too loose in three ways.** A leading `.` passed, and `list.files()` does not list hidden files, so a report lost every figure while the folder was complete. A leading `-` reads as an option. And `null` passed, which is also what the template's own `fileName = "${params.outputPrefix}"` reads as when someone deletes or comments out the `outputPrefix` line, so such a config ran as `null.vcf`. A name now starts with a letter or a digit and `null` is refused with that cause named, in `check_parameters.sh`, `targetPrefix()` and the run-table parser alike.

**A run table's cells were never checked.** Step 0 runs `check_parameters.sh` over the global parameters only. Above I wrote that `targetPrefix()` is where a run-table value would first become a file name; that was wrong, because `deriveRunPaths()` makes a run's prefix its VCF name, and step 6 passes that name to `bcftools` unquoted, so a cell holding a space failed at variant calling after trimming and alignment. `parse_multirun.py` now holds `outputPrefix` and `vcf.fileName` cells to the rule, beside its RunID check, before anything runs.

**The migration still renamed a VCF silently in two shapes.** A current config whose `vcf.fileName` is an expression of its own, `"${params.outputPrefix}_v2"`, was given the template's line with no report entry; `pinned()` only kept literals. And a config from before the prefix whose name was an expression lost it the same way, with no note, because the rename into `outputPrefix` only carries a literal and nothing else reported it. Now a config that has `outputPrefix` keeps whatever `vcf.fileName` it wrote; a config without it keeps an expression where it is and gets the template's prefix, with a note saying so; and only a literal name moves into `outputPrefix`.

**The empty-name finding had an empty middle field**, and both callers read findings with `IFS=<tab> read`, where two tabs are one, so the explanation landed in the detail column. It carries `no name` now, and a case reads a finding the way the callers do.

**Smaller.** The pin test compares as text, since an unquoted prefix is a number and a GString is not equal to one. Three `complete` cases still asserted `result.tsv` in a published folder; I had run selected cases of the suite and not all of it. The manual now says that varying `outputPrefix` in a run table varies the VCF name and so repeats variant calling, and that a fixed `fileName` keeps it shared; it no longer names step 0 in the new prose; it widens "produce nothing" wherever it describes the check; and it lists `vcf.fileName` among the derived values.

**Left as it is.** The rename covers what sits at the top of the folder, which is all any module produces; the contract text now says a directory's contents keep their names rather than the frame refusing a directory. `mds.png` still says `few_sites in distance.tsv` in its own caption, which is module output that does not know the prefix.

Nine more mutants, of these fixes, each killed: six without a JVM (`null` and a leading dot accepted, the empty detail field, the run-table cells unchecked, the pin back to literals only, an expression moved into the prefix) and three through Nextflow (no default in `frame.config`, the prefix out of step 7's identity, the pin compared as values). A number written as the prefix cannot be varied by a run-table cell holding text: a cell takes the type of the config's value, and that conversion fails for every parameter alike.
