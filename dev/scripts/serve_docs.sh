#!/usr/bin/env bash
# Live preview of the manual. Regenerates docs/ whenever manual/ changes and serves the
# site with live reload, so an edit to the manual shows in the browser a second later.
#
#   pip install -r manual/requirements.txt      # once
#   dev/scripts/serve_docs.sh                   # http://127.0.0.1:8055/PoolSeqFlow/
#
# Not MkDocs' own default of 8000, which is the first port anything else takes. Override with
# PSF_DOCS_ADDR, or pass --dev-addr yourself; any other arguments go through to mkdocs.
#
#   PSF_DOCS_ADDR=0.0.0.0:9001 dev/scripts/serve_docs.sh
#
# Set MKDOCS to use a particular interpreter's mkdocs rather than the one on PATH.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

MKDOCS="${MKDOCS:-$(command -v mkdocs || true)}"
if [ -z "$MKDOCS" ]; then
    echo "mkdocs not found. Install it with: pip install -r manual/requirements.txt" >&2
    exit 1
fi

# mtimes of everything hand-written, as one number. python, not `stat`, whose flags differ
# between GNU and BSD.
stamp() {
    python3 -c "import pathlib; print(sum(p.stat().st_mtime_ns for p in pathlib.Path('manual').rglob('*') if p.is_file()))"
}

python3 dev/scripts/build_docs.py

# A generation failure leaves the last good docs/ in place and prints why, so the browser keeps
# showing the last page that built.
watch_manual() {
    local last current
    last="$(stamp)"
    while sleep 1; do
        current="$(stamp)"
        [ "$current" = "$last" ] && continue
        last="$current"
        python3 dev/scripts/build_docs.py || echo "  (docs/ left at the last version that generated)" >&2
    done
}

watch_manual &
WATCHER=$!
trap 'kill "$WATCHER" 2>/dev/null || true' EXIT INT TERM

# An explicit --dev-addr wins; otherwise serve somewhere less contested than port 8000.
case " $* " in
    *" --dev-addr "*|*" -a "*) exec "$MKDOCS" serve "$@" ;;
    *) exec "$MKDOCS" serve --dev-addr "${PSF_DOCS_ADDR:-127.0.0.1:8055}" "$@" ;;
esac
