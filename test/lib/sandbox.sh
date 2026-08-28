#!/bin/bash
# Isolated working areas for the test suite.
#
# Every test that runs the pipeline or the launcher does so against a throwaway copy under
# TEST_TMPDIR. Nothing in here may write inside the repository, and nothing may point the
# pipeline at a real project directory - guard_path below refuses both.

# Refuse any path that is not inside the suite's own temporary area. The pipeline deletes
# and overwrites whatever mainDir/storageDir point at, and a real project holds sequencing
# data that took days to produce, so this is checked rather than assumed.
guard_path() {
    local path="$1" resolved
    resolved=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")
    case "$resolved" in
        "$TEST_TMPDIR"/*) ;;
        *)
            echo "test harness: refusing to use '$resolved' - outside TEST_TMPDIR" >&2
            exit 1
            ;;
    esac
    case "$resolved" in
        "$REPO_ROOT"/*)
            echo "test harness: refusing to use '$resolved' - inside the repository" >&2
            exit 1
            ;;
    esac
    printf '%s' "$resolved"
}

# A sandbox holding the three directories a real deployment keeps apart. Echoes the sandbox
# path. Optional second argument names the fixture (default: base).
#
#   $sb/install   the installed pipeline. One copy serves any number of projects, so it is
#                 not under either of the others, and a run never writes to it.
#   $sb/main      mainDir, and the project directory: the fixture's inputs, parameters.config
#                 and work/. This is where a run is launched from.
#   $sb/store     storageDir: everything a run produces, and nothing before the first run.
#
# The code and mainDir were one directory until 3.0, which left the suite blind to the
# distinction it now exists to test: `dir.bin` was "${mainDir}/bin" and appeared to work only
# because the two were the same place. Kept apart here so that a path assuming otherwise
# fails a test instead of passing by coincidence.
#
# The fixture is a mainDir - Data/, Reference/ and RGTags.csv, exactly what a user prepares
# by hand - so it is copied there whole. Nothing is seeded into storageDir: if a test finds
# something there, the run put it there.
make_pipeline_sandbox() {
    local name="$1" fixture="${2:-base}" sb
    sb=$(guard_path "$TEST_TMPDIR/$name")
    rm -rf "$sb"
    mkdir -p "$sb/install" "$sb/main" "$sb/store"
    cp -r "$REPO_ROOT"/scripts "$REPO_ROOT"/bin "$sb/install"/
    cp "$REPO_ROOT"/poolseqflow.nf "$REPO_ROOT"/nextflow.config "$sb/install"/
    # The wrapper too, so cases can exercise clean/reset against a real project instead of
    # reimplementing what they do.
    cp "$REPO_ROOT/PoolSeqFlow" "$sb/install"/
    cp -r "$REPO_ROOT/test/data/$fixture/." "$sb/main"/
    # A fingerprint of the installation as deployed. One installation serves any number of
    # projects, so a run that wrote inside it would corrupt every other project on the
    # machine - and would do it silently. Recorded here, checked by whichever case wants to
    # prove nothing moved. Kept outside the three roots, like run.out.
    install_fingerprint "$sb" > "$sb/install.before"
    printf '%s' "$sb"
}

# Every file in the installation and its checksum, in a stable order.
#
# Only meaningful for a sandbox driven by run_pipeline. run_dictionaries_only and
# run_trim_only generate their entry scripts INTO the installation, so comparing a
# fingerprint after one of those reports a difference the harness caused rather than the
# pipeline - which is a true statement about the files and a misleading one about the run.
install_fingerprint() {
    ( cd "$1/install" && find . -type f -exec md5sum {} + | sort -k2 )
}

# Write a parameters.config into a sandbox, derived from the shipped template so the test
# exercises the real defaults. Extra `key=value` style sed expressions may follow.
#
# It lands in $sb/main, not beside the code: nextflow.config includes
# "${launchDir}/parameters.config", so the config is found because the run is launched in the
# project directory. A config left beside the installation is simply not read.
write_sandbox_config() {
    local sb="$1"; shift
    local -a seds=(
        -e "s|^    mainDir .*|    mainDir         = \"$sb/main\"|"
        -e "s|^    storageDir .*|    storageDir      = \"$sb/store\"|"
        -e "s|^    threads .*|    threads         = 4|"
        -e "s|^    memory .*|    memory          = '6 GB'|"
    )
    local expr
    for expr in "$@"; do
        seds+=(-e "$expr")
    done
    sed "${seds[@]}" "$REPO_ROOT/parameters.config.template" > "$sb/main/parameters.config"

    # Checked rather than assumed. These substitutions are keyed on parameter names, and a
    # rename in the template would silently stop them matching - leaving the sandbox config
    # pointing at the template's own placeholder paths. guard_path cannot catch that,
    # because the bad path never passes through it.
    local dir
    for dir in mainDir storageDir; do
        grep -q "^    $dir  *= \"$sb" "$sb/main/parameters.config" || {
            echo "test harness: $dir was not redirected into the sandbox." >&2
            echo "  The template parameter has probably been renamed; update" >&2
            echo "  write_sandbox_config in test/lib/sandbox.sh to match." >&2
            exit 1
        }
    done
    grep -q '/path/to/' "$sb/main/parameters.config" && {
        echo "test harness: a placeholder path survived into $sb/main/parameters.config" >&2
        exit 1
    }
    return 0
}

# Run the pipeline inside a sandbox. Stores combined output in $sb/run.out and echoes the
# exit status. Any extra arguments are passed through to `nextflow run`.
run_pipeline() {
    local sb="$1"; shift
    _run_entry "$sb" poolseqflow.nf "$@"
}

# Run step 1 on its own, for tests about reference handling that would otherwise pay for a
# full end-to-end run. Output and status behave as run_pipeline's do.
#
# `-entry` is unsupported under the strict parser, so running one workflow alone needs a
# small include file. It is generated here rather than committed: the include path has to be
# './scripts/...' to resolve where it runs, and a committed copy under test/lib/ carrying
# that path cannot resolve from its own location, so `nextflow lint .` fails on it.
#
# BuildDictionaries' `verify` input is a pure ordering barrier - no process in step 1 ever
# names it in a script body - so a placeholder value stands in for step 0.
#
# Every entry script must call runDefinitions() and then resolveParameters(), in that order,
# exactly as poolseqflow.nf does. Without resolveParameters() the computed parameters are
# simply absent and the first process to read one dies on a null; with the two in the wrong
# order a run that changes an input to a derivation silently keeps the base value.
run_dictionaries_only() {
    local sb="$1"
    cat > "$sb/install/dictionaries_only.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from './scripts/resolve_parameters.nf'
include { BuildDictionaries; dictionaryRuns } from './scripts/1_build_dictionaries.nf'

workflow {
    def runs = runDefinitions()
    resolveParameters()
    BuildDictionaries(channel.fromList(dictionaryRuns(runs)), channel.value('step0'))
}
ENTRY
    _run_entry "$sb" dictionaries_only.nf
}

# Run step 2 on its own, for tests about where the trimmed reads are looked for and left.
# Same generate-rather-than-commit reasoning as run_dictionaries_only.
#
# TrimReads' `verify` input is an ordering barrier - it is never named in the script body -
# so a placeholder value stands in for step 0, and step 1 is not needed at all because nothing
# in step 2 touches the reference.
run_trim_only() {
    local sb="$1"
    cat > "$sb/install/trim_only.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from './scripts/resolve_parameters.nf'
include { variantPlan } from './scripts/variants.nf'
include { TrimQcClip; readPairChannel } from './scripts/2_trim_reads.nf'

workflow {
    def runs = runDefinitions()
    resolveParameters()
    // The divergence analysis, exactly as poolseqflow.nf builds it. Step 2 takes VARIANTS,
    // not runs, and a variant carries the roots its skip checks search - so an entry script
    // that handed it bare run maps would be testing a shape the pipeline never produces.
    def variants = variantPlan(runs).variants[2]
    TrimQcClip(readPairChannel(variants),
               channel.fromList(variants).map { variant -> tuple(variant, 'step0') })
}
ENTRY
    _run_entry "$sb" trim_only.nf
}

# Dump what runDefinitions() produces, without running any of the pipeline.
#
# One JVM start covers as many divergence scenarios as the table has rows, which is what makes
# it affordable to check a dozen parameter combinations rather than one. Output is one
# `RUN <runId> <dotted.key>=<value>` line per value asked for, plus `AGREE`/`DRIFT` lines for
# the single-run case.
#
# The DRIFT lines are the point of the single-run case. deriveRunPaths() in
# resolve_parameters.nf is a second copy of derivations that also live in parameters.config -
# unavoidable, because config interpolation runs once at parse time while a run needs its own
# values, and the config's copy cannot go because `nextflow config -flat` is how the wrapper
# learns the paths clean/reset delete. Nothing but this check keeps the two in step.
run_definitions_only() {
    local sb="$1"
    cat > "$sb/install/dump_runs.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from './scripts/resolve_parameters.nf'

// Values worth asserting on: one per derivation family, plus the per-run roots.
//
// A function, not `def REPORT = [...]`. A top-level assignment is a STATEMENT under the
// strict parser - "Statements cannot be mixed with script declarations" - and generated entry
// scripts are not covered by `nextflow lint .`, so it fails at run time instead.
def reportKeys() {
    return ['poolSize', 'diploidy', 'filterFalsePositives.sensitivity',
            'trim_galore.quality', 'trim_galore.options',
            'bcftools.maxDepth', 'bcftools.mpileupOptions',
            'threads', 'cores.bwa', 'referenceFile', 'reference', 'snpEff.db',
            'storageDir', 'dir.utilized', 'dir.output.vcf', 'dir.dictionaries']
}

def dig(Map m, String dotted) {
    def cur = m
    dotted.tokenize('.').each { part -> cur = cur[part] }
    return cur
}

workflow {
    // runDefinitions() BEFORE resolveParameters(), which is the required order: afterwards a
    // pinned value cannot be told from a filled one and re-derivation stops working.
    def runs = runDefinitions()
    resolveParameters()

    runs.each { r ->
        reportKeys().each { key -> println "RUN ${r.runId} ${key}=${dig(r, key)}" }
    }

    if (!params.multiRun) {
        reportKeys().each { key ->
            def a = dig(runs[0], key)
            def b = dig(params, key)
            println(a.toString() == b.toString() ? "AGREE ${key}" : "DRIFT ${key} run=${a} config=${b}")
        }
    }
}
ENTRY
    _run_entry "$sb" dump_runs.nf
}

# The cohort completeness guard, and the dictionary grouping it sits beside.
#
# No analysis runs: the grouping prints and returns, and the cohort check is a deliberately
# short channel, which throws and takes the run with it - so the caller expects a non-zero
# status. Both are DAG-side, which is why they can be exercised this cheaply and also why they
# need exercising at all: neither shows up in any task's exit status.
#
# The conflicting-dictionary case is deliberately NOT here. Catching that exception inside a
# workflow body wraps it in an InvocationTargetException whose own message is null, so a test
# written that way would be asserting on the harness rather than on what a user sees. It runs
# the real entry point instead - which costs nothing extra, because it fails while the DAG is
# still being built.
run_multirun_guards() {
    local sb="$1"
    cat > "$sb/install/multirun_guards.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { runDefinitions; resolveParameters; deepCopy } from './scripts/resolve_parameters.nf'
include { variantPlan } from './scripts/variants.nf'
include { dictionaryRuns } from './scripts/1_build_dictionaries.nf'
include { VariantCalling } from './scripts/6_variant_call.nf'

workflow {
    def runs = runDefinitions()
    resolveParameters()
    // The step-6 variant rather than the run: calling takes variants now, and the cohort guard
    // is what this exercises. It fires while the DAG is still being built, so no task runs.
    def base = variantPlan(runs).variants[6][0]

    // Two runs that agree share one build rather than racing for it.
    def c = deepCopy(base); c.runId = 'c'
    def d = deepCopy(base); d.runId = 'd'
    println "GROUPS ${dictionaryRuns([c, d]).size()}"

    // Three BAMs where the run started with four. Any file will do - the guard fires before
    // anything is handed to bcftools.
    def stand_in = file("${base.rgTagsPath}")
    VariantCalling(
        channel.fromList(['s1', 's2', 's3']).map { s -> tuple(base, s, stand_in) },
        channel.of(tuple(base, stand_in)),
        channel.of(tuple(base, 4)))
}
ENTRY
    _run_entry "$sb" multirun_guards.nf
}

# The terminal run-completeness assertion, against a channel that is deliberately one variant
# short - which is what a fan-back join used to leave behind when it dropped a key.
#
# The same operators and the same function the entry point uses, so what is exercised is the
# real guard rather than a restatement of it. Only the source of the channel differs: here one
# variant is removed on purpose, where the pipeline expands into all of them.
#
# The caller expects a non-zero status: the guard has to FAIL the run, not merely print.
run_completeness_guard() {
    local sb="$1"
    cat > "$sb/install/completeness_guard.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from './scripts/resolve_parameters.nf'
include { variantPlan; runToken; assertEveryRunProduced } from './scripts/variants.nf'

workflow {
    def runs = runDefinitions()
    resolveParameters()
    def variants = variantPlan(runs).variants[7]

    channel.fromList(variants.tail())
        .flatMap { variant -> variant.members.collect { member -> runToken(member) } }
        .unique()
        .collect()
        .subscribe { produced ->
            assertEveryRunProduced(runs.collect { run -> runToken(run.runId) }, produced) }
}
ENTRY
    _run_entry "$sb" completeness_guard.nf
}

# Run step 0 by itself, for tests about the environment and parameter guards. Same
# generate-rather-than-commit reasoning as run_dictionaries_only.
run_verify_only() {
    local sb="$1"
    cat > "$sb/install/verify_only.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from './scripts/resolve_parameters.nf'
include { variantPlan; attachProbeRoots } from './scripts/variants.nf'
include { sharingReportLines; publishConflictLines; sharedMemberFiles } from './scripts/variants.nf'
include { VerifyEnvironment } from './scripts/0_verify_environment.nf'

workflow {
    def runs = runDefinitions()
    resolveParameters()
    def plan = variantPlan(runs)
    // CheckRGTagsFile probes the working roots that hold the ready BAMs and the VCF, and which
    // those are is a question only the divergence analysis can answer. Without this the guard
    // sees nothing on disk and records a new baseline every time.
    attachProbeRoots(plan, runs)
    VerifyEnvironment(channel.fromList(runs), channel.value(tuple(
        sharingReportLines(plan, runs),
        publishConflictLines(plan, runs),
        sharedMemberFiles(plan))))
}
ENTRY
    _run_entry "$sb" verify_only.nf
}

# Shared runner for the generated entry scripts above and for run_pipeline.
#
# Launched from the project directory and pointed at the installation by absolute path,
# exactly as ./PoolSeqFlow does it. That is what makes ${launchDir} the project (so
# parameters.config is found) and ${projectDir} the installation (so dir.bin and the entry
# scripts' './scripts/...' includes resolve against the code).
#
# run.out is written outside all three roots. Inside one, it would show up in the directory
# listings the tests assert on.
# SANDBOX_PROJECT_DIR and SANDBOX_RUN_OUT let a single call launch from somewhere other than
# the sandbox's own mainDir. Only the several-projects-one-installation case needs them, and
# it sets them for the duration of one call rather than for the suite:
#
#     status=$(SANDBOX_PROJECT_DIR="$sb/main2" SANDBOX_RUN_OUT="$sb/run2.out" run_verify_only "$sb")
#
# A positional argument would collide with the extra arguments run_pipeline forwards to
# `nextflow run`.
_run_entry() {
    local sb="$1" entry="$2"; shift 2
    local proj="${SANDBOX_PROJECT_DIR:-$sb/main}"
    local out="${SANDBOX_RUN_OUT:-$sb/run.out}"
    (
        cd "$proj" || exit 1
        export JAVA_HOME="$TEST_CONDA_ENV" JAVA_CMD="$TEST_CONDA_ENV/bin/java"
        export PATH="$TEST_CONDA_ENV/bin:$PATH"
        export NXF_HOME="$sb/nxfhome" NXF_VER="${TEST_NXF_VER:-26.04.6}"
        nextflow -q run "$sb/install/$entry" "$@" > "$out" 2>&1
    )
    printf '%s' "$?"
}

# Where Nextflow's trace landed.
#
# It describes the whole INVOCATION, so under multiRun it is filed with the rest of the work
# every run shares - Output/All_Runs/Reports - while a single run keeps it at Output/Reports,
# having nothing to be shared with. Both are looked for rather than the layout being reasoned
# about at each call site: a wrong guess reports "no-trace", which reads as a broken run
# rather than as a test looking in the wrong place.
trace_file() {
    local sb="$1" candidate
    for candidate in "$sb/store/Output/All_Runs/Reports/PoolSeqFlow_pipeline_trace.txt" \
                     "$sb/store/Output/Reports/PoolSeqFlow_pipeline_trace.txt"; do
        if [ -f "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
    done
    return 0
}

# How many tasks a process ran, from the Nextflow trace. Takes the fully qualified name as
# the trace records it (`AlignReads:Align`), because the short name is ambiguous.
#
# This is the guard against a whole class of refactoring bug that a status check cannot see.
# Every singleton artifact in this pipeline rides a value channel, which is what lets one
# reference index broadcast against N samples; inserting an operator into such a path can
# turn it into a queue channel, at which point the run still succeeds but does the work
# once instead of N times.
task_count() {
    local sb="$1" process="$2" trace
    trace=$(trace_file "$sb")
    [ -f "$trace" ] || { printf 'no-trace'; return; }
    awk -F'\t' -v want="$process" '
        NR > 1 {
            split($4, a, " ")        # strip the "(tag)" suffix Nextflow appends
            if (a[1] == want) n++
        }
        END { print n + 0 }
    ' "$trace"
}

# The same count, for one run of a multi-run invocation.
#
# The total is not enough on its own: eighteen Align tasks could be six samples across three
# runs, which is right, or one run's six samples attempted three times, which is not - and both
# report SUCCESS. Every per-run process tags itself `<RunID>:<sample>`, or `<RunID>` alone for
# the step-0 stages, so the run can be read back out of the trace.
#
# Step 1's processes deliberately carry NO run tag, so this returns 0 for them whichever run is
# asked. That is the correct answer rather than a gap: a dictionary is shared between the runs
# that use it and belongs to none of them.
run_task_count() {
    local sb="$1" process="$2" run="$3" trace
    trace=$(trace_file "$sb")
    [ -f "$trace" ] || { printf 'no-trace'; return; }
    awk -F'\t' -v want="$process" -v run="$run" '
        NR > 1 {
            split($4, a, " ")
            if (a[1] != want) next
            tag = $4
            sub(/^[^ ]* \(/, "", tag)     # drop the process name and the opening paren
            sub(/\)$/, "", tag)           # and the closing one
            if (tag == run || index(tag, run ":") == 1) n++
        }
        END { print n + 0 }
    ' "$trace"
}

# A fake `conda` that answers from a canned environment list and records what it was asked
# to do. Launcher tests use this so they never create, activate or remove a real
# environment - a test suite must not be able to delete an operator's 1 GB install.
#
# `conda shell.bash hook` prints nothing, so the launcher's `eval` is a no-op and later
# `conda` calls resolve to this stub on PATH.
make_stub_conda() {
    local dir="$1"; shift
    mkdir -p "$dir/bin"
    : > "$dir/conda.log"
    {
        echo '#!/bin/bash'
        echo "LOG=\"$dir/conda.log\""
        echo 'echo "$*" >> "$LOG"'
        echo 'case "$1 $2" in'
        echo '    "shell.bash hook") exit 0 ;;'
        echo '    "env list")'
        echo '        echo "# conda environments:"'
        for env in "$@"; do
            printf '        echo "%-24s %s"\n' "$env" "/fake/envs/$env"
        done
        echo '        exit 0 ;;'
        echo '    "env create") exit 0 ;;'
        echo '    "env remove") exit 0 ;;'
        echo 'esac'
        echo 'exit 0'
    } > "$dir/bin/conda"
    chmod +x "$dir/bin/conda"
}

# Run the real ./PoolSeqFlow wrapper against a real project sandbox.
#
# The conda side is stubbed exactly as the launcher suite stubs it - `activate` is a no-op,
# nothing is created or removed - so this cannot touch an operator's environments. Everything
# else is real: the project's own parameters.config, the deployed payload, and `nextflow
# config`, which is how the wrapper learns the paths it is about to delete. That last part is
# the reason a stub project would be worthless here.
#
# Results land in WRAPPER_OUTPUT / WRAPPER_STATUS. Not written as `out=$(run_project_wrapper
# ...)`: a function called in a command substitution runs in a subshell and its assignments
# never reach the caller. Feed stdin with a herestring, not a pipe, for the same reason.
run_project_wrapper() {
    local sb="$1"; shift
    guard_path "$sb" > /dev/null
    local version stub
    version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    stub="$sb/stub"
    make_stub_conda "$stub" base "PoolSeqFlow-$version"
    WRAPPER_OUTPUT=$(cd "$sb/main" && \
        PATH="$stub/bin:$TEST_CONDA_ENV/bin:$PATH" \
        JAVA_HOME="$TEST_CONDA_ENV" JAVA_CMD="$TEST_CONDA_ENV/bin/java" \
        NXF_HOME="$sb/nxfhome" NXF_VER="${TEST_NXF_VER:-26.04.6}" \
        POOLSEQFLOW_HOME="$sb/install" \
        "$sb/install/PoolSeqFlow" "$@" 2>&1)
    WRAPPER_STATUS=$?
}

WRAPPER_OUTPUT=""
WRAPPER_STATUS=0
LAUNCHER_OUTPUT=""
LAUNCHER_STATUS=0
LAUNCHER_CONDA_LOG=""
LAUNCHER_PREFIX=""

# Run ./PoolSeqFlow against a stub conda, in a copy of the repository with the slow parts
# stubbed out. Results land in LAUNCHER_OUTPUT / LAUNCHER_STATUS / LAUNCHER_CONDA_LOG.
#
# Deliberately not written as `out=$(run_launcher_with_envs ...)`. A function called inside
# a command substitution runs in a subshell, so anything it assigns is lost when that
# subshell exits - the status would never reach the caller. Feed stdin with a herestring
# (`run_launcher_with_envs ... <<< y`) rather than a pipe, for the same reason: a pipeline
# puts the function in a subshell too.
# What `install` deploys, read out of the wrapper itself. Extracted and eval'd rather than
# parsed, because the assignment is a plain shell one with line continuations, and eval is the
# thing that already knows how to read those.
payload_items() {
    local assignment
    assignment=$(awk '/^PAYLOAD_ITEMS=/{p=1} p{print; if ($0 !~ /\\$/) exit}' "$REPO_ROOT/PoolSeqFlow")
    eval "$assignment"
    printf '%s' "$PAYLOAD_ITEMS"
}

run_launcher_with_envs() {
    local envs_spec="$1"; shift   # space-separated environment names, may be empty
    local sb
    sb=$(guard_path "$TEST_TMPDIR/launcher")
    rm -rf "$sb"
    mkdir -p "$sb/install" "$sb/bin" "$sb/scripts"
    cp "$REPO_ROOT/PoolSeqFlow" "$sb/"
    # check_install.sh does real work against a real environment; these tests are about
    # environment selection, so it is stubbed to a success.
    printf '#!/bin/bash\necho "STUB check_install ran"\n' > "$sb/install/check_install.sh"
    printf 'name: stub\n' > "$sb/install/environment.yml"
    chmod +x "$sb/install/check_install.sh"
    # A complete payload, because `install` refuses to deploy an incomplete copy - it would
    # otherwise produce an installation missing a file, which is worse than failing. Empty
    # placeholders are enough: nothing here ever runs Nextflow.
    #
    # The list is read out of the wrapper rather than repeated here. A hand-kept copy drifts
    # the moment a release adds a file to the payload, and it does it silently in the worst
    # way: every launcher case fails at once, on a message about an incomplete installation
    # that has nothing to do with what any of them is testing. That is exactly what happened
    # when multi-run.csv.example was added.
    local f
    for f in $(payload_items); do
        [ "$f" = "PoolSeqFlow" ] && continue   # copied above, and it must be the real one
        if [ -d "$REPO_ROOT/$f" ]; then mkdir -p "$sb/$f"; else : > "$sb/$f"; fi
    done
    # The stub conda goes in its own directory rather than $sb/bin, which belongs to the
    # pipeline and is part of what `install` deploys - a fake conda inside the payload would
    # be copied into every test installation.
    # shellcheck disable=SC2086
    make_stub_conda "$sb/stub" $envs_spec
    LAUNCHER_CONDA_LOG="$sb/stub/conda.log"
    # Installs go inside the sandbox, never into the operator's real ~/.local. Without this
    # a launcher test would deploy a stub payload over a working installation.
    LAUNCHER_PREFIX="$sb/prefix"
    LAUNCHER_OUTPUT=$(cd "$sb" && PATH="$sb/stub/bin:$PATH" \
                      POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" ./PoolSeqFlow "$@" 2>&1)
    LAUNCHER_STATUS=$?
}
