#!/usr/bin/env bash
#
# Prepare the tool set for a release: update every package, prove the pipeline still works,
# then record what was proven.
#
# Usage:  dev/scripts/prep-version.sh <new-version>          e.g. 2.3.0
#         dev/scripts/prep-version.sh <new-version> --from <env>
#
# What it does, in order:
#
#   1. Clones the environment for the version this working copy currently declares into a
#      scratch environment, PoolSeqFlow-update.
#   2. Runs `conda update --all` there, so the tools move as one mutually consistent set
#      rather than one package at a time.
#   3. Runs the full test suite against it.
#   4. Only if that passes: exports it to install/environment.yml and removes it.
#
# Nothing is exported when the tests fail, and the scratch environment is left in place. Output
# lands in dev/logs/prep-<version>-<timestamp>/, including a table of which packages moved.
#
# This does not bump the version or touch the CHANGELOG - run dev/scripts/bump-version.sh
# afterwards. It does not commit anything.

set -euo pipefail

NEW="${1-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <new-version> [--from <environment>]   (e.g. 2.3.0)" >&2
    exit 1
fi
shift

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

CURRENT="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow | head -1)"
[ -n "$CURRENT" ] || { echo "ERROR: no VERSION= line in ./PoolSeqFlow" >&2; exit 1; }

SOURCE_ENV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) SOURCE_ENV="${2-}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

env_exists() {
    conda env list | awk '{print $1}' | grep -qxF "$1"
}

# One fixed name, not PoolSeqFlow-<new>. It does not outlive the run that made it.
UPDATE_ENV="PoolSeqFlow-update"

# A leftover means an earlier run failed and was not cleaned up.
if env_exists "$UPDATE_ENV"; then
    echo "ERROR: '$UPDATE_ENV' already exists." >&2
    echo "" >&2
    echo "That is left over from an earlier preparation run, most likely one whose tests" >&2
    echo "failed. Investigate or discard it before starting again:" >&2
    echo "    conda env remove -n $UPDATE_ENV" >&2
    exit 1
fi

# Which environment to start from: the version this copy declares, unless told otherwise. An
# unversioned environment from an older release is accepted with a note.
if [ -z "$SOURCE_ENV" ]; then
    if env_exists "PoolSeqFlow-$CURRENT"; then
        SOURCE_ENV="PoolSeqFlow-$CURRENT"
    elif env_exists "PoolSeqFlow"; then
        SOURCE_ENV="PoolSeqFlow"
        echo "Note: starting from the unversioned 'PoolSeqFlow' environment."
        echo "      That is an install from before environments were named per version."
        echo ""
    else
        echo "ERROR: no environment to start from." >&2
        echo "Looked for 'PoolSeqFlow-$CURRENT' and 'PoolSeqFlow'." >&2
        echo "Install one first:  ./PoolSeqFlow install" >&2
        exit 1
    fi
fi
env_exists "$SOURCE_ENV" || { echo "ERROR: no environment named '$SOURCE_ENV'" >&2; exit 1; }

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
LOGDIR="dev/logs/prep-$NEW-$STAMP"
mkdir -p "$LOGDIR"

say() { printf '%s\n' "$*" | tee -a "$LOGDIR/summary.txt"; }

say "PoolSeqFlow release preparation"
say "  target version : $NEW"
say "  starting from  : $SOURCE_ENV"
say "  scratch env    : $UPDATE_ENV  (removed once the export succeeds)"
say "  logs           : $LOGDIR"
say ""

# ---------------------------------------------------------------- snapshot and clone ----
say "[1/5] Recording the current tool set..."
conda list --name "$SOURCE_ENV" --export > "$LOGDIR/packages-before.txt"
say "      $(grep -c '^[^#]' "$LOGDIR/packages-before.txt") packages"

say "[2/5] Cloning to '$UPDATE_ENV' and updating everything..."
conda create --name "$UPDATE_ENV" --clone "$SOURCE_ENV" --yes > "$LOGDIR/clone.log" 2>&1 \
    || { say "      FAILED - see $LOGDIR/clone.log"; exit 1; }
