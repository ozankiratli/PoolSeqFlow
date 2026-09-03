#!/usr/bin/env python3
"""Read and check the sample metadata CSV, and emit it as JSON for the pipeline to consume.

Usage: parse_metadata.py <csv-path>

Exit 0 and print a JSON array of sample records; exit 1 and print every problem found to
stderr; exit 2 for a usage mistake, so a caller can tell "your file is wrong" from "you
called me wrong".

FIVE KINDS OF COLUMN, and the prefix is what separates them:

    SampleID        required. Joins to the sample id derived from the FASTQ file names, and
                    becomes the read group's ID.
    RG_*            a read group tag, by the table below. A closed list: an unknown RG_ column
                    is refused.
    param_*         a per-sample override of a pipeline parameter, by the table below. Also a
                    closed list, refused the same way.
    exp_*           an experimental variable. An OPEN list: any name after the prefix is
                    accepted, so exp_tiempoint is a variable and not an error. Recorded, never
                    read by steps 0-8.
    anything else   design metadata. Recorded, never read by steps 0-8.

pt_* IS RESERVED AND REFUSED. It has no meaning yet, and every pt_ column is refused so that
one can be given to it later without changing what a file written today means.

PARAM_POOLSIZE IS KEYED BY RG_Sample, NOT BY SampleID. Rows sharing an RG_Sample are one pool
and become one VCF column, which carries one sensitivity, so those rows must agree on the size
or the file is refused.

Every problem is reported at once, with line numbers.

A BLANK CELL MEANS "NO VALUE", not "inherit" - the opposite of the multi-run table. Every column
is kept in the output, blanks included, and each consumer decides what an empty string means.
"""

import csv
import json
import re
import sys

SAMPLE_ID = "SampleID"

# The read group tags this pipeline accepts, by the name the user writes. Mirrored by rgTagMap()
# in scripts/metadata.nf.
RG_TAGS = {
    "RG_Sample": "SM",
    "RG_Library": "LB",
    "RG_Platform": "PL",
    "RG_PlatformUnit": "PU",
    "RG_Description": "DS",
    "RG_Center": "CN",
    "RG_Date": "DT",
    "RG_FlowOrder": "FO",
}

# The parameters a row may override, mapped to the parameter each one displaces. Mirrored by
# paramColumns() in scripts/metadata.nf. A CLOSED LIST, like RG_TAGS.
PARAM_COLUMNS = {
    "param_poolSize": "poolSize",
    "param_capMaxDepth": "capBAM.maxDepth",
    "param_adapter1": "trim_galore.adapter1",
    "param_adapter2": "trim_galore.adapter2",
}

# An experimental variable. Open where RG_ and param_ are closed: there is no list to check a
# name against, so nothing here can catch a misspelling.
EXPERIMENTAL_PREFIX = "exp_"
TIME_VARIABLE = "exp_time"

# Claimed and unused. Every column carrying it is refused.
RESERVED_PREFIX = "pt_"

# The param_ columns with rules of their own, beyond being recognised.
POOL_SIZE = "param_poolSize"
CAP_MAX_DEPTH = "param_capMaxDepth"
ADAPTER_COLUMNS = ("param_adapter1", "param_adapter2")

# A tab ends a field in the SAM header, and a control character has no business in one.
BAD_IN_TAG = re.compile(r"[\t\r\n\x00-\x08\x0b\x0c\x0e-\x1f]")


