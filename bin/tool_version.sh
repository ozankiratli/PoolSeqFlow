#!/bin/bash
# Asks a tool for the version it reports. Sourced, not executed:
#
#     . "$(dirname "$0")/../bin/tool_version.sh"
#     v=$(tool_version bwa bwa)

# Each tool is handled by name: they answer differently, and several report on stderr or exit
# non-zero. The result is a display string, never parsed.
tool_version() {
    local name="$1" cmd="$2" raw=""
    case "$name" in
        java)     raw=$("$cmd" -version 2>&1) ;;
        bwa)      raw=$("$cmd" 2>&1 | sed -n 's/^Version: *//p') ;;
        snpEff)   raw=$("$cmd" -version 2>&1) ;;
        unzip)    raw=$("$cmd" -v 2>&1) ;;
        nextflow) raw=$("$cmd" -version 2>&1 | sed -n 's/.*version *//p') ;;
        python)   raw=$("$cmd" --version 2>&1) ;;
        *)        raw=$("$cmd" --version 2>&1) ;;
    esac
    # First non-empty line, whitespace squeezed.
    printf '%s' "$(printf '%s\n' "$raw" | grep -m1 . | tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//')"
}
