#!/usr/bin/env bash
#
# Regenerate a shipped environment file from an installed PoolSeqFlow environment.
#
# Usage:  dev/scripts/export-environment.sh [--check] [--allow-removals]
#                                           [environment-name [output-file]]
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
# --allow-removals permits an export that names FEWER packages than the file it replaces. That
# is refused by default because this regenerates from a LIVE environment: anything the file
# asked for that the environment never actually held is dropped here, permanently, and the
# release loses it with nothing saying so. typst went exactly that way on 2026-09-09.
#
# THE HOST FLOOR, AND THE DEFECT THAT PUT IT HERE
# -----------------------------------------------
# A conda package may depend on a VIRTUAL package - a `__`-prefixed name describing the machine
# rather than anything installable. `__glibc` is the one that matters here, and a constraint on
# it is a property of the host the export was taken on, frozen into a file that ships to every
# other host.
#
# v3.1.1 shipped environment-analysis.yml pinning `sysroot_linux-64=2.39`, which declares
# `__glibc >=2.39`. It solved on the machine that froze it, which reports `__glibc=2.44`, and
# could not be installed on any cluster older than that - the analysis layer was uninstallable
# on most HPC and nothing said so. Reported from a cluster on 2026-09-21.
#
# The toolchain did not ask for it. gcc_impl_linux-64, gxx_impl_linux-64 and
# binutils_impl_linux-64 all depend on a bare `sysroot_linux-64` with no version constraint, so
# the solver was free to take the newest the host allowed and did. Nothing in the environment
# needs a sysroot newer than the floor below.
#
# So the export declares the floor in the file's own header and refuses to write a file that
# breaks it. The header is what prep-version.sh reads to pull the floor back down after
# `conda update --all`, and what 00_static compares the pins against. One number, three readers.
#
# It is a FLOOR ON THE HOST, so a LOWER value reaches more machines: code built against
# sysroot 2.17 runs on glibc 2.17 and everything after it. Raising it drops machines and is a
# release decision, not a side effect of whoever ran the export.
#
# Two keys are stripped from conda's output:
#
#   prefix:  an absolute path into whoever ran the export.
#   name:    without it, `conda env create -f` refuses to run unless given -n. ./PoolSeqFlow
#            install passes -n, naming the environment after the release.

set -euo pipefail

CHECK_ONLY=0
ALLOW_REMOVALS=0
while :; do
    case "${1-}" in
        --check)          CHECK_ONLY=1;     shift ;;
        --allow-removals) ALLOW_REMOVALS=1; shift ;;
        *) break ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

# The oldest glibc a shipped environment may require of the host, and the authority for it.
# Written into every exported file's header, enforced below, and read back by prep-version.sh
# and by 00_static. Moving it is a release decision: see THE HOST FLOOR above.
HOST_GLIBC_FLOOR="2.17"

# Every package a conda env export names whose version would require a newer glibc than the
# floor, as `name version` pairs. sysroot_linux-64 is the only one today: its version IS the
# glibc it targets, which is what makes it checkable without asking conda anything. A package
# that raises the floor some other way is invisible here and is what the release-time check
# exists for.
host_floor_violations() {
    awk -v floor="$HOST_GLIBC_FLOOR" '
        /^dependencies:/ { d = 1; next }
        /^[a-z]/         { d = 0 }
        d && /^ *- *sysroot_linux-64=/ {
            spec = $0
            sub(/^ *- *sysroot_linux-64=/, "", spec)
            sub(/=.*/, "", spec)
            # Version compare, field by field, so 2.9 does not read as newer than 2.17.
            n = split(spec, a, "."); split(floor, b, ".")
            for (i = 1; i <= n; i++) {
                if ((a[i] + 0) > (b[i] + 0)) { print "sysroot_linux-64 " spec; break }
                if ((a[i] + 0) < (b[i] + 0)) break
            }
        }' "$1"
}

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
#
# TWO STORES AND THE SOURCES. A module can reach this environment from an installation's store
# or by being installed out of this checkout, so both are read - and `modules/` with it, because
# `$REPO_ROOT/analysis/modules` is the checkout's own store, which is gitignored and empty and
# says nothing at all. Reading it alone left this guard answering over nothing.
#
# THE BASELINE IS SUBTRACTED. Every module declares what it needs whether or not the release
# already carries it, so `r-ggplot2` appears in a manifest and in environment-analysis.yml both.
# Without this the guard refuses every export, which is the same failure as refusing none.
INSTALL="$REPO_ROOT"
POOLSEQFLOW_INSTALLED_HOME="${POOLSEQFLOW_INSTALLED_HOME:-}"
# shellcheck source=../../lib/wrapper_lib.sh
. "$REPO_ROOT/lib/wrapper_lib.sh"

