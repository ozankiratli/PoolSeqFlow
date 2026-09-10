#!/usr/bin/env bash
#
# Print one version's section of CHANGELOG.md on stdout.
#
# Usage: dev/scripts/changelog-section.sh <version> [--file <path>]
#
# The section is everything from `## [<version>]` up to whichever comes first: the next
# `## [` heading, the reference-link block at the foot of the file, or the end of the file.
# The `---` rule between sections belongs to neither, so it and the blank lines around it are
# trimmed; everything else is printed exactly as it stands, including the `### Commits` list.
#
# Exits non-zero with nothing on stdout when the version has no section. release.yml feeds
# this to the GitHub release body, so an absent section has to fail the release rather than
# publish an empty one.
#
# dev/ carries export-ignore, so this file never ships to a user.

set -euo pipefail

VERSION=""
FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --file)
            FILE="${2-}"
            [ -n "$FILE" ] || { echo "--file needs a path" >&2; exit 1; }
            shift
            ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *)
            [ -z "$VERSION" ] || { echo "unexpected argument: $1" >&2; exit 1; }
            VERSION="$1"
            ;;
    esac
    shift
done

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--file <path>]   (e.g. 3.0.0)" >&2
    exit 1
fi

[ -n "$FILE" ] || FILE="$(git rev-parse --show-toplevel)/CHANGELOG.md"
[ -f "$FILE" ] || { echo "changelog-section.sh: no such file: $FILE" >&2; exit 1; }

# The heading is matched as a literal, not a regular expression: a version is full of dots, and
# `## [3.0.1]` as a pattern would also match `## [3.0.10]`. The version reaches awk through
# ENVIRON rather than -v, which processes escape sequences in the value.
VERSION="$VERSION" awk '
    BEGIN { want = "## [" ENVIRON["VERSION"] "]"; n = 0 }
    !inside && substr($0, 1, length(want)) == want { inside = 1 }
    inside && NR > 1 {
        # The next section, or the reference-link block that closes the file.
        if (substr($0, 1, 4) == "## [" && substr($0, 1, length(want)) != want) exit
        if ($0 ~ /^\[[0-9]+\.[0-9]+\.[0-9]+\]: /) exit
    }
    inside { body[n++] = $0 }
    END {
        if (n == 0) exit 3
        # The rule and the blank lines that bound one section from the next belong to neither.
        last = n - 1
        while (last >= 0 && (body[last] == "" || body[last] == "---")) last--
        for (i = 0; i <= last; i++) print body[i]
        if (last < 0) exit 4
    }
' "$FILE" || {
    status=$?
    if [ "$status" -eq 3 ]; then
        echo "changelog-section.sh: ${FILE##*/} has no '## [$VERSION]' section" >&2
    elif [ "$status" -eq 4 ]; then
        echo "changelog-section.sh: the '## [$VERSION]' section is empty" >&2
    fi
    exit 1
}
