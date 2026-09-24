#!/bin/bash
#
# PoolSeqFlow test suite.
#
#   test/run_tests.sh                 run everything
#   test/run_tests.sh --list          show the suites without running them
#   test/run_tests.sh --suite static  run suites whose name contains "static"
#   test/run_tests.sh --case citation run only cases whose name contains "citation"
#   test/run_tests.sh --changed       run the suites that cover what you have changed
#   test/run_tests.sh --cost static   run only the suites that need nothing but a shell
#   test/run_tests.sh --fast          skip the cases that run the pipeline
#   test/run_tests.sh --keep          leave the working directories behind for inspection
#
# --suite and --case may be given more than once and accumulate, so
#
#   test/run_tests.sh --suite guards --suite pipeline
#
# runs both. Every run prints the filters it applied and how many suites they selected: a run
# that narrowed itself has to say so, or a green result over a subset nobody chose reads
# exactly like a green result over everything.
#
# Exit status is 0 only when every case that ran passed. Skips do not fail the run: a
# machine without the conda environment can still check everything that does not need it.
#
# Deliberately not `set -e`. A failing assertion has to be recorded and reported, not abort
# the whole run - a suite that stops at its first problem hides the rest of them.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
export REPO_ROOT

LIST_ONLY=0
FAST=0
KEEP=0
CHANGED=0
SUITE_FILTERS=()
CASE_FILTERS=()
COST_FILTERS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --list)  LIST_ONLY=1 ;;
        --fast)  FAST=1 ;;
        --keep)  KEEP=1 ;;
        --suite) SUITE_FILTERS+=("${2:-}"); shift ;;
        --case)  CASE_FILTERS+=("${2:-}"); shift ;;
        --cost)  COST_FILTERS+=("${2:-}"); shift ;;
        --changed) CHANGED=1 ;;
        -h|--help)
            sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "unknown option: $1" >&2
            exit 2 ;;
    esac
    shift
done

# The version this tree is. An environment is named PoolSeqFlow-<version>[-analysis], so this is
# what tells this release's own environment from one another release left behind.
TREE_VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
export TREE_VERSION

# WHERE CONDA KEEPS ENVIRONMENTS. The wrapper never has to know, because it activates by name; a
# test has to probe bin/nextflow and bin/Rscript, so it needs the directory.
#
# DERIVED FROM THE conda EXECUTABLE, NEVER FROM `conda info --base`. That command prints a
# plugin's load error onto stdout ahead of its answer, on every invocation:
#
#     Error loading anaconda-anon-usage: module 'conda.cli.install' has no attribute 'check_prefix'
#     /home/tholian/.local/opt/miniconda3
#
# so the variable holds an error message with a path stuck on the end, every directory built from
# it is nonsense, the glob matches nothing and discovery falls through in silence. `conda env
# list --json` is corrupted the same way, the error landing ahead of the opening brace. conda
# itself lives at <base>/condabin/conda, so the base is two directories up and needs no conda to
# say so.
#
# Both directories are searched because conda uses both: envs_dirs puts the installation's own
# envs/ ahead of ~/.conda/envs and `conda env create -n` takes the first writable one, so which
# it is depends on where conda was installed and neither can be assumed. Searching only
# ~/.conda/envs is what made every environment invisible on a machine with miniconda under
# ~/.local/opt, however many were installed.
conda_env_dirs() {
    local exe base
    exe=$(command -v conda 2>/dev/null || true)
    if [ -n "$exe" ]; then
        base=$(dirname "$(dirname "$exe")")
        [ -d "$base/envs" ] && printf '%s\n' "$base/envs"
    fi
    [ -d "$HOME/.conda/envs" ] && printf '%s\n' "$HOME/.conda/envs"
    return 0
}

