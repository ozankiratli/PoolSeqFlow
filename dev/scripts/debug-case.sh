#!/usr/bin/env bash
#
# Run one test case and show everything it left behind, so a failure that reproduces on one
# machine and not another can be compared directly.
#
# Usage:  dev/scripts/debug-case.sh <suite> <case> [label]
#           dev/scripts/debug-case.sh 04_guards unusable_multirun mine
#           dev/scripts/debug-case.sh 15_analysis_results one_pdf yours
#
# WHY THIS EXISTS
# ---------------
# The suite reports which assertion failed, and for a case that runs a pipeline that is rarely
# enough: the reason is in Nextflow's output or in a task's log, inside a sandbox the harness
# deletes on exit. Worse, several cases share one sandbox and overwrite each other's run.out,
# so by the end of a suite the evidence for an early failure is gone. Chasing the 3.1.2 release
# cost most of a day for exactly that reason.
#
# So this runs ONE case with --keep, harvests every run.out and .nextflow.log, and reads out the
# failure signatures the pipeline and the frame print on purpose:
#
#   ERROR ~ ...                               a guard refusing, which is often the expected result
#   PUBLISHING <label>: ... could not be built the PDF report failing, with the knitr log inlined
#   [SUCCESS]/[FAILED] completed=N ...        Nextflow's own summary, when it prints one
#
# It also dumps the environment from INSIDE _run_entry, after that function's own exports, via
# TEST_DEBUG_DIR. That is what the JVM inherits and it is neither shell's environment, which is
# why comparing `env` between two terminals proved nothing.
#
# Run it where the case fails and where it passes, then diff the two .env files.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT"

SUITE="${1-}"; CASE="${2-}"
if [ -z "$SUITE" ] || [ -z "$CASE" ]; then
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
fi
LABEL="${3:-$(hostname -s 2>/dev/null || echo host)}"
OUT="/tmp/psf-debug-$SUITE-$CASE-$LABEL"
rm -rf "$OUT"; mkdir -p "$OUT"

: "${TEST_CONDA_ENV:=/home/tholian/.local/opt/miniconda3/envs/PoolSeqFlow-update}"
: "${TEST_ANALYSIS_ENV:=/home/tholian/.local/opt/miniconda3/envs/PoolSeqFlow-update-analysis}"
export TEST_CONDA_ENV TEST_ANALYSIS_ENV
export TEST_DEBUG_DIR="$OUT/env"

echo "PoolSeqFlow case debug"
echo "  case       : $SUITE / $CASE"
echo "  label      : $LABEL"
echo "  collecting : $OUT"
echo "  shell      : tty=$(tty 2>/dev/null || echo none) TERM=${TERM:-unset}"
echo ""

./test/run_tests.sh --suite "$SUITE" --case "$CASE" --keep > "$OUT/suite.log" 2>&1
STATUS=$?
KEPT=$(sed -n 's/^working directory kept at //p' "$OUT/suite.log" | tail -1)
KEPT_XDEV=$(sed -n 's/^second filesystem kept at //p' "$OUT/suite.log" | tail -1)

echo "--- what the suite said ---"
sed -n "/^$SUITE/,\$p" "$OUT/suite.log" | head -12 | sed 's/^/  /'
echo ""

if [ -z "$KEPT" ] || [ ! -d "$KEPT" ]; then
    echo "  no sandbox was kept - see $OUT/suite.log"
    exit "$STATUS"
fi

# Absolute destination: the copy loop cds into the sandbox, and a relative path would write the
# harvest inside the directory it is reading.
mkdir -p "$OUT/artifacts"
( cd "$KEPT" && find . \( -name 'run*.out' -o -name '.nextflow.log*' -o -name '.command.log' \
      -o -name '.command.sh' -o -name '.exitcode' -o -name 'report_knit.log' \) -print0 \
  | while IFS= read -r -d '' f; do
        mkdir -p "$OUT/artifacts/$(dirname "$f")"
        cp "$f" "$OUT/artifacts/$f" 2>/dev/null
    done )
echo "--- harvested $(find "$OUT/artifacts" -type f | wc -l | tr -d ' ') files ($(du -sh "$OUT/artifacts" 2>/dev/null | cut -f1)) ---"
echo ""

echo "--- failure signatures the code prints on purpose ---"
found=0
if grep -rh "could not be built" "$OUT/artifacts" 2>/dev/null | head -1 | grep -q .; then
    found=1
    echo "  THE PDF REPORT FAILED TO BUILD. The frame prints the reason; here it is:"
    grep -rh -A40 "could not be built" "$OUT/artifacts" 2>/dev/null | head -45 | sed 's/^/    /'
fi
if grep -rhc "ERROR ~" "$OUT/artifacts" 2>/dev/null | grep -qv '^0$'; then
    found=1
    echo "  A run stopped with an error (often the expected result for a guard case):"
    grep -rh -A4 "ERROR ~" "$OUT/artifacts" 2>/dev/null | head -12 | sed 's/^/    /'
fi
line=$(grep -rho '\[[A-Z]*\] completed=[^ ]* failed=[^ ]* cached=[^ ]*' "$OUT/artifacts" 2>/dev/null | head -1)
if [ -n "$line" ]; then
    echo "  Nextflow printed a summary line: $line"
else
    echo "  Nextflow printed NO summary line (it has two renderers and only one does)."
    echo "    Nothing should assert on it - see tasks_started() in test/lib/sandbox.sh."
fi
[ "$found" -eq 0 ] && echo "  no known signature found; read $OUT/artifacts by hand"
echo ""

echo "--- non-zero task exit codes, if any ---"
find "$OUT/artifacts" -name .exitcode 2>/dev/null | while read -r f; do
    code=$(cat "$f" 2>/dev/null)
    [ "$code" = "0" ] || echo "  ${f#"$OUT/artifacts/"} -> exit $code"
done | head -10
echo ""

echo "Collected in $OUT :"
echo "  artifacts/   run.out, .nextflow.log, task logs and scripts, report_knit.log"
echo "  env/*.env    the environment inside _run_entry, after its own exports"
echo "  suite.log    the harness output"
echo ""
echo "Sandbox kept at $KEPT"
[ -n "$KEPT_XDEV" ] && echo "            and $KEPT_XDEV"
echo "Delete both when done."
exit "$STATUS"
