#!/usr/bin/env bash
#
# Is every settable parameter named in the manual?
#
# Usage: dev/scripts/check-manual-parameters.sh
#
# Silent means every key is named. Each line printed is a key the manual never mentions.
#
# BOTH FILES ARE READ. parameters.config.template holds what a project sets, and nextflow.config
# resolves defaults below the include for parameters whose absence would change behavior, so a
# template-only audit misses those.
#
# Commented-out assignments count. They are knobs the pipeline computes and a user may uncomment,
# so they are as settable as the rest.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT. It proves a name appears somewhere in the manual, by
# substring, falling back to the leaf of a dotted key so `dir.utilized` is satisfied by the
# `Utilized` directory the manual documents. It does NOT prove the manual says what the parameter
# is, what it does, and how to set it -- which is the requirement. That part is a person reading.
#
# A short leaf name is the weak spot: `align` would be satisfied by the word appearing anywhere.
# Tightening it produces false positives on every parameter documented in prose rather than as a
# literal, which is most of them, so it is left loose and said out loud here.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

MANUAL="manual/PoolSeqFlow-manual.md"
for f in "$MANUAL" parameters.config.template nextflow.config; do
    [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

MISSING=0
for key in $(grep -hoE '^[[:space:]]*(//[[:space:]]*)?[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*=' \
                 parameters.config.template nextflow.config \
             | sed -E 's|//[[:space:]]*||; s|[[:space:]]*=||; s|^[[:space:]]*||; s|^params\.||' \
             | sort -u); do
    # Nextflow's own manifest keys. They describe the pipeline to Nextflow and a project sets none
    # of them, so the manual has nothing to say about them.
    case $key in homePage|mainScript|nextflowVersion) continue ;; esac

    grep -qiF "$key" "$MANUAL" && continue
    grep -qiF "${key##*.}" "$MANUAL" && continue
    echo "undocumented: $key"
    MISSING=$((MISSING + 1))
done

[ "$MISSING" -eq 0 ] || exit 1
