#!/usr/bin/env bash
#
# Migrate an existing parameters.config onto the current parameters.config.template.
#
# Usage: bin/config_migrate.sh [current-config] [template] [output]
#          defaults: parameters.config  parameters.config.template  parameters.config
#
# The template defines the parameter set for this release. Your own settings are carried
# across wherever the same parameter still exists; anything the template computes for
# itself (paths, thread counts, tool option strings) is taken from the template so the
# migrated file picks up this release's behaviour.
#
# The original is copied to parameters.config.bak before anything is written.
#
# Reports:
#   CARRIED   your value was kept
#   RENAMED   the parameter was renamed this release; your value followed it
#   NEW       the template has a parameter your config did not - review the default
#   DROPPED   your config had a parameter this release no longer uses

set -euo pipefail

OLD="${1:-parameters.config}"
TPL="${2:-parameters.config.template}"
OUT="${3:-parameters.config}"

for f in "$OLD" "$TPL"; do
    [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

# Never clobber an existing backup.
BAK="${OLD}.bak"
if [ -e "$BAK" ]; then
    n=1
    while [ -e "${BAK}.${n}" ]; do n=$((n + 1)); done
    BAK="${BAK}.${n}"
fi
cp -p "$OLD" "$BAK"

TMP="$(mktemp)"; REPORT="$(mktemp)"
trap 'rm -f "$TMP" "$REPORT"' EXIT

awk -v OLDF="$OLD" -v REPORT="$REPORT" '
    # Track the scope stack so nested blocks give fully-qualified keys such as
    # dir.output.report.align, and strip the outermost params scope.
    function qualify(k,   p, i) {
        p = ""
        for (i = 1; i <= depth; i++) p = p (p == "" ? "" : ".") stack[i]
        sub(/^params\.?/, "", p)
        return (p == "") ? k : p "." k
    }
    # A value is the users to keep only if it is a literal. Anything referencing another
    # parameter is derived, and this release may compute it differently.
    function literal(v) { return (index(v, "params.") == 0 && index(v, "${") == 0) }

    # Strip a trailing // comment that is not inside a quoted string.
    function strip_comment(v,   i, c, inq, q) {
        inq = 0
        for (i = 1; i <= length(v); i++) {
            c = substr(v, i, 1)
            if (c == "\"" || c == "'"'"'") {
                if (inq == 0) { inq = 1; q = c } else if (c == q) inq = 0
            }
            if (inq == 0 && c == "/" && substr(v, i + 1, 1) == "/") { v = substr(v, 1, i - 1); break }
        }
        sub(/[ \t]+$/, "", v)
        return v
    }

    # Parameters whose meaning or format changed in this release: the template value must
    # win even though both sides look like plain literals.
    function reformatted(k) { return (k == "fastqc.memory") }

    # Parameters renamed in this release, keyed by their CURRENT name and returning the
    # name they had before. Without this a rename is two unrelated events - one DROPPED
    # and one NEW - and the user silently gets the template default back.
    #
    # Add a line whenever a parameter is renamed. If a rename also changed what the
    # parameter means, add the new name to reformatted() as well: that check runs first,
    # so the template value wins and the rename is reported without carrying a value
    # that no longer means the same thing.
    function renamed(k) {
        if (k == "vcffilter.minDP")   return "vcftools.minDP"
        if (k == "vcffilter.minQUAL") return "vcftools.minQUAL"
        if (k == "storageDir")        return "projectDir"
        return ""
    }

    BEGIN { depth = 0; pass = 1 }

    FILENAME == OLDF && FNR == 1 { pass = 1 }
    FILENAME != OLDF && FNR == 1 { pass = 2; depth = 0 }

    {
        line = $0
        sub(/^[ \t]+/, "", line)

        # scope close
        if (line ~ /^\}/) { if (depth > 0) depth--; if (pass == 2) print; next }

        # scope open:  name {          (a trailing // comment is allowed, as on the close
        # above - without that, annotating a block header silently drops every value in
        # it: the line matches neither this rule nor the assignment rule below, so depth
        # is never incremented and the keys in that block are qualified one level short)
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\{[ \t]*(\/\/.*)?$/) {
            name = line; sub(/[ \t]*\{.*$/, "", name)
            stack[++depth] = name
            if (pass == 2) print
            next
        }

        # assignment:  key = value      (ignore comments)
        if (line !~ /^\/\// && line ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
            key = line; sub(/[ \t]*=.*$/, "", key)
            raw = line; sub(/^[^=]*=[ \t]*/, "", raw)
            val = strip_comment(raw)
            full = qualify(key)

            if (pass == 1) { oldval[full] = val; seen[full] = 1; next }

            # Which key in the old config supplies this template key. Normally the same
            # name; for a renamed parameter, the name it used to have.
            src = full
            was_renamed = 0
            if (!(full in oldval)) {
                prev = renamed(full)
                if (prev != "" && (prev in oldval)) { src = prev; was_renamed = 1 }
            }

            if (src in oldval) {
                used[src] = 1
                if (!literal(val)) {
                    # this release computes it - the template wins
                    if (literal(oldval[src]) && oldval[src] != val)
                        printf "COMPUTED\t%s\t%s\t%s\n", full, val, oldval[src] >> REPORT
                } else if (reformatted(full)) {
                    if (oldval[src] != val)
                        printf "REFORMAT\t%s\t%s\t%s\n", full, val, oldval[src] >> REPORT
                } else if (literal(oldval[src])) {
                    if (was_renamed)
                        printf "RENAMED\t%s\t%s\t%s\n", full, oldval[src], src >> REPORT
                    else if (oldval[src] != val)
                        printf "CARRIED\t%s\t%s\t%s\n", full, val, oldval[src] >> REPORT

                    # replace only the value, keeping the template comment and layout
                    if (was_renamed || oldval[src] != val) {
                        head = $0; sub(/=[ \t]*.*$/, "= ", head)
                        tail = substr(raw, length(val) + 1)
                        $0 = head oldval[src] tail
                    }
                }
            } else {
                printf "NEW\t%s\t%s\t\n", full, val >> REPORT
            }
            print; next
        }

        if (pass == 2) print
    }

    END {
        if (pass == 2)
            for (k in seen) if (!(k in used)) printf "DROPPED\t%s\t%s\t\n", k, oldval[k] >> REPORT
    }
' "$OLD" "$TPL" > "$TMP"

cp "$TMP" "$OUT"

echo "Migrated $OLD -> $OUT   (original saved as $BAK)"
echo

show() {
    local tag="$1" title="$2" fmt="$3"
    local n; n=$(grep -c "^${tag}	" "$REPORT" || true)
    printf '%s (%s)\n' "$title" "$n"
    [ "$n" -eq 0 ] && { echo "  none"; echo; return; }
    # shellcheck disable=SC2016
    awk -F'\t' -v T="$tag" -v F="$fmt" '$1==T { printf F, $2, $3, $4 }' "$REPORT"
    echo
}

show CARRIED  "Kept your value"                              "  %-30s %s -> %s\n"
show RENAMED  "Renamed this release - your value followed"   "  %-30s %s (was %s)\n"
show COMPUTED "Now computed by the pipeline - your value ignored" "  %-30s now %s (was %s)\n"
show REFORMAT "Format changed this release - template value used"  "  %-30s now %s (was %s)\n"
show NEW      "New in this release - review these defaults"   "  %-30s %s%s\n"
show DROPPED  "No longer used - dropped"                      "  %-30s was %s%s\n"

echo "Review $OUT before running the pipeline."
