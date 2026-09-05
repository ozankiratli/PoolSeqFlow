#!/usr/bin/env python3
"""Compiles a references.bib into the citations.json beside it.

    dev/scripts/bib2citations.py                 rewrite every citations.json
    dev/scripts/bib2citations.py --check         report any that is out of date

A `.bib` is what a person edits: entries are pasted from a publisher and read like BibTeX
everywhere else. The `.json` is what the pipeline reads at run time, and it is GENERATED - the
parser lives here, in a development script run by hand, rather than inside `write_citations.py`,
which executes in every published analysis where a silently dropped field would reach a user's
methods section.

Each `references.bib` compiles to the `citations.json` in the same directory:

    install/references.bib                     ->  install/citations.json
    analysis/references.bib                    ->  analysis/citations.json
    analysis/modules/<name>/references.bib     ->  analysis/modules/<name>/citations.json

## The format

Standard BibTeX, with the entry type carrying `type` and the entry key carrying `key`. Four
fields are PoolSeqFlow's own and are not bibliographic:

    id         the name this entry answers to in the JSON, when it differs from the entry key.
               Version reporting keys on it: `citationShell()` passes `<id>=<version>`.
    name       what a reader is shown, where that differs from the title - "SAMtools and
               BCFtools" for a paper titled "Twelve years of SAMtools and BCFtools".
    r_package  the R package whose version is asked of R at run time.
    when       a gate: `annotate` means the entry belongs only to a run that annotated.
    cite       `false` for something a run uses and should not be credited as a method.
    reason     why, for a `cite = {false}` entry.
    tools      `name = Label` pairs, comma-separated, for one paper covering several commands.
    also       other BibTeX keys, comma-separated, that belong beside this one.

`%` lines before the first entry become the JSON's `_comment`, so the prose a person needs
stays where a person edits. `@string` is refused rather than half-understood.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Fields whose value is not a plain string, and the order every entry is written in. Ordering is
# fixed here so a regenerated file differs from the committed one only where the .bib did.
ORDER = ["name", "type", "key", "referenced_only", "r_package", "when", "cite", "reason",
         "tools", "also",
         "authors", "title", "journal", "volume", "number", "pages", "publisher",
         "address", "year", "doi", "url", "note"]

ENTRY = re.compile(r"@(\w+)\s*\{\s*([^,\s]+)\s*,", re.S)


class BibError(Exception):
    pass


def strip_comments(text: str) -> tuple[list[str], str]:
    """The leading `%` block, and the text from the first entry on."""
    lines = text.splitlines()
    comment: list[str] = []
    for index, line in enumerate(lines):
        if line.startswith("%"):
            comment.append(line[1:].strip())
            continue
        if line.strip() == "" and not any(l.strip() for l in lines[index:] if l.startswith("@")):
            continue
        if line.lstrip().startswith("@"):
            return comment, "\n".join(lines[index:])
        if line.strip():
            raise BibError(f"line {index + 1}: expected a % comment or an @entry, got {line!r}")
    return comment, ""


def balanced(text: str, start: int) -> tuple[str, int]:
    """The braced value beginning at `start`, and the index just past it."""
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i + 1
        i += 1
    raise BibError("a braced value is never closed")


def parse_fields(body: str) -> list[tuple[str, str]]:
    """`field = {value}` pairs, in the order the entry gives them."""
    fields: list[tuple[str, str]] = []
    i = 0
    while i < len(body):
        if body[i] in " \t\r\n,":
            i += 1
            continue
        if body[i] == "}":
            break
        match = re.compile(r"(\w+)\s*=\s*").match(body, i)
        if not match:
            raise BibError(f"expected `field = {{value}}`, got {body[i:i + 40]!r}")
        i = match.end()
        if body[i] != "{":
            raise BibError(f"field {match.group(1)!r} is not braced; quote-delimited values "
                           f"and @string concatenation are not read here")
        value, i = balanced(body, i)
        fields.append((match.group(1), " ".join(value.split())))
    return fields


def parse(text: str) -> tuple[list[str], list[tuple[str, str, list[tuple[str, str]]]]]:
    """Every entry as (type, key, fields), with the file's leading comment."""
    comment, rest = strip_comments(text)
    entries = []
    for match in ENTRY.finditer(rest):
        kind = match.group(1).lower()
        if kind == "string":
            raise BibError("@string is not read here; write the value into each entry")
        if kind == "comment":
            continue
        body, _ = balanced(rest, rest.index("{", match.start()))
        entries.append((kind, match.group(2), parse_fields(body[body.index(",") + 1:])))
    return comment, entries


def to_entry(kind: str, key: str, fields: list[tuple[str, str]]) -> tuple[str, dict]:
    """One BibTeX entry as the slot name and the JSON object the pipeline reads."""
    raw = dict(fields)
    if len(raw) != len(fields):
        raise BibError(f"{key}: a field is given twice")
    slot = raw.pop("id", key)
    out: dict[str, object] = {}
    if "name" in raw:
        out["name"] = raw.pop("name")
    out["type"] = kind
    out["key"] = key
    for field, value in list(raw.items()):
        if field == "tools":
            pairs = [p.split("=", 1) for p in value.split(",")]
            out["tools"] = {a.strip(): b.strip() for a, b in pairs}
        elif field == "also":
            out["also"] = [p.strip() for p in value.split(",") if p.strip()]
        elif field in ("cite", "referenced_only"):
            if value not in ("true", "false"):
                raise BibError(f"{key}: {field} is {value!r}, which is not true or false")
            out[field] = value == "true"
        else:
            out[field] = value
    return slot, {name: out[name] for name in ORDER if name in out}


def compile_bib(path: Path) -> str:
    """The citations.json text one references.bib compiles to."""
    comment, entries = parse(path.read_text(encoding="utf-8"))
    data: dict[str, object] = {}
    if comment:
        data["_comment"] = comment + [
            "",
            f"GENERATED from {path.name} beside this file. Do not edit it: "
            f"dev/scripts/bib2citations.py overwrites it, and 00_static fails when the two differ.",
        ]
    for kind, key, fields in entries:
        slot, entry = to_entry(kind, key, fields)
        if slot in data:
            raise BibError(f"two entries answer to {slot!r}")
        data[slot] = entry
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def sources() -> list[Path]:
    found = [REPO / "install" / "references.bib", REPO / "analysis" / "references.bib"]
    found += sorted((REPO / "analysis" / "modules").glob("*/references.bib"))
    return [path for path in found if path.exists()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="report files that are out of date instead of rewriting them")
    args = parser.parse_args()

    stale = []
    for path in sources():
        target = path.with_name("citations.json")
        try:
            compiled = compile_bib(path)
        except BibError as error:
            print(f"{path.relative_to(REPO)}: {error}", file=sys.stderr)
            return 1
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if compiled == current:
            continue
        if args.check:
            stale.append(target.relative_to(REPO))
        else:
            target.write_text(compiled, encoding="utf-8")
            print(f"wrote {target.relative_to(REPO)}")

    if stale:
        print("out of date with the references.bib beside them:", file=sys.stderr)
        for path in stale:
            print(f"  {path}", file=sys.stderr)
        print("\nregenerate with dev/scripts/bib2citations.py", file=sys.stderr)
        return 1
    if args.check:
        print(f"every citations.json matches its references.bib ({len(sources())} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
