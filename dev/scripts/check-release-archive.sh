#!/usr/bin/env bash
#
# Does the published release archive install?
#
# Usage: dev/scripts/check-release-archive.sh [version]
#          default: the version this working copy declares
#
# Downloads the tarball and SHA256SUMS from the GitHub release, verifies the checksum, extracts
# it, and installs into a throwaway prefix removed on every exit. Real network, minutes. Run it
# after the tag is pushed and the workflow has finished, because it fetches what was published
# rather than what is in the tree.
#
# POOLSEQFLOW_PREFIX is what keeps it out of the way: install_prefix() returns it when set and
# bindir is "$prefix/bin", so the payload and every command link land inside the sandbox and
# $HOME/.local/bin is untouched.
#
# WHAT IT DOES NOT ANSWER, because it cannot from here:
#
#   The conda environment is reused when it is already present. `install` derives the name from
#   the version alone - ENV_NAME="PoolSeqFlow-${VERSION}" - so a machine that has run the release
#   suite already holds it and the install prints "already exists" rather than creating one. This
#   answers whether the ARCHIVE is complete and deployable. Whether the environment FILES solve
#   from nothing is answered by check-exported-floor.sh before the export.
#
#   Nothing about a host unlike this one. Three of the four defects in
#   .claude/development-notes/someone-elses-machine.md were found by running on a cluster and a
#   server, and the suite was green for every one of them.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

V="${1-}"
if [ -z "$V" ]; then
    V="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow | head -1)"
    [ -n "$V" ] || { echo "ERROR: no VERSION= line in ./PoolSeqFlow; name a version" >&2; exit 1; }
fi

command -v curl > /dev/null || { echo "ERROR: curl is not on PATH" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

BASE="https://github.com/ozankiratli/PoolSeqFlow/releases/download/v$V"
echo "Fetching the published v$V archive into $SANDBOX"

cd "$SANDBOX"
# -f so a 404 is a failure rather than a file containing GitHub's error page.
curl -fsSLO "$BASE/PoolSeqFlow-$V.tar.gz" \
    || { echo "ERROR: no published archive at $BASE/PoolSeqFlow-$V.tar.gz" >&2; exit 1; }
curl -fsSLO "$BASE/SHA256SUMS" \
    || { echo "ERROR: no SHA256SUMS at $BASE" >&2; exit 1; }

echo ""
echo "Checksum:"
sha256sum --ignore-missing -c SHA256SUMS

tar -xzf "PoolSeqFlow-$V.tar.gz"
cd "PoolSeqFlow-$V"
cp parameters.config.template parameters.config

export POOLSEQFLOW_PREFIX="$SANDBOX/prefix"
echo ""
echo "Installing into $POOLSEQFLOW_PREFIX"
echo ""
./PoolSeqFlow install
./PoolSeqFlow analysis install
./PoolSeqFlow check install

echo ""
echo "The published v$V archive installs. The sandbox is being discarded."
