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
    cp -r "$REPO_ROOT/test/data/$fixture/." "$sb/main"/
    printf '%s' "$sb"
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
# BuildDictionaries' `verify` input is a pure ordering barrier - UngzipReference stages it
# and never reads it (its only references are commented out), and BuildSnpEffDb never names
# it in its script body at all - so a placeholder file stands in for step 0.
#
# Every entry script must call resolveParameters() first, exactly as poolseqflow.nf does.
# Without it the computed parameters are simply absent, and the first process to read one
# dies on a null - which looks like a bug in that process rather than a missing setup call.
run_dictionaries_only() {
    local sb="$1"
    cat > "$sb/install/dictionaries_only.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { resolveParameters } from './scripts/resolve_parameters.nf'
include { BuildDictionaries } from './scripts/1_build_dictionaries.nf'

workflow {
    resolveParameters()
    BuildDictionaries(channel.value(file("${params.storageDir}/.step0_token")))
}
ENTRY
    _run_entry "$sb" dictionaries_only.nf
}

# Run step 0 by itself, for tests about the environment and parameter guards. Same
# generate-rather-than-commit reasoning as run_dictionaries_only.
run_verify_only() {
    local sb="$1"
    cat > "$sb/install/verify_only.nf" <<'ENTRY'
nextflow.enable.dsl=2

include { resolveParameters } from './scripts/resolve_parameters.nf'
include { VerifyEnvironment } from './scripts/0_verify_environment.nf'

workflow {
    resolveParameters()
    VerifyEnvironment()
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
    trace="$sb/store/Output/Reports/PoolSeqFlow_pipeline_trace.txt"
    [ -f "$trace" ] || { printf 'no-trace'; return; }
    awk -F'\t' -v want="$process" '
        NR > 1 {
            split($4, a, " ")        # strip the "(tag)" suffix Nextflow appends
            if (a[1] == want) n++
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
    : > "$sb/poolseqflow.nf"
    local f
    for f in nextflow.config parameters.config.template RGTags.csv.template \
             README.md CHANGELOG.md LICENSE; do
        : > "$sb/$f"
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
