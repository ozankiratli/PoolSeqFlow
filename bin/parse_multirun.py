#!/usr/bin/env python3
"""Read and check the multi-run CSV, and emit it as JSON for the pipeline to consume.

Usage: parse_multirun.py <csv-path>

Exit 0 and print a JSON array of run definitions; exit 1 and print every problem found to
stderr; exit 2 for a usage mistake, so a caller can tell "your file is wrong" from "you
called me wrong".

Every problem is reported at once, each with the line number it is on.

EMPTY CELL MEANS "INHERIT". A row carries only the parameters that differ from
parameters.config; anything left blank comes from the config as usual. So there is no way to
set a parameter to an empty STRING here. The one parameter where an empty string is meaningful,
trim_galore.adapterOptions, is derived from trim_galore.autodetect - set that instead.
"""

import csv
import json
import re
import sys

# A dotted parameter name as it appears in parameters.config, with no `params.` prefix:
# `referenceFile`, `trim_galore.quality`, `variantCall.maxDepth`.
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$")

RUN_ID = "RunID"

# The parameters a file name starts with, checked in a cell as bin/check_parameters.sh checks them
# in parameters.config: letters, digits, dot, dash and underscore, the first a letter or a digit.
FILE_NAMES = ("outputPrefix", "vcf.fileName")
FILE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def rows_of(path):
    """Every non-blank, non-comment row, paired with the line it came from.

    Comments are whole lines starting with `#`, tested before parsing so that a `#` inside a
    quoted value is left alone.

    `utf-8-sig` consumes a leading UTF-8 byte-order mark, which Excel writes when it saves as
    "CSV UTF-8". Plain `utf-8` leaves the mark on the front of the first header name, where no
    editor shows it and no message printed from here can name it.
    """
    out = []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        for lineno, raw in enumerate(handle, start=1):
            # CRLF is tolerated; the file the user wrote is never rewritten.
            stripped = raw.strip("\r\n").strip()
            if not stripped or stripped.startswith("#"):
                continue
            fields = next(csv.reader([raw.strip("\r\n")]))
            out.append((lineno, [f.strip() for f in fields]))
    return out


def leading_mark(path):
    """The name of the byte-order mark the file begins with, or None.

    Read as raw bytes, because rows_of() decodes with `utf-8-sig` and consumes a UTF-8 mark: by
    the time anything else here sees a column name, the evidence is gone. Only the UTF-8 mark is
    looked for - a UTF-16 file never reaches this, having failed to decode.
    """
    try:
        with open(path, "rb") as handle:
            return "UTF-8" if handle.read(3) == b"\xef\xbb\xbf" else None
    except OSError:
        return None


