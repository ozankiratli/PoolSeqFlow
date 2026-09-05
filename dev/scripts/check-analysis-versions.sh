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

# The day analysis/frame.version names, from its one non-comment line. YYYYMMDD.
frame_version_day() {
    grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | head -1 | tr -d ' ' | cut -d. -f1
}

# The day the given paths last changed: today when anything is uncommitted, otherwise the day of
# the last commit touching them. UTC, which is what bump-analysis-version.sh writes.
last_change_day() {
    if dirty "$@"; then date -u +%Y%m%d; return; fi
    TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d -- "$@" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------
# The frame: analysis/frame.config and analysis/lib/ against analysis/frame.version.

FRAME_SOURCES=(analysis/frame.config analysis/lib)
FRAME_VERSION=analysis/frame.version

# The DAY the version names, against the day the frame last changed.
#
# A day, not a commit and not a timestamp. The counter after the dot is bookkeeping; the day is
# what this compares, so a run of frame changes on one day needs one bump rather than one each.
# Commit timestamps cannot do the job at all: `%ct` is whole seconds, so a source commit landing
# in the same second as the version's compares equal and the drift goes unreported - measured.
#
# It reads a bump the moment it is written, committed or not, because the bump writes today's
# date and the comparison is on dates.
#
# What it gives up: a frame change made AFTER the bump on the SAME day reads as covered. That is
# the price of one bump a day, and it is paid in development rather than in a release.
ver_day=$(frame_version_day "$FRAME_VERSION")
src_day=$(last_change_day "${FRAME_SOURCES[@]}")
if [ -n "${ver_day:-}" ] && [ -n "${src_day:-}" ] && [ "$ver_day" -lt "$src_day" ]; then
    if dirty "${FRAME_SOURCES[@]}"; then
        report "the frame changed and analysis/frame.version still says ${ver_day}" \
            "uncommitted: $(git status --porcelain -- "${FRAME_SOURCES[@]}" | awk '{print $NF}' | tr '\n' ' ')" \
            "bump it:     dev/scripts/bump-analysis-version.sh frame"
    else
        report "the frame changed on ${src_day} and analysis/frame.version still says ${ver_day}" \
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
        # A manifest that is not in HEAD yet is a module being added, and its version is new by
        # construction - there is no earlier one it could have failed to move from. Without this
        # every new module reports as behind, because `git diff HEAD` says nothing at all about
        # an untracked file.
        git cat-file -e "HEAD:${dir}manifest.json" 2>/dev/null || continue
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
