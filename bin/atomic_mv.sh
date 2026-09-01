#!/usr/bin/env bash
#
# Move a finished artifact into place.
#
# Usage: atomic_mv.sh <source> <destination>
#        atomic_mv.sh <source> <destination-directory>/     <- note the trailing slash
#
# The source may be a file or a directory: step 1 moves a whole snpEff database with this.
#
# rename(2) is the only thing that writes the destination name, in the direct case and the
# staged one alike. It replaces that name in a single step, and it refuses a destination of the
# wrong type, or a directory with anything in it, without touching either side.
#
# Within one filesystem that rename is the whole move: the artifact keeps its inode, so no
# second copy exists that could be wrong. Across filesystems it is copied into a staging
# directory of this caller's own, compared against its source, and renamed into place only once
# the two match; the source goes after that. The artifact is whole in one root or the other at
# every point, and when it is in both, find_artifact.sh reports it.
#
# NO LOCKING. Callers racing for one destination stage separately and the last rename wins.
# They all do the work, and two callers writing DIFFERENT content to one destination is a bug
# in the caller.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $(basename "$0") <source> <destination-file-or-directory/>" >&2
    exit 1
fi

# rsync reads a trailing slash on the source as "the contents of", so the source always names
# the thing itself.
SRC="${1%/}"
DEST="$2"

if [ ! -e "$SRC" ] && [ ! -L "$SRC" ]; then
    echo "atomic_mv: source not found: $SRC" >&2
    exit 1
fi

# What this moves is a file, a directory, or a link to one. `diff` opens a FIFO and waits for a
# writer that never comes, so anything else would hang here rather than fail.
if [ ! -f "$SRC" ] && [ ! -d "$SRC" ] && [ ! -L "$SRC" ]; then
    echo "atomic_mv: source is neither a file nor a directory: $SRC" >&2
    exit 1
fi

# A trailing slash means "into this directory", the way `mv file dir/` does.
case "$DEST" in
    */) DEST="${DEST%/}/$(basename -- "$SRC")" ;;
esac

# The only writer of the destination name, and the only judge of whether the two paths can be
# moved onto each other at all: rename(2) reports EISDIR, ENOTDIR and ENOTEMPTY itself and
# leaves both sides alone when it refuses. Exit 9 is EXDEV, and means the artifact has to be
# copied.
#
# Not `mv`, which answers EXDEV by copying onto the destination's own name, and which puts the
# source INSIDE a destination that is a directory.
place() {
    python3 -c '
import errno, os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError as exc:
    if exc.errno == errno.EXDEV:
        sys.exit(9)
    sys.exit("atomic_mv: cannot move %s to %s: %s" % (sys.argv[1], sys.argv[2], exc.strerror))
' "$1" "$2"
}

mkdir -p "$(dirname "$DEST")"

STATUS=0
place "$SRC" "$DEST" || STATUS=$?
[ "$STATUS" -eq 9 ] || exit "$STATUS"

# A staging directory of this caller's own, beside the destination so the rename below stays
# within one filesystem. It is a directory because the source may be one, and `mktemp` makes
# only files.
STAGE=$(mktemp -d "$(dirname "$DEST")/.atomic_mv.XXXXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT

rsync -a -- "$SRC" "$STAGE/" || {
    echo "atomic_mv: could not copy $SRC to $DEST" >&2
    exit 1
}
COPY="$STAGE/$(basename -- "$SRC")"

# THE COPY IS NOT TAKEN ON TRUST. `rsync -a` reports success and says nothing when the source
# changed while it was being read, so the copy is compared against the source as it stands
# before anything is removed. --no-dereference compares a symlink's target instead of
# following it.
if ! diff -qr --no-dereference -- "$SRC" "$COPY" > /dev/null 2>&1; then
    echo "atomic_mv: the copy does not match the source: $SRC" >&2
    diff -qr --no-dereference -- "$SRC" "$COPY" >&2 || true
    echo "atomic_mv: nothing was written to $DEST and the source is untouched." >&2
    exit 1
fi

place "$COPY" "$DEST" || {
    echo "atomic_mv: the copy of $SRC could not be put in place at $DEST" >&2
    exit 1
}

rm -rf -- "$SRC"
