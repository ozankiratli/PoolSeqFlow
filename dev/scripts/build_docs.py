#!/usr/bin/env python3
"""Generate the documentation page tree and nav from the manual.

`manual/` holds everything written by hand: the manual itself and the site's
assets, stylesheets and scripts. `docs/` is output — untracked, rebuilt whole,
and safe to delete. The nav block of `mkdocs.yml` is generated too, and is the
one generated thing under version control.

    python3 dev/scripts/build_docs.py            # rebuild docs/ and the nav
    python3 dev/scripts/build_docs.py --check    # validate; exit 1 if the nav is stale

Structure comes from heading depth, and the URL of every page from a directive
rather than from its title, so rewording a heading cannot move a published page:

    # Getting Started
    <!--@ section: getting-started -->

    ## Install
    <!--@ page: install -->

    ### Requirements

A section's prose, before its first page, becomes that section's `index.md`; a
section with no prose gets no index page. Headings inside a page are promoted by
one level on the way out, so the manual's `###` is a page's `##`.

Cross-references are written as plain in-document anchors, which keeps the
manual readable on its own; this script resolves each one to the page that owns
it. An anchor with no heading behind it, or two headings that slugify the same,
is an error rather than a broken link on the site.

An `include: FILE` field ends the page with a snippet of that file and emits no
heading of its own, because an included document brings its own.
"""

from __future__ import annotations

import argparse
import posixpath
import re
import shutil
import sys
import unicodedata
from pathlib import Path

# The BibTeX reader lives beside this script and is the only one in the repository. Two would
# be two grammars, and the entries it reads reach a user's methods section either way.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bib2citations  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
MANUAL = REPO / "manual" / "PoolSeqFlow-manual.md"
DOCS = REPO / "docs"
MKDOCS = REPO / "mkdocs.yml"
STATIC = ("assets", "stylesheets", "javascripts")

HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
DIRECTIVE = re.compile(r"^<!--@\s*(.*?)\s*-->\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")
EXPLICIT_ID = re.compile(r"\{:?\s*#([\w-]+)\s*\}\s*$")
MD_LINK = re.compile(r"(?<!!)\[([^\]]*)\]\(\s*(#[^)\s]*)\s*\)")
HTML_ANCHOR = re.compile(r'(href=")(#[^"]*)(")')
# An image is written as the manual itself reads it, `assets/…` beside the manual. Every page
# but the home page is emitted one directory down, so the path has to move with it.
MD_IMAGE = re.compile(r"(!\[[^\]]*\]\(\s*)(assets/)")

# A citation in the prose, expanded in place into a link to the group it is filed under. Not
# followed by `(`, which is an ordinary link whose text happens to start with an @ - a GitHub
# handle, say - and which expansion would otherwise claim as a citation key.
CITE = re.compile(r"\[@([A-Za-z0-9_:.\-]+)\](?!\()")
# The same citation once expanded. Both forms are read, so compiling is idempotent: the key
# survives in the link, and a bibliography rebuilt from an already-expanded manual is the same.
CITED = re.compile(r"\[([^\]]*)\]\(#ref-([A-Za-z0-9_:.\-]+)\)")
BIB_START = "<!-- generated: bibliography -->\n"
BIB_END = "<!-- end generated -->"

# The headings the bibliography is divided into, in the order they appear. Authored, so that
# adding a group is a decision someone made rather than a side effect of a new `group` value.
BIBLIOGRAPHY_GROUPS = (
    "The statistics PoolSeqFlow computes",
    "Estimating from pooled reads",
    "Other software for pooled sequencing",
    "Where these methods have been used",
)

# The accents the references use, as combining marks. `{\"o}` is one letter to a reader.
ACCENTS = {'"': "̈", "'": "́", "`": "̀", "^": "̂", "~": "̃"}


class ManualError(Exception):
    """One or more problems in the manual, reported together."""


