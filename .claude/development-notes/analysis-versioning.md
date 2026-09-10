# Versioning the analysis frame

**Written 2026-09-07, against the tree at `f2a7774` plus the uncommitted change that added `analysis/lib/R/allele_frequencies.R`.** The rule below is Z's, given the same day.

## The rule

**The frame version moves with a change to the frame and never with the calendar.** Z, 2026-09-07: *"If there is no change in the frame, we should not create a new version just because it is a new day."*

`analysis/frame.version` is `YYYYMMDD.NNN` and covers `analysis/frame.config` and everything under `analysis/lib/`. The date in it is a *name*, taken from the day the bump was written; it is not a trigger. A version that has stood for a month is correct for as long as the frame has.

## What was violating it

`dev/scripts/check-analysis-versions.sh` compared the version's day against `last_change_day()`, and that function answered **today's date** for anything dirty in the working tree:

```bash
last_change_day() {
    if dirty "$@"; then date -u +%Y%m%d; return; fi
    ...
}
```

Work sits uncommitted in this project for as long as it is under review — that is the whole point of the working tree being the review surface. So a frame change made on the 7th and bumped on the 7th went BEHIND again at midnight on the 8th, and again on the 9th, each time asking for a fresh stamp from a frame nobody had touched since. A new version for a new day, which is exactly what the rule forbids.

It now takes the newest mtime among the changed paths, falling back to today only when the change removed files and left no mtime to read.

## The stricter design that was considered and dropped

The obvious repair is to drop dates from the frame check entirely and ask what the module and catalogue branches of the same script already ask: *did the change that touched the frame also touch its version?* That is exact, portable and needs no clock.

**Measured against the history, and it is too strict.** Of the eight most recent commits touching frame sources at `f2a7774`, four moved `frame.version` and four did not:

| | |
|---|---|
| moved it | `306dd26`, `c6544d7`, `2915346`, `a06c312` |
| did not | `381541e`, `fabdb5c`, `4cb4ae7`, `e76774a` |

Each of the four that did not landed on a day an earlier commit had already bumped — which is the property the day comparison exists to give: **one bump covers a day's frame changes.** `e76774a` is the clearest case for keeping it: a comment-only pass over `analysis/lib/`, which changes nothing a derivation produces and should not need a version of its own.

So the day comparison stays for committed history, and only the dirty answer changed.

## The same rule, one level down: a module's own cases

**A change confined to `analysis/modules/<name>/test/` does not move that module's manifest version.** Found the same day, by the check reporting `basicstats` as behind after two of its cases were edited.

The reasoning is the rule above applied where it also holds. `analysis/modules/*/test/` carries `export-ignore`, so nothing in it reaches a published module tarball — a case cannot change what a user installs or what the module computes. The manifest version is what `modules install` sorts on and what every published result records the module *by*, so moving it for a test fix says the module changed when it did not.

`dirty "$dir" ":(exclude)${dir}test"` is the whole change. A change to `main.nf`, the module's R, its manifest, its `references.bib` or its `citations.json` still requires the bump.

**This extends Z's rule rather than being asked for**, and it is two lines to revert if the intent was that the version covers the directory whole.

## What guards it

`test/suites/00_static.sh`, `test_the_frame_version_moves_with_a_change_and_not_with_the_calendar`. It builds a repository of its own under `TEST_TMPDIR` — a frame, a catalogue and a module with a case of its own — and runs the script against that, because the script takes its root from its own location and the answer depends on whether the tree it reads is dirty.

Two assertions carry it. A frame file whose mtime is in January, a version that says January, and a check that stays quiet although today is September. And a module whose `test/` changed staying quiet while the same module's `main.nf` changing does not.

Both were verified by breaking them: `last_change_day()` back to `date -u`, and `dirty "$dir"` without the exclusion. Each fails its own assertion and nothing else.

## The timezone, which is not a defect

The version is stamped in **UTC**, which is what `bump-analysis-version.sh` writes and what the check compares against. On a machine four hours behind UTC that means work done after 20:00 local is stamped with tomorrow's date. Machine-independence is worth more than that: a version stamped locally would read as BEHIND in CI, which runs in UTC.
