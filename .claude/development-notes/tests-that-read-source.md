# Tests that read the source instead of running it

**Written 2026-09-24, against the tree at `b5c63ba`, during the 3.2.0 cycle.** Z removed a comment from the wrapper in a commit called *"Removed wordy comment"* and a test failed:

```
FAIL install says the analysis command is not the analysis layer
     install must say that answering is not an installation:
     expected to find [THAT DOES NOT MEAN THE ANALYSIS LAYER IS INSTALLED]
```

Z: *"why is this a test?"* It was not one. It read `PoolSeqFlow` as text and asserted a sentence appeared in it. That case is deleted; this note is the class it belonged to and the twenty cases still in it.

## The class, and how to judge one

**A case that asserts a string appears in a source file is testing spelling, not behavior.** The test that separates the useful from the useless is two-sided:

> Would it fail if the behavior broke? **And would it pass if the behavior were correct but written differently?**

A source grep fails the second. That is what makes it brittle rather than merely indirect: it breaks on a refactor that changed nothing, and it trains the next person to reword around the assertion instead of improving the code.

The deleted case failed both sides at once. Its first assertion pinned prose that Z later judged wordy and removed; its second, `assert_contains "$wrapper" 'analysis install'`, **could not fail** - `PAYLOAD_ITEMS` at line 157 reads

```
nextflow.config scripts bin lib analysis install citations parameters.config.template
```

so `analysis install` matches two unrelated payload entries sitting next to each other.

## What a review finds, three outcomes not one

Every one of these needs the same judgment, and only reading decides which:

| | |
|---|---|
| **duplicate** | a running case already asserts the same property. Delete the grep. |
| **the only guard** | nothing else covers it. A behavior case has to be written BEFORE the grep goes, or the property becomes unguarded. |
| **lint-like** | an invariant about the code that running cannot reach - a dependency direction, a string that must never appear. Legitimate, but it belongs in `00_static`. |

The worked example, done on 2026-09-24 in `test_the_analysis_settings_default_without_a_config_block`:

- `assert_contains "$paths" "runs      : 'all'"` - **duplicate**. `11_analysis_plan` already asserts `analysis.runs = 'all'` off a real report. Deleted.
- `assert_contains "$paths" 'if (!scope.containsKey(key)) return defaults[key]'` - an exact line of Groovy, so any refactor fails it while the behavior holds. Deleted.
- `assert_contains "$paths" 'return defaults + written'` - **the only guard**, and it stays. Nextflow REPLACES a nested map rather than merging into it, so a project writing one sub-key would lose every other default in that scope. No running case covers that. **It wants a case that sets one sub-key of a scope and finds the rest of the defaults intact**; until there is one, the grep is all there is.

## Where they are

Measured 2026-09-24: **34 cases** read a repo file and assert on its text. **Fourteen are in `00_static` and are not a finding** - that suite exists to check what needs no data, and a static check is what it is for. The review surface is the other twenty:

```
08_analysis_frame   13   the analysis layer reads the pipeline partition
                         the frame and a module share one answer
                         the analysis layer ships with the release
                         the module roster lives in one place
                         the wrapper layers three configurations
                         the defaults keep the session files out of the pipeline reports
                         the defaults carry what a module run has no other source for
                         the frame version does not hijack the release
                         bump version does not touch the frame
                         a run without a frame version refuses
                         the task path does not wait for params dir bin
                         the analysis settings default without a config block
                         the template documents the run selection

02_launcher          4   check activates when the matching environment exists
                         install refuses when a sealed item is missing
                         the deployed wrapper is stamped and the source is not
                         every environment removal passes minus y

09_analysis_modules  1   a module version is not the release version
15_analysis_results  1   an intermediate records the frame that derived it
mds                  1   a single haploid genome is refused
```

**The concentration is the useful part.** Thirteen of twenty are in one file, and `08_analysis_frame` is where it is most tempting: the frame is configuration and wiring, a running case needs a JVM and a module, and grepping the config is the cheap way out. That is the trade to look at, not the individual assertions.

## Why this is not a sweep

The finding is greppable and the fix is not. The command that produced the table above is a regex over `(cat|grep|sed).*$REPO_ROOT/` in a case that also asserts - run it again whenever you want the current list. Deciding which of the three outcomes each case falls into means reading the case, then searching for a running case that covers the same property, then either deleting or writing one.

Deferred out of the 3.2.0 cycle deliberately: it is the kind of work that turns into rewriting the frame's tests at the wrong moment, and nothing here is wrong today - only weaker than it reads.

## The related habit

This is the same failure this project keeps meeting, recorded in [[gates-that-stopped-checking]]: a check that has stopped pointing at the thing it was aimed at, while still exiting 0. A source grep starts in that state rather than drifting into it, because it was never pointed at behavior to begin with.

It is also worth noticing that the deleted case was found by **deleting a comment**, not by the test suite or by an audit. A redundancy audit had run over these suites the day before and did not flag it, because the sentence still existed then and only the second assertion was dead.