def slugify(text: str) -> str:
    """Reproduce Python-Markdown's toc slugify over a heading's rendered text."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    # Backticks and asterisks fall to the class below. Underscores must NOT: `\w` keeps them,
    # so `RG_Sample` anchors as rg_sample, and stripping one here would name a heading the
    # built site does not have.
    text = text.replace("`", "").replace("*", "")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^\w\s-]", "", text).strip().lower()
    return re.sub(r"[-\s]+", "-", text)


def heading_anchor(title: str) -> str:
    """The anchor a heading gets: an attr_list id if it pins one, else its slug."""
    match = EXPLICIT_ID.search(title)
    return match.group(1) if match else slugify(title)


def parse_directive(line: str) -> dict[str, str] | None:
    """Parse `<!--@ page: install | nav: Install -->` into a field mapping."""
    match = DIRECTIVE.match(line)
    if not match:
        return None
    fields: dict[str, str] = {}
    for part in match.group(1).split("|"):
        part = part.strip()
        if not part:
            continue
        key, _, value = part.partition(":")
        fields[key.strip()] = value.strip()
    return fields


class Page:
    def __init__(self, path: str, title: str, nav: str, include: str | None):
        self.path = path
        self.title = title
        self.nav = nav
        self.include = include
        self.lines: list[str] = []
        self.anchors: list[str] = []


class Section:
    def __init__(self, slug: str, nav: str):
        self.slug = slug
        self.nav = nav
        self.index: Page | None = None
        self.pages: list[Page] = []


def parse(text: str) -> tuple[list[Page], list[Section]]:
    """Split the manual into pages, keeping every body line verbatim."""
    errors: list[str] = []
    lines = text.splitlines()

    home: Page | None = None
    sections: list[Section] = []
    section: Section | None = None
    page: Page | None = None
    pending_heading: tuple[int, int, str] | None = None
    in_fence = False
    fence_marker = ""

    for number, line in enumerate(lines, 1):
        fence = FENCE.match(line)
        if fence:
            if not in_fence:
                in_fence, fence_marker = True, fence.group(1)
            elif line.strip().startswith(fence_marker):
                in_fence = False
            if page:
                page.lines.append(line)
            continue

        if in_fence:
            if page:
                page.lines.append(line)
            continue

        fields = parse_directive(line)
        if fields is not None:
            if pending_heading is None:
                errors.append(f"line {number}: directive does not follow a heading")
                continue
            level, _, title = pending_heading
            pending_heading = None

            if "home" in fields:
                if level != 1:
                    errors.append(f"line {number}: `home` must sit under a level-1 heading")
                home = Page("index.md", title, fields.get("nav", title), fields.get("include"))
                page, section = home, None
            elif "section" in fields:
                if level != 1:
                    errors.append(f"line {number}: `section` must sit under a level-1 heading")
                section = Section(fields["section"], fields.get("nav", title))
                sections.append(section)
                page = Page(f"{section.slug}/index.md", title, section.nav, fields.get("include"))
                section.index = page
            elif "page" in fields:
                if level != 2:
                    errors.append(f"line {number}: `page` must sit under a level-2 heading")
                elif section is None:
                    errors.append(f"line {number}: page `{fields['page']}` is not inside a section")
                else:
                    page = Page(
                        f"{section.slug}/{fields['page']}.md",
                        title,
                        fields.get("nav", title),
                        fields.get("include"),
                    )
                    section.pages.append(page)
            else:
                errors.append(f"line {number}: directive names no page: {line.strip()}")
            continue

        heading = HEADING.match(line)
        if heading:
            level, title = len(heading.group(1)), heading.group(2)
            if level <= 2:
                pending_heading = (level, number, title)
                continue
            if page is None:
                errors.append(f"line {number}: heading before the first page: {title!r}")
                continue
            page.anchors.append(heading_anchor(title))
            page.lines.append("#" * (level - 1) + " " + title)
            continue

        if pending_heading is not None:
            level, heading_line, title = pending_heading
            errors.append(f"line {heading_line}: heading {title!r} has no directive after it")
            pending_heading = None
        if page is not None:
            page.lines.append(line)
        elif line.strip():
            errors.append(f"line {number}: text before the first heading")

    if pending_heading is not None:
        _, heading_line, title = pending_heading
        errors.append(f"line {heading_line}: heading {title!r} has no directive after it")
    if home is None:
        errors.append("no `<!--@ home -->` directive: nothing to write as docs/index.md")

    if errors:
        raise ManualError("\n".join(errors))

    pages = [home] + [p for s in sections for p in ([s.index] if s.index else []) + s.pages]
    for section in sections:
        if section.index is not None and not any(line.strip() for line in section.index.lines):
            pages.remove(section.index)
            section.index = None
    return pages, sections


def index_anchors(pages: list[Page]) -> dict[str, Page]:
    """Map every anchor in the manual to the page that owns it."""
    owner: dict[str, Page] = {}
    duplicates: list[str] = []
    for page in pages:
        for anchor in [heading_anchor(page.title)] + page.anchors:
            if anchor in owner:
                duplicates.append(f"#{anchor}: {owner[anchor].path} and {page.path}")
            owner[anchor] = page
    if duplicates:
        raise ManualError(
            "two headings share one anchor, so a link to it is ambiguous:\n"
            + "\n".join("  " + d for d in duplicates)
        )
    return owner


def resolve(anchor: str, source: Page, owner: dict[str, Page]) -> str:
    """Turn an in-document anchor into a link as written from `source`."""
    target = owner[anchor]
    if target is source:
        return f"#{anchor}"
    link = posixpath.relpath(target.path, posixpath.dirname(source.path) or ".")
    return link if anchor == heading_anchor(target.title) else f"{link}#{anchor}"


def render(page: Page, owner: dict[str, Page]) -> str:
    """Emit one page: its title, its body, and every anchor rewritten."""
    body = "\n".join(page.lines).strip("\n")
    if page.include:
        text = (body + "\n\n" if body else "") + f'--8<-- "{page.include}"\n'
    else:
        text = f"# {page.title}\n\n{body}\n"

    unknown: list[str] = []

    def rewrite_md(match: re.Match[str]) -> str:
        anchor = match.group(2)[1:]
        if anchor not in owner:
            unknown.append(match.group(2))
            return match.group(0)
        return f"[{match.group(1)}]({resolve(anchor, page, owner)})"

    def rewrite_html(match: re.Match[str]) -> str:
        anchor = match.group(2)[1:]
        if anchor not in owner:
            unknown.append(match.group(2))
            return match.group(0)
        return match.group(1) + resolve(anchor, page, owner) + match.group(3)

    text = MD_LINK.sub(rewrite_md, text)
    text = HTML_ANCHOR.sub(rewrite_html, text)
    if posixpath.dirname(page.path):
        text = MD_IMAGE.sub(lambda m: m.group(1) + "../" + m.group(2), text)
    if unknown:
        raise ManualError(
            f"{page.path}: link to an anchor no heading provides: " + ", ".join(sorted(set(unknown)))
        )
    return text


def render_nav(home: Page, sections: list[Section]) -> str:
    """Build the `nav:` block mkdocs.yml ends with."""
    lines = ["nav:", f"  - {home.nav}: {home.path}"]
    for section in sections:
        lines.append(f"  - {section.nav}:")
        if section.index is not None:
            lines.append(f"      - {section.index.path}")
        for page in section.pages:
            lines.append(f"      - {page.nav}: {page.path}")
    return "\n".join(lines) + "\n"


def reference_files() -> list[Path]:
    """Every references.bib: what a run cites, plus the manual's own context-only entries."""
    found = [MANUAL.parent / "references.bib",
             REPO / "install" / "references.bib",
             REPO / "analysis" / "references.bib"]
    found += sorted((REPO / "analysis" / "modules").glob("*/references.bib"))
    return [path for path in found if path.exists()]


