# The pattern that cost most of 2026-09-10: a correct change quietly disarms a gate

**Written 2026-09-10 against the tree at `8b4f0ca`, after releasing v3.1.0 and v3.1.1 in one day.**

Six separate instances in one session, each independently discovered, each the same shape. That is not six mistakes; it is one failure mode this project is structurally prone to, and the point of writing it down is that the *next* one will look like an ordinary improvement too.

**The shape.** A change makes the code better and, as a side effect, moves something a checker was pointed at. The checker keeps running, keeps exiting 0, and stops examining anything. Nothing fails. Nobody is told.

## The six

| what changed | what stopped checking |
|---|---|
| `analysis/modules/` became the gitignored install store | `check-analysis-versions.sh` looped over an empty directory — **zero modules examined**, and a release could ship any manifest unbumped |
| the same | `bib2citations.py --check` reported *"every citations.json matches (2 files)"* with three module bibliographies unread |
| the same | `export-environment.sh`'s guard — half of what `RELEASING.md` calls the sharpest trap in the feature |
| the same | `check-module-packages.sh`, the only real conda solve, asking it of an empty set |
| the same | five `00_static` globs, `07_analysis_frame`, and `08_analysis_rlib`'s no-package grep, which printed `grep: ... No such file` and passed |
| `conda_install_packages` learned to skip satisfied pins | `check-module-packages.sh` again — every declared pin was already in the baseline, so the filter emptied the list, the function returned 0 without asking conda anything, and the gate printed `ok` |

The last one is the sharpest because it was *mine*, made an hour after fixing the first five, in full knowledge of the pattern.

## Two ways a case hides it

**A fixture that agrees with the bug.** Both version-gate cases in `00_static` planted their `demo` module into `analysis/modules/` — the store — so the gate found it there and the case went green over a loop that finds nothing in reality. A fixture matching the defect is worse than no fixture: it is a standing assertion that the wrong thing is right.

**A fixture that disables the check under test.** The first version of the `check install` environment cases named the fake environment directory `env` while passing `ENV_NAME=check-install-env`. The script only compares paths when `basename $CONDA_PREFIX` matches `ENV_NAME`, so the comparison was off and both cases passed over nothing.

## And the inverse: a case that reads the developer's machine

`make_pipeline_sandbox` copied `analysis/` whole, so a module installed into the checkout arrived in every sandbox and the sandbox stopped being a fresh installation. It surfaced only because Z installed `mds` by hand between the two releases: the roster case that asserts a fresh release offers `verify` alone then failed on Z's machine and would have passed on a clean one. The store is removed after the copy now, matching the tarball, which carries no `analysis/modules` at all.

The same case also asserted *"mds must not be sitting in the store of a checkout"* — which is not a property anyone should hold. Installing a module into the copy you are developing against is ordinary. It asserted the opposite and passed until somebody did it.

## What actually finds these

**Not reasoning.** Every one was found by running something and reading the output, and twice the reasoning was confidently wrong:

- I asserted that `conda_install_packages`' conflict check *had* to precede the filter or the refusal would break, and wrote a comment saying so. The mutation test disproved it: a spec held at another version is not satisfied, so it survives the filter either way. The comment was deleted.
- I argued 3.1.0 had to be 4.0.0 from `CHANGELOG.md`'s semver claim. Z asked *"How is this not adhering semver?"* — and the answer was that semver's own first clause requires a declared public API, which the project had never written down. Declaring it (**the public API is what a result depends on**) settled it and the semver claim stayed.

**Mutation testing, every time.** Revert the fix, watch the case fail, restore. It caught the two vacuous fixtures above and disproved the ordering claim. A case written after the fact that does not fail on the original bug is worth nothing.

**And the full suite, run when the tree is still.** Z, 2026-09-10, correcting the reason I had given for killing earlier runs: *"We were actively developing and fixing things full runs would cost us hours of extra work. Now we are done, we are running the full suite to make sure that everything works together. If it doesn't we can fix it at a single pass."* Both releases' full runs found things nothing cheaper could: six failures the first time, two the second, and none of them reachable from `--fast` or `--cost static`.

## The counting habit that makes it visible

`RELEASING.md` already said *"a number in a message is worth reading twice"*. Today added a second number: **read the SKIP count, not only the failures.** A full run reported `549 passed, 3 skipped` and exit 0; the three that skipped were the PDF report, the compiled hot path, and the compiled-and-parallel agreement — and F1's Rcpp worker bug was caught by that last combination and by nothing else. They skipped because the shell had no working `conda`, so the suite found no analysis environment and said so quietly. That is in `RELEASING.md`'s post-release triage now, with the note that the suite should **refuse** rather than skip when it was asked for a full run.
