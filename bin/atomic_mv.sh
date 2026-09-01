#!/usr/bin/env bash
#
# Move a finished artifact into place without ever leaving a partial file under its final name.
#
# Usage: atomic_mv.sh <source> <destination>
#        atomic_mv.sh <source> <destination-directory>/     <- note the trailing slash
#
# The source may be a file or a directory: step 1 moves a whole snpEff database with this.
#
# Staged through a temp name of this caller's own: the cross-filesystem copy lands on a name the
# skip logic cannot match, and the last step is an atomic rename within the destination
# filesystem.
#
# NO LOCKING, and none is needed for the destination to stay whole: callers racing for one
# destination stage separately and the last rename wins, so the destination is only ever absent
# or complete. They all do the work, and two callers writing DIFFERENT content to one
# destination is a bug in the caller.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $(basename "$0") <source-file> <destination-file-or-directory>" >&2
    exit 1
fi

SRC="$1"
DEST="$2"

if [ ! -e "$SRC" ]; then
    echo "atomic_mv: source not found: $SRC" >&2
    exit 1
fi

if [ -z "$DEST" ]; then
    echo "atomic_mv: empty destination" >&2
    exit 1
fi

# A trailing slash means "into this directory", the way `mv file dir/` does. Without one, a
# destination that turns out to be a directory is an error.
case "$DEST" in
    */)
        mkdir -p "${DEST%/}"
        DEST="${DEST%/}/$(basename "$SRC")"
        ;;
    *)
        if [ -d "$DEST" ]; then
            echo "atomic_mv: destination is a directory but no trailing slash was given: $DEST" >&2
            echo "atomic_mv: pass '${DEST}/' to move into it, or remove the directory to write the file." >&2
            exit 1
        fi
        mkdir -p "$(dirname "$DEST")"
        ;;
esac

# Staged inside a directory of this caller's own: a temp name derived from the destination alone
# is shared by every concurrent caller. It is a directory because the source may be one, and
# `mktemp` makes only files.
STAGE=$(mktemp -d "$(dirname "$DEST")/.atomic_mv.XXXXXXXX")

# Without this, a kill between the two moves below leaves the staged copy behind for good.
trap 'rm -rf -- "$STAGE"' EXIT

mv "$SRC" "$STAGE/item"
mv "$STAGE/item" "$DEST"