conda update --all --name "$UPDATE_ENV" --yes > "$LOGDIR/update.log" 2>&1 \
    || { say "      FAILED - see $LOGDIR/update.log"; exit 1; }
conda list --name "$UPDATE_ENV" --export > "$LOGDIR/packages-after.txt"

# What actually moved: the release-note material, and the first thing to read on a failure.
awk -F'=' '
    FNR == NR { if ($0 !~ /^#/ && NF >= 2) before[$1] = $2; next }
    /^#/ || NF < 2 { next }
    {
        if (!($1 in before))          { printf "%s\t(new)\t%s\n", $1, $2 }
        else if (before[$1] != $2)    { printf "%s\t%s\t%s\n", $1, before[$1], $2 }
        seen[$1] = 1
    }
    END {
        for (p in before) if (!(p in seen)) printf "%s\t%s\t(removed)\n", p, before[p]
    }
' "$LOGDIR/packages-before.txt" "$LOGDIR/packages-after.txt" | sort > "$LOGDIR/packages-changed.tsv"

CHANGED=$(wc -l < "$LOGDIR/packages-changed.tsv")
say "      $CHANGED package(s) changed - see $LOGDIR/packages-changed.tsv"
if [ "$CHANGED" -gt 0 ]; then
    say ""
    { printf 'PACKAGE\tBEFORE\tAFTER\n'; cat "$LOGDIR/packages-changed.tsv"; } \
        | column -t -s $'\t' | sed 's/^/      /' | tee -a "$LOGDIR/summary.txt"
    say ""
fi

# ------------------------------------------------------------------------- test ---------
say "[3/5] Running the full test suite against '$UPDATE_ENV'..."
ENV_PREFIX="$(conda env list | awk -v n="$UPDATE_ENV" '$1 == n {print $NF}')"
if [ -z "$ENV_PREFIX" ] || [ ! -x "$ENV_PREFIX/bin/nextflow" ]; then
    say "      ERROR: '$UPDATE_ENV' has no usable nextflow at $ENV_PREFIX/bin/nextflow"
    exit 1
fi

set +e
TEST_CONDA_ENV="$ENV_PREFIX" ./test/run_tests.sh > "$LOGDIR/tests.log" 2>&1
TEST_STATUS=$?
set -e

tail -n 20 "$LOGDIR/tests.log" | sed 's/^/      /' | tee -a "$LOGDIR/summary.txt"
say ""

if [ "$TEST_STATUS" -ne 0 ]; then
    say "STOPPED: the test suite failed (status $TEST_STATUS). Nothing was exported."
    say ""
    say "      install/environment.yml is unchanged, so the current release still"
    say "      describes a tool set that works."
    say ""
    say "      '$UPDATE_ENV' has been kept so the failure can be reproduced:"
    say "          TEST_CONDA_ENV=$ENV_PREFIX ./test/run_tests.sh --suite <name>"
    say ""
    say "      Start with $LOGDIR/packages-changed.tsv - the failure is almost"
    say "      certainly one of the packages listed there."
    say ""
    say "      Discard the attempt with:  conda env remove -n $UPDATE_ENV"
    exit 1
fi

# ----------------------------------------------------------------------- export ---------
say "[4/5] Tests passed. Exporting '$UPDATE_ENV' to install/environment.yml..."
bash dev/scripts/export-environment.sh "$UPDATE_ENV" >> "$LOGDIR/summary.txt" 2>&1

# Removed only after the export has succeeded, so a failure there does not lose the solve.
say "[5/5] Removing the scratch environment..."
conda env remove --name "$UPDATE_ENV" --yes > "$LOGDIR/cleanup.log" 2>&1 \
    || say "      WARNING: could not remove '$UPDATE_ENV' - see $LOGDIR/cleanup.log"

say ""
say "Done. Next:"
say "    git diff install/environment.yml"
say "    dev/scripts/bump-version.sh $NEW"
say "    ./PoolSeqFlow install          # builds PoolSeqFlow-$NEW from the exported file"
say "    ./PoolSeqFlow check"
say ""
say "The release environment is built by that install, from install/environment.yml, so"
say "what ships and what was tested are the same set - and the file, not a long-lived"
say "environment, is what carries it forward."