def check(path):
    errors = []

    try:
        rows = rows_of(path)
    except FileNotFoundError:
        return None, [f"{path}: no such file"]
    except OSError as exc:
        return None, [f"{path}: {exc.strerror}"]
    except csv.Error as exc:
        return None, [f"{path}: could not be read as CSV: {exc}"]
    except UnicodeDecodeError:
        return None, [
            f"{path}: is not UTF-8 text, so none of it could be read. Excel's "
            f"'Unicode Text' and a PowerShell redirect both write UTF-16. Save it as "
            f"'CSV UTF-8' and try again."
        ]

    if not rows:
        return None, [f"{path}: is empty (only blank lines and comments)"]

    header_line, header = rows[0]
    body = rows[1:]

    # --- the header ---
    seen = {}
    for column in header:
        if not column:
            errors.append(f"line {header_line}: a column has no name")
        elif column.startswith("params."):
            errors.append(
                f"line {header_line}: column '{column}' should not carry the 'params.' "
                f"prefix - write '{column[len('params.'):]}'"
            )
        elif not NAME.match(column):
            errors.append(
                f"line {header_line}: '{column}' is not a parameter name; expected "
                f"something like 'referenceFile' or 'trim_galore.quality'"
            )
        if column:
            seen[column] = seen.get(column, 0) + 1

    for column, count in seen.items():
        if count > 1:
            errors.append(f"line {header_line}: column '{column}' appears {count} times")

    if RUN_ID not in header:
        errors.append(
            f"line {header_line}: no '{RUN_ID}' column. Every run needs a name: it is what "
            f"separates the runs' outputs from each other. "
            f"The names read from that line were: "
            f"{', '.join(repr(column) for column in header)}"
        )

    if not body:
        errors.append(f"{path}: has a header but no runs")

    # Field counts and RunID values, reported even when the header is already wrong.
    width = len(header)
    ids = {}
    id_at = header.index(RUN_ID) if RUN_ID in header else None

    for lineno, fields in body:
        if len(fields) != width:
            errors.append(
                f"line {lineno}: has {len(fields)} fields, the header has {width}. "
                f"A value containing a comma must be quoted."
            )
            continue
        for column in FILE_NAMES:
            if column not in header:
                continue
            # A blank cell takes parameters.config's value, which step 0 checks.
            value = fields[header.index(column)]
            if value == "null":
                errors.append(
                    f"line {lineno}: {column} is 'null', which names nothing. Leave the cell "
                    f"blank to take the value in parameters.config, or write a name"
                )
            elif value and not FILE_NAME.match(value):
                errors.append(
                    f"line {lineno}: {column} '{value}' starts the name of the files this run "
                    f"writes; use letters, digits, dot, dash or underscore, starting with a "
                    f"letter or a digit"
                )
        if id_at is None:
            continue
        run_id = fields[id_at]
        if not run_id:
            errors.append(f"line {lineno}: {RUN_ID} is empty")
        elif not re.match(r"^[A-Za-z0-9._-]+$", run_id):
            # It becomes a directory name, so it has to be one.
            errors.append(
                f"line {lineno}: {RUN_ID} '{run_id}' is used as a directory name; use "
                f"letters, digits, dot, dash or underscore"
            )
        elif re.match(r"^(All_Runs|Shared_[0-9]+)$", run_id):
            # A run's directory sits beside the ones named for shared work, so those names
            # are taken.
            errors.append(
                f"line {lineno}: {RUN_ID} '{run_id}' is a name the pipeline uses itself. "
                f"Results shared by every run are filed under All_Runs, and results shared "
                f"by some of them under Shared_1, Shared_2 and so on, beside the directory "
                f"this run would get. Pick another name."
            )
        else:
            ids.setdefault(run_id, []).append(lineno)

    for run_id, lines in ids.items():
        if len(lines) > 1:
            errors.append(
                f"{RUN_ID} '{run_id}' is used on lines "
                f"{', '.join(str(n) for n in lines)} - each run needs its own name"
            )

    if errors:
        return None, errors

    # --- the runs themselves ---
    runs = []
    for _lineno, fields in body:
        run = {}
        for column, value in zip(header, fields):
            # A blank cell is omitted from the record, which is what makes it inherit.
            if column == RUN_ID or value != "":
                run[column] = value
        runs.append(run)
    return runs, []


def main(argv):
    if len(argv) != 2:
        print(f"Usage: {argv[0].split('/')[-1]} <csv-path>", file=sys.stderr)
        return 2

    runs, errors = check(argv[1])
    if errors:
        print(f"{argv[1]}: cannot be used as a multi-run table.", file=sys.stderr)
        for message in errors:
            print(f"  {message}", file=sys.stderr)
        return 1

    # stderr and exit 0, as parse_metadata.py does: the caller reads the table off stdout either
    # way. A note about the FILE rather than the rows, which is why it is not one of check()'s
    # errors - nothing here is wrong.
    mark = leading_mark(argv[1])
    if mark:
        print(f"{argv[1]}: usable, with notes.", file=sys.stderr)
        print(
            f"  it begins with a {mark} byte-order mark, which was read past. Nothing about "
            f"this file is wrong, but the editor that added one adds it to every file it "
            f"saves, and in parameters.config it stops the run: check that file too, and "
            f"dos2unix removes the mark.",
            file=sys.stderr,
        )

    json.dump(runs, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
