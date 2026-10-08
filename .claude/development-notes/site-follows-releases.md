# The site follows releases

**Written 2026-10-07 against `dev` at `d8b7cee` plus uncommitted work**: `.github/workflows/docs.yml`, its 00_static case `test_the_site_deploys_only_for_a_released_version`, and the lines in `dev/RELEASING.md`, `modules/README.md` and `dev/scripts/publish-module.sh` that described the old wiring.

## What happened

`docs.yml` deployed the site on any push to `main` that touched the manual, the CHANGELOG, the catalogue or the build. A release pushes `main` before it tags: the step-6 merge and the step-9 commit. On 2026-10-07 the merge `84def44` and the version-bump commit `babb475` each deployed, so the site carried the 3.3.0 manual and a 3.3.0 CHANGELOG entry. The v3.3.0 tag then failed `release.yml` at its analysis version gate, and no release was made. The site went on describing a release that did not exist, with v3.2.0 still the latest.

Z, the same day: "If a release fails website should not be published."

## What was weighed

The site holds one manual, and the module pages (basicstats, association, mds, the modules index) are sections of it, deployed together with the catalogue. Modules are meant to publish between releases, page and catalogue row together. Three shapes were put to Z:

- pipeline pages and the CHANGELOG from the latest successful release, module pages and the catalogue from `main`, which needs `build_docs.py` to assemble one site from two commits;
- the whole site from the latest successful release, with only the catalogue moving between releases, so a module published between releases has no page until the next release;
- keep deploying from `main`, and hold every deploy while a release is in flight, which needs "a release is in flight" read off `main`'s history.

Z: "Isn't it a single manual anyway?" It is, and that settles it: the site is built from one commit, and the only question is when it deploys.

## What was built

`docs.yml` deploys in two cases. After `release.yml` completes, through `workflow_run`, when that run was a pushed tag and succeeded, building the commit the release was made from. And when run by hand, which is how a module published between releases reaches the site. In both cases a step first asks GitHub whether the version the commit declares (`VERSION=` in `./PoolSeqFlow`) has a published, non-draft release, and refuses otherwise. A push to `main` and a pull request still build with `--strict`, so a broken page fails early, and deploy nothing. A `release.yml` run by hand checks a commit without publishing it, so it does not deploy the site either.

`workflow_run` runs from the default branch's copy of the workflow and checks out the released commit itself. A deploy job inside `release.yml` would run on the tag instead, and a `github-pages` environment limited to `main`, which is how Pages environments are commonly set up, would refuse it. That limit was not checked against this repository's settings; `workflow_run` avoids depending on it.

## What it costs

**A module published between releases needs the Documentation workflow run by hand** once its commit is on `main`. Before, the push deployed it.

**The hand run checks only the declared version.** Between the step-6 merge and the step-7 bump, `main` holds the next release's manual while still declaring the released version, and a hand run then would deploy it. Nothing in the release procedure runs the workflow by hand, and no automatic path deploys in that window.

## How it is checked

`test_the_site_deploys_only_for_a_released_version` reads the workflow and requires every path to the deploy to go through the release check: the deploy job's condition, the build's output, the release check's events, the Pages steps' conditions, the `workflow_run` gate on a successful pushed tag, and `workflow_run` naming `release.yml` by its `name:`. It then runs the release check's own script against a stand-in `gh` answering published, draft and missing. Four mutants of the workflow were each caught when it was built: deploy on anything but a pull request, the pushed-tag condition dropped, the Pages steps ungated, and `workflow_run` following another name.

## The case needed PyYAML, and the 3.3.0 prep run found it (2026-10-08)

**`prep-version.sh` stopped at step 2 on this case alone: 710 passed, 1 failed, `ModuleNotFoundError: No module named 'yaml'`.** The case read both workflows with `yaml.safe_load`. `00_static` declares no environment, so it runs on whichever `python3` the launching shell finds, and Z's shell had `PoolSeqFlow-3.2.0-analysis` active (the run's `system-before.txt` records `CONDA_DEFAULT_ENV`). Neither PoolSeqFlow environment carries PyYAML. Every run before it, mine included, had used `/usr/bin/python3`, which has PyYAML 6.0.3 for reasons of its own, so the dependency was never declared and never seen. Nothing else in the suite imports outside the standard library: checked by parsing every Python file in `bin/`, `test/tools/` and `dev/scripts/` and every Python heredoc and `-c` body in the suites, a scan that does report `yaml` in the committed case.

**The fix reads the workflows with `test/tools/workflow_yaml.py`, stdlib only, and refuses what it does not read.** It takes the part of YAML the three workflow files use and exits naming the line for anything else, rather than adding PyYAML to an environment that ships for one test case. Checked against PyYAML on all three workflow files and on the reader case's own sample, with the same value everywhere after reading every scalar as text, which is the one difference by design: PyYAML types `on` as true and `false` as a boolean. The reader has a case of its own, and five mutants were each caught: the deploy job's condition and the release check's event condition removed from `docs.yml`, and in the reader the folding of a more-indented line, strip chomping, and the refusal of an anchor.

**`00_static` also gained the case that would have caught it first**: `test_every_python_the_suite_runs_imports_the_standard_library_alone`, which reads every Python file the suite runs and every Python snippet a suite hands `python3`, and refuses an import outside the standard library and the repository's own scripts. `dev/RELEASING.md` asks for exactly that when a gate turns out wrong.

## The reader's own review, the same day

Two read-only reviewers went over the reader before Z had seen it, one comparing it with PyYAML over generated and damaged documents, one reading the code and the two cases. **The first version misread valid YAML in five ways**: plain items of a flow sequence skipped every check a block value gets, so `paths: [*.md]` and `x: [a: b]` read as text; folding lost the line break beside an empty line; spaces past a block's indentation on a white-space-only line were dropped; a block ending a file with no final line break gained one; and characters outside ASCII were read, among them the line separators PyYAML breaks a line at. A file that was not UTF-8 crashed with a traceback. **The cases claimed more than they checked**: the reader's case passed with 42 of the reader's rules mutated away, since its refusals asserted only that something was refused somewhere; the site case passed a gate whose `&&` was made `||`, a second job deploying Pages ungated, the release looked up without its `v`, and draft read from another field; and the import scan missed `python3 -c "..."`.

The reader now refuses every character outside printable ASCII but the tab, which removes the whole class of invisible characters rather than reading it, as the repository's own files are ASCII. Folding follows YAML's rule. The other three misreads are fixed, and a bad encoding or nesting deeper than Python recurses is refused by name. Each refusal in the case now names its line and its reason, the sample carries every construct the reviewers found uncovered, and the site case reads every job, compares the gate whole, and records what `gh` was asked.

Measured against PyYAML afterwards: 80,000 documents, generated, damaged, and damaged in ASCII alone, with no misread and no crash. Every valid document it refused, 1,987 of 5,000 generated, was refused for a character outside ASCII. What it reads that PyYAML rejects is damaged input: mostly a tab where PyYAML's scanner refuses one, and flow items holding `?` or a stray bracket. That is the reader being more lenient than the library, never reading a valid document differently.
