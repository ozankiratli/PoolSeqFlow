# PoolSeqFlow test suite

```
test/run_tests.sh --changed       the suites that cover what you have changed
test/run_tests.sh --cost static   everything that needs nothing installed (~40 s)
test/run_tests.sh --fast          skip what runs the pipeline (~2 min)
test/run_tests.sh --suite guards --suite analysis_time   one or more, by name
test/run_tests.sh --case citation only cases whose name matches
test/run_tests.sh                 everything (~40 min, and the analysis layer is 30 of it)
test/run_tests.sh --list          the suites, with what each costs
test/run_tests.sh --keep          leave the working directories behind for inspection
```

**Run `--fast` constantly, and the full suite only for a release or the end of a major
feature.** In between, run the suite that covers what you changed — `--suite <name>` takes a
substring and may be repeated, and the mapping from what you touched to which suite to run is
the table in `CLAUDE.md` at the repository root.

Every run prints the scope it selected before it runs anything, so a narrowed run cannot be
mistaken for a full one. That matters more than it sounds: the failure this guards against is
a green summary over a subset nobody chose.

Exit status is 0 only when every case that ran passed; skips do not fail the run, so a
machine without the conda environment can still check everything that does not need it.

The suite is kept out of release downloads by `test/ export-ignore` in `.gitattributes`,
the same arrangement `dev/` uses.

## Layout

| Path | What it is |
|---|---|
| `run_tests.sh` | Driver: discovers suites, runs their `test_*` functions, reports |
| `lib/harness.sh` | Assertions and result accounting |
| `lib/sandbox.sh` | Throwaway project directories, and the stub conda |
| `lib/analysis.sh` | The analysis layer's shared fixtures: baselines, planted results, the corpus |
| `tools/make_fixture.py` | Generates the fixture. A development tool — its output is committed |
| `tools/freq_corpus.py` | The analytic corpus a planted result carries, and what a module must compute from it |
| `data/base/` | The committed fixture: 6 samples, 20 kb genome, 3 genes, ~80x |
| `suites/00_static.sh` | Syntax, release packaging, version consistency. No data needed |
| `suites/01_migrate.sh` | `bin/config_migrate.sh`, against configs written for earlier releases |
| `suites/02_launcher.sh` | `./PoolSeqFlow` environment handling, against a stub conda |
| `suites/03_pipeline.sh` | End-to-end runs against the fixture. The slow one |
| `suites/04_guards.sh` | The step 0 change guards, via step-0-only runs |
| `suites/05_helpers.sh` | Unit coverage for `bin/`, called directly. No conda, no fixture |
| `suites/06_dryrun.sh` | The layout preview, and what `dryclean` will and will not delete |

The analysis layer is nine suites rather than one. It runs **no** pipeline — artifacts are planted — but most of it still starts a Nextflow run per case, which is what makes running only the seam you touched worth doing.

| Path | What it is |
|---|---|
| `suites/07_analysis_frame.sh` | What the frame is, what it reads, and what keeps it optional |
| `suites/08_analysis_rlib.sh` | The shared R library, called directly. **No Nextflow at all** — seconds, not minutes |
| `suites/09_analysis_modules.sh` | The module store, and what a module gets from the frame: its library, settings and artifact classes |
| `suites/10_analysis_verify.sh` | What the frame checks before a module reads anything |
| `suites/11_analysis_plan.sh` | Which results an invocation covers, and where each lands |
| `suites/12_analysis_design.sh` | The experimental design, and the pools a frequency is read against |
| `suites/13_analysis_time.sh` | The time axis and its date parsing |
| `suites/14_analysis_series.sh` | Series, units and conditions |
| `suites/15_analysis_results.sh` | What a module writes, what it carries, and completion |

**A module ships its own cases**, discovered from `analysis/modules/*/test/*.sh` and run under a suite named after the module. A module is a pipeline published on its own timetable, so what judges it travels with it — which is also what lets a module somebody else wrote be tested the way ours are. The harness, the fixtures and the assertions stay shared; only the cases are the module's. They are `export-ignore`d from a release for the same reason `test/` is.

