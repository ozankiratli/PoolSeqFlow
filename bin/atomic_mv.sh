#!/usr/bin/env bash
#
# Move a finished artifact into permanent storage without ever leaving a partial file
# under its final name.
#
# Usage: atomic_mv.sh <source-file> <destination-file>
#        atomic_mv.sh <source-file> <destination-directory>/     <- note the trailing slash
#
# The work directory and storageDir are normally on different filesystems, so `mv` is a
# copy followed by an unlink rather than a rename(). A job killed mid-copy therefore
# leaves a truncated file at the destination - and the pipeline's skip logic only asks
# whether the file exists, so the next run treats that fragment as a completed step.
#
# Staging through a .part suffix avoids it: the cross-filesystem copy lands on a name the
# skip logic cannot match, and the final step is a rename within the destination
# filesystem, which is atomic. Either the artifact is complete and correctly named, or it
# is not there at all.

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

# The caller states its intent with a trailing slash, the way `mv file dir/` does, instead
# of this script inferring it from `[ -d "$DEST" ]`. Inference cannot tell "put it in this
# directory" apart from "a directory is sitting on the artifact's name" - and the second is
# a collision that has to fail. Obeying it silently buries the artifact one level down
# under a name the skip logic still matches, which breaks the guarantee above: the step
# then looks complete on every later run.
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

# Cross-filesystem copy onto a name the skip logic will not accept ...
mv "$SRC" "${DEST}.part"
# ... then an atomic rename within the destination filesystem.
mv "${DEST}.part" "$DEST"
