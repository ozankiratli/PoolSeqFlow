#!/usr/bin/env bash
#
# Publish one analysis module into modules/repo/: build its tarball, add its catalogue row.
#
# Usage: dev/scripts/publish-module.sh <name> [ref]
#          ref defaults to HEAD
#
# Writes modules/repo/<name>-<version>.tar.gz, appends a row to modules/repo/index.tsv, and
# bumps the catalogue's #!index-version. It does not commit or push. The site deploys
# modules/repo/ wholesale, so the tarball and the row that advertises it go out together -
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
    echo "       $0 --list        what is in the tree and not yet in the catalogue" >&2
    exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# The source directory and the PUBLISHED path are different on purpose. The source sits under
# modules/ with everything else module-related; the published address may never move, because
# MODULE_INDEX_URL in lib/wrapper_lib.sh compiles into every release and asks for it for as long
# as that release exists. build_docs.py copies the one to the other.
REPO_DIR="modules/repo"
PUBLISHED_PATH="modules-repo"
INDEX="$REPO_DIR/index.tsv"
[ -f "$INDEX" ] || { echo "ERROR: $INDEX not found" >&2; exit 1; }

# Is this name and version already a catalogue row? Prints DUPLICATE, BADHEADER, or nothing.
#
# THE COLUMNS ARE MATCHED BY NAME, from the header row, as module_index_rows() in
# lib/wrapper_lib.sh does. Read by position this compared the version against `kind`, which holds
# "module" or "library", so it never matched and the check passed over everything.
#
# The outcome is printed rather than carried in the exit status: a header naming neither column
# has to be told apart from a row that is simply absent, and both are non-zero.
catalogue_has() {   # name version
    awk -F'\t' -v n="$1" -v v="$2" '
        /^[[:space:]]*(#|$)/ { next }
        !header {
            header = 1
            for (i = 1; i <= NF; i++) at[$i] = i
            if (!("name" in at) || !("version" in at)) { print "BADHEADER"; exit }
            next
        }
        $(at["name"]) == n && $(at["version"]) == v { print "DUPLICATE"; exit }
    ' "$INDEX"
}

# Every module and library in the tree against the catalogue. Reads the working tree rather than a
# ref, because this answers what is left to publish; publishing itself refuses an uncommitted
# source and says so.
if [ "$NAME" = "--list" ]; then
    LEFT=0
    for dir in modules/*/ modules/lib/*/; do
        [ -f "$dir/manifest.json" ] || continue
        read -r m_name m_version <<EOF
$(python3 -c "import json;m=json.load(open('$dir/manifest.json'));print(m.get('name',''), m.get('version',''))")
EOF
        [ -n "$m_name" ] && [ -n "$m_version" ] || {
            printf '  %-14s %s\n' "NO MANIFEST" "$dir"; continue; }
        case "$(catalogue_has "$m_name" "$m_version")" in
            BADHEADER) echo "ERROR: $INDEX has no header row naming 'name' and 'version'" >&2
                       exit 1 ;;
            DUPLICATE) printf '  %-14s %s %s\n' "published" "$m_name" "$m_version" ;;
            *)         printf '  %-14s %s %s\n' "UNPUBLISHED" "$m_name" "$m_version"
                       LEFT=$((LEFT + 1)) ;;
        esac
    done
    echo ""
    if [ "$LEFT" -eq 0 ]; then
        echo "Everything in the tree is in the catalogue."
    else
        echo "$LEFT to publish, each with:  $0 <name>"
    fi
    exit 0
fi

# A module or a library: both are a folder with a manifest, published the same way, and the
# manifest's own `kind` says which. Looked for in both places rather than taking a flag, so the
# caller names the thing and the repository says what it is.
SRC=""
for candidate in "modules/$NAME" "modules/lib/$NAME"; do
    if git cat-file -e "$REF:$candidate/manifest.json" 2>/dev/null; then SRC="$candidate"; break; fi
done
[ -n "$SRC" ] || {
    echo "ERROR: no module or library '$NAME' at $REF" >&2
    echo "Looked for modules/$NAME/manifest.json and modules/lib/$NAME/manifest.json" >&2
    exit 1; }

