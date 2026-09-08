# Shell and Nextflow traps

Every entry here produced a **confident wrong answer** at least once before it was caught — a test that passed against broken code, a survey that missed a file, a run that failed three lines from its cause. None of them is exotic; that is the point. Check this list before believing a result.

The companion notes are `dag-wiring.md` for channel shape and `parameter-resolution.md` for how a run's parameters are built. The largest single source of silent wrong values in this project is config interpolation and params mutation, which has its own note.

---

**Maintained, not dated.** This is the one subject note that is kept current rather than stamped: it is appended to as traps are found, and an entry carries its own *Found <date>* where knowing when matters. Last reviewed 2026-09-05 against `d674e8f`.

## The shell you are typing into is not the shell that runs

**The agent's Bash tool runs zsh; the pipeline runs bash.** Three differences have bitten:

- **`${var%$pat}` does not glob-expand a pattern held in a variable in zsh.** A sample-ID-stripping test reported "nothing is stripped" while the code was correct. Run anything the pipeline will run with `bash -c`.
- **zsh does not word-split unquoted parameters.** `$2` holding `-c file` arrives as one argument and the tool reports `Unknown option`. The same rule silently breaks a loop: `FILES="a b c"; for f in $FILES` iterates **once**, with the whole string as the filename. It cost a bulk rename on 2026-08-30 — `cp` and `sed` both errored on one absurd path, only the command *after* the loop took effect, and the tree was left half renamed.
- **`grep -rn --include='*.nf'` needs the glob quoted**, or zsh expands it against the cwd and the whole command dies with `no matches found`.

---

## Bash under `set -e` and `set -u`

**An unmatched glob is passed to the loop body as the pattern itself.** `for f in *_unpaired_*` with nothing matching iterates once with `f` set to the literal `*_unpaired_*`. Handing that to a helper that refuses a missing source kills the task under `set -eo pipefail`. Reproduced 2026-09-02: `atomic_mv: source not found: *_unpaired_*`, and the loop never reached its end. Seven loops in `scripts/2_trim_reads.nf` were exposed this way, the live one being Trim Galore's unpaired reads — written only when a mate is discarded, so a run where every pair survived trimming died on the pattern. Guard with `if [ -e "$f" ]; then … fi`. `[ -e "$f" ] && cmd` is also safe (the `&&` exemption holds, tested), but the `if` needs no reader to know that.

**`set -e` is suppressed inside a function invoked as an `&&` operand.** `( f && touch x ) || exit 1` means nothing inside `f` aborts on failure — which is why copy loops need explicit `|| return 1` rather than relying on `set -e`.

**The mirror image is worse because it is silent: under `set -e`, `X=$(f)` aborts the script when `f`'s LAST command returns non-zero.** A function ending in a `for` loop whose body is `[ -f … ] && printf …` returns 1 whenever nothing matched — the ordinary case — so `./PoolSeqFlow reset` exited 1 having printed nothing at all, before its own first `echo`. **Empty output plus status 1 is the signature.** End such helpers with an explicit `return 0`, and write loop bodies as `if …; then …; fi`: a loop's exit status is its last body command's, so an empty list leaves the loop returning 1 too — which in a deletion loop would abort partway through. Found 2026-08-26.

**`A || B && continue` is not "skip when either holds".** Bash parses it `(A || B) && continue`, so when neither holds the compound's status is non-zero and `set -e` ends the script rather than falling through. Write `if A || B; then continue; fi`.

**A function called inside `$(…)` runs in a subshell, so anything it assigns is lost.** `out=$(run_launcher …)` meant the status variable never reached the caller. Assign in the caller (`OUT=$(cd x && cmd)` then `STATUS=$?`), and feed stdin with a herestring (`f <<< "y"`) — a pipeline is also a subshell. The same rule is why a loud `exit 1` inside a helper that is always called in a command substitution would silently do nothing.

**`local a="$1" b=".../$a"` dies under `set -u`.** Referencing a name in the same `local` that declares it is unbound. Split the declaration. In a test helper this failed silently mid-case and presented as three unrelated assertion failures.

**`grep -c` exits 1 when it counts none**, and a Nextflow process script runs under `bash -ue`, so `N=$(grep -c PATTERN file)` kills the task when the answer is zero. Use `|| true`. The older code sidesteps this with `grep … | wc -l`, whose status is `wc`'s.

