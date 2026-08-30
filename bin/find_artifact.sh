#!/usr/bin/env bash
#
# Where does an artifact live right now?
#
# Usage: find_artifact.sh <relative-path> <root> [<root>...]
#
# Prints the absolute path of the first root that has it and exits 0. Exits 1, silently,
# when no root has it - "not there yet" is the ordinary answer on a first run, not an error.
# Usage mistakes exit 2, so a caller can tell "absent" from "you called me wrong".
#
# Roots are given in PRIORITY ORDER, permanent first, and all take the SAME relative path. An
# artifact found in more than one is reported on stderr.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $(basename "$0") <relative-path> <root> [<root>...]" >&2
    exit 2
fi

REL="$1"
shift

case "$REL" in
    "")
        echo "find_artifact: empty relative path" >&2
        exit 2
        ;;
    /*)
        # An absolute path here would ignore every root.
        echo "find_artifact: expected a relative path, got an absolute one: $REL" >&2
        exit 2
        ;;
esac

FOUND=""
ALSO=""

for root in "$@"; do
    # An empty root is skipped, not treated as "/".
    [ -n "$root" ] || continue
    candidate="$root/$REL"
    if [ -e "$candidate" ]; then
        if [ -z "$FOUND" ]; then
            FOUND="$candidate"
        else
            ALSO="${ALSO}${ALSO:+$'\n'}$candidate"
        fi
    fi
done

if [ -z "$FOUND" ]; then
    exit 1
fi

if [ -n "$ALSO" ]; then
    echo "find_artifact: '$REL' exists in more than one place." >&2
    echo "  using   $FOUND" >&2
    while IFS= read -r extra; do
        echo "  also at $extra" >&2
    done <<< "$ALSO"
    echo "  The first is the one that counts. A duplicate means a promotion did not" >&2
    echo "  finish; atomic_mv.sh stages through .part and renames, so this should not" >&2
    echo "  happen, and the extra copy is worth looking at before it is removed." >&2
fi

printf '%s\n' "$FOUND"
