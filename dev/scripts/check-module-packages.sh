#!/usr/bin/env bash
#
# Prove that a module's declared packages install into the shared analysis environment, come
# out again, and leave the other modules' packages behind.
#
# Usage:  dev/scripts/check-module-packages.sh [--keep]
#
# RUN THIS BY HAND, BEFORE A RELEASE. It is not in the test suite and must not be: it creates a
# real conda environment, solves it, and installs real packages from the network. That is
# minutes of work and a live network, which is the opposite of what a per-commit suite is for.
#
# WHAT IT PROVES, AND WHY THE SUITE CANNOT
# ----------------------------------------
# test/suites/02_launcher.sh runs the wrapper against a stub conda, so it can prove which conda
# command lines are issued and in what order - that an unpinned spec is refused before conda is
# reached, that a module declaring nothing issues no install, that a removal reads its plan
# first. It can prove nothing about whether a solve SUCCEEDS, because a stub always says yes.
#
# The guarantee is a solver behavior, so only a solver settles it - a release-time question,
# Z, 2026-09-03: "there is no real union, we test it here."
#
# THE FIRST RUN OF THIS SCRIPT FOUND THAT `--freeze-installed` DOES LESS THAN IT SOUNDS. It
# refuses to change a package the solve reaches on its own; a package NAMED ON THE COMMAND LINE
# it installs at the version asked for, downgrading what is there. A fixture pinning
# r-glue=1.8.0 against a baseline holding 1.8.1 downgraded it and reported success. That is why
# conda_install_packages refuses a disagreeing pin before conda is asked, and why the check for
# it below is here.
#
# WHAT IT DOES
# ------------
# Builds the baseline analysis environment from install/environment-analysis.yml under a
# throwaway name, then:
#
#   1. installs whatever the shipped modules declare, and checks the baseline did not move
#   2. installs fixture-a's pins and checks the solve succeeded
#   3. loads each one in R, because installing and importing are different failures
#   4. asks for a pin over a version the environment holds, and checks it is refused
#   5. installs fixture-b, which shares one pin, and checks fixture-a's versions did not move
#   6. removes what only fixture-a asked for, and checks fixture-b's survives and still loads
#   7. checks the baseline never lost a package across any of it
#
# The fixtures exist because F1, F2 and F3 declare nothing - cmdscale, p.adjust, pt and eigen
# are base R - so without them this script would pass by having done no work. They pin real
# conda-forge packages, and step 0 checks they are not in the baseline: the first pair chosen
# WAS, which made four checks meaningless before anyone noticed.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

INSTALL="$REPO_ROOT"
POOLSEQFLOW_INSTALLED_HOME="${POOLSEQFLOW_INSTALLED_HOME:-}"
# shellcheck source=../../lib/wrapper_lib.sh
. "$REPO_ROOT/lib/wrapper_lib.sh"

ENV_NAME="PoolSeqFlow-modulecheck-$$"
BASELINE_FILE="$REPO_ROOT/install/environment-analysis.yml"
FAILURES=0
BASELINE_PACKAGES=""

cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        echo ""
        echo "Environment kept: $ENV_NAME"
        echo "Remove it with:   conda env remove -n $ENV_NAME -y"
        return
    fi
    conda env remove -n "$ENV_NAME" -y >/dev/null 2>&1 || true
}
trap cleanup EXIT

