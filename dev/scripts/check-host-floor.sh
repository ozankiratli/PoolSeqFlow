#!/usr/bin/env bash
#
# Read the glibc an installed environment really requires, and refuse it if that is newer than
# the release promises.
#
# Usage:  dev/scripts/check-host-floor.sh [environment-name]
#           environment-name defaults to PoolSeqFlow-<version>-analysis
#
# RUN THIS BY HAND, AFTER INSTALLING, BEFORE A RELEASE. It is not in the test suite and must not
# be: it reads an environment that exists on this machine, which a per-commit suite has no way
# to guarantee. Its cheap half already is in the suite - see below.
#
# WHAT THIS ANSWERS THAT 00_static CANNOT
# ---------------------------------------
# A conda package may depend on a VIRTUAL package, a `__`-prefixed name describing the machine
# rather than anything installable. `__glibc` is the one that matters: a package requiring
# `__glibc >=X` cannot be installed on a host below X, and that is a property of whoever solved
# the environment rather than of the software.
#
# 00_static reads the shipped yml and checks the one package whose VERSION is the glibc it
# targets - sysroot_linux-64=2.39 says `__glibc >=2.39` in its name, so a text file is enough.
# That is the case that would have caught v3.1.1, and it is cheap enough to run per commit.
#
# It is not enough in general. Every other package carries its constraint in conda metadata and
# not in its version: libsanitizer=16.2.0 requires `__glibc >=2.17,<3.0.a0` and nothing about
# the string "16.2.0" says so. A release that picks up such a package with a higher bound ships
# the same defect with the static check passing - which is the failure this project keeps
# meeting, a gate that stopped pointing at the thing it was aimed at.
#
# So the general answer needs the real constraints, and an installed environment has them:
# every package writes $PREFIX/conda-meta/<dist>.json carrying its own `depends` list. Reading
# those is exact, offline and instant, where asking the solver about 190 packages is neither.
#
# WHY NOT READ THEM FROM A DRY-RUN SOLVE INSTEAD
# ----------------------------------------------
# Measured 2026-09-21: `conda env create --dry-run --json` returns name, version, build_string,
# channel and platform per package and NO `depends` key - 0 of 190 records carried one. So the
# solve says what would be installed and not what any of it requires, and the environment has
# to exist. That is why this runs after an install rather than instead of one.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$REPO_ROOT"

VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow | head -1)
ENV_NAME="${1:-PoolSeqFlow-$VERSION-analysis}"

# The promise, taken from the file that ships rather than from this script, so the two cannot
# disagree about what a user was told - and from the file belonging to the environment being
# checked, not always the analysis one. Both carry rsync and so both have a floor; reading one
# file for both would answer about the wrong promise the moment they differ.
case "$ENV_NAME" in
    *-analysis) FLOOR_FILE="install/environment-analysis.yml" ;;
    *)          FLOOR_FILE="install/environment.yml" ;;
esac
FLOOR=$(sed -n 's/^# host-glibc-floor: *\(.*\)$/\1/p' "$FLOOR_FILE" | head -1)
if [ -z "$FLOOR" ]; then
    echo "check-host-floor: $FLOOR_FILE declares no host-glibc-floor." >&2
    echo "Re-export it: dev/scripts/export-environment.sh $ENV_NAME" >&2
    exit 1
fi

PREFIX=$(conda env list 2>/dev/null | awk -v n="$ENV_NAME" '$1 == n {print $NF}')
if [ -z "$PREFIX" ] || [ ! -d "$PREFIX/conda-meta" ]; then
    echo "check-host-floor: no installed environment named '$ENV_NAME'." >&2
    echo "This reads what an environment REQUIRES, so it needs one that exists:" >&2
    echo "    ./PoolSeqFlow analysis install" >&2
    exit 1
fi

echo "Reading what '$ENV_NAME' requires of its host."
echo "  promised floor: __glibc >= $FLOOR"

python3 - "$PREFIX" "$FLOOR" <<'PY'
import glob, json, os, re, sys

prefix, floor = sys.argv[1], sys.argv[2]

def key(v):
    # Field by field, so 2.9 does not read as newer than 2.28.
    return tuple(int(p) if p.isdigit() else 0 for p in v.split("."))

# `__glibc >=2.17,<3.0.a0` and `__glibc >=2.39` both appear; only the lower bound constrains
# which hosts can install, so the upper half is ignored on purpose.
lower = re.compile(r"^__glibc\s*>=\s*([0-9][0-9.]*)")

worst, imposed_by, records = "0", [], 0
for path in glob.glob(os.path.join(prefix, "conda-meta", "*.json")):
    try:
        with open(path) as fh:
            meta = json.load(fh)
    except (OSError, ValueError):
        continue
    records += 1
    name = meta.get("name", os.path.basename(path))
    for dep in meta.get("depends", []) or []:
        m = lower.match(dep.strip())
        if not m:
            continue
        v = m.group(1).rstrip(".")
        if key(v) > key(worst):
            worst, imposed_by = v, [(name, dep.strip())]
        elif key(v) == key(worst):
            imposed_by.append((name, dep.strip()))

if records == 0:
    print("  ERROR: read no package records - conda-meta is empty or unreadable.")
    sys.exit(1)

print(f"  read {records} package records")
print(f"  actual floor:   __glibc >= {worst}")

if key(worst) > key(floor):
    print()
    print(f"  REFUSED: this environment cannot be installed on a host below glibc {worst},")
    print(f"  but the release promises {floor}. Imposed by:")
    for name, dep in sorted(set(imposed_by)):
        print(f"      {name}  ({dep})")
    print()
    print("  Either pull the offending package back to a build with a lower bound, or move")
    print("  HOST_GLIBC_FLOOR in dev/scripts/export-environment.sh, say so in the manual's")
    print("  Requirements, re-export, and write it in the CHANGELOG. Raising it drops machines.")
    sys.exit(1)

print()
print(f"  OK - nothing in it requires more than glibc {floor}.")
if imposed_by:
    print("  What sets the actual floor:")
    for name, dep in sorted(set(imposed_by)):
        print(f"      {name}  ({dep})")
PY
