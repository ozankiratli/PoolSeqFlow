#!/usr/bin/env python3
r"""Read a GitHub workflow file into JSON, with nothing outside Python's standard library.

Usage: workflow_yaml.py <workflow.yml>

Prints the file as one JSON value. Exits 1 with "file:line: message" for anything it does not
read and "file: message" for a file it cannot read as text, and exits 2 for a usage mistake.

00_static asks questions of the files under .github/workflows, and it runs on whichever python3
the shell finds, which is the active conda environment's when there is one. Neither PoolSeqFlow
environment carries PyYAML. The case that imported it passed every run on a system Python that
happened to have it, and failed the 3.3.0 prep run on 2026-10-08, launched from a shell with the
analysis environment active, with ModuleNotFoundError. So this reads the part of YAML those files
are written in, and REFUSES everything else rather than guessing at it, so that a workflow edit
reaching past it fails the case instead of being misread:

    block mappings and block sequences, a sequence item holding a mapping ("- uses: ..."), a
    sequence at the same indentation as the key it belongs to, plain scalars, single-quoted
    scalars, double-quoted scalars whose only escapes are \" \\ \/ \n and \t, flow sequences of
    scalars ([a, "b"] and []), literal and folded block scalars with clip or strip chomping
    (|, |-, >, >-), and comments.

A line ends at \n, \r\n or \r, as YAML ends one; Python's text mode reads all three as \n.

Refused: any other character outside printable ASCII but the tab, a byte-order mark included; a
tab in the indentation, or on a line of nothing but white space inside a block scalar; anchors,
aliases, tags, flow mappings and document markers; a value or flow item starting with "- ", ",",
"]" or "}", and a flow item holding ": " or a comment; a plain scalar continued onto a second
line; a block scalar with an indentation or keep indicator; a key given twice; nesting deeper
than Python's recursion allows; and anything else it cannot place.

Every scalar is a string. That includes the `on` key, which PyYAML reads as the boolean true
under YAML 1.1: a property of that library, not of the file, and every question the cases ask
compares text.

The first version, written the same day, was compared with PyYAML by a review over some 360,000
generated documents and misread five things: plain flow items, which skipped every check a block
value gets; folding beside an empty line; white-space-only lines inside a block scalar, whose
spaces past the block's indentation are text; a block scalar ending a file with no final line
break, which gained one; and characters outside ASCII, which are refused now rather than read.
"""

import json
import re
import sys

# A key as these files write one: plain, starting with a letter, a digit or an underscore, or
# quoted. What follows the colon is the value, when there is one.
KEY = re.compile(r'''^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[A-Za-z0-9_][^:#]*?)\s*:(?:\s+(.*))?$''')

ESCAPES = {'"': '"', "\\": "\\", "/": "/", "n": "\n", "t": "\t"}

# What a value may not start with: an anchor, an alias, a tag, a flow mapping, a directive, the two
# reserved indicators, a complex key, and the flow indicators that only separate or close.
UNTAKEN = "&*!{%@`?,]}"

NOT_PRINTABLE = re.compile(r"[^\t\x20-\x7e]")


class Refused(Exception):
    pass


