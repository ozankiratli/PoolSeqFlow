#!/usr/bin/env bash
#
# Publish one analysis module into modules/repo/: build its tarball, add its catalogue row.
#
# Usage: dev/scripts/publish-module.sh <name> [ref]
#          ref defaults to HEAD
#        dev/scripts/publish-module.sh --list
#          every module and library in the tree, published or not
#        dev/scripts/publish-module.sh --all-pending
#          publish every one --list calls UNPUBLISHED, from HEAD
#
# Writes modules/repo/<name>-<version>.tar.gz, appends a row to modules/repo/index.tsv, and
# bumps the catalogue's #!index-version. It does not commit or push. The site deploys
# modules/repo/ wholesale, so the tarball and the row that advertises it go out together -
# which is why they are written in one step and not two.
#
# --ALL-PENDING IS THE SINGLE PUBLISH, RUN ONCE PER MODULE
# ---------------------------------------------------------
# Each module goes through `publish-module.sh <name> HEAD` in a child process, so there is one
# path that writes a tarball or a row, and a release publishing six modules gets exactly the six
# artifacts six single publishes would have made. Each of them bumps #!index-version as a single
# publish does, so the counter moves once per module.
#
# The pending set is the one --list prints, read from the working tree, while a publish reads
# HEAD. A module whose source differs from HEAD would therefore be listed with one version and
# published with another, or published without the change in the tree, so the batch refuses
# before writing anything while any pending source is uncommitted. `test/` is left out of that
# comparison because the tarball drops it, the same rule check-analysis-versions.sh applies.
# git status is asked for untracked files outright. Under status.showUntrackedFiles=no a plain
# one hid a new module, which the batch reached only after publishing the ones before it, and a
# new file in a tracked one, which it published from HEAD without. A git status that fails is
# refused too, because its empty output reads as clean.
#
# It also refuses, before writing anything, a manifest it cannot read a name and version from,
# which a single publish would refuse and the pending set would otherwise skip without a word,
# and a pending directory whose name another directory shares: a publish is asked for by name
# and finds modules/<name> before modules/lib/<name>, so the library could never be reached and
# the module would be attempted twice.
#
# Whether it stops or finishes, it reads the catalogue back to say what this run published and
# what is still pending. A publish can fail after its row is written, so counting along the loop
# would name the wrong module, and a run that reports success is read back as well, so a success
# with no row behind it is reported rather than counted. A catalogue that cannot be read back
# stops it with that said, rather than with a guess. Nothing is undone. A published module
# leaves the pending set, so fixing the failure and running it again picks up where it stopped.
# The report also names what would stop that: an uncommitted tarball with no row, which a
# publish refuses to overwrite, and, once nothing is left pending, rows added without
# #!index-version moving, which no later run would move.
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
    echo "       $0 --list          every module and library, and whether it is published" >&2
    echo "       $0 --all-pending   publish every one that is not, from HEAD" >&2
    exit 1
fi