**An optional positional parameter needs `${3:-}`, not `$3`.** Widening a test helper from two arguments to three, 2026-09-07: every existing two-argument call died on `analysis.sh: line 266: $3: unbound variable`, and the suite stopped mid-file rather than failing a case — so the log showed a suite that simply ended. `local design="${3:-}"` is the whole fix. The same shape bit an argument that was *always* passed but sometimes empty, which `set -u` does not mind and `[ -n "$x" ] && printf …` does: a failing test is the last command of an AND-list, so under `set -e` an empty body ends the case. Write it as `if …; then …; fi`.

---

## awk and sed

**An apostrophe inside an embedded awk program breaks the shell parse.** `bin/filterFalsePositives.sh` and `bin/config_migrate.sh` hold their awk program in a single-quoted shell string, so any `'` inside it — **including one in an awk `#` comment** — closes the string and the file stops parsing. Writing "the VCF's own header" into a comment broke it during the 2026-08-30 comment pass; so did "the block's keys". The code uses the `'"'"'` dance where an apostrophe is unavoidable, and `config_migrate.sh` says "a value is yours to keep" rather than "the user's" for exactly this reason. **`bash -n` catches it instantly — run it over every shell file after any edit, however cosmetic.**

**`awk -v x=…` applies escape-sequence processing.** A commit subject containing `\t` becomes a tab; `\n` injects a newline. Pass arbitrary text through `ENVIRON` instead (`X="$X" awk '… ENVIRON["X"] …'`). The same applies to *patterns*: `-v pat='^## \['` dies with `fatal: invalid regexp: unbalanced [`, which is why the two insertion blocks in `dev/scripts/bump-version.sh` were deliberately not factored into a shared helper. `-v` is fine for values you control.

**`\t` in a sed PATTERN is a GNU extension, and BSD sed reads it as a literal `t` without complaining.** Caught before shipping in E3b's pool-size guard, where a condition decided whether a metadata edit touched only the pool sizes. On macOS it would never hold, and a size edit would have been reported as a read-group change — telling that user, and only that user, to delete every BAM. Replaced with awk. `sed -i` without a suffix is also GNU-only but fails **loudly** there, which is why the codebase gets away with it; `\t` fails silently. **Prefer awk for anything tab-delimited.**

**A line-level `grep -v` filter hides a line that holds BOTH patterns.** Surveying the `samtools`/`bcftools` scope rename with `grep … | grep -v software` reported 12 references in 7 files and missed `scripts/6_variant_call.nf` entirely, because one line carries `run.software.bcftools` and `run.bcftools.mpileupOptions` together. The bad count reached a plan Z used to weigh two designs. **Verify a filtered survey by searching for what should REMAIN afterwards**, not by trusting the filtered list.

---

## Git and time

**`%ct` is whole seconds.** Two commits landing in the same second compare equal, so a check of the form "were the sources committed after the version" silently passes on a real drift. Found 2026-09-02 while re-verifying `dev/scripts/check-analysis-versions.sh` — a path that should have reported BEHIND reported PASS. That check compares **days** now, taken from the version string itself, and no timestamps are involved.

**`git check-attr export-ignore` does not report a file inside an export-ignored directory.** A pattern like `dev/` removes the directory from `git archive` but `check-attr` on a file within it answers `unspecified`. Do not use it as an oracle for "will this ship".

**A checker must not read its exclusion list from the file that causes the bug.** `dev/scripts/verify-archive.sh` was briefly rewritten to read its `export-ignore` rules out of `.gitattributes` at the same ref — which made it blind to exactly the accident it exists for, since an export-ignore added by mistake takes the file out of the *check* as well as out of the archive. Measured in a throwaway clone: `bin/find_artifact.sh export-ignore` passed the gate green. The list is hand-kept in the script now, so an export-ignore fails the gate until it is named there too. **Write the negative test; a checker that only ever says "fine" is worse than none.**

---

## The Nextflow strict parser (26.04)

**Top-level statements are a hard error** — "Statements cannot be mixed with script declarations". A script-level constant (`def DEFAULTS = [runs: 'all']`) is therefore impossible; a hardcoded default has to be returned by a function. Multiple declarations on one line (`def a = 1, b = 2`) do not parse either.

