#!/bin/bash
#
# Verify a PoolSeqFlow analysis-layer installation before a module depends on it.
#
# Usage:  ./PoolSeqFlow-analysis check     (the wrapper activates the environment first)
#
# Checks three things:
#   1. Every command an analysis module invokes resolves and runs, with its version.
#   2. Every R package this release pins loads, with its version.
#   3. The analysis entry point is present.
#
# The package list is read from install/environment-analysis.yml, so it cannot drift from
# what the environment was built from.

set -uo pipefail

# Two directories: the installation holds the entry point and the environment file, the
# directory this was invoked from is the project. Captured before the cd.
PROJECT_DIR="$PWD"
cd "$(dirname "$0")/.." || exit 1
INSTALL_DIR="$PWD"

# Which environment this copy expects: from ./PoolSeqFlow-analysis's export, or read out of
# the wrapper when this script is run directly.
if [ -z "${ENV_NAME:-}" ]; then
    _version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow-analysis 2>/dev/null | head -1)
    ENV_NAME="PoolSeqFlow${_version:+-$_version}-analysis"
fi

# Read by analysis_r_packages, which is the one list of what this release pins.
ENV_FILE="$INSTALL_DIR/install/environment-analysis.yml"

RED=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    DIM=$'\033[2m'; RESET=$'\033[0m'
fi

missing=0
checked=0

# The commands an analysis module runs. R and Rscript are the layer itself; the rest derive
# per-position depth from the BAMs a run produced.
CANONICAL="R Rscript nextflow samtools bcftools tabix bgzip python3"

# Checked first: this runs without `set -e`, so a missing library would leave the functions
# below undefined and the report would be quietly wrong rather than absent.
for _lib in tool_version.sh wrapper_lib.sh; do
    [ -f "$INSTALL_DIR/lib/$_lib" ] || {
        echo "ERROR: $INSTALL_DIR/lib/$_lib is missing." >&2
        echo "  This installation is incomplete; reinstall it." >&2
        exit 1
    }
done

# Shared with the pipeline's check, so the two report versions the same way.
. "$INSTALL_DIR/lib/tool_version.sh"

# Shared with the wrapper, for analysis_r_packages.
. "$INSTALL_DIR/lib/wrapper_lib.sh"

check_tool() {
    local name="$1" cmd="$2" resolved version
    checked=$((checked + 1))

    if ! resolved=$(command -v "$cmd" 2>/dev/null); then
        printf '  %-14s %-12s %sMISSING%s  %s\n' "$name" "$cmd" "$RED" "$RESET" "not on PATH"
        missing=$((missing + 1))
        return
    fi

    version=$(tool_version "$name" "$cmd")
    if [ -z "$version" ]; then
        printf '  %-14s %-12s %sFOUND%s    %s(version not reported)%s\n' \
            "$name" "$cmd" "$YELLOW" "$RESET" "$DIM" "$RESET"
    else
        printf '  %-14s %-12s %sOK%s       %s\n' "$name" "$cmd" "$GREEN" "$RESET" "$version"
    fi
}

echo "PoolSeqFlow analysis layer installation check"
echo "============================================"
echo

# ----------------------------------------------------------------- 1. tools --

echo "Tools"
echo

for n in $CANONICAL; do
    check_tool "$n" "$n"
done
echo

# -------------------------------------------------------------- 2. packages --

echo "R packages"
echo

if [ ! -f "$ENV_FILE" ]; then
    printf '  %-28s %sMISSING%s  cannot tell what this release pins\n' \
        "environment-analysis.yml" "$RED" "$RESET"
    missing=$((missing + 1))
elif ! command -v Rscript >/dev/null 2>&1; then
    printf '  %-28s %sSKIPPED%s  Rscript not available\n' "all packages" "$YELLOW" "$RESET"
else
    # Asked of R one package at a time, so a failure names the package that failed rather
    # than ending the report. conda spells them r-<name> and R's own name may differ in
    # case, so the installed name is recovered case-insensitively.
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        checked=$((checked + 1))
        version=$(Rscript --vanilla -e '
            w <- commandArgs(trailingOnly = TRUE)[1]
            m <- rownames(installed.packages())
            m <- m[tolower(m) == tolower(w)]
            if (length(m)) cat(m[1], as.character(packageVersion(m[1])))
        ' "$pkg" 2>/dev/null)
        if [ -z "$version" ]; then
            printf '  %-28s %sMISSING%s  R cannot find it\n' "$pkg" "$RED" "$RESET"
            missing=$((missing + 1))
        else
            printf '  %-28s %sOK%s       %s\n' "${version%% *}" "$GREEN" "$RESET" "${version#* }"
        fi
    done < <(analysis_r_packages)
fi
echo

# ----------------------------------------------------------- 3. entry point --

echo "Analysis layer"
echo

checked=$((checked + 1))
if [ -f "$INSTALL_DIR/analysis.nf" ]; then
    printf '  %-28s %sOK%s\n' "analysis.nf" "$GREEN" "$RESET"
else
    printf '  %-28s %sMISSING%s  in %s\n' "analysis.nf" "$RED" "$RESET" "$INSTALL_DIR"
    missing=$((missing + 1))
fi
echo

# ---------------------------------------------------------------- summary ----

if [ "$missing" -eq 0 ]; then
    echo "${GREEN}All $checked checks passed.${RESET}"
    exit 0
fi

echo "${RED}$missing of $checked checks failed.${RESET}"
echo
echo "If tools or packages are missing, the environment is either not active or not built:"
echo "  ./PoolSeqFlow-analysis install"
echo "  conda activate $ENV_NAME"
exit 1
