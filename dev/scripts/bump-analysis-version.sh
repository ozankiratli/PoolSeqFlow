#!/usr/bin/env bash
#
# Bumps one of the analysis layer's YYYYMMDD.NNN versions, or every one that is behind.
#
# Usage: dev/scripts/bump-analysis-version.sh frame
#        dev/scripts/bump-analysis-version.sh index
#        dev/scripts/bump-analysis-version.sh module <name>
#        dev/scripts/bump-analysis-version.sh --pending
#
# Three things carry one of these and each moves on its own:
#
#   frame     analysis/frame.version      - frame.config and anything under analysis/lib/
#   index     modules/repo/index.tsv  - the #!index-version header, on every publish
#   module    modules/<name>/manifest.json, or modules/lib/<name>/manifest.json for a library
#
# The new value is today's UTC date and a counter: .001 the first time on a given day, then
# .002 and so on. It writes one line and nothing else, and prints what it changed.
#
# --pending bumps every target dev/scripts/check-analysis-versions.sh names behind, taken from its
# own "bump it:" lines so the two cannot disagree, each bumped as it would be on its own. Then it
# runs the check again, and fails unless it passes. With nothing behind it changes nothing.
#
# It does NOT touch the release version. That is dev/scripts/bump-version.sh.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

usage() {
    sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's|^# \{0,1\}||' >&2
    exit 2
}

# Today's stamp, or the next counter when the current value is already today's.
next_version() {
    local current="$1" today count
    today=$(date -u +%Y%m%d)
    case $current in
        "${today}."*)
            count=$(( 10#${current#"${today}".} + 1 ))
            if [ "$count" -gt 999 ]; then
                echo "ERROR: $current is the 999th change today. Wait for tomorrow." >&2
                exit 1
            fi
            printf '%s.%03d' "$today" "$count"
            ;;
        *)
            printf '%s.001' "$today"
            ;;
    esac
}

# The current value, per target. Empty when there is none to read.
read_frame()  { grep -vE '^[[:space:]]*(#|$)' "$REPO/analysis/frame.version" | head -1 | tr -d ' '; }
read_index()  { sed -n 's|^#![[:space:]]*index-version:[[:space:]]*\(.*\)$|\1|p' \
                    "$REPO/modules/repo/index.tsv" | head -1 | tr -d ' '; }
read_module() { sed -n 's|.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*|\1|p' "$1" | head -1; }

# A module or a library, named the same way and versioned the same way. The caller gives a name
# and the repository says which it is.
module_manifest() {
    local d
    for d in "$REPO/modules/$1" "$REPO/modules/lib/$1"; do
        [ -f "$d/manifest.json" ] && { printf '%s' "$d/manifest.json"; return 0; }
    done
    return 1
}

[ "$#" -ge 1 ] || usage

if [ "$1" = "--pending" ]; then
    [ "$#" -eq 1 ] || usage
    CHECK="$REPO/dev/scripts/check-analysis-versions.sh"
    STATUS=0
    REPORT=$(bash "$CHECK" 2>&1) || STATUS=$?
    if [ "$STATUS" -eq 0 ]; then
        echo "Nothing is behind: every analysis version is up to date with what it covers."
        exit 0
    fi
    PENDING=$(printf '%s\n' "$REPORT" \
        | sed -n 's|^[[:space:]]*bump it:[[:space:]]*dev/scripts/bump-analysis-version.sh[[:space:]]*||p' \
        | awk '!seen[$0]++')
    if [ -z "$PENDING" ]; then
        echo "ERROR: check-analysis-versions.sh failed, and named nothing to bump:" >&2
        printf '%s\n' "$REPORT" | sed 's/^/    /' >&2
        exit 1
    fi
    while read -r -a ONE; do
        BUMPED=$(bash "${BASH_SOURCE[0]}" "${ONE[@]}" 2>&1) || { printf '%s\n' "$BUMPED" >&2; exit 1; }
        printf '%s\n' "$BUMPED" | head -2
    done <<< "$PENDING"
    echo ""
    STATUS=0
    REPORT=$(bash "$CHECK" 2>&1) || STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        echo "ERROR: check-analysis-versions.sh still names something behind:" >&2
        printf '%s\n' "$REPORT" | sed 's/^/    /' >&2
        exit 1
    fi
    echo "Every analysis version is up to date with what it covers."
    echo "Commit them with the changes they describe."
    exit 0
fi

TARGET="$1"

case "$TARGET" in
    frame)
        FILE="$REPO/analysis/frame.version"
        [ -f "$FILE" ] || { echo "ERROR: $FILE not found." >&2; exit 1; }
        CURRENT=$(read_frame)
        NEW=$(next_version "$CURRENT")
        # The version is the only line that is not a comment, so it is matched as that rather
        # than by its value - a malformed one still has to be replaceable.
        sed -i -E "0,/^[[:space:]]*[^#[:space:]].*$/s||${NEW}|" "$FILE"
        [ "$(read_frame)" = "$NEW" ] || { echo "ERROR: could not write $FILE." >&2; exit 1; }
        ;;
    index)
        FILE="$REPO/modules/repo/index.tsv"
        [ -f "$FILE" ] || { echo "ERROR: $FILE not found." >&2; exit 1; }
        CURRENT=$(read_index)
        [ -n "$CURRENT" ] || { echo "ERROR: $FILE has no '#!index-version:' header." >&2; exit 1; }
        NEW=$(next_version "$CURRENT")
        sed -i -E "s|^#![[:space:]]*index-version:.*|#!index-version: ${NEW}|" "$FILE"
        [ "$(read_index)" = "$NEW" ] || { echo "ERROR: could not write $FILE." >&2; exit 1; }
        ;;
    module)
        [ "$#" -eq 2 ] || usage
        NAME="$2"
        FILE=$(module_manifest "$NAME") || {
            echo "ERROR: no module or library '$NAME'." >&2
            echo "  Looked for modules/$NAME/manifest.json and modules/lib/$NAME/manifest.json" >&2
            exit 1; }
        CURRENT=$(read_module "$FILE")
        [ -n "$CURRENT" ] || { echo "ERROR: $FILE has no 'version'." >&2; exit 1; }
        NEW=$(next_version "$CURRENT")
        sed -i -E "s|(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${NEW}\2|" "$FILE"
        [ "$(read_module "$FILE")" = "$NEW" ] || { echo "ERROR: could not write $FILE." >&2; exit 1; }
        ;;
    *)
        usage
        ;;
esac

echo "${TARGET}${2:+ $2}: ${CURRENT:-none} -> ${NEW}"
echo "    ${FILE#"$REPO"/}"
echo ""
echo "Commit it with the change it describes."