**Every suite declares its cost** in a `# cost:` line, one of three words, and `--cost` selects on it:

| class | what it promises | suites |
|---|---|---|
| `static` | completes with **nothing installed**; a case wanting a tool skips rather than building | `00_static` `01_migrate` `02_launcher` `05_helpers` `08_analysis_rlib` |
| `jvm` | starts Nextflow per case, against planted artifacts | `04_guards` `06_dryrun`, the other analysis suites, and a module's own |
| `pipeline` | runs the pipeline itself against the fixture | `03_pipeline` |

The line between `static` and `jvm` is whether a case **builds** something. Asking `have_tools` and skipping is static — that is how `00_static` holds its `nextflow lint` case. Calling for a baseline or a pipeline run is not, and `00_static` refuses a suite that does both.

An undeclared suite reads as `pipeline`, so it can never slip into a cheap run by accident, and a static one that reaches for a builder is refused by name.

**`--changed` works it out for you.** `dev/scripts/select-tests.py` reads what each suite
declares it *runs* — a `# covers:` line in its header — and expands that through the include
graph into what the suite therefore depends on. A change to a file in that set selects the
suite. Run the script directly to see the reasoning before committing to it:

```
$ dev/scripts/select-tests.py analysis/lib/nf/plan.nf
$ dev/scripts/select-tests.py bin/depth_cutoff.py     # 03_pipeline 04_guards 05_helpers
```

**Two halves, and only one of them is maintained by hand.** The graph is derived — `include {}
from`, a shell `source`, a bare call to a helper in `bin/` — so a new import needs no
bookkeeping. What a suite *runs* has to be declared, because no parser can see it, and
`00_static` refuses a source file that no suite reaches as well as a claimed path that does not
exist.

**It errs wide, on purpose.** Following the graph forward from what a suite runs is the only
direction that answers the question: reading upwards alone misses a suite that goes through the
same entry script, and reading both ways connects the whole repository to itself through
`bin/atomic_mv.sh`, which twelve `.nf` files name. A change to the harness, or to the selector
itself, selects everything — a selection that is too big costs minutes, one that is too small
costs a bug nobody was looking for.

## What to run, and when

Counts move with every stage, so read them off the run rather than from here —
`grep -c '^test_' test/suites/*.sh` is the check. At the time of writing:

| | Cases | Time | |
|---|---|---|---|
| `--cost static` | 229 | ~2 min | Needs nothing installed. The first thing to reach for |
| `--fast` | 257 of 443 | ~2 min | The above, plus every case elsewhere that builds nothing |
| `--suite <seam>` | varies | 3 s – 5 min | What you changed. `analysis_rlib` is 8 cases in three seconds |
| everything | 443 | ~40 min | A release, or the end of a major feature |

The two slow suites are slow for one reason: a Nextflow run costs about **21 seconds of
startup**, flat, cached or not. Nothing in the pipeline dominates that at fixture scale, so
suite runtime is essentially a count of `nextflow run` invocations. Two consequences worth
knowing before adding a case:

- Prefer a **unit test in `05_helpers.sh`** over an end-to-end one. `bin/classify_manifest.sh`
  exists as a separate script for exactly this reason — its edge cases (a value containing
  `=`, an empty value, no trailing newline, an unparseable line) are milliseconds there and a
  JVM start each through a pipeline run. When new guard logic is worth testing thoroughly,
  extract it to `bin/` first.
- Never give a case its own setup run. `04_guards.sh` builds one verified project and each
  case works on a copy — 22ms against 21s. Doing it per case was most of that suite's
  runtime and tested nothing.

## Two rules the suite is built around

**Nothing may touch a real project.** `guard_path` in `lib/sandbox.sh` refuses any path
that is not inside the suite's own temporary directory, and refuses anything inside the
repository. The pipeline deletes and overwrites whatever `mainDir`/`storageDir` point at,
and a real project holds sequencing data that took days to produce.