**`-entry` does not exist.** `nextflow run analysis.nf -entry Complete` fails with *"The `-entry` option is not supported with the strict parser"*, and **`nextflow lint` does not catch it** — a script with an anonymous workflow plus named ones lints clean and fails only when run. Cost half a suite run and seven red cases before the error was read rather than guessed at. The answer is the pattern the codebase already uses: **one entry script per command** — `poolseqflow.nf`, `dryrun.nf`, `analysis.nf`, `analysis/complete.nf`, and every module's `main.nf`.

**`switch` is rejected.** `switch (x) { case 'a': … }` fails with `Unexpected input: '\n'` at the `case` line, and the knock-on is misleading: the file fails to parse, so every workflow it exports is reported "is not defined" at each call site in another file. Use a map literal plus `containsKey` — that is why `promotionRow()` in `scripts/9_completion.nf` is shaped the way it is.

**Both `for` forms are rejected.** `for (int k = 2; k <= n; k++)` fails with `Unexpected input: 'k'`; `for (part in list)` fails with `` `part` is not defined `` at the first *use* rather than at the loop. Use a range (`(2..n).each { k -> … }`) or `.each`. Reassigning a captured local **is** allowed — `dotted.tokenize('.').each { part -> cur = cur[part] }` is committed and works — it is only the loop syntax that is refused.

**A local closure called by name is rejected**: `def refuse = { … }; refuse('x')` gives `refuse is not defined`. Use a plain `def` function.

**An interpolated slashy regex is rejected** — `return ~/${pattern}/` gives `Unexpected input: '/'`, and the knock-on is the misleading one again: the file stops parsing, so every workflow it exports is reported "is not defined" at each call site in three other files, and `analysis.nf` looks like the broken one. Use `java.util.regex.Pattern.compile("${pattern}".toString())` and match with `matcher.matcher(value).matches()` rather than `==~`. Found 2026-09-05 building `missingValueMatcher()` in `analysis/lib/nf/design.nf`; a plain `~/literal/` with no interpolation is fine.

**An implicit closure parameter is deprecated** — `collect { "'${it}'" }` warns; write `collect { p -> … }`. `00_static` requires zero warnings.

**A named `emit` is rejected when a workflow has only one** — "Emit name should be omitted when there is only one emit".

**`take:` / `main:` / `emit:` must be on their own lines.** A one-liner gives `Invalid workflow definition -- check for missing or out-of-order section labels`.

**`nextflow.config` rejects `if` statements** — "If statements cannot be mixed with config statements". There is no way to validate a parameter in the config file; validation belongs in `bin/config_migrate.sh`. Use a ternary where a conditional is unavoidable.

**`workflow.onComplete` in `nextflow.config` is deprecated.** The working form is a top-level `def` plus one registration line *inside* the entry workflow — which is why `assembleCombinedLog()` in `poolseqflow.nf` looks the way it does.

**`.execute()` and `groovy.json.JsonSlurper` DO work**, at DAG-build time. That is what lets `runDefinitions()` shell out to a tested Python parser instead of reimplementing CSV quoting in Groovy.

---

**An EMPTY config block reaches `params` as nothing at all.** Measured 2026-09-07: `phenotypes { pt_wingspan { }; pt_other { levels = ['a','b'] } }` arrives as `[pt_other:[levels:[a, b]]]` — `pt_wingspan` is *absent*, not present and empty. So a checker that iterates a declaration scope cannot refuse an empty declaration: it never sees one, and it cannot tell that block from a column nobody wrote about. This bites any open scope declared per column — `analysis.metadata.phenotypes` and `analysis.metadata.covariates` both. **The defence is to report what is UNdeclared**, which covers the empty block for free; a test case asserting that an empty block refuses will fail, and correctly.

---

## Interpolation, and one character that shifts everything

**A bare `$?` in a Nextflow script string SHIFTS every interpolation after it by one slot.** It does not error. A `` `[ $? -eq 0 ]` `` written inside a **shell comment** in a script block made `${workflow.runName}` print the session id, `${workflow.sessionId}` print `1`, `${task.attempt}` print a directory path, and `${dir_log}` come out as the run name — so the task died on `No such file or directory` for a log path, three lines from the cause and looking nothing like it. Being inside a `#` comment does not help: the substitution happens in Groovy, long before bash sees the line. **Write `\$?` even in comments.** Found 2026-08-25.