# The installed environment for this tree's version. <suffix> is "" for the pipeline environment
# and "-analysis" for the other; <probe> is the binary that proves it is usable.
#
# THIS TREE'S VERSION FIRST, and another only with a warning on stderr. A bare PoolSeqFlow-*
# glob takes whatever sorts first, which is the oldest environment on the machine, so a tree at
# 3.1.2 with 3.1.1 still installed measured 3.1.1 and said nothing. The same glob had already
# been caught doing the same thing in prep-version.sh.
#
# The analysis environment is excluded by name rather than by probe, because it carries nextflow
# too - measured, all four installed environments do - so `PoolSeqFlow-*` probed for bin/nextflow
# returns PoolSeqFlow-<version>-analysis as the pipeline environment.
find_release_env() {
    local suffix="$1" probe="$2" dir candidate other=""
    while IFS= read -r dir; do
        candidate="$dir/PoolSeqFlow-${TREE_VERSION}${suffix}"
        if [ -x "$candidate/bin/$probe" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        for candidate in "$dir"/PoolSeqFlow-*"$suffix"; do
            [ -z "$suffix" ] && case "$candidate" in *-analysis) continue ;; esac
            [ -x "$candidate/bin/$probe" ] && [ -z "$other" ] && other="$candidate"
        done
    done < <(conda_env_dirs)
    if [ -n "$other" ]; then
        printf 'WARNING: PoolSeqFlow-%s%s is not installed; testing %s instead\n' \
            "$TREE_VERSION" "$suffix" "$(basename "$other")" >&2
        printf '%s' "$other"
    fi
    return 0
}

# The conda environment supplying nextflow, bwa, samtools and the rest. Point
# TEST_CONDA_ENV at another one to test against it; suites that need tools skip without it.
if [ -z "${TEST_CONDA_ENV:-}" ]; then
    TEST_CONDA_ENV=$(find_release_env "" nextflow)
fi
TEST_CONDA_ENV="${TEST_CONDA_ENV:-}"
export TEST_CONDA_ENV

# True when the tools needed to run the pipeline are actually present.
have_tools() {
    [ -n "$TEST_CONDA_ENV" ] && [ -x "$TEST_CONDA_ENV/bin/nextflow" ]
}
export -f have_tools

# The R a module actually runs under. Every module case must use this: a number computed by the
# system R was computed against different package versions than the ones the release pins, so a
# green result describes software nobody receives.
#
# A function rather than a variable, because TEST_ANALYSIS_ENV is discovered further down and a
# variable assigned here would be fixed to the empty string before discovery ever ran.
have_analysis_r() {
    [ -n "${TEST_ANALYSIS_ENV:-}" ] && [ -x "$TEST_ANALYSIS_ENV/bin/Rscript" ]
}
export -f have_analysis_r

# The analysis environment, which is where a module actually runs. Found rather than assumed:
# the wrapper creates it with `conda env create -n`, naming it and leaving the directory to
# conda. TEST_ANALYSIS_ENV points it at another one.
#
# This discovery used to call `conda info --base` itself, which is the trap the activation block
# below describes - the fix landed on the activation and never reached the search that decides
# whether there is anything to activate. So the hook was resolved correctly from a variable that
# was always empty.
if [ -z "${TEST_ANALYSIS_ENV:-}" ]; then
    TEST_ANALYSIS_ENV=$(find_release_env -analysis Rscript)
fi
TEST_ANALYSIS_ENV="${TEST_ANALYSIS_ENV:-}"
export TEST_ANALYSIS_ENV