**Nothing may touch a real conda environment.** Launcher tests run against a fake `conda`
that answers from a canned environment list and logs what it was asked to do. A test suite
that could delete an operator's 1 GB install is not worth having.

## Adding a case

Add a `test_*` function to the relevant suite. The name becomes the label with underscores
turned into spaces, so name it as the claim being made:

```bash
test_rerunning_a_finished_project_changes_nothing() {
    needs_run || return
    assert_eq "$before" "$after" "Output/VCF should be unchanged by a rerun"
}
```

Assertions record a failure and let the case continue, so one broken case reports every
problem it has instead of only the first: `assert_eq`, `assert_contains`,
`assert_not_contains`, `assert_status`, `assert_file`, `assert_no_file`, `assert_count`,
plus `fail_case` and `skip_case`.

Cases that need the pipeline start with `needs_run || return`, which skips them when there
is no conda environment or `--fast` was given.

Two helpers in `lib/sandbox.sh` are worth knowing about before writing a new case:

`task_count <sandbox> <Workflow:Process>` reads the Nextflow trace and returns how many
tasks that process ran. Use it whenever a change touches channel wiring. Every singleton
artifact here — the verify token, the reference, both indexes, the snpEff marker — rides a
value channel, which is what lets one index broadcast against N samples. An operator
inserted into such a path turns it into a queue channel, and the run then still reports
SUCCESS while doing the work once instead of N times. `test_each_step_runs_once_per_sample`
is the standing guard; extend it rather than trusting an exit status.

`run_dictionaries_only <sandbox>` and `run_verify_only <sandbox>` run step 1 and step 0 by
themselves, for questions that would otherwise cost a full end-to-end run. `-entry` does not
work under the strict parser, so each generates a small include file into the sandbox —
generated rather than committed, because the include path has to be `./scripts/…` to resolve
where it runs, and a committed copy carrying that path fails `nextflow lint .`.

## The fixture, and what it can and cannot tell you

`data/base/` is committed rather than generated at test time. Generating it per run would
make the reference outputs depend on the Python version's RNG, so a baseline recorded on
one machine would not reproduce on another. Regenerate deliberately:

```bash
python3 test/tools/make_fixture.py test/data/base
```

`planted.tsv` records **what went in**. It is not an answer key, and asserting output
values against it directly does not work — trimming, the FastQC-driven clip, the
proper-pair filter and the caller all sit in between. An earlier version of the fixture
tried to be exactly predictable by giving every fragment the same length; that left bwa
with a zero-variance insert size distribution, so every indel-bearing pair was flagged
improper and discarded, and six planted deletions produced zero indel calls.

What the plant does support is the assertion in
`test_sites_planted_absent_stay_absent`: an allele planted at 0.0 in a sample has no read
carrying it, and nothing downstream can invent one. Intermediate frequencies are
deliberately never asserted against the plant.

Two details worth knowing when writing assertions against the frequency tables:

- `MajorAlleleToRef.py` re-polarises every site to the cohort major allele, so a planted
  ALT routinely becomes the REF. Match rows on the allele **base**, never on "the row where
  REF differs from ALLELE".
- Sites where no sample varies are absent by design — fixed-for-the-same-allele everywhere
  is dropped by the false-positive filter, and never-varying sites are never called. Both
  are symmetric and intended; see the fixed-site matrix in the project notes.

## Known gaps

- **`depth2freq.awk` and `MajorAlleleToRef.py` still have no unit coverage** and are exercised
  end to end only. Most of this gap has closed since it was written — `05_helpers.sh` now covers
  `classify_manifest.sh`, `find_artifact.sh`, `depth_cutoff.py`, `filterFalsePositives.sh`, both
  parsers and `atomic_mv.sh`, and `config_migrate.sh` has a suite of its own — but those two are
  the ones left.
- No fault injection: the failure paths hardened during the audit — a mid-pipe tool death,
  an interrupted decompress, a failed database copy — have no cases.
- The `-m` parsing in `ClipReads` is only covered end to end. Finer cases would want that
  logic moved into a `bin/` helper where it can be called directly.
