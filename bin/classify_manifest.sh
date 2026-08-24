#!/usr/bin/env bash
#
# Compare two parameter manifests and say HOW they differ, not just THAT they do.
#
# Usage: classify_manifest.sh <stored-manifest> <current-manifest>
#
# Both files are `key=value`, one per line, as analysisParams() emits them. Writes one
# tab-separated record per difference, then a COUNTS line:
#
#   CHANGED <tab> key <tab> old-value <tab> new-value
#   ADDED   <tab> key <tab>           <tab> new-value
#   REMOVED <tab> key <tab> old-value <tab>
#   MALFORMED <tab> line <tab> which-file <tab>
#   COUNTS  <tab> added <tab> changed <tab> removed <tab> malformed
#
# Exit 0 whether or not anything differs: this classifies, it does not judge. Deciding which
# differences invalidate existing outputs is the caller's job. Exit 2 on a usage error.
#
# Why the distinction matters. A CHANGED value means the user altered a setting, and the
# outputs on disk were produced with the old one. ADDED and REMOVED mean the set of
# parameters itself moved, which is what a release does - the outputs predate the parameter
# existing, so there is no earlier value to conflict with. A plain `diff` shows both as a
# pair of +/- lines, which is why every release that introduced a parameter used to fail
# every existing project and tell it to delete its results.
#
# Split on the FIRST '=' only. Values legitimately contain '=' (option strings do), and
# splitting on the last or on every one would corrupt them.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $(basename "$0") <stored-manifest> <current-manifest>" >&2
    exit 2
fi

STORED="$1"
CURRENT="$2"

for f in "$STORED" "$CURRENT"; do
    if [ ! -f "$f" ]; then
        echo "classify_manifest: not a file: $f" >&2
        exit 2
    fi
done

# A blank line is ordinary padding and ignored. A non-blank line with no '=' is reported
# rather than skipped: a manifest is machine-written, so a line that does not parse means
# something upstream is wrong, and silently dropping it would hide a key from the comparison
# and make a real change look like no change at all.
awk '
    FNR == NR {
        if ($0 ~ /^[[:space:]]*$/) next
        eq = index($0, "=")
        if (eq == 0) { printf "MALFORMED\t%s\tstored\t\n", $0; m++; next }
        k = substr($0, 1, eq - 1)
        old[k] = substr($0, eq + 1)
        if (!(k in oldseen)) { oldseen[k] = 1; order[++n] = k }
        next
    }
    {
        if ($0 ~ /^[[:space:]]*$/) next
        eq = index($0, "=")
        if (eq == 0) { printf "MALFORMED\t%s\tcurrent\t\n", $0; m++; next }
        k = substr($0, 1, eq - 1)
        v = substr($0, eq + 1)
        seen[k] = 1
        if (!(k in old))      { printf "ADDED\t%s\t\t%s\n", k, v; a++ }
        else if (old[k] != v) { printf "CHANGED\t%s\t%s\t%s\n", k, old[k], v; c++ }
    }
    END {
        for (i = 1; i <= n; i++)
            if (!(order[i] in seen)) {
                printf "REMOVED\t%s\t%s\t\n", order[i], old[order[i]]
                r++
            }
        printf "COUNTS\t%d\t%d\t%d\t%d\n", a + 0, c + 0, r + 0, m + 0
    }
' "$STORED" "$CURRENT"
