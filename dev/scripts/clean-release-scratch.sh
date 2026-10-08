#!/usr/bin/env bash
#
# Remove what a release cycle leaves behind, once the release is out.
#
# Usage:  dev/scripts/clean-release-scratch.sh [--dry-run]
#
# Removes, naming each as it goes:
#
#   - the test suite's working directories, poolseqflow-test.XXXXXX under ${TMPDIR:-/tmp} and
#     /tmp, and their second filesystem, poolseqflow-test-xdev.XXXXXX under /dev/shm, /var/tmp or
#     $POOLSEQFLOW_TEST_XDEV. `run_tests.sh --keep` leaves both, prep-version.sh runs the suite
#     with --keep, and every interrupted run leaves its pair as well;
#   - the scratch conda environments the release scripts build: PoolSeqFlow-update and
#     PoolSeqFlow-update-analysis, which `prep-version.sh --no-cleanup` keeps for step 5;
#     PoolSeqFlow-floorcheck from check-exported-floor.sh; PoolSeqFlow-modulecheck-<pid> from
#     check-module-packages.sh; and PoolSeqFlow-suite-<pid> and PoolSeqFlow-suite-<pid>-analysis
#     from a full suite run. The last three only when the process the name carries is gone;
#   - .tmp/release-review/, the scratch check-manual-parameters.sh writes for step 1.
#
# Keeps dev/logs/, which is the record of every prep run; every installed PoolSeqFlow-<version>
# environment and any other environment not named above; and conda's package cache.
#
# REFUSES, AND REMOVES NOTHING, while a run_tests.sh, prep-version.sh, check-exported-floor.sh,
# check-module-packages.sh or check-release-archive.sh is running anywhere on the machine, since
# such a process is using what this would remove. One that this script descends from is not
# counted, which is what lets the suite run it.
#
# --dry-run lists what would be removed and removes nothing.
#
# Exits 0 when everything it found is gone, or there was nothing; 1 when it refused, when
# something could not be removed, or when conda could not be asked; 2 for a usage mistake.
#
# RELEASE_SCRATCH_ROOTS replaces the directories searched for working directories, and is how
# the suite points this at a sandbox instead of /tmp.

set -uo pipefail

usage() {
    echo "usage: $0 [--dry-run]" >&2
    exit 2
}

DRY=0
case "$#:${1:-}" in
    0:) ;;
    1:--dry-run) DRY=1 ;;
    *) usage ;;
esac

REPO=$(cd "$(dirname "$0")/../.." && pwd)
FAILED=0
FOUND=0

# This process and every process it descends from.
ancestors() {
    local pid=$$ parent
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        echo "$pid"
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ "$parent" != "$pid" ] || break
        pid=$parent
    done
}

# Whether any process at all has this pid.
alive() {
    ps -p "$1" > /dev/null 2>&1
}

# --- anything still running ----------------------------------------------------------------

BUSY=$(ps -eo pid=,args= 2>/dev/null | awk -v mine=" $(ancestors | tr '\n' ' ') " '
    {
        pid = $1
        args = $0
        sub(/^[ \t]*[0-9]+[ \t]+/, "", args)
        if (index(mine, " " pid " ")) next
        if (args ~ /(^|[ \/])(run_tests|prep-version|check-exported-floor|check-module-packages|check-release-archive)\.sh( |$)/)
            print "    " pid "  " args
    }')
if [ -n "$BUSY" ]; then
    echo "Still running, and using what this would remove:" >&2
    printf '%s\n' "$BUSY" >&2
    echo "Nothing was removed. Run this again once they have finished." >&2
    exit 1
fi

if [ "$DRY" -eq 1 ]; then
    VERB="would remove"
else
    VERB="removed"
fi

# --- the suite's working directories --------------------------------------------------------

ROOTS=${RELEASE_SCRATCH_ROOTS:-"${TMPDIR:-/tmp} /tmp ${POOLSEQFLOW_TEST_XDEV:-} /dev/shm /var/tmp"}
declare -A SEEN=()
DIRS=()
for root in $ROOTS; do
    [ -d "$root" ] || continue
    real=$(cd "$root" && pwd -P) || continue
    [ -z "${SEEN[$real]:-}" ] || continue
    SEEN[$real]=1
    while IFS= read -r -d '' dir; do
        DIRS+=("$dir")
    done < <(find "$real" -mindepth 1 -maxdepth 1 -type d -user "$(id -u)" \
                  \( -name 'poolseqflow-test.??????' -o -name 'poolseqflow-test-xdev.??????' \) \
                  -print0 2>/dev/null | sort -z)
done
if [ -d "$REPO/.tmp/release-review" ]; then
    DIRS+=("$REPO/.tmp/release-review")
fi

for dir in "${DIRS[@]+"${DIRS[@]}"}"; do
    FOUND=1
    size=$(du -sh -- "$dir" 2>/dev/null | cut -f1)
    if [ "$DRY" -eq 1 ]; then
        printf '%s %s (%s)\n' "$VERB" "$dir" "${size:-?}"
        continue
    fi
    # A case may leave a directory it made read-only, which rm alone cannot empty.
    rm -rf -- "$dir" 2>/dev/null || { chmod -R u+w -- "$dir" 2>/dev/null; rm -rf -- "$dir"; }
    if [ -e "$dir" ]; then
        printf 'COULD NOT REMOVE %s\n' "$dir" >&2
        FAILED=1
    else
        printf '%s %s (%s)\n' "$VERB" "$dir" "${size:-?}"
    fi
done

# --- the scratch conda environments ---------------------------------------------------------

# Whether a name is one of the release scripts' scratch environments, and its run is over.
scratch_env() {
    case "$1" in
        PoolSeqFlow-update|PoolSeqFlow-update-analysis|PoolSeqFlow-floorcheck) return 0 ;;
    esac
    if [[ "$1" =~ ^PoolSeqFlow-modulecheck-([0-9]+)$ ]] \
       || [[ "$1" =~ ^PoolSeqFlow-suite-([0-9]+)(-analysis)?$ ]]; then
        alive "${BASH_REMATCH[1]}" && return 1
        return 0
    fi
    return 1
}

if ! command -v conda > /dev/null 2>&1 || ! conda env list > /dev/null 2>&1; then
    echo "conda could not be asked, so no scratch environment was looked for. Source its hook," >&2
    echo "then run this again:" >&2
    echo "    . \"\$(dirname \"\$(dirname \"\$(command -v conda)\")\")/etc/profile.d/conda.sh\"" >&2
    FAILED=1
else
    while read -r name; do
        scratch_env "$name" || continue
        FOUND=1
        if [ "$DRY" -eq 1 ]; then
            printf '%s the conda environment %s\n' "$VERB" "$name"
        elif said=$(conda env remove --name "$name" --yes 2>&1); then
            printf '%s the conda environment %s\n' "$VERB" "$name"
        else
            printf 'COULD NOT REMOVE the conda environment %s:\n' "$name" >&2
            printf '%s\n' "$said" | sed 's/^/    /' >&2
            FAILED=1
        fi
    done < <(conda env list 2>/dev/null | awk 'NF && $1 !~ /^#/ { print $1 }')
fi

if [ "$FOUND" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    echo "Nothing to remove."
fi
exit "$FAILED"
