#!/usr/bin/env bash
#
# Bump the PoolSeqFlow version and add a CHANGELOG entry from the git log.
#
# Usage: dev/scripts/bump-version.sh <new-version>          e.g. 1.0.2
#
# Rewrites the version in the PoolSeqFlow wrapper (both the header comment and
# VERSION=) and prepends a CHANGELOG section listing every commit since the last
# release tag under a "### Commits" heading, along with the matching reference-link
# definition at the foot of the file. Does not commit, tag, or push - it prints those
# commands for you.
#
# Add release notes above that heading, not over it: the commit list stays in the
# changelog as the record of what landed.

set -euo pipefail

NEW="${1-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <new-version>   (e.g. 1.0.2)" >&2
    exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

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
echo "  git add $WRAPPERS $NFCONFIG $LOG && git commit -m 'Version bump $NEW'"
echo "  git tag v$NEW"