def rows_of(path):
    """Every non-blank, non-comment row, paired with the line it came from.

    Comments are whole lines starting with `#`, tested before parsing so that a `#` inside a
    quoted value is left alone. CRLF is tolerated; the file is never rewritten.
    """
    out = []
    with open(path, newline="", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, start=1):
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
        elif column.startswith("RG_") and column not in RG_TAGS:
            errors.append(
                f"line {header_line}: '{column}' is not a read group tag. The RG_ prefix is "
                f"reserved for them, so this is almost certainly a typo. Known: "
                f"{', '.join(sorted(RG_TAGS))}. For anything else, drop the RG_ prefix and it "
                f"becomes a column the pipeline records and never interprets."
            )
        elif column.startswith("param_") and column not in PARAM_COLUMNS:
            errors.append(
                f"line {header_line}: '{column}' is not a per-sample parameter. The param_ "
                f"prefix is reserved for the ones the pipeline can act on, so this is almost "
                f"certainly a typo. Known: {', '.join(sorted(PARAM_COLUMNS))}. For anything "
                f"else, drop the param_ prefix and it becomes a column the pipeline records "
                f"and never interprets."
            )
        elif f"param_{column}" in PARAM_COLUMNS:
            # A recognised name with the prefix missing, which would pass as design metadata.
            errors.append(
                f"line {header_line}: '{column}' is missing its prefix - write "
                f"'param_{column}' if you mean to override {PARAM_COLUMNS['param_' + column]} "
                f"for these samples. As written it would be recorded as design metadata and "
                f"never acted on."
            )
        elif column.startswith(RESERVED_PREFIX):
            errors.append(
                f"line {header_line}: '{column}' uses the {RESERVED_PREFIX} prefix, which is "
                f"reserved and carries no meaning yet. Every {RESERVED_PREFIX} column is "
                f"refused so that one can be given to it later without changing what a file "
                f"written today means. Drop the prefix and it becomes a column that is "
                f"recorded and never interpreted."
            )
        elif column == EXPERIMENTAL_PREFIX:
            errors.append(
                f"line {header_line}: '{EXPERIMENTAL_PREFIX}' is the prefix with no variable "
                f"name after it. Write {EXPERIMENTAL_PREFIX}<name> - {TIME_VARIABLE}, "
                f"{EXPERIMENTAL_PREFIX}treatment - or drop the prefix."
            )
        if column:
            seen[column] = seen.get(column, 0) + 1

    for column, count in seen.items():
        if count > 1:
            errors.append(f"line {header_line}: column '{column}' appears {count} times")

    if SAMPLE_ID not in header:
        errors.append(
            f"line {header_line}: no '{SAMPLE_ID}' column. Every row needs one: it is what "
            f"joins the row to a pair of FASTQ files, and it becomes the read group's ID."
        )

    if not body:
        errors.append(f"{path}: has a header but no samples")

    # Field counts and SampleID values, reported even when the header is already wrong.
    width = len(header)
    ids = {}
    id_at = header.index(SAMPLE_ID) if SAMPLE_ID in header else None

    for lineno, fields in body:
        if len(fields) != width:
            errors.append(
                f"line {lineno}: has {len(fields)} fields, the header has {width}. "
                f"A value containing a comma must be quoted."
            )
            continue
        if id_at is None:
            continue
        sample_id = fields[id_at]
        if not sample_id:
            errors.append(f"line {lineno}: {SAMPLE_ID} is empty")
        elif BAD_IN_TAG.search(sample_id):
            errors.append(
                f"line {lineno}: {SAMPLE_ID} '{sample_id}' contains a tab or control "
                f"character; it goes into the BAM header, where a tab ends the field"
            )
        else:
            ids.setdefault(sample_id, []).append(lineno)

    for sample_id, lines in ids.items():
        if len(lines) > 1:
            errors.append(
                f"{SAMPLE_ID} '{sample_id}' is used on lines "
                f"{', '.join(str(n) for n in lines)} - each row needs its own. Two "
                f"sequencing runs of one pool are two rows with two ids that share an "
                f"RG_Sample; that is what merges them into one column."
            )

    # Per-row checks that need a well-formed row to be worth making.
    for lineno, fields in body:
        if len(fields) != width:
            continue
        row = dict(zip(header, fields))

        for column in header:
            if column in RG_TAGS and BAD_IN_TAG.search(row[column]):
                errors.append(
                    f"line {lineno}: {column} contains a tab or control character; it goes "
                    f"into the BAM header, where a tab ends the field"
                )

        # Trim Galore takes both adapters or auto-detects, so one alone cannot be acted on.
        present = [c for c in ADAPTER_COLUMNS if row.get(c)]
        if len(present) == 1:
            errors.append(
                f"line {lineno}: {present[0]} is set but "
                f"{[c for c in ADAPTER_COLUMNS if c not in present][0]} is not. Give both "
                f"adapter sequences for a sample, or neither and let the global setting apply."
            )

        # A blank cell means the global poolSize; anything else has to be a positive count.
        size = row.get(POOL_SIZE, "")
        if size and not (size.isdigit() and int(size) > 0):
            errors.append(
                f"line {lineno}: {POOL_SIZE} '{size}' is not a whole number of individuals. "
                f"It is how many individuals went into the pool, and sensitivity is "
                f"1 / (2 * diploidy * {POOL_SIZE}). Leave it blank to use the global poolSize."
            )

        # -1, 0 and any positive depth are all valid, so only the shape is checked.
        cap = row.get(CAP_MAX_DEPTH, "")
        if cap and not (cap == "-1" or cap.isdigit()):
            errors.append(
                f"line {lineno}: {CAP_MAX_DEPTH} '{cap}' is not a depth. Write -1 to measure "
                f"this sample's ceiling from its own depth histogram, 0 to leave it uncapped, "
                f"or the depth to cap it at. Leave it blank to use the global capBAM.maxDepth."
            )

    # ONE POOL, ONE SIZE: rows sharing an RG_Sample become a single VCF column. A blank cell
    # counts as a disagreement, since it means the global poolSize.
    if POOL_SIZE in header:
        sizes = {}
        for lineno, fields in body:
            if len(fields) != width:
                continue
            row = dict(zip(header, fields))
            pool = row.get("RG_Sample") or row.get(SAMPLE_ID, "")
            sizes.setdefault(pool, {}).setdefault(row.get(POOL_SIZE, ""), []).append(lineno)

        for pool, by_size in sizes.items():
            if len(by_size) > 1:
                stated = ", ".join(
                    f"'{size or '(blank)'}' on line{'s' if len(lines) > 1 else ''} "
                    f"{', '.join(str(n) for n in lines)}"
                    for size, lines in sorted(by_size.items())
                )
                errors.append(
                    f"RG_Sample '{pool}' is given more than one {POOL_SIZE}: {stated}. Rows "
                    f"sharing an RG_Sample are one pool and become one VCF column, so they "
                    f"need one size. A blank cell means the global poolSize, which is a third "
                    f"answer rather than agreement with either."
                )

    if errors:
        return None, errors

    # --- the records themselves ---
    #
    # RG_Sample is filled in from SampleID when absent or blank, so what comes out is the
    # EFFECTIVE row and no consumer re-derives it.
    records = []
    for _lineno, fields in body:
        record = dict(zip(header, fields))
        if not record.get("RG_Sample"):
            record["RG_Sample"] = record[SAMPLE_ID]
        records.append(record)
    return records, []


def main(argv):
    if len(argv) != 2:
        print(f"Usage: {argv[0].split('/')[-1]} <csv-path>", file=sys.stderr)
        return 2

    records, errors = check(argv[1])
    if errors:
        print(f"{argv[1]}: cannot be used as a sample metadata file.", file=sys.stderr)
        for message in errors:
            print(f"  {message}", file=sys.stderr)
        return 1

    json.dump(records, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
