#!/usr/bin/env bash
#
# Bump the PoolSeqFlow version and add a CHANGELOG entry from the git log.
#
# Usage: dev/scripts/bump-version.sh <new-version>          e.g. 1.0.2
#        dev/scripts/bump-version.sh --revert               undo the bump that is in the tree
#
# --revert puts the version back to the last released tag and removes the CHANGELOG section this
# script added, with its reference link. A release cycle is often abandoned partway - a gate
# fails, or something turns up that should not ship - and the bump is then three edits across
# three files to undo by hand, which is how a half-reverted version reaches a commit. It refuses
# once the version has been tagged, because at that point it is published rather than prepared.
#
# Rewrites the version in the PoolSeqFlow wrapper (both the header comment and
# VERSION=) and in nextflow.config's manifest, and prepends a
# CHANGELOG section listing every commit since the last release tag under a "### Commits"
# heading, along with the matching reference-link definition at the foot of the file.
# Does not commit, tag, or push - it prints those commands for you.
#
# It does NOT touch a module or library manifest. No module ships inside a release, so a
# module's "environment" is the oldest release its author says it needs, moved when its needs
# move - not a field a release bump may rewrite on its behalf.
#
# Add release notes above that heading, not over it: the commit list stays in the
# changelog as the record of what landed.

set -euo pipefail

NEW="${1-}"
REVERT=0
if [ "$NEW" = "--revert" ]; then
    REVERT=1
elif [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <new-version>   (e.g. 1.0.2)" >&2
    echo "       $0 --revert        (undo the bump in the tree)" >&2
    exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [ "$REVERT" -eq 1 ]; then
    MAIN="PoolSeqFlow"
    LOG="CHANGELOG.md"
    NFCONFIG="nextflow.config"
    CURRENT="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$MAIN" | head -1)"
    [ -n "$CURRENT" ] || { echo "ERROR: no VERSION= line in $MAIN" >&2; exit 1; }

    # Tagged means published. Reverting then would leave the tree claiming a version older than
    # a release that exists, which is worse than the half-bumped state this is meant to fix.
    if git rev-parse -q --verify "refs/tags/v$CURRENT" > /dev/null; then
        echo "ERROR: v$CURRENT is tagged, so it is released rather than prepared." >&2
        echo "Reverting a published version is not what this does." >&2
        exit 1
    fi

    PREVIOUS="$(git tag --sort=-v:refname | head -1 | sed 's/^v//')"
    [ -n "$PREVIOUS" ] || { echo "ERROR: no release tag to go back to" >&2; exit 1; }
    [ "$PREVIOUS" != "$CURRENT" ] || {
        echo "ERROR: $MAIN is already at $PREVIOUS - there is no bump to revert." >&2; exit 1; }

    sed -i -E "s|^# Version: .*|# Version: $PREVIOUS|; s|^VERSION=\".*\"|VERSION=\"$PREVIOUS\"|" "$MAIN"
    sed -i -E "s|^(\s*version\s*=\s*)'.*'|\1'$PREVIOUS'|" "$NFCONFIG"

    # The section runs from its heading to the `---` that closes it, and the reference link sits
    # at the foot of the file. Both go, or the next bump refuses on a [x.y.z] section it finds.
    if grep -q "^## \[$CURRENT\]" "$LOG"; then
        awk -v v="$CURRENT" '
            $0 ~ "^## \\[" v "\\]" { dropping = 1; next }
            dropping && /^---$/    { dropping = 0; next }
            dropping               { next }
            $0 ~ "^\\[" v "\\]: "  { next }
            { print }
        ' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        # A section leaves one blank line behind where it was; the file is normalized rather
        # than left with a widening gap every time a cycle is abandoned.
        awk 'NF == 0 { blank++; if (blank > 1) next } NF { blank = 0 } { print }' \
            "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        LOGNOTE="the [$CURRENT] section and its link removed"
    else
        LOGNOTE="no [$CURRENT] section to remove"
    fi

    grep -q "^VERSION=\"$PREVIOUS\"$" "$MAIN" || {
        echo "ERROR: could not put VERSION= back in $MAIN" >&2; exit 1; }
    grep -q "version *= *'$PREVIOUS'" "$NFCONFIG" || {
        echo "ERROR: could not put the manifest version back in $NFCONFIG" >&2; exit 1; }

    echo "$CURRENT -> $PREVIOUS  (reverted)"
    echo "  $MAIN      : header comment and VERSION="
    echo "  $NFCONFIG : manifest version"
    echo "  $LOG   : $LOGNOTE"
    echo
    echo "Nothing was committed. Check it:"
    echo "  git diff $MAIN $NFCONFIG $LOG"
    exit 0
