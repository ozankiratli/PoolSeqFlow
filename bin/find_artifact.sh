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
# Why this exists. Artifacts move during a run: a step writes its output to the working
# volume and it is promoted to permanent storage once the step that consumes it has
# succeeded. A skip check can therefore no longer ask a single directory whether its work is
# already done - the honest question is "is it in permanent storage, or still waiting to be
# promoted, or neither".
#
# Roots are given in priority order, permanent first. If an artifact somehow exists in both,
# the promoted copy is the finished one and the other is residue from a move that did not
# complete; that is reported rather than passed over, because a stale copy silently winning
# would go on winning for every later run.
#
# Both roots take the SAME relative path. That is the whole reason the working tree mirrors
# the output tree exactly instead of inventing its own layout - it makes this lookup a
# matter of trying one path against N roots rather than translating between two schemes.

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
        # An absolute path here means the caller has already decided where to look, which
        # defeats the point and would silently ignore every root.
        echo "find_artifact: expected a relative path, got an absolute one: $REL" >&2
        exit 2
        ;;
esac

FOUND=""
ALSO=""

for root in "$@"; do
    # An empty root is skipped rather than treated as "/". A caller interpolating an unset
    # parameter would otherwise search the filesystem root and match almost anything.
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
