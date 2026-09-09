#!/usr/bin/env bash
#
# Regenerate a shipped environment file from an installed PoolSeqFlow environment.
#
# Usage:  dev/scripts/export-environment.sh [--check] [environment-name [output-file]]
#
# With no argument the pipeline environment belonging to this working copy's version is
# exported, so the shipped file always describes the release it travels with. Pass a name to
# export a different one. A name ending in -analysis goes to install/environment-analysis.yml
# and any other to install/environment.yml; the second argument overrides that.
#
# --check runs the module-package refusal below and stops there, writing nothing. It answers
# "would an export of this environment be accepted?", which prep-version.sh asks before it
# spends an hour solving and testing an environment it would then be refused permission to
# freeze.
#
# Two keys are stripped from conda's output:
#
#   prefix:  an absolute path into whoever ran the export.
#   name:    without it, `conda env create -f` refuses to run unless given -n. ./PoolSeqFlow
#            install passes -n, naming the environment after the release.

set -euo pipefail

CHECK_ONLY=0
if [ "${1-}" = "--check" ]; then CHECK_ONLY=1; shift; fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
if [ -z "$VERSION" ]; then
    echo "export-environment: could not read VERSION from $REPO_ROOT/PoolSeqFlow" >&2
    exit 1
fi
ENV_NAME="${1:-PoolSeqFlow-$VERSION}"

# Which file the environment belongs in, and what its header should say it is named after.
case "$ENV_NAME" in
    *-analysis)
        DEFAULT_OUTPUT="$REPO_ROOT/install/environment-analysis.yml"
        DESCRIBED_AS="PoolSeqFlow analysis-layer conda environment"
        NAMED_AFTER="PoolSeqFlow-<version>-analysis"
        INSTALL_CMD="./PoolSeqFlow analysis install"
        ;;
    *)
        DEFAULT_OUTPUT="$REPO_ROOT/install/environment.yml"
        DESCRIBED_AS="PoolSeqFlow conda environment"
        NAMED_AFTER="PoolSeqFlow-<version>"
        INSTALL_CMD="./PoolSeqFlow install"
        ;;
esac
OUTPUT="${2:-$DEFAULT_OUTPUT}"

if ! conda env list | awk '{print $1}' | grep -qxF "$ENV_NAME"; then
    echo "export-environment: no conda environment named '$ENV_NAME'" >&2
    echo "Install it first:  $INSTALL_CMD" >&2
    exit 1
fi

# An installed module puts its own packages into the shared analysis environment. Exporting one
# in that state folds them into the baseline every project installs, permanently and invisibly -
# the module would then be un-uninstallable and the release would ship a dependency nothing
# declares. The export is refused instead, and the fix is to remove the modules and re-export.
#
# Only the module's OWN specs are looked for. What conda pulled in beneath them is not
# distinguishable here from what the baseline needed anyway, which is exactly why the answer is
# to rebuild the environment rather than to subtract from it.
INSTALL="$REPO_ROOT"
POOLSEQFLOW_INSTALLED_HOME="${POOLSEQFLOW_INSTALLED_HOME:-}"
# shellcheck source=../../lib/wrapper_lib.sh
. "$REPO_ROOT/lib/wrapper_lib.sh"

INSTALLED_STORE="$(install_prefix)/opt/PoolSeqFlow-$VERSION/analysis/modules"
DECLARED=$( { store_packages "$REPO_ROOT/analysis/modules"
              store_packages "$INSTALLED_STORE"; } | sort -u )
HELD=$(conda_installed_packages "$ENV_NAME")
CARRIED=""
while IFS= read -r SPEC; do
    [ -n "$SPEC" ] || continue
    if printf '%s\n' "$HELD" | grep -qxF "${SPEC%%=*}"; then
        CARRIED="$CARRIED    $SPEC"$'\n'
    fi
done <<< "$DECLARED"
if [ -n "$CARRIED" ]; then
    echo "export-environment: '$ENV_NAME' carries packages an analysis module declares:" >&2
    printf '%s' "$CARRIED" >&2
    echo "Exporting now would write them into the file every release installs from, where" >&2
    echo "nothing declares them and nothing can remove them. Take the modules out first:" >&2
    echo "    ./PoolSeqFlow analysis modules list" >&2
    echo "    ./PoolSeqFlow analysis modules uninstall <module>" >&2
    echo "or rebuild the environment from the shipped file and export that." >&2
    exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "'$ENV_NAME' carries nothing an analysis module declares - an export would be accepted."
    exit 0
fi

# Through a temporary file: a failed export must not leave a truncated file behind.
TMP=$(mktemp "$OUTPUT.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# Re-emitted every export: `conda env export` does not preserve comments, so anything written
# into the file by hand is lost.
{
    echo "# $DESCRIBED_AS, exported by dev/scripts/export-environment.sh"
    echo "#"
    echo "# Every tool is pinned to an exact build so a release always installs the same"
    echo "# software. Do not edit by hand: change the environment, then re-export."
    echo "#"
    echo "# There is no 'name:' key. Environments are named after the release"
    echo "# ($NAMED_AFTER), which is what $INSTALL_CMD supplies with -n."
    conda env export --name "$ENV_NAME" | sed -e '/^name:/d' -e '/^prefix:/d'
} > "$TMP"

mv "$TMP" "$OUTPUT"
trap - EXIT

echo "Exported '$ENV_NAME' to ${OUTPUT#"$REPO_ROOT"/}"
echo "Check the diff before committing: git diff ${OUTPUT#"$REPO_ROOT"/}"