def load_references() -> dict[str, dict[str, str]]:
    """Every entry by its BibTeX key. A key defined twice is a citation that means two things."""
    entries: dict[str, dict[str, str]] = {}
    for path in reference_files():
        try:
            _comment, parsed = bib2citations.parse(path.read_text(encoding="utf-8"))
        except bib2citations.BibError as error:
            raise ManualError(f"{path.relative_to(REPO)}: {error}") from error
        for _kind, key, fields in parsed:
            if key in entries:
                raise ManualError(f"@{key} is defined in two references.bib files")
            entries[key] = dict(fields)
    return entries


def detex(text: str) -> str:
    """A BibTeX-escaped name as it should read. `Schl{\\"o}tterer` is one word to a person."""
    def one(match: re.Match[str]) -> str:
        return unicodedata.normalize("NFC", match.group(2) + ACCENTS[match.group(1)])
    return re.sub(r"\{\\([\"'`^~])\s*\{?(\w)\}?\}", one, text).replace("{", "").replace("}", "")


def format_authors(entry: dict[str, str]) -> str:
    """`Nei, M.`, `Futschik, A. & Schlötterer, C.`, and so on for the whole list."""
    people = []
    for name in [a.strip() for a in entry.get("authors", "").split(" and ") if a.strip()]:
        surname, _, given = detex(name).partition(",")
        initials = " ".join(f"{part[0]}." for part in given.split() if part)
        people.append(f"{surname}, {initials}" if initials else surname)
    if len(people) > 1:
        return ", ".join(people[:-1]) + " & " + people[-1]
    return people[0] if people else ""