**A heredoc terminator cannot be indented.** A block interpolated into an already-indented script takes its indentation with it, so `<<'X'` … `X` never terminates and the whole task script breaks. Render such blocks with `printf` and escaped quotes instead. Found 2026-09-01 building the citations shell.

**`for x in ; do … done` is a bash SYNTAX error, not an empty loop.** Groovy-interpolating a list that is normally empty into a shell `for` breaks every task of that process. Emit the calls themselves — `link_into "a"` per element, nothing when the list is empty.

**`join('\\t')` in Groovy source is what samtools wants.** A single-quoted `'\\t'` in a `.nf` file is backslash-then-t, two characters, which is the literal `\t` an `@RG` line expects — not a tab. Getting this "right" with a real tab breaks it.

**A backslash-u-0000 escape typed into a source file may be written as a real NUL byte**, which turns the file `binary` to git (`Bin 12716 -> 17407 bytes` in `git diff --stat` instead of a line count) and makes the change unreviewable. Groovy accepts it silently and the pipeline runs. **Check `git diff --stat` for `Bin` before handing a change over** — or `file` it, which says `data` instead of `Unicode text`.

That escape is written out in words above for the same reason: the first draft of this very entry put the escape in a code span, and it was written into this file as a real NUL. `file` caught it. **The trap survives being documented; spell it, do not quote it.**

---

## Channels

**`combine` FLATTENS.** `a.collect().combine(b.collect())` emits ONE list holding everything from both, not a tuple of two lists. A closure declaring two parameters looks right and fails at runtime with ``Invalid method invocation `call` with arguments: […] (java.util.LinkedList)``.

**The rule behind it: `combine` treats a channel ITEM that is a List as a tuple and spreads it.** `queue.combine(valueChannelHoldingAListOfN)` gives an (N+1)-element tuple, not a pair — and every downstream closure is then called with the wrong arity, far from the cause. A list *inside* a tuple slot is safe (`[key, [f1..f5]]` → `[key, x, [f1..f5]]`, verified); it is a bare list **as** the item that spreads. `count()` is a scalar and cannot spread, which is the fix when the channel is only an ordering gate.

**`combine(by: 0)` is the explicit form of what an implicit value channel did for free** — the cartesian product *within* a key, which is exactly "broadcast this per-run singleton across that run's samples". `join(by: 0)` is wrong there: it matches one-to-one, so every sample after the first silently gets nothing.

**Verified safe by probe for run-keyed channels:** a Map as element 0 works as a key for `combine(by: 0)`, `join(by: 0)`, `join(by: [0,1])` and `groupTuple(by: 0)`; a process can take `tuple val(someMap), …` and read it in `tag { }` / `cpus { }` closures and in `output: path("${someMap.field}")`. Re-probe rather than assume if the Nextflow version moves.

**Almost every value channel in this pipeline is IMPLICIT.** There are three explicit `channel.value` calls; everything else comes from Nextflow's rule that a process emits a value channel when all its inputs were value channels. So the cardinality risk is worse than "do not put an operator in a value channel": **nothing in the source marks which channels those are.** `test_each_step_runs_once_per_sample` is the only statement of the property in the repository, which makes those task-count assertions load-bearing.

**A process input has to be the thing the process needs, not something it can derive.** Passing `ctx.runs.size()` where `analysisParams(Map)` was expected failed with a `doCall()` signature error naming a closure inside `flattenParams`, five frames from the mistake. Render the value at DAG-build time and pass it.

---

## Configuration

**Config interpolation is eager and TOP TO BOTTOM within a scope block.** A `dir` entry reading `params.dir.subpath.*` from above where `subpath` is defined gets null, and the only diagnosis is `Unable to parse config file` plus a bare NullPointerException buried in `.nextflow.log`. `dir.sessionReports` must be the last entry in that block for exactly this reason.