# Straight out of the module's own manifest at that ref. The catalogue repeats what the manifest
# says because the choice of which version to install is made before the tarball is downloaded.
field() {
    git show "$REF:$SRC/manifest.json" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"
}
VERSION=$(field version)
KIND=$(field kind); [ -n "$KIND" ] || KIND="module"
CONTRACT=$(field contract)
FRAME=$(field frame)
ENVIRONMENT=$(field environment)
SUMMARY=$(field summary)

# A library that reads no published table declares no contract, and an empty column is read as
# "no requirement". Everything else is required of both kinds.
[ "$KIND" = "library" ] || REQUIRED_CONTRACT="contract:$CONTRACT"
for pair in "version:$VERSION" "${REQUIRED_CONTRACT:-version:$VERSION}" "frame:$FRAME" \
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

case "$(catalogue_has "$NAME" "$VERSION")" in
    BADHEADER)
        echo "ERROR: $INDEX has no header row naming 'name' and 'version'" >&2
        exit 1 ;;
    DUPLICATE)
        echo "ERROR: $INDEX already has a row for $NAME $VERSION" >&2
        exit 1 ;;
esac

# The commit that last touched the module at this ref, for a timestamp that follows the content
# rather than the clock.
STAMP=$(git log -1 --format=%ct "$REF" -- "$SRC" 2>/dev/null || true)
[ -n "$STAMP" ] || STAMP=$(git log -1 --format=%ct "$REF" 2>/dev/null || true)
# A tree object has no commit and therefore no date of its own; fall back to the commit that
# last touched the source on the current branch. Without a timestamp tar stamps whatever it
# likes and two builds of one ref stop matching, which is the property this whole path exists
# for - so an empty stamp is refused rather than guessed.
[ -n "$STAMP" ] || STAMP=$(git log -1 --format=%ct HEAD -- "$SRC" 2>/dev/null || true)
[ -n "$STAMP" ] || {
    echo "ERROR: no commit timestamp for $SRC at $REF, so the tarball would not be" >&2
    echo "  reproducible. Commit the source and publish from a commit." >&2
    exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$NAME"
git archive --format=tar "$REF:$SRC" | tar -x -C "$WORK/$NAME"
rm -rf "$WORK/$NAME/test"

required="manifest.json"
[ "$KIND" = "module" ] && required="manifest.json main.nf citations.json"
for f in $required; do
    [ -f "$WORK/$NAME/$f" ] || { echo "ERROR: $NAME has no $f - install would refuse it" >&2
                                 exit 1; }
done

mkdir -p "$REPO_DIR"
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner \
    --mtime="@$STAMP" -C "$WORK" -cf - "$NAME" | gzip -n > "$TARBALL"

SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
URL="https://ozankiratli.github.io/PoolSeqFlow/$PUBLISHED_PATH/$(basename "$TARBALL")"

# Appended in the header's column order, which is the order the file declares and not one this
# script decides. Read back and compared before anything else is written.
HEADER=$(grep -v '^#' "$INDEX" | grep -v '^[[:space:]]*$' | head -1)
EXPECTED=$'name\tkind\tversion\tcontract\tframe\tenvironment\turl\tsha256\tsummary'
[ "$HEADER" = "$EXPECTED" ] || {
    echo "ERROR: $INDEX's header is not the layout this script writes:" >&2
    printf '  found:    %s\n  expected: %s\n' "$HEADER" "$EXPECTED" >&2
    exit 1; }

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NAME" "$KIND" "$VERSION" "$CONTRACT" "$FRAME" "$ENVIRONMENT" "$URL" "$SHA" "$SUMMARY" >> "$INDEX"

bash "$ROOT/dev/scripts/bump-analysis-version.sh" index > /dev/null

echo "Published $KIND $NAME $VERSION"
echo "  tarball : $TARBALL  ($(stat -c%s "$TARBALL") bytes)"
echo "  sha256  : $SHA"
echo "  url     : $URL"
echo "  index   : row added, #!index-version bumped"
echo ""
echo "Nothing is committed. The site deploys $REPO_DIR/ on a push to main, so the tarball"
echo "and the row that advertises it have to land in the same commit."
