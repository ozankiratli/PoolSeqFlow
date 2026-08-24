#!/bin/bash
#
# Verify a PoolSeqFlow installation before a run depends on it.
#
# Usage:  ./PoolSeqFlow check          (the wrapper activates the environment first)
#
# Checks three things:
#   1. Every command the pipeline invokes resolves and runs, with its version.
#   2. Every helper in bin/ is present and executable.
#   3. If parameters.config exists, that Nextflow can parse it.
#
# Where the tool list comes from
# ------------------------------
# With a parameters.config present the commands are read from `params.software`
# through `nextflow config`, so a command repointed at a system binary is checked
# as configured rather than as shipped. That override is the setting most likely
# to be wrong and least likely to announce itself at run time - a missing tool
# fails in the middle of step 4, hours in.
#
# Without one - a fresh install, before there is anything to configure - the
# canonical list below is used instead.

set -uo pipefail

# Two directories, and they are no longer the same one. The installation holds the tools,
# the helpers and nextflow.config; the directory the check was invoked from is the project
# and holds parameters.config. Captured before the cd, because everything below runs from
# the installation.
PROJECT_DIR="$PWD"
cd "$(dirname "$0")/.." || exit 1
INSTALL_DIR="$PWD"

# Which environment this copy expects. ./PoolSeqFlow exports it; derived from the same
# source here so the epilogue still names the right one when this script is run directly,
# and so the name can never be stale relative to the launcher. Under `set -u` an unset
# variable would abort the run outright, which is the other reason this is not left to the
# caller.
if [ -z "${ENV_NAME:-}" ]; then
    _version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow 2>/dev/null | head -1)
    ENV_NAME="PoolSeqFlow${_version:+-$_version}"
fi

RED=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    DIM=$'\033[2m'; RESET=$'\033[0m'
fi

missing=0
checked=0

# Tools the pipeline runs, as params.software names them. `nextflow` is not in
# that block - it is the engine rather than a pipeline tool - but nothing works
# without it, and python3/awk carry bin/ helpers, so all three are checked too.
CANONICAL="java cutadapt fastqc trim_galore samtools bamtools bwa bcftools vcftools snpEff unzip"

# Ask a tool for its version. Every one of these answers differently, and several
# report on stderr or exit non-zero while doing it, so each is handled by name and
# the result is only ever used for display.
tool_version() {
    local name="$1" cmd="$2" raw=""
    case "$name" in
        java)     raw=$("$cmd" -version 2>&1) ;;
        bwa)      raw=$("$cmd" 2>&1 | sed -n 's/^Version: *//p') ;;
        snpEff)   raw=$("$cmd" -version 2>&1) ;;
        unzip)    raw=$("$cmd" -v 2>&1) ;;
        nextflow) raw=$("$cmd" -version 2>&1 | sed -n 's/.*version *//p') ;;
        *)        raw=$("$cmd" --version 2>&1) ;;
    esac
    # First non-empty line. bamtools leads with a blank line and several tools
    # follow the version with a banner, so neither `head -1` nor the whole output
    # is right on its own. Tabs are squeezed too - snpEff separates with them.
    printf '%s' "$(printf '%s\n' "$raw" | grep -m1 . | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')"
}

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
        # It resolved but would not report a version. Not fatal - some tools
        # simply have no version flag - but worth seeing.
        printf '  %-14s %-12s %sFOUND%s    %s(version not reported)%s\n' \
            "$name" "$cmd" "$YELLOW" "$RESET" "$DIM" "$RESET"
    else
        printf '  %-14s %-12s %sOK%s       %s\n' "$name" "$cmd" "$GREEN" "$RESET" "$version"
    fi
}

echo "PoolSeqFlow installation check"
echo "=============================="
echo

# ----------------------------------------------------------------- 1. tools --

echo "Tools"
echo

declare -a NAMES=() CMDS=()
source_note=""

# Say which list is in use and, when it is the fallback, why - "no config yet" and
# "nextflow could not read the config" send you to very different places.
if [ ! -f "$PROJECT_DIR/parameters.config" ]; then
    source_note="canonical list - no parameters.config in $PROJECT_DIR"
