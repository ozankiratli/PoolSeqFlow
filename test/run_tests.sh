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
#   test/run_tests.sh --fast          skip the suites that run the pipeline
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

# The conda environment supplying nextflow, bwa, samtools and the rest. Point
# TEST_CONDA_ENV at another one to test against it; suites that need tools skip without it.
if [ -z "${TEST_CONDA_ENV:-}" ]; then
    for candidate in "$HOME"/.conda/envs/PoolSeqFlow-* "$HOME"/.conda/envs/PoolSeqFlow; do
        if [ -x "$candidate/bin/nextflow" ]; then
            TEST_CONDA_ENV="$candidate"
            break
        fi
    done
fi
TEST_CONDA_ENV="${TEST_CONDA_ENV:-}"
export TEST_CONDA_ENV

# True when the tools needed to run the pipeline are actually present.
have_tools() {
    [ -n "$TEST_CONDA_ENV" ] && [ -x "$TEST_CONDA_ENV/bin/nextflow" ]
}
export -f have_tools

# True when there is an R to run the shared analysis library against. Any R will do, and that is
# the point of that library being base R: the pipeline environment carries none, the analysis
# environment is not built on a development machine, and a system R is enough.
have_r() {
    command -v Rscript > /dev/null 2>&1
}
export -f have_r

# True when a named R package is installed. A module may offer a path that needs one, and the
# case for that path skips where it is absent rather than failing the machine for not having it.
have_r_package() {
    have_r || return 1
    Rscript --vanilla -e "quit(status = !requireNamespace('$1', quietly = TRUE))" > /dev/null 2>&1
}
export -f have_r_package

# True when a compiled path can actually be built here: Rcpp AND the toolchain it drives. Rcpp
# alone is not enough - it compiles against whatever the machine has, and a release ships no
# compiler.
have_rcpp() {
    have_r_package Rcpp || return 1
    command -v "$(R CMD config CXX 2>/dev/null | awk '{print $1}')" > /dev/null 2>&1
}
export -f have_rcpp

# The analysis environment, which is where a module actually runs. Found rather than assumed:
# the wrapper creates it with `conda env create -n`, naming it and leaving the directory to
# conda - the first writable entry of envs_dirs, which is the conda installation's own envs/
# before ~/.conda/envs. TEST_ANALYSIS_ENV points it at another one.
if [ -z "${TEST_ANALYSIS_ENV:-}" ]; then
    _conda_base=$(conda info --base 2>/dev/null || true)
    for _dir in ${_conda_base:+"$_conda_base/envs"} "$HOME/.conda/envs"; do
        for _candidate in "$_dir"/PoolSeqFlow-*-analysis; do
            if [ -x "$_candidate/bin/Rscript" ]; then
                TEST_ANALYSIS_ENV="$_candidate"
                break 2
            fi
        done
    done
    unset _conda_base _dir _candidate
fi
TEST_ANALYSIS_ENV="${TEST_ANALYSIS_ENV:-}"
export TEST_ANALYSIS_ENV

# The analysis environment's Rscript, empty when there is none. A module's own R may use the
# packages that environment pins, and some of its paths need one the system R does not carry;
# the shared library stays base R and is tested against whatever Rscript is on PATH.
analysis_rscript() {
    [ -n "$TEST_ANALYSIS_ENV" ] && printf '%s' "$TEST_ANALYSIS_ENV/bin/Rscript"
}
export -f analysis_rscript

# True when the frame can build a PDF report: pandoc to convert and typst to typeset. Both are
# pinned in the analysis environment, so this is about the machine the suite runs on rather
# than about the release.
have_report_tools() {
    command -v pandoc > /dev/null 2>&1 && command -v typst > /dev/null 2>&1
}
export -f have_report_tools

# A PDF's text, for a case that has to know what a report SAYS rather than that one exists.
# Empty when no extractor is installed, and the caller skips.
pdf_text() {
    command -v pdftotext > /dev/null 2>&1 || return 0
    pdftotext -q "$1" - 2>/dev/null
}
export -f pdf_text

# True when a named package is installed in the analysis environment.
have_analysis_r_package() {
    [ -n "$TEST_ANALYSIS_ENV" ] || return 1
    "$TEST_ANALYSIS_ENV/bin/Rscript" --vanilla \
        -e "quit(status = !requireNamespace('$1', quietly = TRUE))" > /dev/null 2>&1
}
export -f have_analysis_r_package

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
for suite in "$REPO_ROOT"/analysis/modules/*/test/*.sh; do
    [ -f "$suite" ] || continue
    SUITES+=("$suite")
done

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
if have_tools; then
    printf '%stools: %s%s\n' "$C_DIM" "$TEST_CONDA_ENV" "$C_OFF"
else
    printf '%stools: none found - suites needing the pipeline will skip%s\n' "$C_DIM" "$C_OFF"
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
for suite in "${SUITES[@]}"; do
    name=$(basename "$suite" .sh)
    matches_any "$name" "${SUITE_FILTERS[@]+"${SUITE_FILTERS[@]}"}" || continue
    matches_any "$(suite_cost "$suite")" "${COST_FILTERS[@]+"${COST_FILTERS[@]}"}" || continue
    SUITES_RUN=$((SUITES_RUN + 1))
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
