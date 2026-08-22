#!/bin/bash
# Assertions and result accounting for the PoolSeqFlow test suite.
#
# Sourced by run_tests.sh. Suites call the assert_* helpers and never exit on their own: a
# failed assertion records the failure and lets the case continue, so one broken case
# reports every problem it has rather than only the first.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CASE_NAME=""
CASE_FAILED=0
CASE_SKIPPED=0
CASE_MESSAGES=()
FAILED_CASES=()

if [ -t 1 ]; then
    C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_SKIP=$'\033[33m'
    C_HEAD=$'\033[1m';  C_DIM=$'\033[2m';   C_OFF=$'\033[0m'
else
    C_PASS=""; C_FAIL=""; C_SKIP=""; C_HEAD=""; C_DIM=""; C_OFF=""
fi

# Record a failure against the case in progress. Never exits - see the note above.
fail_case() {
    CASE_FAILED=1
    CASE_MESSAGES+=("$1")
}

# Mark the case as not applicable here (a missing tool, no conda environment, and so on).
# A skip is neither a pass nor a failure and does not affect the exit status.
skip_case() {
    CASE_SKIPPED=1
    CASE_MESSAGES+=("$1")
}

assert_eq() {          # expected actual [label]
    [ "$1" = "$2" ] && return 0
    fail_case "${3:-values differ}: expected [$1], got [$2]"
}

assert_contains() {    # haystack needle [label]
    case "$1" in *"$2"*) return 0 ;; esac
    fail_case "${3:-missing text}: expected to find [$2]"
}

assert_not_contains() {  # haystack needle [label]
    case "$1" in *"$2"*) fail_case "${3:-unexpected text}: did not expect [$2]"; return 1 ;; esac
    return 0
}

assert_status() {      # expected actual [label]
    [ "$1" = "$2" ] && return 0
    fail_case "${3:-exit status}: expected $1, got $2"
}

assert_file() {        # path [label]
    [ -f "$1" ] && return 0
    fail_case "${2:-expected a file}: $1"
}

assert_no_file() {     # path [label]
    [ ! -e "$1" ] && return 0
    fail_case "${2:-expected nothing at}: $1"
}

assert_count() {       # expected actual-count [label]
    [ "$1" = "$2" ] && return 0
    fail_case "${3:-count}: expected $1, got $2"
}

# Run one test function and report its verdict. Failure messages are buffered so they print
# underneath the case they belong to rather than ahead of it.
run_case() {
    local fn="$1" label
    label="${fn#test_}"
    label="${label//_/ }"
    CASE_NAME="$label"
    CASE_FAILED=0
    CASE_SKIPPED=0
    CASE_MESSAGES=()

    "$fn"

    if [ "$CASE_SKIPPED" -eq 1 ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        printf '  %sSKIP%s %s' "$C_SKIP" "$C_OFF" "$label"
        [ ${#CASE_MESSAGES[@]} -gt 0 ] && printf ' %s(%s)%s' "$C_DIM" "${CASE_MESSAGES[0]}" "$C_OFF"
        printf '\n'
        return 0
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$CASE_FAILED" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '  %sPASS%s %s\n' "$C_PASS" "$C_OFF" "$label"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_CASES+=("$CURRENT_SUITE / $label")
        printf '  %sFAIL%s %s\n' "$C_FAIL" "$C_OFF" "$label"
        local msg
        for msg in "${CASE_MESSAGES[@]}"; do
            printf '       %s%s%s\n' "$C_FAIL" "$msg" "$C_OFF"
        done
    fi
}

print_summary() {
    printf '\n%s%s%s\n' "$C_HEAD" "----------------------------------------------------------" "$C_OFF"
    if [ "$TESTS_FAILED" -eq 0 ]; then
        printf '%sPASS%s  %d passed' "$C_PASS" "$C_OFF" "$TESTS_PASSED"
    else
        printf '%sFAIL%s  %d passed, %d failed' "$C_FAIL" "$C_OFF" "$TESTS_PASSED" "$TESTS_FAILED"
    fi
    [ "$TESTS_SKIPPED" -gt 0 ] && printf ', %d skipped' "$TESTS_SKIPPED"
    printf '\n'
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf '\nFailed:\n'
        local c
        for c in "${FAILED_CASES[@]}"; do
            printf '  %s\n' "$c"
        done
    fi
}