**`trace`, `report`, `timeline` and `dag` CANNOT be set from a `.nf`.** Assigned on the session config inside `workflow{}` they write zero files; the identical settings in a config file write both. The observers are constructed during session init, strictly before the entry script's body runs. These four are what stop an analysis run overwriting `Output/Reports/PoolSeqFlow_pipeline_*`, so the frame config cannot be hardcoded away.

**Config-to-config MERGES a nested scope.** Frame declares `analysis { runs; folderName; installDir }`, project sets only `runs` → all three keys survive. The replace-wholesale gotcha is about a **script**-declared map being replaced by a config leaf, which is a different case — do not generalise it to config files. Where a default lives in an accessor instead, use `containsKey`, never `?:`: measured, `runs = []` must stay `[]` rather than falling back to `'all'`.

**A later `-c` file wins over an earlier one, including whole scopes.** Measured with a failing task: frame sets `errorStrategy='finish'` → exit 1; a project `analysis.config` passed as a second `-c` sets `'ignore'` → exit 0. This is why the analysis layer removes no knob.

**Later-wins is also how `nextflow.config` used to remove seven of them.** Its `includeConfig "${launchDir}/parameters.config"` sat above its own assignments, so a project setting `cleanup=false`, `conda.enabled=false`, `errorStrategy='ignore'` or `maxRetries=99` resolved to `true/true/'finish'/3` — silently, while the config advertised the alternatives in a comment beside each one. **Fixed 2026-09-02 (E6g):** everything reading no parameter moved above the include, so a project's value wins. `workDir` and `env.PATH` stay below and stay the installation's — both read a parameter and so cannot move, and both are structural rather than tuning. The `process` block is deliberately two blocks now; the merge rule above is what makes that safe.

**`params.dir.bin = …` from a library function at DAG-build time sticks**, and both a later Groovy read and a process script block see the new value. **`env.PATH` does not** — `env` is config-only and config is parsed first, so it has to compute the installation itself with `System.getenv('POOLSEQFLOW_HOME')`.

**`System.getenv('X')` works inside a `-c` config file** — the one way a config learns something Nextflow does not compute. The wrapper exports `POOLSEQFLOW_HOME` before running anything.

---

## Where a script thinks it is

**`moduleDir` is the file's own directory; `projectDir` is the entry script's.** Tested on 26.04.6: a function defined in `analysis/lib/nf/paths.nf` and *called from* a module's `main.nf` still sees `moduleDir = <install>/analysis/lib/nf`. That is how a library locates the installation without being told which script is the entry point.

**`projectDir` follows the ENTRY SCRIPT, and `env{}` interpolates once.** Running a script from a subdirectory makes `params.dir.bin` (`${projectDir}/bin`) point there. Overriding the param is not enough — `env { PATH = "${params.dir.bin}:$PATH" }` was already interpolated against the old value, so the helpers are simply not found. Set both.

**An entry script outside the installation loads NONE of the installation's `nextflow.config`.** Nextflow reads `<projectDir>/nextflow.config` and `<launchDir>/nextflow.config` only, and for a module both are somewhere else. Measured, in this order: `params.dir.bin` became `<store>/<module>/bin` so `parse_metadata.py` was not found; then `params.cores` was null and `fill()` died at `resolve_parameters.nf:8` with `Cannot invoke method containsKey() on null object`. Also silently absent: `conda.enabled`, the `process` block with `resourceLimits`, `env.PATH`, and `enabled = true` on all four observers. **Anything the pipeline gets from `nextflow.config`, a second entry point must be given again.**

**`workflow.manifest.version` is null for an entry script not beside `nextflow.config`.** The repo root gets the real version; a subdirectory gets null. Anything writing a release into a provenance record from a module has nothing to write — which is why the analysis frame carries its version in `analysis/frame.version` instead.

**Nextflow `include` is static** (26.04.6, 2026-08-31). An interpolated path is rejected at lint AND at run time (`Unexpected input: '"'`). An include of an ABSENT file is a hard compile error (`Invalid include source`), so "ship every include, install some" is impossible. An absolute or relative single-quoted literal works. The entry script on the command line is the one path Nextflow lets you choose at runtime — which is why the analysis layer runs a module's own `main.nf` rather than including it.

**An unused `include` still couples you.** Deleting a workflow from a library broke a module that named it in its include list but never called it. Import only what you call.

---

## How a failure presents

**Two rules about `workflow.onComplete`, both learned by breaking them.**