INSTALLED_STORE="$(install_prefix)/opt/PoolSeqFlow-$VERSION/analysis/modules"
BASELINE=$(baseline_packages)
DECLARED=$( { store_packages "$REPO_ROOT/analysis/modules"
              store_packages "$REPO_ROOT/modules"
              store_packages "$REPO_ROOT/modules/lib"
              store_packages "$INSTALLED_STORE"; } | sort -u )
HELD=$(conda_installed_packages "$ENV_NAME")
CARRIED=""
while IFS= read -r SPEC; do
    [ -n "$SPEC" ] || continue
    printf '%s\n' "$BASELINE" | grep -qxF "${SPEC%%=*}" && continue
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
    echo "#"
    echo "# host-glibc-floor: $HOST_GLIBC_FLOOR"
    echo "#"
    echo "# The oldest glibc this file installs on. A package pinned here that requires a newer"
    echo "# one makes the release uninstallable on every older machine, which is a property of"
    echo "# whoever ran the export rather than of the software. Read by dev/scripts and checked"
    echo "# by the test suite; raising it drops machines and is a release decision."
    conda env export --name "$ENV_NAME" | sed -e '/^name:/d' -e '/^prefix:/d'
} > "$TMP"

# Every package a shipped environment file names, as bare names: the dependencies: block only,
# so the channel list is not read as packages, and only up to the first '=' so a version move
# is not a removal.
spec_names() {
    awk '/^dependencies:/ { d = 1; next }
         /^[a-z]/         { d = 0 }
         d && /^ *- / { sub(/^ *- */, ""); sub(/[=<> ].*/, ""); if ($0 != "") print }' "$1" | sort -u
}

if [ -f "$OUTPUT" ] && [ "$ALLOW_REMOVALS" -eq 0 ]; then
    LEAVING=$(comm -23 <(spec_names "$OUTPUT") <(spec_names "$TMP"))
    if [ -n "$LEAVING" ]; then
        echo "export-environment: this export would drop packages ${OUTPUT#"$REPO_ROOT"/} names:" >&2
        printf '%s\n' "$LEAVING" | sed 's/^/    /' >&2
        echo "" >&2
        echo "'$ENV_NAME' does not hold them, so the export describes a release without them." >&2
        echo "Usually the environment predates the line that asks for them. Put them in and" >&2
        echo "export again:" >&2
        echo "    conda install -n $ENV_NAME $(printf '%s ' $LEAVING)" >&2
        echo "" >&2
        echo "If they are meant to go, say so: --allow-removals" >&2
        exit 1
    fi
fi

# Checked on the generated content rather than on the environment, so it answers about the file
# that is one line from being written and not about something adjacent to it.
RAISING=$(host_floor_violations "$TMP")
if [ -n "$RAISING" ]; then
    echo "export-environment: '$ENV_NAME' would ship a file no older host can install:" >&2
    printf '%s\n' "$RAISING" | sed "s/^/    /; s/\$/  (floor is $HOST_GLIBC_FLOOR)/" >&2
    echo "" >&2
    echo "Those pins require a newer glibc than this release promises, so every machine below" >&2
    echo "it would fail to solve - as a cluster did on v3.1.1. Nothing in the environment asks" >&2
    echo "for them; the solver took what this host happened to allow. Pull them back down and" >&2
    echo "export again:" >&2
    echo "    conda install -n $ENV_NAME -c conda-forge sysroot_linux-64=$HOST_GLIBC_FLOOR" >&2
    echo "" >&2
    echo "If the release really is dropping those machines, move HOST_GLIBC_FLOOR in this" >&2
    echo "script, say so in the manual's Requirements, and write it in the CHANGELOG." >&2
    exit 1
fi

mv "$TMP" "$OUTPUT"
trap - EXIT

echo "Exported '$ENV_NAME' to ${OUTPUT#"$REPO_ROOT"/}"
echo "Check the diff before committing: git diff ${OUTPUT#"$REPO_ROOT"/}"
