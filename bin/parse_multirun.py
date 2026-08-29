#!/usr/bin/env python3
"""Read and check the multi-run CSV, and emit it as JSON for the pipeline to consume.

Usage: parse_multirun.py <csv-path>

Exit 0 and print a JSON array of run definitions; exit 1 and print every problem found to
stderr; exit 2 for a usage mistake, so a caller can tell "your file is wrong" from "you
called me wrong".

WHY THIS IS PYTHON AND NOT AWK OR SHELL. The values here are parameter values, and one of
the parameters people are most likely to vary between runs is `readPattern`, whose default
is `*_R{1,2}.fq.gz` - a comma inside a value. Splitting on commas would quietly cut that in
half and produce a row with one field too many, which is the kind of wrong that looks like a
different mistake entirely. csv.reader implements the actual quoting rules, so
`"*_R{1,2}.fq.gz"` survives.

WHY IT REPORTS EVERYTHING RATHER THAN THE FIRST PROBLEM. A hand-written table with four
mistakes in it should take one fix-and-rerun cycle, not four. Each message carries the line
number the problem is on.

EMPTY CELL MEANS "INHERIT". A row carries only the parameters that differ from
parameters.config, so a short table stays short; anything left blank comes from the config
as usual. The consequence, stated because it is a real limit rather than an oversight:
there is no way to set a parameter to an empty STRING from this file, because an empty cell
already means something else. The one parameter where an empty string is meaningful -
trim_galore.adapterOptions - is derived from trim_galore.autodetect, so set that instead.
"""

import csv
import json
import re
import sys

# A dotted parameter name as it appears in parameters.config, with no `params.` prefix:
# `referenceFile`, `trim_galore.quality`, `bcftools.maxDepth`.
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$")

RUN_ID = "RunID"


def rows_of(path):
    """Every non-blank, non-comment row, paired with the line it came from.

    Comments are whole lines starting with `#`, tested before parsing so that a `#` inside a
    quoted value is left alone.
    """
    out = []
    with open(path, newline="", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, start=1):
            # Tolerate CRLF without rewriting the file. Step 0 used to repair line endings
            # in the user's RGTags.csv in place; that wart is gone, and this is why.
            stripped = raw.strip("\r\n").strip()
            if not stripped or stripped.startswith("#"):
                continue
            fields = next(csv.reader([raw.strip("\r\n")]))
            out.append((lineno, [f.strip() for f in fields]))
    return out


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
            f"separates the runs' outputs from each other."
        )

    if not body:
        errors.append(f"{path}: has a header but no runs")

    # Field counts and RunID values. Reported even when the header is already wrong, so one
    # pass finds everything.
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
            # are taken. Refused rather than renamed: the run would otherwise write into a
            # directory whose contents claim to belong to a different set of runs.
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
            # Blank means inherit; see the module docstring.
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

    json.dump(runs, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