# THE conda SHELL FUNCTION, DEFINED BUT NOT USED YET. Sourcing the hook is what makes
# `conda activate` exist in a script at all; the activation itself happens further down, around
# the block of suites that declare `# env: analysis`, so nothing else in the run has an
# environment on its PATH.
#
# It used to activate here, for the whole process. That put the analysis environment behind
# every one of the 500-odd cases that do not want it, and made the pipeline suites unable to
# notice a missing tool: both environments carry nextflow, samtools, bcftools and rsync, so
# anything dropped from the pipeline environment was quietly answered by the analysis one.
#
# THE HOOK IS FOUND FROM THE ENVIRONMENT'S OWN PATH, NOT FROM `conda info --base`. That command
# prints a plugin's load error onto stdout alongside the answer - anaconda-anon-usage does it on
# every invocation - so the variable holds an error message with a path stuck on the end, the
# `-f` test fails against nonsense, and the activation is skipped in silence. An environment
# lives at <base>/envs/<name>, so the base is two directories up and needs nothing to say so.
if [ -n "$TEST_ANALYSIS_ENV" ]; then
    _conda_hook="$(dirname "$(dirname "$TEST_ANALYSIS_ENV")")/etc/profile.d/conda.sh"
    # shellcheck disable=SC1091
    [ -f "$_conda_hook" ] && . "$_conda_hook"
    unset _conda_hook
fi

# The analysis environment's Rscript, empty when there is none. A module's own R may use the
# packages that environment pins, and some of its paths need one the system R does not carry;
# the shared library stays base R and is tested against whatever Rscript is on PATH.
analysis_rscript() {
    [ -n "$TEST_ANALYSIS_ENV" ] && printf '%s' "$TEST_ANALYSIS_ENV/bin/Rscript"
}
export -f analysis_rscript

# True when the frame can build a PDF report: pandoc to convert and typst to typeset. Both are
# pinned in the analysis environment and the frame runs them with it active, so the ENVIRONMENT
# is what is asked and not the machine.
#
# It asked the machine until 2026-09-09, through `command -v`. A developer's own /usr/sbin/typst
# answered yes for five days while the shipped environment carried none, so every report case
# passed against a binary no user would receive. That is the whole reason this reads a prefix.
have_report_tools() {
    [ -n "$TEST_ANALYSIS_ENV" ] || return 1
    [ -x "$TEST_ANALYSIS_ENV/bin/pandoc" ] && [ -x "$TEST_ANALYSIS_ENV/bin/typst" ]
}
export -f have_report_tools

# A PDF's text, for a case that has to know what a report SAYS rather than that one exists.
# Empty when no extractor is installed, and the caller skips.
pdf_text() {
    command -v pdftotext > /dev/null 2>&1 || return 0
    pdftotext -q "$1" - 2>/dev/null
}
export -f pdf_text

# What a suite may cost, declared in its own header as `# cost: <class>`:
#
#   static    completes with nothing installed. A case wanting a tool skips rather than
#             building anything, so the suite is minutes-free on any machine.
#   jvm       starts Nextflow per case, against planted artifacts rather than a real run.
#   pipeline  runs the pipeline itself, against the committed fixture.
#
# The line between static and jvm is whether a case BUILDS something: asking `have_tools` and
# skipping is static, calling for a baseline or a pipeline run is not. 00_static lints with
# Nextflow when it is there and skips when it is not, which is why the test is what a case does
# without tools rather than whether a JVM can ever start.
#
# Undeclared reads as `pipeline`: an unclassified suite must not slip into a cheap run, and
# 00_static refuses one anyway.
suite_cost() {
    local declared
    declared=$(sed -n '1,12s/^# cost: *//p' "$1" | head -1)
    printf '%s' "${declared:-pipeline}"
}

