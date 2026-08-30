#!/usr/bin/env bash
#
# Regenerate install/environment.yml from an installed PoolSeqFlow environment.
#
# Usage:  dev/scripts/export-environment.sh [environment-name]
#
# With no argument the environment belonging to this working copy's version is exported, so
# the shipped file always describes the release it travels with. Pass a name to export a
# different one.
#
# Two keys are stripped from conda's output:
#
#   prefix:  an absolute path into whoever ran the export.
#   name:    without it, `conda env create -f` refuses to run unless given -n. ./PoolSeqFlow
#            install passes -n, naming the environment after the release.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
OUTPUT="$REPO_ROOT/install/environment.yml"

VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
if [ -z "$VERSION" ]; then
    echo "export-environment: could not read VERSION from $REPO_ROOT/PoolSeqFlow" >&2
    exit 1
fi
ENV_NAME="${1:-PoolSeqFlow-$VERSION}"

if ! conda env list | awk '{print $1}' | grep -qxF "$ENV_NAME"; then
    echo "export-environment: no conda environment named '$ENV_NAME'" >&2
    echo "Install it first:  ./PoolSeqFlow install" >&2
    exit 1
fi

# Through a temporary file: a failed export must not leave a truncated environment.yml behind.
TMP=$(mktemp "$OUTPUT.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# Re-emitted every export: `conda env export` does not preserve comments, so anything written
# into the file by hand is lost.
{
    echo "# PoolSeqFlow conda environment, exported by dev/scripts/export-environment.sh"
    echo "#"
    echo "# Every tool is pinned to an exact build so a release always installs the same"
    echo "# software. Do not edit by hand: change the environment, then re-export."
    echo "#"
    echo "# There is no 'name:' key. Environments are named after the release"
    echo "# (PoolSeqFlow-<version>), which is what ./PoolSeqFlow install supplies with -n."
    conda env export --name "$ENV_NAME" | sed -e '/^name:/d' -e '/^prefix:/d'
} > "$TMP"

mv "$TMP" "$OUTPUT"
trap - EXIT

echo "Exported '$ENV_NAME' to ${OUTPUT#"$REPO_ROOT"/}"
echo "Check the diff before committing: git diff install/environment.yml"
