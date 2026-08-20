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
# Kept here rather than inline in the workflows so the two cannot drift, and so
# it can be run locally before pushing. dev/ carries export-ignore, so this file
# never ships to a user.

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

# Everything a run needs.
for f in PoolSeqFlow poolseqflow.nf nextflow.config \
         parameters.config.template RGTags.csv.template \
         install/environment.yml install/check_install.sh \
         LICENSE README.md CHANGELOG.md; do
    [ -f "$root/$f" ] || fail "missing from archive: $f"
done

# All nine step modules, not however many happened to be committed.
steps_found=$(find "$root/scripts" -name '*.nf' | wc -l)
[ "$steps_found" -eq 9 ] || fail "expected 9 scripts/*.nf, found $steps_found"

# The helpers the process scripts call by bare name via nextflow.config's PATH.
for f in atomic_mv.sh config_migrate.sh createDepthFile.sh \
         depth2freq.awk filterFalsePositives.sh MajorAlleleToRef.py; do
    [ -f "$root/bin/$f" ] || fail "missing from archive: bin/$f"
done

# Repository furniture must NOT ship. This is the other half of .gitattributes:
# if an export-ignore is dropped, this catches it.
for f in docs .github mkdocs.yml .gitignore .gitattributes dev Project; do
    [ ! -e "$root/$f" ] || fail "should have been export-ignored: $f"
done

# Compiled Python must not ship: it is one machine's bytecode for one interpreter
# version, and it is regenerated on first use anyway. bin/__pycache__ was tracked and
# did ship until 2.3.0. Note the executable-bit loop below would not catch it - a
# directory carries the execute bit, so __pycache__ passes that check.
if find "$root" \( -name '__pycache__' -o -name '*.pyc' \) -print -quit | grep -q .; then
    fail "compiled Python found in the archive"
fi

# The executable bit is the whole reason for git archive over tar.
[ -x "$root/PoolSeqFlow" ] || fail "./PoolSeqFlow is not executable"
for s in "$root"/bin/*; do
    [ -x "$s" ] || fail "$(basename "$s") is not executable"
done

# The version the extracted copy would report, in all three places it lives.
grep -q "^VERSION=\"${version}\"$" "$root/PoolSeqFlow" \
    || fail "extracted wrapper does not report ${version}"
grep -q "^# Version: ${version}$" "$root/PoolSeqFlow" \
    || fail "extracted wrapper's header comment does not say ${version}"
grep -q "version *= *'${version}'" "$root/nextflow.config" \
    || fail "extracted nextflow.config manifest does not say ${version}"

echo "${OUT}/${name}.tar.gz"
