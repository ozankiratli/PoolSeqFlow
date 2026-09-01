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

# Everything a run needs.
for f in PoolSeqFlow poolseqflow.nf analysis.nf nextflow.config \
         parameters.config.template metadata.csv.template \
         analysis/modules.nf analysis/0_verify_analysis.nf analysis/frame.config \
         analysis/analysis.config.template \
         install/environment.yml install/environment-analysis.yml \
         install/check_install.sh install/check_analysis_install.sh \
         LICENSE README.md CHANGELOG.md; do
    [ -f "$root/$f" ] || fail "missing from archive: $f"
done

# Every module poolseqflow.nf includes, named rather than counted.
for f in 0_verify_environment.nf 1_build_dictionaries.nf 2_trim_reads.nf 3_align.nf \
         4_clean.nf 5_reports.nf 6_variant_call.nf 7_vcf2freq.nf 8_annotate_variants.nf \
         9_completion.nf citations.nf metadata.nf resolve_parameters.nf variants.nf; do
    [ -f "$root/scripts/$f" ] || fail "missing from archive: scripts/$f"
done

# The helpers the process scripts call by bare name via nextflow.config's PATH.
for f in atomic_mv.sh config_migrate.sh createDepthFile.sh \
         depth2freq.awk filterFalsePositives.sh MajorAlleleToRef.py; do
    [ -f "$root/bin/$f" ] || fail "missing from archive: bin/$f"
done

# Repository furniture must NOT ship: the other half of .gitattributes' export-ignore.
for f in docs .github mkdocs.yml .gitignore .gitattributes dev Project; do
    [ ! -e "$root/$f" ] || fail "should have been export-ignored: $f"
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
