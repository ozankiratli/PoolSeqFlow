#!/usr/bin/env bash
#
# Publish one analysis module into modules-repo/: build its tarball, add its catalogue row.
#
# Usage: dev/scripts/publish-module.sh <name> [ref]
#          ref defaults to HEAD
#
# Writes modules-repo/<name>-<version>.tar.gz, appends a row to modules-repo/index.tsv, and
# bumps the catalogue's #!index-version. It does not commit or push. The site deploys
# modules-repo/ wholesale, so the tarball and the row that advertises it go out together -
# which is why they are written in one step and not two.
#
# WHY A TARBALL IS A FILE HERE AND NOT SOMETHING GENERATED
# --------------------------------------------------------
# Z, 2026-09-09, on generating the set from git history: "I don't want you to derive it from
# the history." Every intermediate version bump would become a published version, including
# ones made mid-development and never meant to leave. Generating from the working tree instead
# gives exactly one version, which is the opposite problem. So published versions accumulate
# as committed files, and publishing is something a person does on purpose.
#
# REPRODUCIBILITY, AND WHY THIS DOES NOT PIPE `git archive` STRAIGHT INTO gzip
# ---------------------------------------------------------------------------
# `git archive <ref>:analysis/modules/<name>` reads a SUBTREE, and .gitattributes patterns are
# anchored at the repository root - so `analysis/modules/*/test/ export-ignore` does not match
# `test/` inside that subtree and the module's own cases would ship. A module has to be the
# same artifact whether it arrived in a release or from here, so the tree is extracted, test/
# is dropped, and it is repacked with tar's reproducibility flags.
#
# Archiving a tree also stamps mtime = now, which is not reproducible. The commit's own
# timestamp is used instead, so republishing the same ref produces the same bytes. Verified by
# building twice and comparing checksums.

set -euo pipefail

NAME="${1-}"
REF="${2:-HEAD}"
if [ -z "$NAME" ]; then
    echo "Usage: $0 <name> [ref]" >&2
    exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REPO_DIR="modules-repo"
INDEX="$REPO_DIR/index.tsv"
[ -f "$INDEX" ] || { echo "ERROR: $INDEX not found" >&2; exit 1; }

SRC="analysis/modules/$NAME"
git cat-file -e "$REF:$SRC/manifest.json" 2>/dev/null || {
    echo "ERROR: no module '$NAME' at $REF ($SRC/manifest.json is not there)" >&2; exit 1; }

# Straight out of the module's own manifest at that ref. The catalogue repeats what the manifest
# says because the choice of which version to install is made before the tarball is downloaded.
field() {
    git show "$REF:$SRC/manifest.json" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"
}
VERSION=$(field version)
CONTRACT=$(field contract)
FRAME=$(field frame)
ENVIRONMENT=$(field environment)
SUMMARY=$(field summary)

for pair in "version:$VERSION" "contract:$CONTRACT" "frame:$FRAME" \
            "environment:$ENVIRONMENT" "summary:$SUMMARY"; do
    [ -n "${pair#*:}" ] || { echo "ERROR: $NAME's manifest has no ${pair%%:*}" >&2; exit 1; }
done

# A tab in a field would shift every column after it, and the catalogue is tab-separated.
case "$SUMMARY$VERSION$CONTRACT$FRAME$ENVIRONMENT" in
    *$'\t'*) echo "ERROR: a manifest field contains a tab" >&2; exit 1 ;;
esac

TARBALL="$REPO_DIR/$NAME-$VERSION.tar.gz"
if [ -e "$TARBALL" ]; then
    echo "ERROR: $TARBALL already exists." >&2
    echo "" >&2
    echo "A published version is never rewritten: somebody may have installed it, and its" >&2
    echo "checksum is in the catalogue. Bump the module's version and publish that:" >&2
    echo "    dev/scripts/bump-analysis-version.sh module $NAME" >&2
    exit 1
fi

if awk -F'\t' -v n="$NAME" -v v="$VERSION" \
       '!/^#/ && NF > 1 && $1 == n && $2 == v { found = 1 } END { exit !found }' "$INDEX"; then
    echo "ERROR: $INDEX already has a row for $NAME $VERSION" >&2
    exit 1
fi

# The commit that last touched the module at this ref, for a timestamp that follows the content
# rather than the clock.
STAMP=$(git log -1 --format=%ct "$REF" -- "$SRC")
[ -n "$STAMP" ] || STAMP=$(git log -1 --format=%ct "$REF")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$NAME"
git archive --format=tar "$REF:$SRC" | tar -x -C "$WORK/$NAME"
rm -rf "$WORK/$NAME/test"

for f in manifest.json main.nf citations.json; do
    [ -f "$WORK/$NAME/$f" ] || { echo "ERROR: $NAME has no $f - install would refuse it" >&2
                                 exit 1; }
done

mkdir -p "$REPO_DIR"
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner \
    --mtime="@$STAMP" -C "$WORK" -cf - "$NAME" | gzip -n > "$TARBALL"

SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
URL="https://ozankiratli.github.io/PoolSeqFlow/$REPO_DIR/$(basename "$TARBALL")"

# Appended in the header's column order, which is the order the file declares and not one this
# script decides. Read back and compared before anything else is written.
HEADER=$(grep -v '^#' "$INDEX" | grep -v '^[[:space:]]*$' | head -1)
EXPECTED=$'name\tversion\tcontract\tframe\tenvironment\turl\tsha256\tsummary'
[ "$HEADER" = "$EXPECTED" ] || {
    echo "ERROR: $INDEX's header is not the layout this script writes:" >&2
    printf '  found:    %s\n  expected: %s\n' "$HEADER" "$EXPECTED" >&2
    exit 1; }

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NAME" "$VERSION" "$CONTRACT" "$FRAME" "$ENVIRONMENT" "$URL" "$SHA" "$SUMMARY" >> "$INDEX"

bash "$ROOT/dev/scripts/bump-analysis-version.sh" index > /dev/null

echo "Published $NAME $VERSION"
echo "  tarball : $TARBALL  ($(stat -c%s "$TARBALL") bytes)"
echo "  sha256  : $SHA"
echo "  url     : $URL"
echo "  index   : row added, #!index-version bumped"
echo ""
echo "Nothing is committed. The site deploys $REPO_DIR/ on a push to main, so the tarball"
echo "and the row that advertises it have to land in the same commit."