# Which conda environment a suite's work happens inside, declared in its own header as
# `# env: <name>`: `pipeline`, `analysis`, or absent for neither.
#
# THE TOOL RUNS IN AN ACTIVATED ENVIRONMENT, SO THE SUITE DOES TOO. `PoolSeqFlow run` activates
# the pipeline environment and `PoolSeqFlow analysis <module>` activates the analysis one, and
# a case that only puts a bin on PATH is testing something the release does not do. What that
# cost, measured 2026-09-23: activation runs `etc/conda/activate.d/openjdk_activate.sh`, which
# exports JAVA_HOME as $CONDA_PREFIX/lib/jvm and JAVA_LD_LIBRARY_PATH beside it, while
# _run_entry had been setting JAVA_HOME to $CONDA_PREFIX - a directory with no lib/server in it,
# so not a JAVA_HOME at all - and JAVA_LD_LIBRARY_PATH not at all. Every pipeline case had been
# launching its JVM under an environment no user has.
#
# For the analysis side it is the compiler: Rcpp drives conda's own x86_64-conda-linux-gnu-c++,
# which is on no PATH but that environment's, and without activation every compiled path fails
# with `sh: x86_64-conda-linux-gnu-c++: command not found`.
#
# Absent means the suite genuinely runs outside both, and the four that declare nothing are the
# static ones: 00_static, 01_migrate, 02_launcher and 03_helpers. They reach a tool by explicit
# path where they need one at all - 00_static's lint case sets PATH per invocation, 03_helpers
# calls bcftools through BCFTOOLS_BIN - and 02_launcher and 06_dryrun drive the wrapper against
# a STUB conda on purpose, which has to stay ahead of anything real on PATH.
suite_env() {
    local declared
    declared=$(sed -n '1,12s/^# env: *//p' "$1" | head -1)
    printf '%s' "${declared:-none}"
}

# True when `name` contains any of the remaining arguments, or when there are none. No filters
# means everything, which is what makes an unfiltered run the whole suite.
matches_any() {
    local name="$1"; shift
    [ "$#" -eq 0 ] && return 0
    local pattern
    for pattern in "$@"; do
        case "$name" in *"$pattern"*) return 0 ;; esac
    done
    return 1
}

# WHAT THE CHANGE REACHES, from dev/scripts/select-tests.py: each suite declares what it runs,
# and the include graph expands that into what it depends on. It errs wide - a file no suite
# reaches, or a change to the harness itself, selects everything - because a selection that is
# too small is a bug nobody was looking for, where one that is too big only costs minutes.
if [ "$CHANGED" -eq 1 ]; then
    _selected=$(python3 "$REPO_ROOT/dev/scripts/select-tests.py" --command 2>/dev/null)
    if [ -z "$_selected" ]; then
        echo "nothing has changed, so nothing is selected" >&2
        exit 0
    fi
    # shellcheck disable=SC2086
    set -- $_selected
    while [ $# -gt 0 ]; do
        [ "$1" = "--suite" ] && SUITE_FILTERS+=("$2") && shift
        shift
    done
    unset _selected
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/poolseqflow-test.XXXXXX")
export TEST_TMPDIR

# XDG_DATA_HOME FOR THE WHOLE RUN, so nothing a case installs reaches the operator's own home.
# `PoolSeqFlow install` writes the tab completion under it and `uninstall` removes it again -
# the one thing the wrapper puts outside its own prefix.
#
# Set here rather than in run_launcher_with_envs, which is where it was first put: 02_launcher
# invokes the wrapper inline in several cases rather than through that helper, and those calls
# went straight to ~/.local/share. Measured - the directory appeared there on the first run.
# One export covers every invocation however a case makes it.
XDG_DATA_HOME="$TEST_TMPDIR/xdg"
export XDG_DATA_HOME
mkdir -p "$XDG_DATA_HOME"

# A second working area on a DIFFERENT filesystem, when the machine has one to offer. Moving an
# artifact between two volumes is a different code path from moving it within one, and it is the
# path both atomic_mv.sh data-loss defects lived in; TEST_TMPDIR alone cannot reach it.
#
# Empty when no second filesystem is found, and the cases that need one skip. POOLSEQFLOW_TEST_XDEV
# names a directory to look in, for a machine whose second volume is somewhere else.
TEST_XDEV_TMPDIR=""
for candidate in "${POOLSEQFLOW_TEST_XDEV:-}" /dev/shm /var/tmp; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ] || continue
    [ "$(stat -c %d "$candidate")" != "$(stat -c %d "$TEST_TMPDIR")" ] || continue
    TEST_XDEV_TMPDIR=$(mktemp -d "$candidate/poolseqflow-test-xdev.XXXXXX") || continue
    # Resolved, because guard_path compares against a resolved path and /dev/shm is a symlink
    # to /run/shm on some distributions.
    TEST_XDEV_TMPDIR=$(cd "$TEST_XDEV_TMPDIR" && pwd -P)
    break
