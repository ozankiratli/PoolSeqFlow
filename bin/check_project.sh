#!/bin/bash
#
# Verify a PoolSeqFlow PROJECT before a run depends on it.
#
# Usage:  PoolSeqFlow check project   (the wrapper activates the environment first)
#         run from the project directory, which is where parameters.config lives
#
# Checks two things:
#   1. The project's files parse: parameters.config, metadata.csv, and the run table when
#      multiRun is on.
#   2. Every command the pipeline will invoke, AS THIS PROJECT CONFIGURES IT. The list comes
#      from params.software through `nextflow config`, so a command repointed at a system
#      binary is checked the way the run will call it.
#
# THE INSTALLATION IS bin/check_install.sh's BUSINESS. That one asks whether the tools a
# release is built to run are present at all; this one asks whether the tools THIS PROJECT
# names resolve. A project that repoints nothing gets the same answer twice, which is the
# point: the difference between them is exactly the project's own configuration.

set -uo pipefail

# Two directories: the project is where this was invoked from and holds parameters.config, the
# installation holds nextflow.config and the helpers. Captured before the cd.
PROJECT_DIR="$PWD"
cd "$(dirname "$0")/.." || exit 1
INSTALL_DIR="$PWD"

INSTALL="$INSTALL_DIR"
# shellcheck source=../lib/wrapper_lib.sh
. "$INSTALL_DIR/lib/wrapper_lib.sh" || {
    echo "ERROR: $INSTALL_DIR/lib/wrapper_lib.sh is missing." >&2
    echo "  This installation is incomplete; reinstall it." >&2
    exit 1
}
# Checked before use: this runs without `set -e`, so a missing library would leave tool_version
# undefined and every tool would report as present with no version.
[ -f "$INSTALL_DIR/lib/tool_version.sh" ] || {
    echo "ERROR: $INSTALL_DIR/lib/tool_version.sh is missing." >&2
    echo "  This installation is incomplete; reinstall it." >&2
    exit 1
}
. "$INSTALL_DIR/lib/tool_version.sh"

RED=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
if [ -t 1 ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    DIM=$'\033[2m'; RESET=$'\033[0m'
fi

missing=0
checked=0

CONFIG="$PROJECT_DIR/parameters.config"

verdict() { printf '  %-28s %s%s%s%s\n' "$2" "$1" "$3" "$RESET" "${4:+  $4}"; }
pass()    { verdict "$GREEN"  "$1" "$2" "${3:-}"; }
warn()    { verdict "$YELLOW" "$1" "$2" "${3:-}"; }
fail()    { verdict "$RED"    "$1" "$2" "${3:-}"; missing=$((missing + 1)); }
note()    { printf '  %-28s %s%s%s\n' "$1" "$DIM" "$2" "$RESET"; }

check_tool() {
    local name="$1" cmd="$2" version
    checked=$((checked + 1))

    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '  %-14s %-22s %sMISSING%s  %s\n' "$name" "$cmd" "$RED" "$RESET" "not on PATH"
        missing=$((missing + 1))
        return
    fi

    version=$(tool_version "$name" "$cmd")
    if [ -z "$version" ]; then
        printf '  %-14s %-22s %sFOUND%s    %s(version not reported)%s\n' \
            "$name" "$cmd" "$YELLOW" "$RESET" "$DIM" "$RESET"
    else
        printf '  %-14s %-22s %sOK%s       %s\n' "$name" "$cmd" "$GREEN" "$RESET" "$version"
    fi
}

# The byte-order mark a file begins with: utf-8, utf-16le, utf-16be, or nothing at all.
#
# Read as bytes through `od`, because a mark is invisible everywhere it matters. Nextflow's own
# refusal prints `Unexpected character: ''` with the character rendered as nothing, and no
# editor shows one, so a file that is wrong looks identical to a file that is right.
#
# Measured against this release, 2026-09-26: a UTF-8 mark makes Nextflow refuse the config it
# leads, whether that file is nextflow.config or an included parameters.config, while both CSV
# parsers read past one. The same three bytes are therefore fatal in one file and harmless in
# another, and each caller below says which it is looking at. CRLF is not checked: a config
# with CRLF line endings parses, measured the same day.
byte_order_mark() {
    local first
    first=$(od -An -tx1 -N3 "$1" 2>/dev/null | tr -d ' \n')
    case $first in
        efbbbf*) printf 'utf-8' ;;
        fffe*)   printf 'utf-16le' ;;
        feff*)   printf 'utf-16be' ;;
    esac
}

echo "PoolSeqFlow project check"
echo "========================="
echo "  $PROJECT_DIR"
echo

# --------------------------------------------------------- 1. configuration --

echo "Configuration"
echo

