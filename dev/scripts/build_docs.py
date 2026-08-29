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


class ManualError(Exception):
    """One or more problems in the manual, reported together."""


def slugify(text: str) -> str:
    """Reproduce Python-Markdown's toc slugify over a heading's rendered text."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("`", "").replace("*", "").replace("_", "")
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate the manual and the generated nav, write nothing",
    )
    args = parser.parse_args()

    try:
        pages, sections = parse(MANUAL.read_text())
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

    MKDOCS.write_text(nav)
    for path, text in rendered.items():
        target = DOCS / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    for orphan in sorted({str(p.relative_to(DOCS)) for p in DOCS.rglob("*.md")} - set(rendered)):
        (DOCS / orphan).unlink()
    for name in STATIC:
        shutil.copytree(MANUAL.parent / name, DOCS / name, dirs_exist_ok=True)
    for directory in sorted(DOCS.rglob("*"), reverse=True):
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()

    print(f"wrote {len(rendered)} pages, {len(STATIC)} asset directories and the nav")
    return 0


if __name__ == "__main__":
    sys.exit(main())
