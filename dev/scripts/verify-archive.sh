#!/usr/bin/env bash
#
# Build the release archive from a git ref and check it is a working copy of the
# pipeline. Used by both .github/workflows/ci.yml (on every pull request, so a
# problem surfaces in review) and release.yml (before publishing).
#
# Usage: dev/scripts/verify-archive.sh [ref] [outdir]
#          defaults: HEAD  dist
#
# Prints the path of the archive it built on success.
#
# dev/ carries export-ignore, so this file never ships to a user.

set -euo pipefail

REF="${1:-HEAD}"
OUT="${2:-dist}"

fail() { echo "ARCHIVE CHECK FAILED: $*" >&2; exit 1; }

version=$(git show "${REF}:PoolSeqFlow" | sed -n 's/^VERSION="\(.*\)"$/\1/p')
[ -n "$version" ] || fail "no VERSION= line in ./PoolSeqFlow at ${REF}"

name="PoolSeqFlow-${version}"
mkdir -p "$OUT"
git archive --format=tar.gz --prefix="${name}/" -o "${OUT}/${name}.tar.gz" "$REF"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "${OUT}/${name}.tar.gz" -C "$tmp"
root="${tmp}/${name}"

# The entry points and the files a user edits. Their absence is a different failure from the one
# below: not "it did not ship" but "it is not there any more".
for f in PoolSeqFlow poolseqflow.nf analysis.nf dryrun.nf nextflow.config \
         parameters.config.template metadata.csv.template multi-run.csv.example \
         LICENSE README.md CHANGELOG.md; do
    [ -f "$root/$f" ] || fail "missing from archive: $f"
done

# EVERYTHING ELSE THE REPOSITORY TRACKS MUST SHIP TOO, enumerated from the ref so that a file
# added to bin/ or to analysis/lib/ is covered without being named anywhere.
#
# What is deliberately kept out of a release, and the only paths that are. NAMED HERE, not read
# from .gitattributes: an export-ignore added by accident would take the file out of this check
# as well as out of the archive, and the check would pass. So an export-ignore fails here until
# it is named in this list too.
excluded='docs/ .github/ mkdocs.yml .gitignore .gitattributes dev/ Project/ test/
          analysis/modules/*/test/ analysis/modules-index.tsv'

# Whether one tracked path is meant to reach the archive at all.
ships() {
    local path="$1" pat
    for pat in $excluded; do
        case "$pat" in
            # A pattern holding a wildcard is matched as one, so a rule can cover every module
            # without naming any of them. Tested first: these also end in a slash.
            *'*'*) case "$path" in $pat*) return 1 ;; esac ;;
            */) case "$path" in "$pat"*) return 1 ;; esac ;;
            *)  if [ "$path" = "$pat" ]; then return 1; fi ;;
        esac
    done
    return 0
}

checked=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    ships "$f" || continue
    [ -f "$root/$f" ] || fail "missing from archive: $f"
    checked=$((checked + 1))
done <<< "$(git ls-tree -r --name-only "$REF")"

# An enumeration that found nothing would pass against an empty archive.
[ "$checked" -gt 40 ] \
    || fail "only ${checked} file(s) enumerated at ${REF}; this check is not reading the release"

# Repository furniture must NOT ship: the other half of .gitattributes' export-ignore.
for f in docs .github mkdocs.yml .gitignore .gitattributes dev Project; do
    [ ! -e "$root/$f" ] || fail "should have been export-ignored: $f"
done

# The same for a module's own cases, which no wildcard above would have caught: `ships` only
# says a path need not be there, and a rule that stopped working would go unnoticed without
# somebody looking for the file.
for d in "$root"/analysis/modules/*/test; do
    [ ! -e "$d" ] || fail "should have been export-ignored: ${d#$root/}"
done

# Compiled Python must not ship. Checked here and not by the executable-bit loop below, which a
# directory passes.
if find "$root" \( -name '__pycache__' -o -name '*.pyc' \) -print -quit | grep -q .; then
    fail "compiled Python found in the archive"
fi

# The executable bit, which the extracted copy must carry. Everything in bin/ is run; the
# libraries another script sources live in lib/ and need no such bit.
[ -x "$root/PoolSeqFlow" ] || fail "./PoolSeqFlow is not executable"
for s in "$root"/bin/*; do
    [ -x "$s" ] || fail "$(basename "$s") is not executable"
done
for s in tool_version.sh wrapper_lib.sh; do
    [ -f "$root/lib/$s" ] || fail "missing from archive: lib/$s"
done

# The version the extracted copy would report, in every place it lives.
grep -q "^VERSION=\"${version}\"$" "$root/PoolSeqFlow" \
    || fail "extracted PoolSeqFlow does not report ${version}"
grep -q "^# Version: ${version}$" "$root/PoolSeqFlow" \
    || fail "extracted PoolSeqFlow header comment does not say ${version}"
grep -q "version *= *'${version}'" "$root/nextflow.config" \
    || fail "extracted nextflow.config manifest does not say ${version}"

echo "${OUT}/${name}.tar.gz"