if [ ! -f "$CONFIG" ]; then
    echo "${RED}No parameters.config in $PROJECT_DIR.${RESET}" >&2
    echo "" >&2
    echo "A project check needs a project. Make one and populate it:" >&2
    echo "    cd $PROJECT_DIR" >&2
    echo "    PoolSeqFlow init" >&2
    exit 1
fi

checked=$((checked + 1))
if config_is_current "$CONFIG"; then
    pass "parameters.config" "WRITTEN FOR THIS RELEASE"
else
    stale=$(config_stale_parameters "$CONFIG")
    fail "parameters.config" "WRITTEN FOR AN OLDER RELEASE" \
         "run: PoolSeqFlow migrate_config"
    [ -n "$stale" ] && printf '    %sparameters it renamed or removed:%s%s\n' \
                              "$DIM" "$RESET" "$stale"
fi

# Before the parse below, because the parse is what a mark breaks. Nextflow names the file and
# the column and then prints the offending character as nothing, so the error it produces on its
# own is a file the user can see is correct and a cause they cannot see at all.
checked=$((checked + 1))
config_mark=$(byte_order_mark "$CONFIG")
if [ -z "$config_mark" ]; then
    pass "parameters.config" "NO BYTE-ORDER MARK"
else
    fail "parameters.config" "STARTS WITH A BYTE-ORDER MARK" "run: dos2unix $CONFIG"
    printf '    %sA %s mark sits before the first setting, and Nextflow refuses the\n' \
           "$DIM" "$config_mark"
    printf '    file over a character nothing displays. Editors on Windows add one\n'
    printf '    when they save as UTF-8; dos2unix removes it, and converts UTF-16\n'
    printf '    to UTF-8 as well.%s\n' "$RESET"
fi

# Nextflow's own parse, from the project against the installation, exactly as a run would.
# Everything below reads settings out of this, so a failure here is reported and the rest is
# skipped by name rather than passing over an empty answer.
PARSED=0
checked=$((checked + 1))
if ! command -v nextflow >/dev/null 2>&1; then
    warn "parameters.config" "NOT PARSED" "nextflow is not on PATH"
else
    # Both streams: Nextflow reports a config error on stdout, so capturing stderr alone leaves
    # a failure with nothing to print. The whole capture is discarded when it succeeds.
    if err=$(cd "$PROJECT_DIR" && nextflow config "$INSTALL_DIR" 2>&1); then
        pass "parameters.config" "PARSES"
        PARSED=1
    else
        fail "parameters.config" "FAILED TO PARSE"
        printf '%s\n' "$err" | sed 's/^/    /'
        # The installation's nextflow.config interpolates the project's settings, so a missing
        # or malformed one surfaces as a failure to parse THAT file. Reported as it comes and
        # then explained: without this the message reads as a broken installation, which is
        # the one thing it is not - a run fails here in exactly the same way.
        case $err in
            *"$INSTALL_DIR/nextflow.config"*)
                printf '    %sThat is the installation'"'"'s own config, and it is not damaged: it\n' \
                    "$DIM"
                printf '    interpolates your settings, so a parameter missing from\n'
                printf '    parameters.config fails while it is being read.%s\n' "$RESET"
                ;;
        esac
    fi
fi

# The two tables, each by the parser the pipeline itself uses, so a project is told here what
# step 0 would tell it. Their JSON goes nowhere; the exit status is the answer.
#
# WHICH FILES THEY ARE COMES OUT OF THE CONFIG, so a config that did not parse means they are
# not known - not that they are the defaults. Guessing a name here would report a file the
# project does not use, and `not in use` would be a claim about multiRun nobody read.
metadata_file=""
multirun_file=""
multirun_on=0
if [ "$PARSED" -eq 1 ]; then
    metadata_file=$(cd "$PROJECT_DIR" && nf_config_value "params.metadataFile")
    multirun_file=$(cd "$PROJECT_DIR" && nf_config_value "params.multiRunFile")
    value=$(cd "$PROJECT_DIR" && nf_config_value "params.multiRun")
    [ "$value" = "true" ] && multirun_on=1
fi