def short_cite(entry: dict[str, str], suffix: str = "") -> str:
    """What `[@key]` reads as in the prose: `Nei 1973`, `Kofler et al. 2011a`."""
    surnames = [detex(a).split(",")[0].strip()
                for a in entry.get("authors", "").split(" and ") if a.strip()]
    if len(surnames) > 2:
        who = f"{surnames[0]} et al."
    elif surnames:
        who = " & ".join(surnames)
    else:
        who = entry.get("name", "")
    year = entry.get("year", "") + suffix
    return f"{who} {year}".strip()


def disambiguate(cited: set[str], refs: dict[str, dict[str, str]]) -> dict[str, str]:
    """A suffix per key, so two papers by one author in one year are told apart.

    `Kofler et al. 2011` names PoPoolation and PoPoolation2 both, which is no citation at all.
    The suffix is assigned by BibTeX key, so it is the same on every rebuild.
    """
    by_label: dict[str, list[str]] = {}
    for key in sorted(cited):
        by_label.setdefault(short_cite(refs[key]), []).append(key)
    suffixes: dict[str, str] = {}
    for keys in by_label.values():
        for index, key in enumerate(keys):
            suffixes[key] = chr(ord("a") + index) if len(keys) > 1 else ""
    return suffixes


def format_entry(key: str, entry: dict[str, str], suffix: str = "") -> list[str]:
    """One bibliography item: a heading carrying its anchor, the reference, and what it is
    doing here. A heading because that is the only thing the manual takes an anchor from, and
    an anchor because a citation has to expand into a link that still names its key - otherwise
    compiling twice would find no citations the second time."""
    where = f"*{entry['journal']}*" if entry.get("journal") else entry.get("publisher", "")
    volume = entry.get("volume", "")
    if volume and entry.get("number"):
        volume += f"({entry['number']})"
    locus = ", ".join(part for part in (volume, entry.get("pages", "").replace("--", "–")) if part)
    year = f" ({entry['year']})." if entry.get("year") else "."
    head = f"**{format_authors(entry)}**{year} {detex(entry.get('title', ''))}."
    tail = " ".join(part for part in (where, locus) if part)
    if tail:
        head += f" {tail}."
    if entry.get("doi"):
        head += f" [{entry['doi']}](https://doi.org/{entry['doi']})"
    elif entry.get("url"):
        head += f" <{entry['url']}>"
    lines = [f"#### {short_cite(entry, suffix)} {{ #ref-{key} }}", "", head]
    if entry.get("note"):
        lines.append(f": {entry['note']}")
    return lines


