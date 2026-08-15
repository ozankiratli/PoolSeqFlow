#!/usr/bin/env bash
#
# Move a finished artifact into permanent storage without ever leaving a partial file
# under its final name.
#
# Usage: atomic_mv.sh <source-file> <destination-file-or-directory>
#
# The work directory and projectDir are normally on different filesystems, so `mv` is a
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

# A directory destination keeps the source filename, as plain `mv file dir/` would.
if [ -d "$DEST" ]; then
    DEST="${DEST%/}/$(basename "$SRC")"
fi

mkdir -p "$(dirname "$DEST")"

# Cross-filesystem copy onto a name the skip logic will not accept ...
mv "$SRC" "${DEST}.part"
# ... then an atomic rename within the destination filesystem.
mv "${DEST}.part" "$DEST"
