#!/usr/bin/env bash
#
# Move a finished artifact into place without ever leaving a partial file under its final name.
#
# Usage: atomic_mv.sh <source-file> <destination-file>
#        atomic_mv.sh <source-file> <destination-directory>/     <- note the trailing slash
#
# Staged through a `.part` suffix: the cross-filesystem copy lands on a name the skip logic
# cannot match, and the last step is an atomic rename within the destination filesystem.
#
# NO LOCKING. The caller is responsible for one task per artifact path.

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

# Without this, a kill between the two moves below leaves ${DEST}.part behind for good.
trap 'rm -rf -- "${DEST}.part"' EXIT

mv "$SRC" "${DEST}.part"
mv "${DEST}.part" "$DEST"
