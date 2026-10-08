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