# This script as an absolute path, for --all-pending to run once per module. Taken before the cd
# below, which would break a relative one, and without a cd of its own, which an exported CDPATH
# could send to another directory. Read from standard input there is no file, which only
# --all-pending needs, and it refuses that.
SELF="${BASH_SOURCE[0]:-$0}"
case $SELF in /*) ;; *) SELF="$PWD/$SELF" ;; esac

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
# has to be told apart from a row that is simply absent, and both are non-zero. A catalogue with
# no header row at all is BADHEADER too, because read as one with no rows it would call every
# module unpublished.
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
        END { if (!header) print "BADHEADER" }
    ' "$INDEX"
}

# Every module and library in the tree against the catalogue, one tab-separated line each: state,
# name, version and directory. The state is published, UNPUBLISHED, or NOMANIFEST for a manifest
# with no name or version to read, whether a field is missing or the JSON does not parse. Reads
# the working tree rather than a ref, because this answers what is left to publish. A single
# publish refuses a module HEAD does not have; --all-pending refuses any pending source that
# differs from HEAD.
catalogue_states() {
    local dir m_name m_version
    for dir in modules/*/ modules/lib/*/; do
        [ -f "$dir/manifest.json" ] || continue
        IFS=$'\t' read -r m_name m_version <<EOF
$(python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); print(m.get("name", ""), m.get("version", ""), sep="\t")' "$dir/manifest.json")
EOF
        [ -n "$m_name" ] && [ -n "$m_version" ] || {
            printf 'NOMANIFEST\t-\t-\t%s\n' "$dir"; continue; }
        case "$(catalogue_has "$m_name" "$m_version")" in
            BADHEADER) echo "ERROR: $INDEX has no header row naming 'name' and 'version'" >&2
                       exit 1 ;;
            DUPLICATE) printf 'published\t%s\t%s\t%s\n' "$m_name" "$m_version" "$dir" ;;
            *)         printf 'UNPUBLISHED\t%s\t%s\t%s\n' "$m_name" "$m_version" "$dir" ;;
        esac
    done
}

# The directories a catalogue_states listing on stdin puts in one state, one per line.
dirs_in() { awk -F'\t' -v s="$1" '$1 == s { print $4 }'; }

# The pending directories of a catalogue_states listing whose name another directory in it
# shares, one per line.
shared_names() {   # listing
    local all dir
    all=$(printf '%s\n' "$1" | awk -F'\t' '{ d = $4; sub(/\/$/, "", d); sub(/.*\//, "", d); print d }')
    printf '%s\n' "$1" | dirs_in UNPUBLISHED | while IFS= read -r dir; do
        [ "$(grep -cxF -- "$(basename "$dir")" <<< "$all")" -le 1 ] || printf '%s\n' "$dir"
    done
}

if [ "$NAME" = "--list" ]; then
    STATES=$(catalogue_states)
    LEFT=0
    UNREAD=0
    while IFS=$'\t' read -r state m_name m_version dir; do
        case $state in
            NOMANIFEST)  printf '  %-14s %s\n' "NO MANIFEST" "$dir"
                         UNREAD=$((UNREAD + 1)) ;;
            published)   printf '  %-14s %s %s\n' "published" "$m_name" "$m_version" ;;
            UNPUBLISHED) printf '  %-14s %s %s\n' "UNPUBLISHED" "$m_name" "$m_version"
                         LEFT=$((LEFT + 1)) ;;
        esac
    done <<< "$STATES"
    echo ""
    [ "$UNREAD" -eq 0 ] \
        || echo "$UNREAD with no name or version to read, which nothing publishes until it is fixed."
    if [ "$LEFT" -gt 0 ] && [ "$UNREAD" -eq 0 ] && [ -z "$(shared_names "$STATES")" ]; then
        echo "$LEFT to publish, all of them with:  $0 --all-pending"
        echo "or one at a time with:  $0 <name>"
    elif [ "$LEFT" -gt 0 ]; then
        echo "$LEFT to publish, one at a time with:  $0 <name>"
        echo "--all-pending refuses until every manifest can be read and no two directories share"
        echo "a name, and says which."
    elif [ "$UNREAD" -eq 0 ]; then
        echo "Everything in the tree is in the catalogue."
    fi
    exit 0
fi

# Everything --list calls UNPUBLISHED, each through the single publish below in a child process.
if [ "$NAME" = "--all-pending" ]; then
    [ "$#" -eq 1 ] || { echo "ERROR: --all-pending publishes from HEAD and takes no ref" >&2
                        exit 1; }
    [ -f "$SELF" ] || { echo "ERROR: --all-pending runs this script once per module, so it has to" >&2
                        echo "  be run from its file rather than from standard input." >&2
                        exit 1; }
    STATES=$(catalogue_states)

    # A directory's version as the listing read it.
    version_of() { printf '%s\n' "$STATES" | awk -F'\t' -v d="$1" '$4 == d { print $3 }'; }
    names() { local d; for d in "$@"; do printf ' %s' "$(basename "$d")"; done; }

    UNREAD=$(printf '%s\n' "$STATES" | dirs_in NOMANIFEST)
    if [ -n "$UNREAD" ]; then
        echo "REFUSED: no name or version can be read from the manifest in:" >&2
        sed 's/^/    /' <<< "$UNREAD" >&2
        echo "A single publish of each would refuse it. Nothing was published." >&2
        exit 1
    fi

    PENDING=()
    PENDING_LIST=$(printf '%s\n' "$STATES" | dirs_in UNPUBLISHED)
    [ -z "$PENDING_LIST" ] || mapfile -t PENDING <<< "$PENDING_LIST"
    if [ "${#PENDING[@]}" -eq 0 ]; then
        echo "Everything in the tree is in the catalogue."
        exit 0
    fi

    SHARED=$(shared_names "$STATES")
    if [ -n "$SHARED" ]; then
        echo "REFUSED: another directory has the name of each of these, and a publish asked for" >&2
        echo "that name finds modules/<name> before modules/lib/<name>:" >&2
        sed 's/^/    /' <<< "$SHARED" >&2
        echo "Rename one of each pair. Nothing was published." >&2
        exit 1
    fi

    UNCOMMITTED=()
    for dir in "${PENDING[@]}"; do
        changed=$(git status --porcelain --untracked-files=all -- "$dir" ":(exclude)${dir}test") || {
            echo "ERROR: git status failed for $dir, so whether it matches HEAD is unknown." >&2
            echo "Nothing was published." >&2
            exit 1; }
        [ -z "$changed" ] || UNCOMMITTED+=("$dir")
    done
    if [ "${#UNCOMMITTED[@]}" -gt 0 ]; then
        echo "REFUSED: a publish builds from HEAD, and these differ from it:" >&2
        printf '    %s\n' "${UNCOMMITTED[@]}" >&2
        echo "Commit them first. Nothing was published." >&2
        exit 1
    fi

    # The pending directories the catalogue still has no row for. Fails when the catalogue cannot
    # be read, which an empty answer would report as everything published.
    still_pending() {
        local listing left dir
        listing=$(catalogue_states) || return 1
        left=$(printf '%s\n' "$listing" | dirs_in UNPUBLISHED)
        for dir in "${PENDING[@]}"; do
            grep -qxF -- "$dir" <<< "$left" && printf '%s\n' "$dir"
        done
        return 0
    }
    unreadable_now() {
        echo "The catalogue could not be read back, so what this run published is unknown. Look at" >&2
        echo "$INDEX before committing anything." >&2
        exit 1
    }

    # What this run published and what is still pending, read back from the catalogue, and what
    # would stop the next run from finishing the job.
    read_back() {
        local left dir tarball index_diff got=() rest=() stray=()
        left=$(still_pending) || unreadable_now
        for dir in "${PENDING[@]}"; do
            if grep -qxF -- "$dir" <<< "$left"; then
                rest+=("$dir")
                tarball="$REPO_DIR/$(basename "$dir")-$(version_of "$dir").tar.gz"
                if [ -e "$tarball" ] && ! git cat-file -e "HEAD:$tarball" 2> /dev/null; then
                    stray+=("$tarball")
                fi
            else
                got+=("$dir")
            fi
        done
        [ "${#got[@]}" -eq 0 ] || echo "Published by this run, and uncommitted:$(names "${got[@]}")" >&2
        [ "${#rest[@]}" -eq 0 ] || echo "Still pending:$(names "${rest[@]}")" >&2
        if [ "${#stray[@]}" -gt 0 ]; then
            echo "Left uncommitted with no catalogue row, so nothing advertises them, and a publish" >&2
            echo "will not overwrite them. Delete them first:" >&2
            printf '    %s\n' "${stray[@]}" >&2
        fi
        # With modules left, the run asked for below moves #!index-version as it publishes them.
        index_diff=$(git diff HEAD -- "$INDEX" 2> /dev/null || true)
        if [ "${#got[@]}" -gt 0 ] && [ "${#rest[@]}" -eq 0 ] \
           && ! grep -q '^+#![[:space:]]*index-version:' <<< "$index_diff"; then
            echo "Rows were added and #!index-version did not move, and no later run will move it:" >&2
            echo "    dev/scripts/bump-analysis-version.sh index" >&2
        fi
        [ "${#rest[@]}" -eq 0 ] || {
            echo "Fix what it names and run --all-pending again, which starts from what is still" >&2
            echo "pending." >&2; }
    }

    echo "Publishing ${#PENDING[@]} from HEAD, $(git log -1 --format='%h %s')"
    echo ""
    for dir in "${PENDING[@]}"; do
        name=$(basename "$dir")
        if ! PUBLISH_MODULE_BATCH=1 bash "$SELF" "$name" HEAD; then
            echo "" >&2
            echo "STOPPED at $name." >&2
            read_back
            exit 1
        fi
        echo ""
    done

    STILL=$(still_pending) || unreadable_now
    if [ -n "$STILL" ]; then
        echo "Every publish reported success, but the catalogue has no row for some of them." >&2
        read_back
        exit 1
    fi
    echo "Published ${#PENDING[@]}:$(names "${PENDING[@]}")"
    echo ""
    echo "Nothing is committed. The site deploys $REPO_DIR/ whole, after a release or when the"
    echo "Documentation workflow is run by hand, so the tarballs and the rows that advertise them"
    echo "have to land in the same commit."
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
MANIFEST_NAME=$(field name)
VERSION=$(field version)
KIND=$(field kind); [ -n "$KIND" ] || KIND="module"

# Published under its directory's name. --list looks a row up by the manifest's name, and the
# frame refuses to run a module whose two names differ.
[ "$MANIFEST_NAME" = "$NAME" ] || {
    echo "ERROR: $SRC/manifest.json calls it '$MANIFEST_NAME', but it is published as '$NAME'," >&2
    echo "  its directory. The catalogue row takes the directory's name while --list looks for the" >&2
    echo "  manifest's, and the frame refuses a module whose two names differ." >&2
    exit 1; }
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

# The catalogue's header, checked before anything is written: the row below is written in this
# column order, so the header has to declare the same one.
HEADER=$(grep -v '^#' "$INDEX" | grep -v '^[[:space:]]*$' | head -1 || true)
EXPECTED=$'name\tkind\tversion\tcontract\tframe\tenvironment\turl\tsha256\tsummary'
[ "$HEADER" = "$EXPECTED" ] || {
    echo "ERROR: $INDEX's header is not the layout this script writes:" >&2
    printf '  found:    %s\n  expected: %s\n' "$HEADER" "$EXPECTED" >&2
    exit 1; }

# A tarball with a row, or one already committed, may have been deployed and installed. Only one
# with neither is a publish that stopped before its row.
TARBALL="$REPO_DIR/$NAME-$VERSION.tar.gz"
if [ -e "$TARBALL" ]; then
    echo "ERROR: $TARBALL already exists." >&2
    echo "" >&2
    if [ "$(catalogue_has "$NAME" "$VERSION")" = "DUPLICATE" ] \
       || git cat-file -e "HEAD:$TARBALL" 2> /dev/null; then
        echo "A published version is never rewritten: somebody may have installed it." >&2
        echo "Bump the module's version and publish that:" >&2
        echo "    dev/scripts/bump-analysis-version.sh module $NAME" >&2
    else
        echo "It has no catalogue row and was never committed, so nothing advertised it and no" >&2
        echo "installation can have taken it: it is left over from a publish that did not finish." >&2
        echo "Delete it and publish again." >&2
    fi
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

# A last line without its newline would put this row on the end of the one before it.
[ -z "$(tail -c 1 "$INDEX")" ] || echo >> "$INDEX"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NAME" "$KIND" "$VERSION" "$CONTRACT" "$FRAME" "$ENVIRONMENT" "$URL" "$SHA" "$SUMMARY" >> "$INDEX"

bash "$ROOT/dev/scripts/bump-analysis-version.sh" index > /dev/null

echo "Published $KIND $NAME $VERSION"
echo "  tarball : $TARBALL  ($(stat -c%s "$TARBALL") bytes)"
echo "  sha256  : $SHA"
echo "  url     : $URL"
echo "  index   : row added, #!index-version bumped"
# --all-pending says the rest once, after its last module.
[ -z "${PUBLISH_MODULE_BATCH:-}" ] || exit 0
echo ""
echo "Nothing is committed. The site deploys $REPO_DIR/ whole, after a release or when the"
echo "Documentation workflow is run by hand, so the tarball and the row that advertises it have"
echo "to land in the same commit."