class Reader:
    def __init__(self, text, name):
        self.name = name
        self.i = 0
        self.lines = text.replace("\r\n", "\n").split("\n")
        for k, line in enumerate(self.lines):
            odd = NOT_PRINTABLE.search(line)
            if odd:
                self.refuse("a character outside printable ASCII, U+%04X, which this reader does "
                            "not take" % ord(odd.group(0)), k)

    def refuse(self, message, line=None):
        raise Refused("%s:%d: %s" % (self.name, (self.i if line is None else line) + 1, message))

    def peek(self):
        """The next line holding content, as (indent, text), past blank lines and comments."""
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            body = raw.lstrip(" ")
            if body.startswith("\t"):
                self.refuse("a tab in the indentation")
            if body.strip() == "" or body.startswith("#"):
                self.i += 1
                continue
            if len(raw) == len(body) and body.rstrip() in ("---", "..."):
                self.refuse("a document marker")
            return len(raw) - len(body), body.rstrip()
        return None

    @staticmethod
    def is_item(text):
        return text == "-" or text.startswith("- ")

    def node(self, indent):
        """The block whose first content line is the next one, at `indent`."""
        if self.is_item(self.peek()[1]):
            return self.sequence(indent)
        return self.mapping(indent)

    def mapping(self, indent):
        result = {}
        while True:
            here = self.peek()
            if here is None or here[0] < indent:
                return result
            if here[0] > indent:
                self.refuse("indented further than the mapping it belongs to")
            if self.is_item(here[1]):
                self.refuse("a sequence item among the keys of a mapping")
            match = KEY.match(here[1])
            if not match:
                self.refuse("expected a key: %s" % here[1])
            key = self.key(match.group(1))
            if key in result:
                self.refuse("the key '%s' given twice" % key)
            line = self.i
            self.i += 1
            result[key] = self.value(match.group(2) or "", indent, line)

    def key(self, text):
        """A key as KEY matched it: a quoted key is exactly its quotes and what they hold."""
        if text[0] in "\"'":
            return self.quoted(text, self.i)[0]
        return text.rstrip()

    def value(self, text, indent, line):
        """The value of a key at `indent`, whose text after the colon is `text`."""
        text = text.strip()
        if text == "" or text.startswith("#"):
            here = self.peek()
            if here is not None and here[0] > indent:
                return self.node(here[0])
            if here is not None and here[0] == indent and self.is_item(here[1]):
                return self.sequence(indent)
            return None
        if text[0] in "|>":
            return self.block(text, indent, line)
        result = self.scalar(text, line)
        here = self.peek()
        if here is not None and here[0] > indent:
            self.refuse("a value continued onto a second line, or a block under a key that "
                        "already has a value")
        return result

    def sequence(self, indent):
        result = []
        while True:
            here = self.peek()
            if here is None or here[0] < indent:
                return result
            if here[0] > indent:
                self.refuse("indented further than the sequence it belongs to")
            text = here[1]
            if not self.is_item(text):
                # A key at the sequence's own indentation: the sequence was the value of the key
                # above it, written at that key's indentation, and the mapping goes on.
                return result
            rest = text[1:].lstrip(" ")
            line = self.i
            if rest == "" or rest.startswith("#"):
                self.i += 1
                below = self.peek()
                result.append(self.node(below[0]) if below is not None and below[0] > indent
                              else None)
                continue
            if self.is_item(rest):
                self.refuse("a sequence item holding a sequence on the same line")
            column = indent + len(text) - len(rest)
            if KEY.match(rest):
                # The item is a mapping whose first key shares the item's line: read that line
                # again as the key it is, at the column it starts at.
                self.lines[self.i] = " " * column + rest
                result.append(self.mapping(column))
                continue
            self.i += 1
            if rest[0] in "|>":
                result.append(self.block(rest, indent, line))
                continue
            result.append(self.scalar(rest, line))
            below = self.peek()
            if below is not None and below[0] > indent:
                self.refuse("a sequence item continued onto a second line")

    def block(self, header, indent, line):
        """A literal or folded block scalar under a line at `indent`.

        Its indentation is its first line holding text. A line of white space alone is empty up
        to that indentation and text past it. A line less indented than that and more than
        `indent` ends the block when it is a comment and is refused otherwise.
        """
        match = re.fullmatch(r"([|>])(-?)(\s+#.*)?", header)
        if not match:
            self.refuse("a block scalar header this reader does not take: %s" % header, line)
        folded, strip = match.group(1) == ">", match.group(2) == "-"
        content = None
        leading, leading_at = 0, None
        lines = []
        last = None
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            body = raw.lstrip(" ")
            width = len(raw) - len(body)
            if body.strip(" \t") == "":
                if "\t" in body:
                    self.refuse("a line of nothing but white space holding a tab, inside a block "
                                "scalar")
                if content is None:
                    if width > leading:
                        leading, leading_at = width, self.i
                    lines.append("")
                elif width > content:
                    lines.append(raw[content:])
                    last = self.i
                else:
                    lines.append("")
                self.i += 1
                continue
            if width <= indent:
                break
            if content is None:
                content = width
                if leading > content:
                    self.refuse("a line of white space before the block scalar's first line, "
                                "wider than it", leading_at)
            elif width < content:
                if body.startswith("#"):
                    break
                self.refuse("a block scalar line indented less than its first line")
            lines.append(raw[content:])
            last = self.i
            self.i += 1
        while lines and lines[-1] == "":
            lines.pop()
        if not lines:
            return ""
        text = self.fold(lines) if folded else "\n".join(lines)
        # Clip keeps the line break after the last line of text, and a file can end without one.
        broken = last < len(self.lines) - 1
        return text if strip or not broken else text + "\n"

    @staticmethod
    def fold(lines):
        """Folded style, by YAML's rule: each empty line is a line break of its own; between two
        lines of text with no empty line between them the break is a space; and a break beside a
        line that starts with white space is kept."""
        out, spaced_before, empties = "", None, 0
        for line in lines:
            if line == "":
                empties += 1
                continue
            spaced = line[0] in " \t"
            if spaced_before is None:
                out = "\n" * empties + line
            elif not spaced and not spaced_before:
                out += (" " if empties == 0 else "\n" * empties) + line
            else:
                out += "\n" * (empties + 1) + line
            spaced_before, empties = spaced, 0
        return out

    def untaken(self, text, line, what):
        if text[0] in UNTAKEN or self.is_item(text):
            self.refuse("%s starting with '%s', which this reader does not take" % (what, text[0]),
                        line)

    def scalar(self, text, line):
        self.untaken(text, line, "a value")
        if text[0] in "\"'":
            value, end = self.quoted(text, line)
            self.after(text[end:], line)
            return value
        if text[0] == "[":
            return self.flow(text, line)
        comment = re.search(r"\s#", text)
        if comment:
            text = text[:comment.start()]
        text = text.rstrip()
        if ": " in text or text.endswith(":"):
            self.refuse("a plain value holding ': ', which is a key where none can be", line)
        return text

    def quoted(self, text, line):
        """A quoted scalar at the start of `text`, and the index just past its closing quote."""
        quote, out, k = text[0], [], 1
        while k < len(text):
            c = text[k]
            if quote == "'" and c == "'":
                if text[k + 1:k + 2] == "'":
                    out.append("'")
                    k += 2
                    continue
                return "".join(out), k + 1
            if quote == '"' and c == "\\":
                escape = text[k + 1:k + 2]
                if escape not in ESCAPES:
                    self.refuse("an escape this reader does not take: \\%s" % escape, line)
                out.append(ESCAPES[escape])
                k += 2
                continue
            if quote == '"' and c == '"':
                return "".join(out), k + 1
            out.append(c)
            k += 1
        self.refuse("a quoted value that does not close on its line", line)

    def after(self, rest, line):
        if rest.strip() and not re.match(r"\s+#", rest):
            self.refuse("text after a quoted value: %s" % rest.strip(), line)

    def flow(self, text, line):
        """A flow sequence of scalars on one line: [a, "b", 'c'], or []."""
        k = 1

        def spaces(k):
            while k < len(text) and text[k] == " ":
                k += 1
            return k

        items = []
        k = spaces(k)
        if text[k:k + 1] == "]":
            self.after(text[k + 1:], line)
            return items
        while True:
            if k >= len(text):
                self.refuse("a flow sequence that does not close on its line", line)
            c = text[k]
            if c in "[{":
                self.refuse("a flow sequence holding a collection", line)
            if c in "\"'":
                value, end = self.quoted(text[k:], line)
                k += end
            else:
                plain = re.match(r"[^,\[\]{}]*", text[k:]).group(0)
                value = plain.rstrip()
                if value == "":
                    self.refuse("an empty item in a flow sequence", line)
                if value[0] in "|>#":
                    self.refuse("a flow sequence item starting with '%s', which this reader does "
                                "not take" % value[0], line)
                self.untaken(value, line, "a flow sequence item")
                if ": " in value or value.endswith(":"):
                    self.refuse("a flow sequence item holding ': ', which makes it a pair", line)
                if re.search(r"\s#", value):
                    self.refuse("a comment inside a flow sequence", line)
                k += len(plain)
            items.append(value)
            k = spaces(k)
            if text[k:k + 1] == ",":
                k = spaces(k + 1)
                continue
            if text[k:k + 1] == "]":
                self.after(text[k + 1:], line)
                return items
            self.refuse("a flow sequence item followed by something other than ',' or ']'", line)


def load(text, name):
    reader = Reader(text, name)
    here = reader.peek()
    if here is None:
        return None
    if here[0] != 0:
        reader.refuse("the document starts indented")
    value = reader.node(0)
    if reader.peek() is not None:
        reader.refuse("content after the end of the document")
    return value


def main(argv):
    if len(argv) != 2:
        print("usage: workflow_yaml.py <workflow.yml>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        print("%s: %s" % (argv[1], exc.strerror), file=sys.stderr)
        return 1
    except UnicodeDecodeError:
        print("%s: not UTF-8 text, which no workflow this reader takes can be" % argv[1],
              file=sys.stderr)
        return 1
    try:
        value = load(text, argv[1])
    except Refused as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except RecursionError:
        print("%s: nested deeper than this reader goes" % argv[1], file=sys.stderr)
        return 1
    json.dump(value, sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