- **A `def` local of the workflow body is NOT visible to the handler.** The closure resolves the name against the script binding when it eventually runs, finds nothing, and dies on `Cannot get property 'x' on null object`. Declare the value **without** `def` so it lands in the binding, or compute it from `params`/`workflow` inside the handler.
- **A handler that throws replaces the real diagnosis.** Nextflow prints ``Failed to invoke `workflow.onComplete` event handler`` *instead of* the error that actually stopped the run, so a fault in logging code hides a genuine configuration error completely. It cost a multi-run dictionary conflict its entire careful message. Make the handler call exactly one guarded function and nothing else: anything in the **argument list** is evaluated outside that function's own try/catch, which is where the throw was.

**Catching an exception thrown by a module function inside a workflow body wraps it in `InvocationTargetException`, whose own `message` is null.** The real message is on `.cause`. Nextflow's top-level handler unwraps it correctly, so the user sees the right text — which means a test written around `try/catch` asserts on the harness rather than on what anyone will see. Test such a throw through the real entry point.

**That unwrapping does NOT happen inside an OPERATOR closure** — `subscribe`, `map`, `flatMap`. There the user sees `ERROR ~ Unexpected error [InvocationTargetException]` and a line number, and nothing else. Verified 2026-08-27. **Print the diagnosis to stderr first; throw only to make the run fail.** The exit status is still 1, so the failure is never lost — only the explanation.

**Groovy `list[0..-2]` on a ONE-element list is a negative range, not an empty one.** It throws `fromIndex = -1`, which Nextflow reports as a bare `ERROR ~ fromIndex = -1` with a line number and nothing else. Guard with `if (parts.size() > 1)`.

**`.unique()` on a Map's `values()` throws `UnsupportedOperationException`** — `values()` is an unmodifiable view and `unique()` sorts in place. Use `map.values().toList().unique()`. Cost one pipeline run, because the throw surfaced as the same contentless "Unexpected error" as every other DAG-build-time exception.

---

## What the tools actually do

**A tool given an ABSOLUTE output path will not create the directory for you.** snpEff exits 255 with "Error creating summary: …/Reports/snpeff_summary.html (No such file or directory)". It had worked for years only because some earlier step in the same run made that directory on the way past — an accident that held until a work item could be the first thing writing into its own output directory. **"Another step will have made it" is not a guarantee the DAG expresses anywhere.**

**snpEff's `-stats` writes TWO files.** It derives the gene table's name from the summary's, so `-stats snpeff_summary.html` also writes `snpeff_summary.genes.txt` beside it. Measured against a real run 2026-09-02; the plan and the manual had both recorded one file.

**The annotated VCF is not byte-reproducible across two runs of the same annotation.** `##SnpEffCmd` records the mktemp name of the normalised input and `##bcftools_normCommand` records a wall-clock `Date=`. Both are the tools' own provenance and neither is a defect — but any "the VCF is unchanged" assertion has to exclude those two lines.

**`samtools stats -c min,max,step` emits COV rows only for the depths that OCCUR.** Measured on a hand-built BAM: `-c 1,20,1` over depths 1 and 2 gives two rows, not twenty, and no open-bin row at all when nothing exceeds the ceiling. This is what makes `capBAM.histogramMax` unable to change a result — every value a run completes at yields the identical histogram — and it is why that parameter is excluded from the recorded manifest.

**vcftools echoes its own parsed parameters, not your command line.** `--minQ 1000` is logged as `--minQ 1e+03`. An assertion on the literal value fails while the pipeline does exactly the right thing.

**`paste -sd', '` cycles the delimiter, it does not use the string.** `-d` takes a delimiter LIST and rotates through its characters, so a two-item list joins with `,` and a three-item one gives `a,b c`. For "join with comma-space" use `paste -sd, file | sed 's/,/, /g'`. Caught in review, where the two-member case looked correct.

**`cp -r src dest/` merges when `dest/src` already exists** — it does not nest into `dest/src/src`. Verified, because the nesting variant would have been silent.

**`realpath -m`** resolves symlinks, `..` and trailing slashes without requiring the path to exist. That is what makes the `mainDir` ≠ `storageDir` check honest: a string comparison passes on `/x` vs `/x/` vs `/x/y/..` vs a symlink, and each is the same directory.

