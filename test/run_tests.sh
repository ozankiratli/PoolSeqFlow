#!/bin/bash
#
# PoolSeqFlow test suite.
#
#   test/run_tests.sh                 run everything
#   test/run_tests.sh --list          show the suites without running them
#   test/run_tests.sh --suite static  run suites whose name contains "static"
#   test/run_tests.sh --fast          skip the suites that run the pipeline
#   test/run_tests.sh --keep          leave the working directories behind for inspection
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
SUITE_FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --list)  LIST_ONLY=1 ;;
        --fast)  FAST=1 ;;
        --keep)  KEEP=1 ;;
        --suite) SUITE_FILTER="${2:-}"; shift ;;
        -h|--help)
            sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

SUITES=()
for suite in "$SCRIPT_DIR"/suites/*.sh; do
    [ -f "$suite" ] || continue
    SUITES+=("$suite")
done

if [ "$LIST_ONLY" -eq 1 ]; then
    echo "Suites:"
    for suite in "${SUITES[@]}"; do
        name=$(basename "$suite" .sh)
        desc=$(sed -n '2s/^# \{0,1\}//p' "$suite")
        printf '  %-16s %s\n' "$name" "$desc"
    done
    exit 0
fi

printf '%sPoolSeqFlow test suite%s\n' "$C_HEAD" "$C_OFF"
if have_tools; then
    printf '%stools: %s%s\n' "$C_DIM" "$TEST_CONDA_ENV" "$C_OFF"
else
    printf '%stools: none found - suites needing the pipeline will skip%s\n' "$C_DIM" "$C_OFF"
fi

CURRENT_SUITE=""
for suite in "${SUITES[@]}"; do
    name=$(basename "$suite" .sh)
    if [ -n "$SUITE_FILTER" ]; then
        case "$name" in *"$SUITE_FILTER"*) ;; *) continue ;; esac
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
        run_case "$fn"
        unset -f "$fn"
    done < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
done

print_summary
[ "$TESTS_FAILED" -eq 0 ]