done
export TEST_XDEV_TMPDIR

cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        printf '\nworking directory kept at %s\n' "$TEST_TMPDIR"
        [ -n "$TEST_XDEV_TMPDIR" ] && printf 'second filesystem kept at %s\n' "$TEST_XDEV_TMPDIR"
    else
        rm -rf "$TEST_TMPDIR"
        [ -n "$TEST_XDEV_TMPDIR" ] && rm -rf "$TEST_XDEV_TMPDIR"
    fi
}
trap cleanup EXIT

# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=lib/sandbox.sh
source "$SCRIPT_DIR/lib/sandbox.sh"
# shellcheck source=lib/analysis.sh
source "$SCRIPT_DIR/lib/analysis.sh"

# A MODULE SHIPS ITS OWN CASES. A module is a pipeline published on its own timetable, so the
# cases that judge it travel with it rather than living in a suite here - which is also what
# lets a module somebody else wrote be tested the way ours are. The harness and the fixtures
# stay shared; only the cases are the module's.
SUITES=()
for suite in "$SCRIPT_DIR"/suites/*.sh; do
    [ -f "$suite" ] || continue
    SUITES+=("$suite")
done
for suite in "$REPO_ROOT"/modules/*/test/*.sh; do
    [ -f "$suite" ] || continue
    SUITES+=("$suite")
done

# THE SUITES THAT NEED AN ENVIRONMENT GO LAST, so they form one block and one activation covers
# all of them. Ordering is the whole mechanism: without it 07_analysis_rlib sits in the middle of
# the numbered suites and the run would have to activate and deactivate around it.
_plain=(); _needs_env=()
for suite in "${SUITES[@]}"; do
    if [ "$(suite_env "$suite")" = "none" ]; then
        _plain+=("$suite")
    else
        _needs_env+=("$suite")
    fi
done
SUITES=("${_plain[@]+"${_plain[@]}"}" "${_needs_env[@]+"${_needs_env[@]}"}")
unset _plain _needs_env

if [ "$LIST_ONLY" -eq 1 ]; then
    echo "Suites:"
    for suite in "${SUITES[@]}"; do
        name=$(basename "$suite" .sh)
        desc=$(sed -n '2s/^# \{0,1\}//p' "$suite")
        printf '  %-24s %-9s %s\n' "$name" "$(suite_cost "$suite")" "$desc"
    done
    exit 0
fi

printf '%sPoolSeqFlow test suite%s\n' "$C_HEAD" "$C_OFF"

# BOTH ENVIRONMENTS, NAMED. Only the pipeline one was printed, so an analysis environment that
# was never found looked exactly like a run that did not need one - and the skips it caused read
# as a machine without R rather than as a suite that had failed to look in the right place.
if have_tools; then
    printf '%stools:    %s%s\n' "$C_DIM" "$TEST_CONDA_ENV" "$C_OFF"
else
    printf '%stools:    none found - suites needing the pipeline will skip%s\n' "$C_DIM" "$C_OFF"
fi
if have_analysis_r; then
    printf '%sanalysis: %s%s\n' "$C_DIM" "$TEST_ANALYSIS_ENV" "$C_OFF"
else
    printf '%sanalysis: none found - suites needing R will skip%s\n' "$C_DIM" "$C_OFF"
fi

# WHAT THIS RUN COVERS, before it covers it. A filtered run and a full one are told apart by
# this line and by nothing else in the output, and a green result over a subset nobody chose
# reads exactly like a green result over everything.
SELECTED=()
for suite in "${SUITES[@]}"; do
    matches_any "$(basename "$suite" .sh)" "${SUITE_FILTERS[@]+"${SUITE_FILTERS[@]}"}" || continue
    matches_any "$(suite_cost "$suite")" "${COST_FILTERS[@]+"${COST_FILTERS[@]}"}" || continue
    SELECTED+=("$(basename "$suite" .sh)")
done
if [ "${#SUITE_FILTERS[@]}" -eq 0 ] && [ "${#CASE_FILTERS[@]}" -eq 0 ] \
   && [ "${#COST_FILTERS[@]}" -eq 0 ]; then
    printf '%sscope: every suite (%d)%s\n' "$C_DIM" "${#SELECTED[@]}" "$C_OFF"
else
    printf '%sscope: %d of %d suites' "$C_DIM" "${#SELECTED[@]}" "${#SUITES[@]}"
    [ "${#SUITE_FILTERS[@]}" -gt 0 ] && printf ' matching %s' "${SUITE_FILTERS[*]}"
    [ "${#COST_FILTERS[@]}" -gt 0 ] && printf ' costing %s' "${COST_FILTERS[*]}"
    [ "${#CASE_FILTERS[@]}" -gt 0 ] && printf '; only cases matching %s' "${CASE_FILTERS[*]}"
    printf '%s\n' "$C_OFF"
fi
if [ "${#SELECTED[@]}" -eq 0 ]; then
    printf 'nothing matches %s%s\n' "${SUITE_FILTERS[*]}" "${COST_FILTERS[*]:+ at cost ${COST_FILTERS[*]}}" >&2
    exit 2
fi

SUITES_RUN=0
CURRENT_SUITE=""
ACTIVE_ENV="none"
for suite in "${SUITES[@]}"; do
    name=$(basename "$suite" .sh)
    matches_any "$name" "${SUITE_FILTERS[@]+"${SUITE_FILTERS[@]}"}" || continue
    matches_any "$(suite_cost "$suite")" "${COST_FILTERS[@]+"${COST_FILTERS[@]}"}" || continue
    SUITES_RUN=$((SUITES_RUN + 1))

    # ONE ACTIVATION, AT THE BOUNDARY. The suites are ordered so that everything needing an
    # environment is contiguous, so this fires once on the way in and once on the way out.
    # Silent when conda is not reachable: the cases inside check have_analysis_r and skip.
    want=$(suite_env "$suite")
    if [ "$want" != "$ACTIVE_ENV" ]; then
        [ "$ACTIVE_ENV" = "none" ] || conda deactivate 2>/dev/null || true
        case "$want" in
            pipeline) [ -n "$TEST_CONDA_ENV" ] \
                          && conda activate "$TEST_CONDA_ENV" 2>/dev/null || true ;;
            analysis) [ -n "$TEST_ANALYSIS_ENV" ] \
                          && conda activate "$TEST_ANALYSIS_ENV" 2>/dev/null || true ;;
        esac
        ACTIVE_ENV="$want"
    fi

    # Suites marked slow read this to decide whether to skip themselves.
    export TEST_FAST="$FAST"
    CURRENT_SUITE="$name"

    before=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
    # shellcheck disable=SC1090
    source "$suite"
    after=$(declare -F | awk '{print $3}' | grep '^test_' | sort)

    printf '\n%s%s%s\n' "$C_HEAD" "$name" "$C_OFF"
    while read -r fn; do
        [ -n "$fn" ] || continue
        # Filtered here rather than at discovery: a suite's fixtures are built by the cases
        # that need them, so the ones that run must still be the ones the suite defines.
        if ! matches_any "$fn" "${CASE_FILTERS[@]+"${CASE_FILTERS[@]}"}"; then
            unset -f "$fn"; continue
        fi
        run_case "$fn"
        unset -f "$fn"
    done < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
done

print_summary
[ "$TESTS_FAILED" -eq 0 ]
