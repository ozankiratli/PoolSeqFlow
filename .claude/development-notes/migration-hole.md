# The migration hole: a note in `config_migrate.sh`, and a default that was not one

**Written 2026-09-30, against the tree at `8e8a078` plus uncommitted work.** The last of the eight items Z ordered on 2026-09-29. It ended as two small changes in two files, and took two wrong turns and two drafts to get there. Both are recorded, because both are reachable.

## Part 1: the shape a new parameter's note has

Z set it, 2026-09-30: **state the default behavior, and say what to write for the other one. Do not describe what the user had.**

    vcffilter.dropZeroDepth IS NEW, and your config now has its default.

    The default is true: a site where any pool has no reads at all is dropped.
    To keep those sites, with the unread pool published as NA, set it to false.

**Not describing the transition is what makes it true for every project rather than only some.** The first draft ran fifteen lines and narrated the change, which forced a second gate on `minDP 0`, because above that the zero term is already covered by the minimum and no site moves. A message that states only the default needs one gate: the parameter appears as `NEW` in the report. Read back from the report, as `OLD_MAXDEPTH` is, so it fires exactly when the migration classified it as added; a config that already sets it chose its own value and is told nothing.

`variantCall.maxDepth`'s note is the other shape and stays as it is. That one exists because a value was deliberately **not** carried across, so the user's own number has to appear in it.

## Part 2: the default was not a default

**Measured through the real engine**, the ternary at `scripts/7_vcf2freq.nf:257` with `minDP 20`:

| config | `run.vcffilter.dropZeroDepth` | expression built |
|---|---|---|
| key absent | `null` | `FMT/DP<20` |
| `= true`, the template default | `true` | `FMT/DP<20 \|\| FMT/DP==0` |

So the shipped default was `true` and an absent key ran as `false`. Z: *"Then the default is not actually default, right? If unset it should fall back to default... nextflow.config is the right place to resolve defaults."*

**Why `true` is the right default, which I had backwards.** Z: *"template default true matches v3.2.0 behavior. That's why I set the default to true."* At v3.2.0 the filter was `FMT/DP<${minDP}` alone, and at the shipped `minDP 20` that already excludes `DP 0`, so `true` reproduces v3.2.0 exactly. The two only differ at `minDP 0`, where v3.2.0 excluded nothing. I had described `false` as the v3.2.0-preserving value, which is true only at `minDP 0` and I stated it flatly.

### The resolution, in `nextflow.config` below the include

    params.vcffilter = params.containsKey('vcffilter') && params.vcffilter != null ? params.vcffilter : [:]
    params.vcffilter.dropZeroDepth = params.vcffilter.containsKey('dropZeroDepth') ? params.vcffilter.dropZeroDepth : true

**Both lines are load-bearing and each was measured.**

`containsKey` and not a plain assignment: that file is below `includeConfig`, and the file's own header says why -- *"Nextflow is later-wins, so the same assignment placed after parameters.config was read would beat whatever the project asked for, silently."* A plain `= true` there overrides every project on the machine. Proven: replacing the ternary with `params.vcffilter.dropZeroDepth = true` fails the second half of the new case.

The map guard above it: **without it, a config carrying no `vcffilter` block at all fails to parse, and the error names the installation's `nextflow.config` rather than the user's file.** Measured directly. `params.cores` carries the same guard for the same reason.

Resolved four ways, against the real repository file via `nextflow config -flat`: key absent gives `true`, explicit `false` stays `false`, explicit `true` stays `true`, no `vcffilter` block at all gives `true` and parses.

## Coverage

`01_migrate`, two cases, each biting on its own breakage:

| broken | what fails |
|---|---|
| the note deleted | `a new parameter states its default`, all three assertions |
| the gate removed so it always fires | `the new parameter note is absent when it was set` |

`05_guards`, one case, `an absent parameter resolves to its default`, in the shape of the `exec-defaults` case beside it -- own sandbox, `sandbox_config_flat`, assert on the flattened resolution. Both halves bite:

| broken | what fails |
|---|---|
| the resolution removed | the absent-key half |
| `containsKey` dropped for a plain assignment | the project-wins half |

**`nextflow.config` was not in `05_guards`' `# covers:` and now is.** Fourth instance of the selector gap in two days: the suite reads a file it never declared.

## Part 3: the check that Part 2 made pointless, removed

`bin/check_parameters.sh` carried a NOTE for `minDP 0` with `dropZeroDepth` off. **Its recorded justification is in `parameter-rules.md`, and Part 2 eliminated it**: *"That is the one combination that cannot tell it is in trouble, and it is precisely the migration hole's real exposure: someone copying an old `parameters.config` into a new project."* A copied old config now resolves to `true`. The stumble-into-it path is gone, and reaching the state takes two explicit non-default edits whose result labels itself `NA` in the published table.

Z: *"I think this check is unnecessary. Unless we decide to report every single parameter and what they do in the logs. That's not what we're doing."* It also fails the file's own admission test -- it is not a setting that produces nothing, and `NA` is precisely what stopped it being silent.

Removed: the rule, its two cases in `03_helpers`, and the manual's `#parameter-checks` row. Nothing else in any suite referenced it, checked by grep before touching it. The `#parameter-checks` paragraph about older configs was rewritten, which it needed regardless: it claimed an unmentioned parameter "resolves as unset, and for a true-or-false setting that is the same as `false`", which Part 2 made false.

