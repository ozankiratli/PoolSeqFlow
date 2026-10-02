#!/usr/bin/env bash
#
# Lay out what a release's read of the manual needs.
#
# Usage: dev/scripts/check-manual-parameters.sh [previous-tag]
#          default: the newest tag, which during a release is the release being replaced
#
# Writes three scratch files into .tmp/release-review/. They are scratch: .tmp/ is gitignored and
# nothing reads them but a person. Delete the directory when the read is done.
#
#   commits.md      every commit since the previous tag, in the form bump-version.sh will prepend
#                   to the CHANGELOG, so the notes can be written against the real list.
#   manual.diff     the manual as published with that tag against the manual now. What changed
#                   since the last release is what has never been read in a release pass.
#   parameters.txt  every parameter a project may set, in the order parameters.config.template
#                   declares them, marked with whether the manual names it. The list to walk the
#                   manual against.
#
# WHAT IS ON THAT LIST IS WHAT A PROJECT SETS, and three kinds of assignment are therefore left
# off it:
#
#   nextflow.config   is the installation's, not a project's. A user edits parameters.config; a
#                     value here applies to every project on the machine and several of these
#                     lines exist precisely to set a default behind a template knob.
#   derived values    whose value references another parameter, so the pipeline computes them from
#                     what was set. The manual has a section for these as a class, and telling
#                     someone how to set one is the opposite of what it should say.
#   scopes            a key other keys nest under, which is a block and not a setting.
#
# A commented-out assignment stays on the list: uncommenting it is the user taking the value back,
# which is why it ships commented.
#
# THE MARK IS WHETHER THE MANUAL NAMES IT, which is not whether the manual documents it. Names are
# matched in backticks, because that is how the manual writes a setting and it is what tells
# `align` the parameter from "align" the verb. Whether the text says what the parameter does, and
# how to set it, is what you are reading for.
#
# dir.*, software.* and cores.* are each documented as a whole block rather than key by key, so a
# missing mark on one of those is not news and is not reported on stdout. Everything else is.
#
# No apostrophes in the awk below: the program is single-quoted and one would end it.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

MANUAL="manual/PoolSeqFlow-manual.md"
for f in "$MANUAL" parameters.config.template; do
    [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

PREV="${1-}"
if [ -z "$PREV" ]; then
    PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi

OUT=".tmp/release-review"
mkdir -p "$OUT"

# --------------------------------------------------------------- what to read against ---

if [ -z "$PREV" ]; then
    echo "No tag to compare against; writing the whole history and no diff."
    git log --no-merges --reverse --pretty='- (%h) %s' HEAD > "$OUT/commits.md"
    : > "$OUT/manual.diff"
else
    # The same range and the same --pretty as bump-version.sh, so this is the list that will
    # appear rather than a second rendering of it.
    git log --no-merges --reverse --pretty='- (%h) %s' "$PREV..HEAD" > "$OUT/commits.md"
    git diff "$PREV" -- "$MANUAL" > "$OUT/manual.diff" || true
fi

printf 'commits since %s : %s (%s commits)\n' "${PREV:-the start of history}" \
    "$OUT/commits.md" "$(wc -l < "$OUT/commits.md" | tr -d ' ')"
if [ -s "$OUT/manual.diff" ]; then
    printf 'manual since %s   : %s (%s changed lines)\n' "${PREV:-}" "$OUT/manual.diff" \
        "$(grep -cE '^[+-]' "$OUT/manual.diff" || true)"
else
    printf 'manual since %s   : unchanged\n' "${PREV:-}"
fi
echo ""

# ------------------------------------------------------------------ what a project sets ---

# Qualified by scope, in declaration order, derived values dropped.
settable() {
    awk '
        function qualify(k,  p, i) {
            p = ""
            for (i = 1; i <= depth; i++) p = p (p == "" ? "" : ".") stack[i]
            sub(/^params\.?/, "", p)
            return (p == "") ? k : p "." k
        }
        function literal(v) { return (index(v, "params.") == 0 && index(v, "${") == 0) }
        {
            line = $0; sub(/^[ \t]+/, "", line)
            if (line ~ /^\}/) { if (depth > 0) depth--; next }
            if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\{[ \t]*(\/\/.*)?$/) {
                name = line; sub(/[ \t]*\{.*$/, "", name); stack[++depth] = name; next
            }
            if (line ~ /^(\/\/[ \t]*)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
                commented = (line ~ /^\/\//)
                k = line; sub(/^\/\/[ \t]*/, "", k); sub(/[ \t]*=.*$/, "", k)
                v = line; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*\/\/.*$/, "", v)
                if (commented || literal(v)) print qualify(k)
            }
        }' parameters.config.template \
    | awk '
        # A key other keys nest under is a block, not a setting.
        { all[NR] = $0; n = NR }
        END {
            for (i = 1; i <= n; i++) {
                scope = 0
                for (j = 1; j <= n; j++) if (index(all[j], all[i] ".") == 1) { scope = 1; break }
                if (!scope) print all[i]
            }
        }'
}

# Named AS A PARAMETER: in backticks, by its own name or by its leaf, since the manual writes
# `adapterOptions` rather than `trim_galore.adapterOptions`.
named_in_manual() {   # key
    grep -qF "\`$1\`" "$MANUAL" && return 0
    grep -qF "\`params.$1\`" "$MANUAL" && return 0
    grep -qF "\`${1##*.}\`" "$MANUAL" && return 0
    return 1
}

MISSING=0
: > "$OUT/parameters.txt"
while read -r key; do
    [ -n "$key" ] || continue
    if named_in_manual "$key"; then
        printf '     %s\n' "$key" >> "$OUT/parameters.txt"
        continue
    fi
    printf '  ?  %s\n' "$key" >> "$OUT/parameters.txt"
    case $key in
        dir.*|software.*|cores.*) ;;
        *) echo "not named in the manual: $key"; MISSING=$((MISSING + 1)) ;;
    esac
done <<< "$(settable)"

printf 'what a project may set : %s (%s parameters, %s unnamed)\n' "$OUT/parameters.txt" \
    "$(wc -l < "$OUT/parameters.txt" | tr -d ' ')" \
    "$(grep -c '^  ?' "$OUT/parameters.txt" || true)"
echo "Remove $OUT when the read is done."

[ "$MISSING" -eq 0 ] || exit 1