say()  { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok    %s\n' "$1"; }
bad()  { printf '   FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# Every version an environment holds, as `name=version` lines, for comparing two moments.
env_versions() {
    conda list -n "$ENV_NAME" --export 2>/dev/null | grep -v '^#' | cut -d= -f1,2 | sort
}

# Whether R can load a package by the name it uses for it, which is not always conda's.
r_loads() {
    local pkg="$1"
    conda run -n "$ENV_NAME" Rscript --vanilla \
        -e "if (!requireNamespace('$pkg', quietly = TRUE)) quit(status = 1)" >/dev/null 2>&1
}

say "Building the baseline from ${BASELINE_FILE#"$REPO_ROOT"/}"
conda env create -n "$ENV_NAME" -f "$BASELINE_FILE" >/dev/null
BASELINE_PACKAGES=$(env_versions)
printf '   %s packages\n' "$(printf '%s\n' "$BASELINE_PACKAGES" | wc -l | tr -d ' ')"

# Whatever the shipped modules declare. None does today, so this is a no-op that becomes the
# most important check in the script the moment one gains a dependency: it is the release's own
# environment being asked to take its own modules' pins.
SHIPPED=$(store_packages "$REPO_ROOT/analysis/modules")
if [ -n "$SHIPPED" ]; then
    say "Installing what the shipped modules declare"
    printf '   %s\n' $SHIPPED
    # shellcheck disable=SC2086
    if OUT=$(conda_install_packages "$ENV_NAME" $SHIPPED 2>&1); then
        ok "the release's own modules install into the release's own environment"
    else
        bad "a module shipped in this release cannot install into its environment:"
        printf '%s\n' "$OUT" | tail -6 | sed 's/^/         /'
    fi
    MOVED=$(comm -23 <(printf '%s\n' "$BASELINE_PACKAGES") <(env_versions) || true)
    if [ -z "$MOVED" ]; then
        ok "and moved nothing the baseline pins"
    else
        bad "and moved these baseline packages:"
        printf '%s\n' "$MOVED" | sed 's/^/         /'
    fi
    BASELINE_PACKAGES=$(env_versions)
else
    say "No shipped module declares a package, so the fixtures below are the whole run"
fi

# The two fixture modules are pins rather than directories: what is being exercised is the
# solver, not the store, and the store's side is what 02_launcher already covers. Real
# conda-forge packages, small enough that the solve is a check rather than an afternoon.
# fixture-a takes both; fixture-b takes SHARED alone, so removing fixture-a has to leave SHARED
# behind - which is the shared-environment rule in one move.
SHARED=r-praise
SHARED_VERSION=1.0.0
ONLY_A=r-brio
ONLY_A_VERSION=1.1.5

# A fixture package the baseline already holds makes every check below meaningless: the install
# would be a version change rather than an addition, and the removal would take a baseline
# package out. This is not hypothetical - the first pair chosen for this script did exactly
# that, and the run reported four failures that were the fixtures' fault and not the code's.
say "Checking the fixtures are not in the baseline"
for PKG in "$SHARED" "$ONLY_A"; do
    if printf '%s\n' "$BASELINE_PACKAGES" | grep -q "^$PKG="; then
        bad "$PKG is in the baseline, so it cannot serve as a fixture. Pick another."
    else
        ok "$PKG is not in the baseline"
    fi
done
[ "$FAILURES" -eq 0 ] || { echo ""; echo "   fixtures unusable, stopping." >&2; exit 1; }

say "Installing fixture-a"
if OUT=$(conda_install_packages "$ENV_NAME" "$SHARED=$SHARED_VERSION" "$ONLY_A=$ONLY_A_VERSION" 2>&1); then
    ok "the solve succeeded with --freeze-installed"
else
    bad "the solve failed:"
    printf '%s\n' "$OUT" | tail -5 | sed 's/^/         /'
fi
AFTER_A=$(env_versions)

for PKG in "$SHARED" "$ONLY_A"; do
    if r_loads "${PKG#r-}"; then
        ok "R loads ${PKG#r-}"
    else
        bad "R cannot load ${PKG#r-} after installing it"
    fi
done

# The baseline is what every project gets. A module that moves one of its versions changes what
# every other module computes, which is the failure --freeze-installed exists to prevent.
MOVED=$(comm -23 <(printf '%s\n' "$BASELINE_PACKAGES") <(printf '%s\n' "$AFTER_A") || true)
if [ -z "$MOVED" ]; then
    ok "no baseline package changed version"
else
    bad "the baseline moved under the install:"
    printf '%s\n' "$MOVED" | sed 's/^/         /'
fi

# THE FINDING THIS SCRIPT EXISTS FOR. `--freeze-installed` covers what the solve reaches on its
# own and NOT what the command line names: conda installs a named pin at the version asked for,
# downgrading the baseline's copy without a word. The first run of this script did exactly that
# to r-glue, 1.8.1 -> 1.8.0, and reported success on the solve. conda_install_packages refuses
# a disagreeing pin before conda is asked, and this is the check that it still does.
say "A pin over a version the environment already holds"
HELD_SPEC=$(printf '%s\n' "$BASELINE_PACKAGES" | grep '^r-jsonlite=' | head -1)
if [ -z "$HELD_SPEC" ]; then
    bad "the baseline has no r-jsonlite to try this with; name another package it does hold"
else
    HELD_NAME="${HELD_SPEC%%=*}"
    if OUT=$(conda_install_packages "$ENV_NAME" "$HELD_NAME=0.0.1" 2>&1); then
        bad "a pin disagreeing with the installed version was accepted"
    else
        ok "refused"
        if printf '%s' "$OUT" | grep -q "already holds"; then
            ok "and said which environment it disagrees with"
        else
            bad "but the message did not explain why:"
            printf '%s\n' "$OUT" | tail -4 | sed 's/^/         /'
        fi
    fi
    NOW=$(env_versions)
    if printf '%s\n' "$NOW" | grep -qxF "$HELD_SPEC"; then
        ok "and $HELD_NAME is still at the version the release ships"
    else
        bad "$HELD_NAME moved anyway"
    fi
fi

say "Installing fixture-b, which pins one package fixture-a already pinned"
if OUT=$(conda_install_packages "$ENV_NAME" "$SHARED=$SHARED_VERSION" 2>&1); then
    ok "a second module asking for the same pin installs"
else
    bad "a second module asking for the same pin failed to install:"
    printf '%s\n' "$OUT" | tail -5 | sed 's/^/         /'
fi
AFTER_B=$(env_versions)
MOVED=$(comm -23 <(printf '%s\n' "$AFTER_A") <(printf '%s\n' "$AFTER_B") || true)
if [ -z "$MOVED" ]; then
    ok "and moved nothing fixture-a had installed"
else
    bad "the second install moved what the first put there:"
    printf '%s\n' "$MOVED" | sed 's/^/         /'
fi

say "Uninstalling fixture-a, with fixture-b still installed"
# What leaves is fixture-a's list minus what fixture-b still declares.
if OUT=$(conda_remove_packages "$ENV_NAME" "$ONLY_A" 2>&1); then
    ok "$ONLY_A came out"
else
    bad "$ONLY_A could not be removed:"
    printf '%s\n' "$OUT" | tail -6 | sed 's/^/         /'
fi
if r_loads "${SHARED#r-}"; then
    ok "$SHARED is still there and still loads"
else
    bad "$SHARED went with it"
fi
if r_loads "${ONLY_A#r-}"; then
    bad "$ONLY_A is still loadable after removal"
else
    ok "$ONLY_A is gone"
fi

AFTER_REMOVE=$(env_versions)
LOST=$(comm -23 <(printf '%s\n' "$BASELINE_PACKAGES") <(printf '%s\n' "$AFTER_REMOVE") || true)
if [ -z "$LOST" ]; then
    ok "the baseline never lost a package"
else
    bad "the baseline lost packages across the whole run:"
    printf '%s\n' "$LOST" | sed 's/^/         /'
fi

say "Result"
if [ "$FAILURES" -eq 0 ]; then
    echo "   every check passed."
    exit 0
fi
echo "   $FAILURES check(s) failed." >&2
exit 1
