#!/usr/bin/env bash
#
# Is bin/config_migrate.sh ready for this release?
#
# Usage: dev/scripts/check-migration.sh [previous-tag]
#          default: the newest v* tag, which during a release is the release being replaced
#
# Migrates the previous release's parameters.config.template onto the current one in a scratch
# directory and prints the report a user would see. Nothing in the working tree is touched.
#
# Read the categories. Two of them are wrong in ways only a person can see: a RENAMED parameter
# with no line in renamed() arrives as one DROPPED plus one NEW, and a knob that is merely
# commented out in the new template is not a parameter that is gone.
#
# The one thing checked mechanically is that every NEW parameter is mentioned in the migration's
# own notes. That is a reminder rather than a refusal: a parameter whose absence changes nothing
# needs no note, and only a person knows which those are.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PREV="${1-}"
if [ -z "$PREV" ]; then
    PREV=$(git tag -l 'v*' --sort=-v:refname | head -1)
    [ -n "$PREV" ] || { echo "ERROR: no v* tag to migrate from; name one" >&2; exit 1; }
fi
git rev-parse --verify --quiet "$PREV^{commit}" > /dev/null \
    || { echo "ERROR: '$PREV' is not a commit this repository has" >&2; exit 1; }

git show "$PREV:parameters.config.template" > /dev/null 2>&1 \
    || { echo "ERROR: '$PREV' carries no parameters.config.template" >&2; exit 1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

git show "$PREV:parameters.config.template" > "$SCRATCH/parameters.config"
cp parameters.config.template "$SCRATCH/"

echo "Migrating a $PREV config onto the current template."
echo ""

REPORT="$SCRATCH/report.txt"
if ! ( cd "$SCRATCH" && bash "$ROOT/bin/config_migrate.sh" ) > "$REPORT" 2>&1; then
    cat "$REPORT"
    echo ""
    echo "ERROR: the migration itself failed." >&2
    exit 1
fi

sed -n '/^Kept your value/,$p' "$REPORT"

# Every parameter the report calls NEW, and whether the notes say anything about it.
NEW_KEYS=$(awk '/^New in this release/{f=1; next} /^$/{f=0} f && $1 != "none" {print $1}' "$REPORT")
if [ -n "$NEW_KEYS" ]; then
    echo "New parameters, and whether the migration explains each:"
    echo ""
    MISSING=0
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        if sed -n '/^Read these before your next run/,$p' "$REPORT" | grep -qF "$key"; then
            printf '  explained    %s\n' "$key"
        else
            printf '  NO NOTE      %s\n' "$key"
            MISSING=1
        fi
    done <<< "$NEW_KEYS"
    echo ""
    if [ "$MISSING" -eq 1 ]; then
        echo "A parameter whose absence changes nothing needs no note. For any that does, add one"
        echo "to the \"Read these before your next run\" section of bin/config_migrate.sh, giving"
        echo "the default and what to write for the other value."
    fi
fi
