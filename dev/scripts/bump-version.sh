#!/usr/bin/env bash
#
# Bump the PoolSeqFlow version and add a CHANGELOG entry from the git log.
#
# Usage: dev/scripts/bump-version.sh <new-version>          e.g. 1.0.2
#
# Rewrites the version in the PoolSeqFlow wrapper (both the header comment and
# VERSION=) and prepends a CHANGELOG section listing every commit since the last
# release tag under a "### Commits" heading. Does not commit, tag, or push - it
# prints those commands for you.
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
LOG="CHANGELOG.md"
for f in "$MAIN" "$LOG"; do
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

COMMITS="$(git log --no-merges --reverse --pretty='- %s (%h)' "$RANGE")"
if [ -z "$COMMITS" ]; then
    echo "ERROR: no commits since ${LAST_TAG:-the start of history} - nothing to release" >&2
    exit 1
fi

# The commit list goes in its own subsection so hand-written notes can be added
# above it without displacing it. It is the record of what actually landed - keep
# it, and write the prose around it rather than in place of it.
ENTRY="## [$NEW] - $(date +%F)

### Commits

$COMMITS

---
"

# Insert above the newest existing section.
#
# The entry reaches awk through the environment rather than `-v entry=...`: POSIX requires
# -v assignments to undergo escape-sequence processing, so a commit subject containing \t
# or \n would be rewritten on its way in - a literal backslash-t becoming a tab, and a
# backslash-n injecting a bare line into the commit list. ENVIRON does no such processing.
ENTRY="$ENTRY" awk '
    !inserted && /^## \[/ { print ENVIRON["ENTRY"]; inserted = 1 }
    { print }
    END { if (!inserted) print ENVIRON["ENTRY"] }
' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

sed -i -E "s|^# Version: .*|# Version: $NEW|; s|^VERSION=\".*\"|VERSION=\"$NEW\"|" "$MAIN"

# The version also lives in nextflow.config's manifest, which is what Nextflow reports and
# what step 0 records alongside a project's outputs. release.yml refuses to publish if it
# disagrees with $MAIN, so it has to move at the same time.
NFCONFIG="nextflow.config"
[ -f "$NFCONFIG" ] || { echo "ERROR: $NFCONFIG not found" >&2; exit 1; }
sed -i -E "s|^(\s*version\s*=\s*)'.*'|\1'$NEW'|" "$NFCONFIG"
grep -q "version *= *'$NEW'" "$NFCONFIG" || {
    echo "ERROR: could not update the manifest version in $NFCONFIG" >&2; exit 1; }

echo "$CURRENT -> $NEW"
echo "  $MAIN  : $(grep -cF "$NEW" "$MAIN") references updated"
echo "  $NFCONFIG : manifest version updated"
echo "  $LOG   : $(printf '%s\n' "$COMMITS" | wc -l) commits since ${LAST_TAG:-start}"
echo
echo "Review, then:"
echo "  git add $MAIN $NFCONFIG $LOG && git commit -m 'Version bump $NEW'"
echo "  git tag v$NEW"