**This is the `how-to-know-a-change-works` rule running forwards rather than backwards.** The usual form is reverting a change whose reason was disproved. Here the reason was not disproved, it was removed by a better fix, and the check left behind would have read to a later session as a live hazard.

## A third thing I got wrong, and it is the same shape as the first two

I told Z the step 0 path had an unasserted consequence: that a project which ran before Part 2 and omitted the key would find its recorded baseline differs by a line. **Two pieces of wiring I had not read make that wrong.**

- **The version guard runs first and exits.** `scripts/0_verify_environment.nf:1079` logs the mismatch, writes the report and `exit 0`, never reaching the parameter comparison at 1141. A project upgrading across releases cannot reach the difference at all.
- **A parameter a release introduces is already a classified case.** `bin/classify_manifest.sh` exists to tell it apart from a value the user changed, which is what `05_guards`' own header says the suite is for.

What survives is coverage rather than hazard, and it is narrow: nothing asserts the manifest carries the key for a config that OMITS it. The existing flip case proves it carries the key for a config that SETS it. `analysisParams()` flattens the whole resolved map and excludes only a named list, which `vcffilter.dropZeroDepth` is not on, so it is carried.

## The first wrong turn: the marker is not a version check

`config_is_current()` at `lib/wrapper_lib.sh:459` is a grep for `storageDir`, shared by `require_migrated_config()` and `bin/check_project.sh`. Counting live assignments in `parameters.config.template` gives 101 at v3.0.0, v3.1.0, v3.1.1 and v3.2.0, and 102 at HEAD. From that I concluded the marker had been "correct for four releases by luck" and was a `gates-that-stopped-checking.md` case caught one release early.

**Z: that is a false conclusion.** `dev/RELEASING.md` step 3 states the marker's job outright: *"It turns on one marker -- `storageDir` being assigned -- so a release that renames that root has to move the marker with it"*, held by `02_launcher`'s `a config from an older release is refused with the fix`. It answers **was this config carried across the root rename**. A parameter added within the 3.x line is the migration's business, and the migration is prepared every release at step 3.

The count is a real measurement and still true. The inference was the error, and it is the one a key count invites.

A second claim built on that reading was also wrong: I offered a user deleting a `fastqc.options` line as something the marker cannot see. It is template line 49, commented out, a knob the pipeline computes, and its deletion changes nothing. It is in the six-knob list CLAUDE.md spells out.

## The second wrong turn: the wrong file

With the marker ruled out, I read "the dropZeroDepth gap" as the reporting gap in `bin/check_parameters.sh`, which cannot tell an absent key from an explicit `false` because both take its `!= "true"` branch. That was built, with two cases, and reverted. **Z: *"Check parameters work as it should. #3 was about config migrate."*** The checker judges a resolved parameter set for a run that is about to happen; explaining what a release changed is the migration's job.

Note that the second part of this note makes the checker's absent-key branch unreachable from a real run: `nextflow config -flat` now always carries the key. The `!= "true"` test stays correct and stays cheap, and the rule it guards is `false`, which a project can still choose.

## Why two wrong turns on an easy step

The failure was procedural rather than technical. **The item named its own file and I opened it last.** "#3 the migration hole" was treated as a problem to diagnose, so the search went to the two places a hole could be argued into existing, and each wrong turn produced real measurements that read as progress. Reading `config_migrate.sh` first would have shown the gap in a minute: the notes section is two entries long and neither is from this release.

## The manual

`## Install` is now `## Install and Update`, with `### Updating to a new release` added to it, carrying `migrate_config` at the front. The Upgrading page was already thorough; what it could not do is reach someone who never looked for it, which is the failure Z named. The new section points at Upgrading for the project-side rules rather than restating them.

Nothing was added to the Upgrading page's per-release sections. The manual describes the current release's behavior; the transition from the previous one is what `migrate_config` prints.

**A heading carrying an explicit `{ #anchor }` needs `nav:` in its page directive.** `render_nav()` takes the label from the raw heading text, so `## Install and Update { #install }` produced the mkdocs entry `Install and Update { #install }: getting-started/install.md`. The three module pages already declare `nav:` for the same reason, their headings being in backticks. `build_docs.py --check` cannot catch it: the braces are equally present in what it generates and in what it compares against, so the nav reads as current. The explicit anchor is what keeps the four `(#install)` links resolving after the rename; anchors went 373 to 374.

## Two things about the harness, both of which cost a wrong reading here

- **`--case` matches the underscored function name, not the displayed one.** `--case "zero depth"` selected nothing and printed `PASS 0 passed`; `--case zero_depth` selects the two. A filter that matches nothing reports success, which CLAUDE.md warns about and which I read past once here.
- **`build_docs.py --check` writes nothing.** If `mkdocs.yml` appears to change under it, `serve_docs.sh` is running in the background and regenerating it.

## Still open

`dev/RELEASING.md` step 3 tells you to check the migration report's categories. It does not tell you to ask whether a parameter this release **added** needs a note, nor whether its default is resolved for a config that does not set it. Both were stale here. Not built, not asked for.
