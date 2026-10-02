#!/usr/bin/env bash
# Live preview of the manual. Regenerates docs/ whenever manual/ changes and serves the
# site with live reload, so an edit to the manual shows in the browser a second later.
#
#   python3 -m venv dev/manual/.venv                                   # once
#   dev/manual/.venv/bin/pip install -r manual/requirements.txt        # once
#   dev/scripts/serve_docs.sh                   # http://127.0.0.1:8055/PoolSeqFlow/
#
# Not MkDocs' own default of 8000, which is the first port anything else takes. Override with
# PSF_DOCS_ADDR, or pass --dev-addr yourself; any other arguments go through to mkdocs.
#
#   PSF_DOCS_ADDR=0.0.0.0:9001 dev/scripts/serve_docs.sh
#
# POOLSEQFLOW_MKDOCS names a particular mkdocs and wins over both of the below.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

# POOLSEQFLOW_MKDOCS first, then the environment this repository keeps, then PATH.
#
# THAT ENVIRONMENT LIVES UNDER dev/, NOT UNDER manual/, and three things make manual/ wrong for
# it: `manual` is a payload item, so deploy_payload's `cp -r` carries whatever is inside it into
# every installation made from a checkout; stamp() below walks manual/ once a second; and dev/ is
# already export-ignore, so nothing has to be added to keep it out of a release.
VENV_MKDOCS="$REPO/dev/manual/.venv/bin/mkdocs"
MKDOCS_BIN="${POOLSEQFLOW_MKDOCS:-}"
if [ -z "$MKDOCS_BIN" ] && [ -x "$VENV_MKDOCS" ]; then
    MKDOCS_BIN="$VENV_MKDOCS"
fi
[ -n "$MKDOCS_BIN" ] || MKDOCS_BIN="$(command -v mkdocs || true)"
if [ -z "$MKDOCS_BIN" ]; then
    echo "mkdocs not found. Build the environment this repository expects:" >&2
    echo "    python3 -m venv dev/manual/.venv" >&2
    echo "    dev/manual/.venv/bin/pip install -r manual/requirements.txt" >&2
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
    *" --dev-addr "*|*" -a "*) exec "$MKDOCS_BIN" serve "$@" ;;
    *) exec "$MKDOCS_BIN" serve --dev-addr "${PSF_DOCS_ADDR:-127.0.0.1:8055}" "$@" ;;
esac
