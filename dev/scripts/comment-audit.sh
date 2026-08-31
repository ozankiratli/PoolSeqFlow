#!/usr/bin/env bash
#
# List comments that may be design decisions rather than descriptions of the code.
#
# Usage:  dev/scripts/comment-audit.sh [path...]     default: the source tree
#         dev/scripts/comment-audit.sh --blocks      only the long-block report
#         dev/scripts/comment-audit.sh --words       only the tell-word report
#
# A review aid, never a gate. Every hit is a candidate to read, not a verdict: the words below
# appear in legitimate descriptions too. Always exits 0, so it cannot become a test case -
# a hard failure would train the next pass to reword around the words instead of deleting the
# decision behind them.
#
# The rule it serves is in CLAUDE.md.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)

# The words a justification arrives in. Anchored to comment lines only.
TELLS='on purpose|deliberately|rather than|because|would otherwise|so that|which is why'

# A block this long is rarely one description.
BLOCK_MIN=4

# Not source. The three templates ship to the user and are read while editing, so their comments
# are documentation at the point of use; test/ comments record the bug a case guards.
SKIP='parameters.config.template|metadata.csv.template|multi-run.csv.example'

DO_WORDS=1
DO_BLOCKS=1
PATHS=()
for arg in "$@"; do
    case "$arg" in
        --words)  DO_BLOCKS=0 ;;
        --blocks) DO_WORDS=0 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PATHS+=("$arg") ;;
    esac
done

if [ "${#PATHS[@]}" -eq 0 ]; then
    PATHS=("$REPO_ROOT/PoolSeqFlow" "$REPO_ROOT/PoolSeqFlow-analysis"
           "$REPO_ROOT/poolseqflow.nf" "$REPO_ROOT/dryrun.nf"
           "$REPO_ROOT/nextflow.config" "$REPO_ROOT/scripts" "$REPO_ROOT/bin"
           "$REPO_ROOT/lib" "$REPO_ROOT/install" "$REPO_ROOT/dev/scripts"
           "$REPO_ROOT/.github")
fi

files() {
    local p
    for p in "${PATHS[@]}"; do
        if [ -d "$p" ]; then
            find "$p" -type f \
                \( -name '*.nf' -o -name '*.sh' -o -name '*.py' -o -name '*.awk' \
                   -o -name '*.config' -o -name '*.yml' \) -print
        elif [ -f "$p" ]; then
            printf '%s\n' "$p"
        fi
    done | grep -Ev "$SKIP" | grep -v '__pycache__' | sort -u
}

rel() { printf '%s' "${1#"$REPO_ROOT"/}"; }

words_found=0
blocks_found=0

if [ "$DO_WORDS" -eq 1 ]; then
    echo "=== Comment clauses that may be decisions ==================================="
    echo "    $TELLS"
    echo ""
    while IFS= read -r f; do
        hits=$(grep -nE "^[[:space:]]*(//|#).*($TELLS)" "$f" || true)
        [ -n "$hits" ] || continue
        printf '%s\n' "$(rel "$f")"
        printf '%s\n' "$hits" | sed 's/^/    /'
        echo ""
        words_found=$((words_found + $(printf '%s\n' "$hits" | grep -c .)))
    done < <(files)
fi

if [ "$DO_BLOCKS" -eq 1 ]; then
    echo "=== Comment blocks of $BLOCK_MIN lines or more =============================="
    echo ""
    while IFS= read -r f; do
        hits=$(awk -v min="$BLOCK_MIN" '
            /^[[:space:]]*(\/\/|#)/ { if (!start) { start = NR; n = 0 } ; n++ ; next }
            { if (start && n >= min) printf "%d-%d (%d lines)\n", start, NR - 1, n ; start = 0 }
            END { if (start && n >= min) printf "%d-%d (%d lines)\n", start, NR, n }
        ' "$f")
        [ -n "$hits" ] || continue
        printf '%s\n' "$(rel "$f")"
        printf '%s\n' "$hits" | sed 's/^/    /'
        echo ""
        blocks_found=$((blocks_found + $(printf '%s\n' "$hits" | grep -c .)))
    done < <(files)
fi

echo "---------------------------------------------------------------------------"
[ "$DO_WORDS"  -eq 1 ] && echo "$words_found clause(s) to read"
[ "$DO_BLOCKS" -eq 1 ] && echo "$blocks_found block(s) of $BLOCK_MIN+ lines to read"
echo ""
echo "Each is a candidate, not a verdict. Read the code under it and ask whether the"
echo "comment describes THAT code, or defends a choice about it."

exit 0
