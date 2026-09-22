#!/bin/bash
#
# Verify a PoolSeqFlow installation before a run depends on it.
#
# Usage:  PoolSeqFlow check install   (the wrapper activates the environment first)
#
# Checks two things:
#   1. Every command the pipeline invokes resolves and runs, with its version.
#   2. Every helper in bin/ is present and executable.
#
# IT KNOWS NOTHING ABOUT parameters.config. That file belongs to a project and this verifies an
# INSTALLATION, which a project need not exist for; the tool list is the canonical one below.
# A project that repoints a tool at a system binary is a project's business, and `run` is where
# that resolves.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
INSTALL_DIR="$PWD"

# Which environment this copy expects: from PoolSeqFlow's export, or read out of the wrapper
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

# THE ENVIRONMENT'S OWN COPY, NOT WHATEVER PATH FINDS. Every tool in CANONICAL is pinned in
# install/environment.yml, so one resolving from outside means the environment is missing a
# package and the system's copy is standing in - at some other version, and only on this
# machine. Reporting that as OK is the failure this check exists to prevent, and it is silent:
# the run works here and does not reproduce anywhere else.
#
# Empty when the script is run without the environment active. Then there is nothing to compare
# against and the section below says so rather than checking PATH and calling it an answer.
ENV_PREFIX="${CONDA_PREFIX:-}"
[ "$(basename "${ENV_PREFIX:-.}")" = "$ENV_NAME" ] || ENV_PREFIX=""

check_tool() {
    local name="$1" cmd="$2" resolved version
    checked=$((checked + 1))

    if ! resolved=$(command -v "$cmd" 2>/dev/null); then
        printf '  %-14s %-12s %sMISSING%s  %s\n' "$name" "$cmd" "$RED" "$RESET" "not on PATH"
        missing=$((missing + 1))
        return
    fi

    if [ -n "$ENV_PREFIX" ]; then
        case $resolved in
            "$ENV_PREFIX"/*) ;;
            *)
                printf '  %-14s %-12s %sOUTSIDE THE ENVIRONMENT%s  %s\n' \
                    "$name" "$cmd" "$RED" "$RESET" "$resolved"
                missing=$((missing + 1))
                return
                ;;
        esac
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
if [ -n "$ENV_PREFIX" ]; then
    printf '  %sfrom %s%s\n' "$DIM" "$ENV_PREFIX" "$RESET"
else
    printf '  %sfrom PATH: %s is not active, so nothing here says WHERE a tool came from%s\n' \
        "$YELLOW" "$ENV_NAME" "$RESET"
fi
echo

declare -a NAMES=() CMDS=()
for n in $CANONICAL; do NAMES+=("$n"); CMDS+=("$n"); done

check_tool nextflow nextflow
for i in "${!NAMES[@]}"; do
    check_tool "${NAMES[$i]}" "${CMDS[$i]}"
done
check_tool python3 python3
check_tool awk awk

echo

# --------------------------------------------------------------- 2. helpers --

echo "Pipeline helpers"
echo

# Enumerated, not hand-listed. Everything in bin/ is run and needs its executable bit;
# anything sourced lives in lib/ instead.
#
# The check scripts are in bin/ and are skipped here: they are run by the wrapper, not by a
# process script, so they are not on the list of helpers a run depends on - and this one
# reporting on itself says nothing, since it is already running.
for path in bin/*; do
    f=$(basename "$path")
    [ -d "$path" ] && continue
    case $f in check_install.sh|check_project.sh|check_analysis_install.sh) continue ;; esac

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

# ---------------------------------------------------------------- summary ----

if [ "$missing" -eq 0 ]; then
    echo "${GREEN}All $checked checks passed.${RESET}"
    exit 0
fi

echo "${RED}$missing of $checked checks failed.${RESET}"
echo
echo "If tools are missing, the environment is either not active or not built:"
echo "  PoolSeqFlow install"
echo "  conda activate $ENV_NAME"
exit 1