**`cleanup = true` is session-scoped.** It removes only its own task leaves and never the workDir root, so two concurrent runs sharing a workDir do **not** delete each other's task directories — six concurrent runs from one checkout all exited 0, `.nextflow/cache` is partitioned by session UUID, and `.nextflow/history` survived an 8-way simultaneous append. The opposite was previously asserted here as a sharp hazard; it was tested and is false.

**`.nextflow.log` is a single 10-slot rotation per launch directory**, so the tenth run started during a long run unlinks that run's live log while it is still writing. `NXF_CACHE_DIR` + `NXF_LOG_FILE` isolate completely and leave zero `.nextflow*` residue. `NXF_WORK` does **not** override a `workDir =` set in config; CLI `-work-dir` does.

---

## The test harness

**A process's own `echo` never reaches the suite's `run.out`.** It goes to that task's `.command.log`, and from there to `Logs/<step>/<sN_Process>/*_nextflow.log`; `run.out` holds only what Nextflow itself prints. A test asserting on a process message must read the per-process log — asserting against `run.out` fails even when the pipeline did exactly the right thing, which presents as a passing mtime check beside a failing message check. Those logs accumulate across runs with a per-run header, so searching the whole file is usually right.

**A sandbox snapshots the installation when it is CREATED.** Re-running an old sandbox after editing `PoolSeqFlow`, `scripts/` or `poolseqflow.nf` tests the code as it was then. It cost a false "the reset bug does not reproduce" — the reused sandbox predated the edit by an hour. Rebuild it, or `cp` the edited file into `$sb/install/` first.

**A kept sandbox is shared across cases.** A report read out of `$TEST_TMPDIR/guards` after a full run belongs to whichever case ran last, not the one being investigated. Reproduce against a fresh sandbox.

**Substring assertions and versioned names do not mix.** `assert_not_contains "conda activate PoolSeqFlow"` fires against the *correct* string `conda activate PoolSeqFlow-2.2.0`. Compare whole lines when the wrong value is a prefix of the right one. Caught twice this way.

**`ls | sort` is locale-dependent** — the default collation puts `_` before `.`, so `Test_annotated.vcf` sorts ahead of `Test.vcf`. Use `LC_ALL=C sort` when asserting on a file listing, or the assertion depends on the machine rather than on the pipeline.

**A test that strips comments must actually strip them.** An assertion that a source file does not mention `workflow.manifest.version` fails against a file that mentions it *in a comment explaining why it is not used*. Filter with `grep -vE '^\s*//'` first.

**Never pipe a suite run through `tail`.** The runner ends a failing run with `FAIL n passed, m failed`, a blank line, `Failed:`, then one `  <suite> / <case>` line per failure. Cut the head off that and what remains is a list of case names indented two spaces — which is the shape of the *passing* output, and `tail`'s own exit status is 0 whatever the suite did. On 2026-09-05 a six-suite run came back as twelve such lines and read as green; twelve cases had failed. Redirect the whole run to a file and read the summary line, or grep for `^FAIL`. The two output shapes are only distinguishable by the ` / ` separator.

**`--case` matches the function name, not the name the runner prints.** The display name has underscores turned into spaces, so `--case "missing encoding"` matches nothing while `--case missing_encoding` matches — and a filter that matches nothing reports `PASS 0 passed`, which reads exactly like a suite where everything succeeded. Two things follow: use the underscored form, and treat a `0 passed` line as a filter that missed rather than as a green run. It also means a case whose name shares no word with its siblings cannot be reached by the group filter that finds the rest of them — 2026-09-05, two new phenotype cases were silently not run because neither name contained `phenotype`.

---

## One rule that is not about syntax

**Anything put in a run map is a candidate for the parameter manifest, and a List lands whole.** `analysisParams()` flattens the map through `flattenParams()`, which recurses into Maps and takes anything else verbatim — so `run.metadata` (a List of Maps) would become one enormous `metadata=[{…}, …]` line, and every edit to a design column would fail the change guard as a changed *parameter*. It is excluded by name in `skipKey`, with the reason written there. **The general rule: when attaching derived data to a run map, check `skipKey` first — the manifest is the default destination, not an opt-in one.**