check_table() {
    local label="$1" path="$2" parser="$3" out
    checked=$((checked + 1))
    if [ ! -f "$path" ]; then
        fail "$label" "MISSING" "expected at $path"
        return
    fi
    if out=$(python3 "$INSTALL_DIR/bin/$parser" "$path" 2>&1 >/dev/null); then
        pass "$label" "PARSES"
        # A parser that exits 0 may still have written notes, and this discarded them. The only
        # note either parser had before 2026-09-26 - a pool given two different exp_, pt_ or
        # cov_ values - could therefore be reached by no user through any path: resolve_
        # parameters.nf keeps a parser's stderr only when it fails, and so did this.
        [ -n "$out" ] && printf '%s\n' "$out" | sed "s/^/    ${DIM}/;s/$/${RESET}/"
    else
        fail "$label" "FAILED TO PARSE"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

if [ "$PARSED" -eq 0 ]; then
    note "the sample metadata" "not checked - parameters.config did not parse"
    note "the run table" "not checked - parameters.config did not parse"
elif [ -z "$metadata_file" ]; then
    fail "metadataFile" "NOT SET" "parameters.config names no sample metadata file"
else
    check_table "$metadata_file" "$PROJECT_DIR/$metadata_file" parse_metadata.py
    if [ "$multirun_on" -eq 0 ]; then
        note "${multirun_file:-the run table}" "not in use - multiRun is false"
    elif [ -z "$multirun_file" ]; then
        fail "multiRunFile" "NOT SET" "multiRun is on and no run table is named"
    else
        check_table "$multirun_file" "$PROJECT_DIR/$multirun_file" parse_multirun.py
    fi
fi

# THE PARAMETER RULES LIVE IN bin/check_parameters.sh, which step 0 runs as well. A project told
# one thing here and another during the run would be worse than either alone, so there is one
# implementation and two callers.
#
# It reads the COMPOSED config, so a project that pinned an option string by hand is judged on
# what will actually run. Silence means nothing to flag.
if [ "$PARSED" -eq 1 ]; then
    checked=$((checked + 1))
    if [ ! -x "$INSTALL_DIR/bin/check_parameters.sh" ]; then
        warn "parameters" "NOT CHECKED" "bin/check_parameters.sh is missing"
    else
        findings=$(cd "$PROJECT_DIR" && nextflow config -flat "$INSTALL_DIR" 2>/dev/null \
                   | "$INSTALL_DIR/bin/check_parameters.sh") || true
        if [ -z "$findings" ]; then
            pass "parameters" "NOTHING TO FLAG"
        else
            printf '%s\n' "$findings" | while IFS=$'\t' read -r level label headline detail why; do
                [ -n "$level" ] || continue
                case $level in
                    FAIL) fail "$label" "$headline" "$detail" ;;
                    WARN) warn "$label" "$headline" "$detail" ;;
                    *)    note "$label" "$headline${detail:+: $detail}" ;;
                esac
                # Folded here rather than in the helper: the helper emits one line per finding so
                # a caller can read it with `read`, and step 0 wraps to its own width.
                [ -n "$why" ] && printf '%s' "$why" | fold -s -w 72 \
                    | sed "s|^|    ${DIM}|;s|$|${RESET}|"
            done
            # The pipeline above runs in a subshell, so `missing` did not survive it. Ask the
            # helper again for the status alone, which is what decides this script's own.
            if printf '%s\n' "$findings" | grep -q '^FAIL'; then
                missing=$((missing + 1))
            fi
        fi
    fi
fi

echo

# ----------------------------------------------------------------- 2. tools --

echo "Tools, as this project configures them"
echo

declare -a NAMES=() CMDS=()
if [ "$PARSED" -eq 1 ]; then
    # Interpolated by Nextflow, so this reads what the pipeline will actually invoke.
    while read -r n c; do
        [ -n "$n" ] || continue
        NAMES+=("$n"); CMDS+=("$c")
    done < <(cd "$PROJECT_DIR" && nextflow config -flat "$INSTALL_DIR" 2>/dev/null |
             sed -n "s|^params\.software\.\([A-Za-z_][A-Za-z0-9_]*\) = '\(.*\)'$|\1 \2|p")
fi

if [ ${#NAMES[@]} -eq 0 ]; then
    # Never silently substituted with the canonical list. The whole reason this section exists
    # is that it reads the PROJECT'S list, and one that could not be read is a finding.
    checked=$((checked + 1))
    fail "params.software" "NOT READ" "so no tool was checked as this project configures it"
    [ "$PARSED" -eq 1 ] && printf '    %sparameters.config parses but declares no software block%s\n' \
                                  "$DIM" "$RESET"
else
    check_tool nextflow nextflow
    for i in "${!NAMES[@]}"; do
        check_tool "${NAMES[$i]}" "${CMDS[$i]}"
    done
    check_tool python3 python3
    check_tool awk awk
    echo
    printf '  %stool list from: params.software in parameters.config%s\n' "$DIM" "$RESET"
fi

echo

# ---------------------------------------------------------------- summary ----

if [ "$missing" -eq 0 ]; then
    echo "${GREEN}All $checked checks passed.${RESET}"
    exit 0
fi

echo "${RED}$missing of $checked checks failed.${RESET}"
echo
echo "This checks a project. To check the installation itself:"
echo "  PoolSeqFlow check install"
exit 1
