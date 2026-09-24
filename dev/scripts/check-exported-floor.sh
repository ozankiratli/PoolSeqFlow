#!/usr/bin/env bash
#
# Solve a shipped environment file into a scratch environment, read what it really requires of
# its host, and throw the scratch away.
#
# Usage:  dev/scripts/check-exported-floor.sh [environment-file ...]
#           defaults to both: install/environment.yml and install/environment-analysis.yml
#
# Minutes, and a real network solve. Run it by hand during a release, after the export.
#
# WHAT IT REPLACES, AND WHY THAT DID NOT WORK
# -------------------------------------------
# dev/RELEASING.md step 2 used to say:
#
#     ./PoolSeqFlow analysis install
#     dev/scripts/check-host-floor.sh
#
# In the middle of a release cycle the wrapper still declares the OLD version, because the bump
# is step 6. So `analysis install` looks for PoolSeqFlow-<old>-analysis, finds it already there,
# prints "Environment ... already exists" and creates nothing - and check-host-floor.sh then
# defaults to that same old name. The step installed nothing and reported on the release being
# replaced, while reading as a check on the new one.
#
# Removing the old environment first, which is the obvious way to make the install actually run,
# is worse than the no-op: it builds the NEW file under the OLD version's name, so the release
# that has not been replaced yet is left pointing at an environment that is no longer its own.
# Z, 2026-09-24: *"Even if it ran it still would be wrong because it would install an updated
# env for an older version."* Hence a scratch name that belongs to no release, and a discard.
#
# WHAT THIS ANSWERS THAT prep-version.sh DOES NOT
# -----------------------------------------------
# prep-version.sh checks the floor at [4/5] against the CLONED AND UPDATED scratch environments,
# before it exports. That catches an update raising the floor while the solve is still in hand.
# It does not check the file that was then written. This does: the exported file is solved from
# scratch, the way a user's install resolves it, and the floor is read out of the result.
#
# The two are not the same question. A clone carries whatever was in the source environment; a
# file names constraints and lets the solver choose again.

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

SCRATCH="PoolSeqFlow-floorcheck"
FILES=("$@")
[ "${#FILES[@]}" -gt 0 ] || FILES=(install/environment.yml install/environment-analysis.yml)

# CONDA HAS TO BE REACHABLE, AND "conda said no" IS NOT "conda did not run".
#
# Release scripts here call `conda env list` and read an empty answer as "not present". On a
# machine whose shell function is set up for another shell family, a non-interactive bash gets
# `__conda_exe: permission denied` and the same empty answer, so a sound release is refused for
# a reason that has nothing to do with the environments. This checks the tool works at all
# before believing anything it says.
if ! command -v conda > /dev/null 2>&1; then
    echo "ERROR: conda is not on PATH." >&2
    exit 1
fi
if ! conda env list > /dev/null 2>&1; then
    echo "ERROR: 'conda env list' failed, so nothing it reports can be trusted." >&2
    echo "  Source the hook first, then run this again:" >&2
    echo "      . \"\$(dirname \"\$(dirname \"\$(command -v conda)\")\")/etc/profile.d/conda.sh\"" >&2
    exit 1
fi

env_exists() {
    conda env list | awk '{print $1}' | grep -qxF "$1"
}

if env_exists "$SCRATCH"; then
    echo "ERROR: '$SCRATCH' already exists, left over from an earlier run." >&2
    echo "  Investigate or discard it, then start again:" >&2
    echo "      conda env remove -n $SCRATCH --yes" >&2
    exit 1
fi

# Removed however this exits, including on an interrupt: a scratch environment left behind makes
# the next run refuse, and it is large.
discard() {
    if env_exists "$SCRATCH"; then
        echo "  discarding $SCRATCH"
        conda env remove --name "$SCRATCH" --yes > /dev/null 2>&1 || true
    fi
}
trap discard EXIT INT TERM

STATUS=0
for file in "${FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: no such file: $file" >&2
        STATUS=1
        continue
    fi
    echo ""
    echo "=== $file"
    echo "  solving into $SCRATCH (minutes)..."
    # -n is required: the exported files carry no `name:` key, which 00_static asserts, so that
    # a user's install cannot be named by whoever ran the export.
    if ! conda env create --name "$SCRATCH" --file "$file" --yes > /tmp/floorcheck.$$.log 2>&1; then
        echo "  REFUSED: the file does not solve on this host." >&2
        sed 's/^/      /' /tmp/floorcheck.$$.log >&2
        rm -f /tmp/floorcheck.$$.log
        STATUS=1
        discard
        continue
    fi
    rm -f /tmp/floorcheck.$$.log
    bash dev/scripts/check-host-floor.sh "$SCRATCH" || STATUS=1
    discard
done

echo ""
if [ "$STATUS" -eq 0 ]; then
    echo "Every file solves from scratch and holds the floor it declares."
else
    echo "At least one file did not. Nothing was changed; the scratch environment is gone." >&2
fi
exit "$STATUS"
