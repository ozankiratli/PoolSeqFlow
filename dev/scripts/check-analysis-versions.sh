#!/usr/bin/env bash
#
# Has anything changed without its version moving?
#
# Usage: dev/scripts/check-analysis-versions.sh
#
# Three versions, each covering a different set of files, and each only useful if it is bumped
# when that set changes. Nothing in the pipeline forces that, so this is what catches a missed
# bump - by hand while working, and as a release gate.
#
#   frame     analysis/frame.version       covers analysis/frame.config and analysis/lib/
#   index     the #!index-version header    covers the rows in analysis/modules-index.tsv
#   module    manifest.json's version       covers that module's own directory
#
# It reads the working tree first and git second, so a change that is still uncommitted is
# reported the same way as one that is already in. Exits 1 when anything is behind.
#
# Bump with dev/scripts/bump-analysis-version.sh.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$REPO"

STALE=0

report() {
    STALE=$(( STALE + 1 ))
    echo "BEHIND: $1"
    shift
    while [ "$#" -gt 0 ]; do echo "    $1"; shift; done
    echo ""
}

# Whether any of the given paths is dirty in the working tree.
dirty() {
    [ -n "$(git status --porcelain -- "$@" 2>/dev/null)" ]
}

# The commit time of the last commit touching any of the given paths, or nothing.
last_commit() {
    git log -1 --format=%ct -- "$@" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------
# The frame: analysis/frame.config and analysis/lib/ against analysis/frame.version.

FRAME_SOURCES=(analysis/frame.config analysis/lib)
FRAME_VERSION=analysis/frame.version

if dirty "${FRAME_SOURCES[@]}" && ! dirty "$FRAME_VERSION"; then
    report "the frame changed and analysis/frame.version did not" \
        "uncommitted: $(git status --porcelain -- "${FRAME_SOURCES[@]}" | awk '{print $NF}' | tr '\n' ' ')" \
        "bump it:    dev/scripts/bump-analysis-version.sh frame"
else
    src=$(last_commit "${FRAME_SOURCES[@]}")
    ver=$(last_commit "$FRAME_VERSION")
    if [ -n "${src:-}" ] && [ -n "${ver:-}" ] && [ "$src" -gt "$ver" ]; then
        report "the frame was committed after analysis/frame.version last moved" \
            "last frame change:   $(git log -1 --format='%h %ad %s' --date=short -- "${FRAME_SOURCES[@]}")" \
            "last version change: $(git log -1 --format='%h %ad %s' --date=short -- "$FRAME_VERSION")" \
            "bump it:             dev/scripts/bump-analysis-version.sh frame"
    fi
fi

# ---------------------------------------------------------------------------------------
# The catalogue. Its rows and its version live in ONE file, so the question is not which
# changed last but whether the change that touched the rows also touched the header.

INDEX=analysis/modules-index.tsv

index_rows() {
    grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' || true
}

if dirty "$INDEX"; then
    if ! git diff HEAD -- "$INDEX" | grep -q '^+#![[:space:]]*index-version:'; then
        report "the catalogue changed and its #!index-version did not" \
            "bump it: dev/scripts/bump-analysis-version.sh index"
    fi
else
    last=$(git log -1 --format=%H -- "$INDEX" 2>/dev/null || true)
    if [ -n "${last:-}" ]; then
        # Rows changed in that commit but the version header did not.
        if git show "$last" -- "$INDEX" | grep -qE '^[+-][^#+-]' \
           && ! git show "$last" -- "$INDEX" | grep -q '^+#![[:space:]]*index-version:'; then
            report "the last commit to the catalogue changed rows without moving its version" \
                "commit:  $(git log -1 --format='%h %ad %s' --date=short -- "$INDEX")" \
                "bump it: dev/scripts/bump-analysis-version.sh index"
        fi
    fi
fi

# ---------------------------------------------------------------------------------------
# Each installed module, against its own manifest.

if [ -d analysis/modules ]; then
    for dir in analysis/modules/*/; do
        [ -f "${dir}manifest.json" ] || continue
        name=$(basename "$dir")
        if dirty "$dir" && ! git diff HEAD -- "${dir}manifest.json" | grep -q '^+.*"version"'; then
            report "module '$name' changed and its manifest version did not" \
                "bump it: dev/scripts/bump-analysis-version.sh module $name"
        fi
    done
fi

# ---------------------------------------------------------------------------------------

if [ "$STALE" -eq 0 ]; then
    echo "Every analysis version is up to date with what it covers."
    exit 0
fi
echo "$STALE version(s) behind."
exit 1
