#!/usr/bin/env python3
"""Writes CITATIONS.md and references.bib for the software a run invoked.

    write_citations.py --data citations.json --out-dir <dir> \
                       --pipeline-version 3.0.0 --annotate true \
                       bwa=0.7.19 samtools=1.24 ...
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def wanted(key: str, entry: dict, annotate: bool) -> bool:
    """Whether this entry belongs in a run's citation list."""
    if key.startswith("_") or entry.get("referenced_only"):
        return False
    if entry.get("cite") is False:
        return False
    if entry.get("when") == "annotate" and not annotate:
        return False
    return True


def prose(entry: dict, key: str, reported: dict[str, str]) -> str:
    """Formats one readable citation line. An entry may cover more than one tool."""
    covered = entry.get("tools") or {key: entry["name"]}
    named = [f"{label} {reported[name]}" for name, label in covered.items() if reported.get(name)]
    head = ", ".join(named) if named else entry["name"]

    authors = entry.get("authors", "").replace("{", "").replace("}", "")
    names = [a.strip() for a in authors.split(" and ") if a.strip()]
    if len(names) > 2:
        who = f"{names[0].split(',')[0]} et al."
    elif names:
        who = " & ".join(n.split(",")[0] for n in names)
    else:
        who = ""

    where = entry.get("journal", "")
    year = entry.get("year", "")
    tail = ", ".join(p for p in (who, where, year) if p)

    line = f"- **{head}** — {tail}" if tail else f"- **{head}**"
    if entry.get("doi"):
        line += f"  \n  <https://doi.org/{entry['doi']}>"
    elif entry.get("url"):
        line += f"  \n  <{entry['url']}>"
    if entry.get("note"):
        line += f"  \n  *{entry['note']}*"
    return line


def versions_used(entry: dict, key: str, reported: dict[str, str]) -> str:
    """The BibTeX note recording what ran. One tool names a version; two name themselves."""
    covered = entry.get("tools") or {key: entry["name"]}
    if len(covered) == 1:
        name = next(iter(covered))
        version = reported.get(name, "")
        return f"Version {version} used" if version else ""
    named = [f"{label} {reported[name]}"
             for name, label in covered.items() if reported.get(name)]
    return f"{', '.join(named)} used" if named else ""


def bibtex(entry: dict, note: str) -> str:
    """One BibTeX entry. `note` carries the version, which no standard field holds."""
    kind = "article" if entry.get("type") == "article" else "misc"
    fields = [("author", entry.get("authors")), ("title", entry.get("title"))]
    if kind == "article":
        fields += [("journal", entry.get("journal")), ("volume", entry.get("volume")),
                   ("number", entry.get("number")), ("pages", entry.get("pages"))]
    fields += [("year", entry.get("year")), ("doi", entry.get("doi")),
               ("url", entry.get("url"))]
    if note:
        fields.append(("note", note))

    body = "".join(f"  {k:<8}= {{{v}}},\n" for k, v in fields if v)
    return f"@{kind}{{{entry['key']},\n{body}}}\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", required=True, help="citations.json")
    parser.add_argument("--out-dir", required=True, help="where to write both files")
    parser.add_argument("--pipeline-version", default="", help="the release that ran")
    parser.add_argument("--annotate", default="false", help="whether step 8 ran")
    parser.add_argument("versions", nargs="*", help="name=version, one per tool invoked")
    args = parser.parse_args(argv)

    data = json.loads(Path(args.data).read_text())
    annotate = str(args.annotate).lower() == "true"

    reported: dict[str, str] = {}
    for pair in args.versions:
        name, _, value = pair.partition("=")
        if name:
            reported[name] = value.strip()
    reported.setdefault("poolseqflow", args.pipeline_version)

    listed = [(k, e) for k, e in data.items()
              if isinstance(e, dict) and wanted(k, e, annotate)]
    if not listed:
        print("write_citations: nothing to cite, which cannot be right", file=sys.stderr)
        return 1

    # Deduplicates shared references. Carried as (key, entry): versions are keyed by the data
    # key, which a display name does not map back to.
    seen: set[str] = set()
    entries: list[tuple[str, dict]] = []
    for key, entry in listed:
        if entry["key"] in seen:
            continue
        seen.add(entry["key"])
        entries.append((key, entry))
        for extra in entry.get("also", []):
            match = next(((k, e) for k, e in data.items()
                          if isinstance(e, dict) and e.get("key") == extra), None)
            if match and extra not in seen:
                seen.add(extra)
                entries.append(match)

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    md = ["# Citations", "",
          "PoolSeqFlow is built on other people's work. This run invoked the software below;",
          "please cite it alongside the pipeline itself.", "",
          "Versions are the ones this run actually reported, not the ones the environment",
          "pins, so they remain correct if a tool was repointed at a system installation.", ""]
    md += [prose(e, k, reported) for k, e in listed]
    md += ["", "BibTeX for all of the above is in `references.bib`, beside this file.", ""]
    (out / "CITATIONS.md").write_text("\n".join(md))

    bib = ["% Citations for the software this PoolSeqFlow run invoked.",
           "% Generated with the results; regenerated on every run.", ""]
    bib += [bibtex(e, versions_used(e, k, reported)) for k, e in entries]
    (out / "references.bib").write_text("\n".join(bib))

    print(f"CITATIONS:             {len(listed)} tools, {len(entries)} references")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