def compile_bibliography(text: str, refs: dict[str, dict[str, str]]) -> str:
    """Expand every `[@key]` and rewrite the generated block between the bibliography markers.

    The manual is what ships and what a person reads offline, so the compiled form has to live
    in it - the same arrangement mkdocs.yml's nav is in, and checked the same way.
    """
    cited = {m.group(1) for m in CITE.finditer(text)} | {m.group(2) for m in CITED.finditer(text)}
    unknown = sorted(cited - set(refs))
    if unknown:
        raise ManualError("cited with no entry in any references.bib: @" + ", @".join(unknown))

    grouped: dict[str, list[str]] = {}
    for key in cited:
        group = refs[key].get("group")
        if not group:
            raise ManualError(f"@{key} is cited but its entry names no `group`")
        if group not in BIBLIOGRAPHY_GROUPS:
            raise ManualError(
                f"@{key} is in group {group!r}, which is not one of the headings "
                f"build_docs.py knows: " + ", ".join(BIBLIOGRAPHY_GROUPS))
        grouped.setdefault(group, []).append(key)

    suffixes = disambiguate(cited, refs)

    def link(key: str) -> str:
        return f"[{short_cite(refs[key], suffixes[key])}](#ref-{key})"

    # Both forms are rewritten, so what a citation READS as is generated too: an entry whose
    # year moves, or which needs an a/b suffix it did not need before, updates everywhere.
    text = CITE.sub(lambda m: link(m.group(1)), text)
    text = CITED.sub(lambda m: link(m.group(2)), text)

    body: list[str] = []
    for group in BIBLIOGRAPHY_GROUPS:
        if group not in grouped:
            continue
        body += ["", f"### {group}", ""]
        for index, key in enumerate(sorted(grouped[group],
                                           key=lambda k: (refs[k].get("year", ""), k))):
            if index:
                body.append("")
            body += format_entry(key, refs[key], suffixes[key])

    start, marker, rest = text.partition(BIB_START)
    if not marker:
        raise ManualError(f"no `{BIB_START}` marker to write the bibliography into")
    _old, end_marker, after = rest.partition(BIB_END)
    if not end_marker:
        raise ManualError(f"no `{BIB_END}` marker closing the bibliography")
    return start + BIB_START + "\n".join(body).rstrip("\n") + "\n\n" + BIB_END + after


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the manual and the generated nav, write nothing",
    )
    args = parser.parse_args()

    try:
        source = MANUAL.read_text()
        compiled = compile_bibliography(source, load_references())
    except ManualError as error:
        print(f"{MANUAL.relative_to(REPO)}: {error}", file=sys.stderr)
        return 1
    if compiled != source:
        if args.check:
            print(f"{MANUAL.relative_to(REPO)}: the Bibliography is out of date with the "
                  f"references.bib files, or a [@key] is unexpanded", file=sys.stderr)
            print("run: python3 dev/scripts/build_docs.py", file=sys.stderr)
            return 1
        MANUAL.write_text(compiled)
        source = compiled

    try:
        pages, sections = parse(source)
        owner = index_anchors(pages)
        rendered = {page.path: render(page, owner) for page in pages}
    except ManualError as error:
        print(f"{MANUAL.relative_to(REPO)}: {error}", file=sys.stderr)
        return 1

    config = MKDOCS.read_text()
    head, marker, _ = config.partition("\nnav:")
    if not marker:
        print(f"{MKDOCS.relative_to(REPO)}: no `nav:` block to replace", file=sys.stderr)
        return 1
    nav = head + "\n" + render_nav(pages[0], sections)

    # docs/ is untracked output, so the only generated thing worth checking is the nav.
    if args.check:
        if MKDOCS.read_text() != nav:
            print(f"{MKDOCS.relative_to(REPO)}: nav is out of date with the manual", file=sys.stderr)
            print("run: python3 dev/scripts/build_docs.py", file=sys.stderr)
            return 1
        print(f"manual is valid: {len(rendered)} pages, {len(owner)} anchors, nav current")
        return 0

    # Only rewrite what changed, so `mkdocs serve` rebuilds the edited page and not the site.
    changed = 0
    if MKDOCS.read_text() != nav:
        MKDOCS.write_text(nav)
        changed += 1
    for path, text in rendered.items():
        target = DOCS / path
        if target.exists() and target.read_text() == text:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        changed += 1
    for orphan in sorted({str(p.relative_to(DOCS)) for p in DOCS.rglob("*.md")} - set(rendered)):
        (DOCS / orphan).unlink()
    for name in STATIC:
        shutil.copytree(MANUAL.parent / name, DOCS / name, dirs_exist_ok=True)
    for directory in sorted(DOCS.rglob("*"), reverse=True):
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()

    print(f"{len(rendered)} pages, {changed} written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