elif ! command -v nextflow >/dev/null 2>&1; then
    source_note="canonical list - nextflow not available to read parameters.config"
else
    # Values are interpolated by Nextflow, so this reads what the pipeline will
    # actually invoke rather than what the file appears to say. Read from the project
    # directory, against the installation, exactly as a run would.
    while read -r n c; do
        [ -n "$n" ] || continue
        NAMES+=("$n"); CMDS+=("$c")
    done < <(cd "$PROJECT_DIR" && nextflow config -flat "$INSTALL_DIR" 2>/dev/null |
             sed -n "s|^params\.software\.\([A-Za-z_][A-Za-z0-9_]*\) = '\(.*\)'$|\1 \2|p")
    if [ ${#NAMES[@]} -gt 0 ]; then
        source_note="params.software in parameters.config"
    else
        source_note="canonical list - could not read params.software from parameters.config"
    fi
fi

if [ ${#NAMES[@]} -eq 0 ]; then
    for n in $CANONICAL; do NAMES+=("$n"); CMDS+=("$n"); done
fi

check_tool nextflow nextflow
for i in "${!NAMES[@]}"; do
    check_tool "${NAMES[$i]}" "${CMDS[$i]}"
done
check_tool python3 python3
check_tool awk awk

echo
echo "  ${DIM}tool list from: ${source_note}${RESET}"
echo

# --------------------------------------------------------------- 2. helpers --

echo "Pipeline helpers"
echo

for f in atomic_mv.sh config_migrate.sh createDepthFile.sh \
         depth2freq.awk filterFalsePositives.sh MajorAlleleToRef.py; do
    checked=$((checked + 1))
    if [ ! -f "bin/$f" ]; then
        printf '  %-28s %sMISSING%s\n' "$f" "$RED" "$RESET"
        missing=$((missing + 1))
    elif [ ! -x "bin/$f" ]; then
        # Nextflow puts the pipeline's own bin/ on every task's PATH, and the process
        # scripts call these by bare name, so a lost executable bit fails mid-run rather
        # than here. (nextflow.config also prepends dir.bin, but that is belt over braces -
        # until 3.0 it named a directory that never existed and the helpers still resolved.)
        printf '  %-28s %sNOT EXECUTABLE%s  chmod +x bin/%s\n' "$f" "$RED" "$RESET" "$f"
        missing=$((missing + 1))
    else
        printf '  %-28s %sOK%s\n' "$f" "$GREEN" "$RESET"
    fi
done
echo

# ---------------------------------------------------------------- 3. config --

echo "Configuration"
echo

if [ ! -f "$PROJECT_DIR/parameters.config" ]; then
    printf '  %-28s %sNOT YET CREATED%s  in %s\n' "parameters.config" "$YELLOW" "$RESET" "$PROJECT_DIR"
    echo "    cp $INSTALL_DIR/parameters.config.template $PROJECT_DIR/parameters.config"
elif ! command -v nextflow >/dev/null 2>&1; then
    printf '  %-28s %sSKIPPED%s  nextflow not available\n' "parameters.config" "$YELLOW" "$RESET"
else
    checked=$((checked + 1))
    if err=$(cd "$PROJECT_DIR" && nextflow config "$INSTALL_DIR" 2>&1 >/dev/null); then
        printf '  %-28s %sPARSES%s\n' "parameters.config" "$GREEN" "$RESET"
    else
        printf '  %-28s %sFAILED TO PARSE%s\n' "parameters.config" "$RED" "$RESET"
        printf '%s\n' "$err" | sed 's/^/    /'
        missing=$((missing + 1))
    fi
fi
echo

# ---------------------------------------------------------------- summary ----

if [ "$missing" -eq 0 ]; then
    echo "${GREEN}All $checked checks passed.${RESET}"
    exit 0
fi

echo "${RED}$missing of $checked checks failed.${RESET}"
echo
echo "If tools are missing, the environment is either not active or not built:"
echo "  ./PoolSeqFlow install"
echo "  conda activate $ENV_NAME"
exit 1
