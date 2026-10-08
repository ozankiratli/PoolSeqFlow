#!/usr/bin/env bash
#
# Raise the `environment` floor of every module and library this release republishes, and move
# the version of each one it raises.
#
# Usage:  dev/scripts/raise-module-floors.sh [version] [--dry-run]
#           default: the version this working copy declares, which after the bump is the new one
#
# RUN THIS AFTER dev/scripts/bump-version.sh AND BEFORE PUBLISHING. Both halves of that matter.
#
# `environment` is the oldest release whose analysis environment holds what a module needs, and
# the wrapper compares it against the installed version: install takes the newest row a release
# can run, and a module with no such row is reported as "needs PoolSeqFlow <version>" instead
# of being installed. When step 2 moves a pin to a version
# only this release's environment holds, that module requires this release, and the field has to
# say so - otherwise a user on the previous release installs it, reaches conda, and is refused
# with "already holds" having been told nothing.
#
# AND IT CANNOT BE DONE AT STEP 2. analysis/lib/nf/modules.nf refuses at run time any module whose
# floor is above the running release, so writing the new floor before the bump makes every one of
# those modules unrunnable in its own repository:
#
#     'mds' v20261004.001 needs the analysis environment of PoolSeqFlow 3.3.0 or newer,
#     and this is 3.2.0.
#
# which is six failures across the three module suites. Hence a step of its own, after the bump.
#
# WHICH ARTIFACTS: EVERY MODULE AND LIBRARY THIS RELEASE REPUBLISHES, not only the ones whose
# pins moved.
#
# A moved pin is one reason a floor has to rise. The general one is that an artifact published
# from this release was only ever proven against this release's environment, and the catalogue
# resolves modules and libraries INDEPENDENTLY - PoolSeqFlow's library lookup takes the newest row
# whose floor the installation clears, exactly as the module lookup does. So if a republished
# library kept an old floor while the module using it rose, an older installation could pair that
# release's library code with the previous release's module. Giving everything republished the
# same floor makes the release the unit, and an installation gets the whole of one or the whole of
# the other.
#
# Republished means its manifest version moved since the previous tag, which is what
# dev/scripts/publish-module.sh --list acts on. Derived from git rather than from a log, so a
# pruned log cannot make this answer wrong.
#
# moved-modules.txt from step 2 is read as a CHECK, not as the list: anything step 2 recorded
# itself moving must appear in the derived set, and a disagreement stops this rather than being
# resolved silently.
#
# IT MOVES THE VERSION OF EVERY MANIFEST WHOSE FLOOR IT RAISES. The floor is part of what is
# published, in the manifest and in the catalogue row, and check-analysis-versions.sh --release
# refuses a commit that changes a module without moving its version. Step 2's bump does not
# cover the floor: step 6 commits and merges it before this runs, so the floor lands in the
# version-bump commit on its own. That is how the v3.3.0 tag failed release.yml on 2026-10-07,
# with six manifests named. A floor already at the version is left alone, version and all, so
# running this twice moves nothing the second time. That makes the order matter: the version is
# moved first and the floor written after, so a run stopped by a refused bump leaves the floor
# where it was, and the next run raises it and moves the version together. The other way round,
# the next run found the floor raised and never moved the version.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DRY=0
VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) [ -z "$VERSION" ] || { echo "ERROR: two versions given: $VERSION and $1" >&2; exit 1; }
           VERSION="$1" ;;
    esac
    shift
done

TREE="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow | head -1)"
[ -n "$TREE" ] || { echo "ERROR: no VERSION= line in ./PoolSeqFlow" >&2; exit 1; }
VERSION="${VERSION:-$TREE}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: '$VERSION' is not a release version" >&2
    exit 1
fi

# THE GUARD FOR THE MISTAKE IN THE HEADER. A floor above the version the tree declares is a
# module its own repository cannot run, so this refuses rather than writing it.
if [ "$VERSION" != "$TREE" ]; then
    python3 - "$VERSION" "$TREE" <<'PY' || exit 1
import sys
want = [int(n) for n in sys.argv[1].split(".")]
tree = [int(n) for n in sys.argv[2].split(".")]
if want > tree:
    sys.exit("ERROR: %s is above the version this tree declares (%s). A module whose floor is\n"
             "  above the running release refuses to run, so bump the version first." %
             (sys.argv[1], sys.argv[2]))
