#!/usr/bin/env bash
#
# Has anything changed without its version moving?
#
# Usage: dev/scripts/check-analysis-versions.sh [--release]
#
# --release is the gate a release passes through, and it is stricter in one way that matters:
# it refuses to answer at all when it cannot. Mid-development the checks below skip a question
# they have no data for, which is right - work is uncommitted, history is local, a version is
# legitimately behind. At a release a skipped question is indistinguishable from a passed one,
# and a gate that reports success over a check it did not run is worse than no gate.
#
# Three versions, each covering a different set of files, and each only useful if it is bumped
# when that set changes. Nothing in the pipeline forces that, so this is what catches a missed
# bump - by hand while working, and as a release gate.
#
#   frame     analysis/frame.version       covers analysis/frame.config and analysis/lib/
#   index     the #!index-version header    covers the rows in modules/repo/index.tsv
#   module    manifest.json's version       covers that module's own directory
#
# It reads the working tree first and git second, so a change that is still uncommitted is
# reported the same way as one that is already in. Exits 1 when anything is behind.
#
# Bump with dev/scripts/bump-analysis-version.sh.

set -euo pipefail

RELEASE=0
case "${1:-}" in
    '')        ;;
    --release) RELEASE=1 ;;
    *)
        echo "Usage: $(basename "$0") [--release]" >&2
        exit 1
        ;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$REPO"

# A SHALLOW CLONE DOES NOT ANSWER WITH SILENCE. IT ANSWERS WRONGLY, IN BOTH DIRECTIONS.
#
# Git treats the grafted tip of a shallow clone as having no parent, so every file reads as
# created in that commit. Measured against a repository built for it:
#
#   the module and catalogue checks ask whether the commit that changed a thing also moved its
#   version, and there the whole file shows as added - version line included - so a module
#   changed three commits ago without a bump is reported as fine. It fails OPEN.
#
#   the frame check asks which day a path last changed, and gets the tip commit's date whatever
#   the path. It fires on a frame nobody touched. It fails CLOSED, on the wrong commit.
#
# So the answer is refused rather than reported.
shallow() { [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != "false" ]; }

if [ "$RELEASE" -eq 1 ]; then
    if shallow; then
        echo "REFUSED: this is a shallow clone or not a git repository, so the history these" >&2
        echo "  checks read is not here. They would answer from the tip commit alone, which" >&2
        echo "  reads as having created every file - a missed version bump goes unreported." >&2
        echo "  Check out with full history - fetch-depth: 0 on actions/checkout." >&2
        exit 1
    fi
    # The uncommitted paths are dated by mtime, which on a fresh checkout is checkout time and
    # says nothing about when the work was done.
    if [ -n "$(git status --porcelain -- analysis 2>/dev/null)" ]; then
        echo "REFUSED: analysis/ has uncommitted changes, and a release is cut from a clean" >&2
        echo "  tree. Commit or stash them first:" >&2
        git status --porcelain -- analysis | sed 's/^/      /' >&2
        exit 1
    fi
elif shallow; then
    echo "WARNING: this is a shallow clone, so everything below is read from the tip commit"
    echo "  alone and is not reliable. Nothing here is a release gate; use --release for that."
    echo ""
fi

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

# The day the given paths last changed: the newest mtime among them while they are uncommitted,
# otherwise the day of the last commit touching them. UTC, which is what
# bump-analysis-version.sh writes.
#
# THE MTIME AND NOT TODAY'S DATE: an uncommitted change keeps the day it was made, so the
# comparison below moves when the frame moves and not when the calendar does.
last_change_day() {
    if dirty "$@"; then
        local newest
        newest=$(git status --porcelain -- "$@" | awk '{print $NF}' \
                 | while IFS= read -r path; do
                       [ -e "$path" ] && date -u -r "$path" +%Y%m%d
                   done | sort -n | tail -1)
        # A change that only removed files leaves no mtime to read.
        echo "${newest:-$(date -u +%Y%m%d)}"
        return
    fi
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
if [ -z "${ver_day:-}" ] || [ -z "${src_day:-}" ]; then
    # Neither day is readable in a checkout with no history, and the comparison below would
    # then pass on both being empty.
    if [ "$RELEASE" -eq 1 ]; then
        report "the frame version could not be compared against the frame" \
            "analysis/frame.version reads: ${ver_day:-<unreadable>}" \
            "last change to the frame:     ${src_day:-<no history for it>}" \
            "A release does not pass a check that did not run."
    fi
elif [ "$ver_day" -lt "$src_day" ]; then
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

INDEX=modules/repo/index.tsv

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
        # NOT THE MODULE'S OWN CASES. `analysis/modules/*/test/` carries export-ignore, so those
        # files are in no published module and can change nothing a user installs - and the
        # version is what an installation and every published result record the module BY.
        if dirty "$dir" ":(exclude)${dir}test"; then
            if ! git diff HEAD -- "${dir}manifest.json" | grep -q '^+.*"version"'; then
                report "module '$name' changed and its manifest version did not" \
                    "bump it: dev/scripts/bump-analysis-version.sh module $name"
            fi
        else
            # Committed, which is the state a release is cut in: the last commit that touched
            # the module has to be the one that moved its version. Without this the loop asks
            # nothing at all of a clean tree, and every module passes a release unexamined.
            last=$(git log -1 --format=%H -- "$dir" ":(exclude)${dir}test" 2>/dev/null || true)
            if [ -n "${last:-}" ] \
               && ! git show "$last" -- "${dir}manifest.json" | grep -q '^+.*"version"'; then
                report "module '$name' last changed in a commit that did not move its version" \
                    "commit:  $(git log -1 --format='%h %ad %s' --date=short -- "$dir" ":(exclude)${dir}test")" \
                    "bump it: dev/scripts/bump-analysis-version.sh module $name"
            fi
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
