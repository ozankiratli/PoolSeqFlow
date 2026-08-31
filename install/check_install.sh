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
# With a parameters.config present the commands come from `params.software` through
# `nextflow config`, so a command repointed at a system binary is checked as configured.
# Without one, the canonical list below is used.

set -uo pipefail

# Two directories: the installation holds the helpers and nextflow.config, the directory this
# was invoked from is the project and holds parameters.config. Captured before the cd.
PROJECT_DIR="$PWD"
cd "$(dirname "$0")/.." || exit 1
INSTALL_DIR="$PWD"

# Which environment this copy expects: from ./PoolSeqFlow's export, or read out of the wrapper
# when this script is run directly.
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

# Tools the pipeline runs, as params.software names them, plus nextflow, python3 and awk, which
# are not in that block but are needed all the same.
CANONICAL="java cutadapt fastqc trim_galore samtools bamtools bwa bcftools vcftools snpEff unzip"

# Shared with the citation writer, so the two report the same versions. Checked first: this
# runs without `set -e`, so a missing library would leave tool_version undefined and every
# tool would report as present with no version.
[ -f "$INSTALL_DIR/lib/tool_version.sh" ] || {
    echo "ERROR: $INSTALL_DIR/lib/tool_version.sh is missing." >&2
    echo "  This installation is incomplete; reinstall it." >&2
    exit 1
}
. "$INSTALL_DIR/lib/tool_version.sh"

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
        # Resolved but reported no version. Not fatal; some tools have no version flag.
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

# Which list is in use, with the reason when it is the fallback.
if [ ! -f "$PROJECT_DIR/parameters.config" ]; then
    source_note="canonical list - no parameters.config in $PROJECT_DIR"
elif ! command -v nextflow >/dev/null 2>&1; then
    source_note="canonical list - nextflow not available to read parameters.config"
else
    # Interpolated by Nextflow, so this reads what the pipeline will actually invoke. From the
    # project directory against the installation, exactly as a run would.
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

# Enumerated, not hand-listed. Everything in bin/ is run and needs its executable bit;
# anything sourced lives in lib/ instead.
for path in bin/*; do
    f=$(basename "$path")
    [ -d "$path" ] && continue

    checked=$((checked + 1))
    if [ ! -f "bin/$f" ]; then
        printf '  %-28s %sMISSING%s\n' "$f" "$RED" "$RESET"
        missing=$((missing + 1))
    elif [ ! -x "bin/$f" ]; then
        # The process scripts call these by bare name off Nextflow's bin/ PATH, so a lost
        # executable bit fails mid-run.
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