PY
fi

PREV=$(git tag --list 'v*' --sort=-v:refname | grep -vxF "v$VERSION" | head -1)
[ -n "$PREV" ] || { echo "ERROR: no previous v* tag to compare against" >&2; exit 1; }

# Everything whose manifest version moved since the previous tag: what this release republishes.
# git run from inside python rather than piped in, because `python3 -` takes its PROGRAM on stdin
# and a pipe into it arrives at a stream the interpreter has already read to the end.
MODULES=$(python3 - "$PREV" <<'PY'
import glob, json, pathlib, subprocess, sys

previous_tag = sys.argv[1]


def at_tag(path):
    out = subprocess.run(["git", "show", "%s:%s" % (previous_tag, path)],
                         capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else ""


for path in sorted(glob.glob("modules/*/manifest.json")) + \
            sorted(glob.glob("modules/lib/*/manifest.json")):
    now = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    was = at_tag(path)
    # Absent at the previous tag means new in this release, which is republished by definition.
    if not was or json.loads(was).get("version") != now.get("version"):
        print(now["name"])
PY
)

# Step 2's own record, as a check on the above. Newest first, because a release is prepared more
# than once.
for d in $(ls -dt dev/logs/prep-"$VERSION"-*/ 2>/dev/null); do
    [ -f "$d/moved-modules.txt" ] || continue
    while read -r NAME; do
        [ -n "$NAME" ] || continue
        printf '%s\n' "$MODULES" | grep -qxF "$NAME" && continue
        echo "ERROR: step 2 recorded moving a pin in '$NAME', and its version has not moved" >&2
        echo "  since $PREV, so it would not be republished and its floor would stay behind." >&2
        echo "  Recorded in: $d/moved-modules.txt" >&2
        exit 1
    done < "$d/moved-modules.txt"
    echo "Checked against $d/moved-modules.txt"
    break
done

echo "Raising the environment floor to $VERSION"
echo "  republished since $PREV, so proven only against this release's environment"
echo ""

if [ -z "$MODULES" ]; then
    echo "  No module's pins moved in this release, so no floor has to move."
    exit 0
fi

CHANGED=0
for NAME in $MODULES; do
    MANIFEST=""
    for candidate in "modules/$NAME/manifest.json" "modules/lib/$NAME/manifest.json"; do
        [ -f "$candidate" ] && MANIFEST="$candidate" && break
    done
    if [ -z "$MANIFEST" ]; then
        echo "ERROR: no module or library '$NAME'" >&2
        exit 1
    fi
    WAS=$(sed -n 's/.*"environment"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
    if [ -z "$WAS" ]; then
        echo "ERROR: $MANIFEST has no 'environment'" >&2
        exit 1
    fi
    if [ "$WAS" = "$VERSION" ]; then
        printf '  %-20s already %s\n' "$NAME" "$VERSION"
        continue
    fi
    if [ "$DRY" -eq 1 ]; then
        printf '  %-20s %s -> %s, and its version moves   (--dry-run, not written)\n' \
            "$NAME" "$WAS" "$VERSION"
        continue
    fi
    BUMPED=$(bash "$ROOT/dev/scripts/bump-analysis-version.sh" module "$NAME") || {
        echo "ERROR: could not move the version of $MANIFEST, so its floor was left at $WAS." >&2
        exit 1; }
    BUMPED=${BUMPED%%$'\n'*}
    sed -i -E "s|(\"environment\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1${VERSION}\2|" "$MANIFEST"
    IS=$(sed -n 's/.*"environment"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
    [ "$IS" = "$VERSION" ] \
        || { echo "ERROR: could not write $MANIFEST (still '$IS')" >&2; exit 1; }
    printf '  %-20s %s -> %s, version %s\n' "$NAME" "$WAS" "$VERSION" "${BUMPED#*: }"
    CHANGED=$((CHANGED + 1))
done

echo ""
if [ "$DRY" -eq 1 ]; then
    echo "Nothing written. Drop --dry-run to apply."
    exit 0
fi
echo "$CHANGED manifest(s) changed, floor and version, uncommitted. Each is republished with the"
echo "release under its new version, which is the one the CHANGELOG names."