fi

MAIN="PoolSeqFlow"
# The wrapper carries the release twice, in its header comment and in VERSION=. release.yml
# and 00_static both refuse a disagreement between any of them.
WRAPPERS="PoolSeqFlow"
LOG="CHANGELOG.md"
for f in $WRAPPERS "$LOG"; do
    [ -f "$f" ] || { echo "ERROR: $f not found in $ROOT" >&2; exit 1; }
done

CURRENT="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$MAIN" | head -1)"
[ -n "$CURRENT" ] || { echo "ERROR: no VERSION= line in $MAIN" >&2; exit 1; }
[ "$NEW" != "$CURRENT" ] || { echo "ERROR: $MAIN is already at $NEW" >&2; exit 1; }
grep -q "^## \[$NEW\]" "$LOG" && { echo "ERROR: $LOG already has a [$NEW] section" >&2; exit 1; }

# Commits to describe: everything since the most recent tag, or the whole history
# if this is the first release.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
    RANGE="$LAST_TAG..HEAD"
else
    RANGE="HEAD"
fi

COMMITS="$(git log --no-merges --reverse --pretty='- (%h) %s' "$RANGE")"
if [ -z "$COMMITS" ]; then
    echo "ERROR: no commits since ${LAST_TAG:-the start of history} - nothing to release" >&2
    exit 1
fi

# The commit list gets its own subsection.
ENTRY="## [$NEW] - $(date +%F)

### Commits

$COMMITS

---
"

# Inserted above the newest existing section. The entry reaches awk through ENVIRON, not
# `-v entry=...`: POSIX makes -v assignments undergo escape-sequence processing, which would
# rewrite a commit subject containing \t or \n.
ENTRY="$ENTRY" awk '
    !inserted && /^## \[/ { print ENVIRON["ENTRY"]; inserted = 1 }
    { print }
    END { if (!inserted) print ENVIRON["ENTRY"] }
' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# The matching reference-link definition at the foot of the file: every `## [x.y.z]` heading is a
# Markdown reference link, and without one it renders as literal brackets. The base URL comes
# from the newest existing definition, so it follows the repository.
LINKBASE="$(sed -n 's|^\[[0-9][0-9.]*\]: \(https://.*\)/v[0-9][0-9.]*$|\1|p' "$LOG" | head -1)"
[ -n "$LINKBASE" ] || LINKBASE="https://github.com/ozankiratli/PoolSeqFlow/releases/tag"
LINK="[$NEW]: $LINKBASE/v$NEW"

if grep -qE '^\[[0-9]+\.[0-9]+\.[0-9]+\]: ' "$LOG"; then
    # Above the newest existing definition, keeping the list in descending order.
    LINK="$LINK" awk '
        !inserted && /^\[[0-9]+\.[0-9]+\.[0-9]+\]: / { print ENVIRON["LINK"]; inserted = 1 }
        { print }
    ' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
else
    printf '\n%s\n' "$LINK" >> "$LOG"
fi

for wrapper in $WRAPPERS; do
    sed -i -E "s|^# Version: .*|# Version: $NEW|; s|^VERSION=\".*\"|VERSION=\"$NEW\"|" "$wrapper"
    grep -q "^VERSION=\"$NEW\"$" "$wrapper" || {
        echo "ERROR: could not update VERSION= in $wrapper" >&2; exit 1; }
    grep -q "^# Version: $NEW$" "$wrapper" || {
        echo "ERROR: could not update the header comment in $wrapper" >&2; exit 1; }
done

# The version also lives in nextflow.config's manifest, and release.yml refuses to publish if it
# disagrees with $MAIN.
NFCONFIG="nextflow.config"
[ -f "$NFCONFIG" ] || { echo "ERROR: $NFCONFIG not found" >&2; exit 1; }
sed -i -E "s|^(\s*version\s*=\s*)'.*'|\1'$NEW'|" "$NFCONFIG"
grep -q "version *= *'$NEW'" "$NFCONFIG" || {
    echo "ERROR: could not update the manifest version in $NFCONFIG" >&2; exit 1; }

echo "$CURRENT -> $NEW"
for wrapper in $WRAPPERS; do
    echo "  $wrapper : $(grep -cF "$NEW" "$wrapper") references updated"
done
echo "  $NFCONFIG : manifest version updated"
echo "  $LOG   : $(printf '%s\n' "$COMMITS" | wc -l) commits since ${LAST_TAG:-start}, link definition added"
echo
echo "Review, then:"
echo "  git add -A && git commit -m 'Version bump $NEW'"
echo "  git tag v$NEW"
