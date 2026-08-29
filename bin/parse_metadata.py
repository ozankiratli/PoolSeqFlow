#!/usr/bin/env python3
"""Read and check the sample metadata CSV, and emit it as JSON for the pipeline to consume.

Usage: parse_metadata.py <csv-path>

Exit 0 and print a JSON array of sample records; exit 1 and print every problem found to
stderr; exit 2 for a usage mistake, so a caller can tell "your file is wrong" from "you
called me wrong".

WHAT THIS FILE IS FOR. It replaces RGTags.csv, which was a SAM header fragment: its columns
were raw @RG tags and nothing else fitted in it. What a pool-seq experiment actually needs
recorded - which population a sample belongs to, which timepoint, which replicate - had
nowhere to live, so it ended up encoded in the DS field or in the sample name. Here the user
writes what they need: SampleID, the RG_* columns that become read-group tags, and any number
of columns of their own that the pipeline records and never interprets.

FOUR KINDS OF COLUMN, and the prefix is what separates them:

    SampleID        required. Joins to the sample id derived from the FASTQ file names, and
                    becomes the read group's ID.
    RG_*            a read group tag, by the table below. Nothing else may start with RG_ -
                    an unknown one is a typo, and accepting it would put a tag in the BAM
                    header that no reader expects, or silently drop the value.
    param_*         a per-sample override of a pipeline parameter, by the table below. Same
                    rule as RG_: the list is closed and an unknown one is refused, because a
                    column called param_anything that the pipeline ignores is a setting the
                    user believes is in effect and is not.
    anything else   design metadata. Recorded, never read by steps 0-8, and there for the
                    analysis layer and for whoever reads the results in two years.

PARAM_POOLSIZE IS KEYED BY RG_Sample, NOT BY SampleID, and that is not a detail. Rows sharing
an RG_Sample are one pool: bcftools names VCF sample columns by SM, so their reads are merged
into a single column and their depths added. The false-positive filter's sensitivity is
1 / (2 * diploidy * poolSize), one number per COLUMN - so two lanes of one pool cannot carry
two different pool sizes, and being asked to pick one silently is how a filter ends up applied
at a threshold nobody chose. Rows of one pool must agree, or the file is refused.

WHY THIS IS PYTHON AND NOT AWK OR SHELL, and it is the same reason as parse_multirun.py: the
values are free text. A description field reading `Pop1, replicate 2` is ordinary, and
splitting on commas would cut it in half and report a row with one field too many - the kind
of wrong that looks like a different mistake entirely. csv.reader implements the real quoting
rules. It also means nothing else in the pipeline has to parse this file: the JSON goes into
each run map once, and step 4, step 6 and the change guard all read that instead of re-reading
the CSV in bash, in Groovy, and in awk as they did when it was RGTags.csv.

WHY IT REPORTS EVERYTHING RATHER THAN THE FIRST PROBLEM. A hand-written table with four
mistakes should take one fix-and-rerun cycle, not four. Each message carries its line number.

A BLANK CELL MEANS "NO VALUE", not "inherit" - which is the opposite of the multi-run table
and is why the two parsers do not share one. A blank RG_ cell omits that tag from the read
group; a blank adapter cell falls back to the global setting; a blank design cell is just
blank. Every column is therefore kept in the output, blanks included, and each consumer
decides what an empty string means to it.
"""

import csv
import json
import re
import sys

SAMPLE_ID = "SampleID"

# The read group tags this pipeline accepts, by the name the user writes. Human-readable
# rather than raw two-letter tags: `RG_PlatformUnit` says what it is, `PU` does not, and the
# file is meant to be written by hand. The set is exactly what RGTags.csv allowed, so no
# read group loses a field in the move.
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

# The parameters a row may override, by the name the user writes, mapped to the parameter in
# parameters.config each one displaces. A CLOSED LIST, for the same reason RG_TAGS is one: the
# prefix is a promise that the pipeline acts on the column, and a param_ column it silently
# ignored would be worse than no column at all - the user would believe the setting was live.
PARAM_COLUMNS = {
    "param_poolSize": "poolSize",
    "param_adapter1": "trim_galore.adapter1",
    "param_adapter2": "trim_galore.adapter2",
}

# The two param_ columns with rules of their own, beyond being recognised.
#
# There is no RESERVED tuple any more: it listed the names a design column may not take, and
# nothing read it. The two prefixes are what reserve those names now, and they do it by shape
# rather than by enumeration - so a design column cannot collide with a future param_ or RG_
# one at all, which is the reason for having prefixes in the first place.
POOL_SIZE = "param_poolSize"
ADAPTER_COLUMNS = ("param_adapter1", "param_adapter2")

# A tab ends a field in the SAM header, and a control character has no business in one.
BAD_IN_TAG = re.compile(r"[\t\r\n\x00-\x08\x0b\x0c\x0e-\x1f]")


def rows_of(path):
    """Every non-blank, non-comment row, paired with the line it came from.

    Comments are whole lines starting with `#`, tested before parsing so that a `#` inside a
    quoted value is left alone. CRLF is tolerated rather than repaired: the pipeline used to
    rewrite the user's own file to fix line endings, and not doing that any more is one of
    the reasons this parser exists.
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
            # The prefix missing rather than misspelled. Without this the column would be
            # accepted as design metadata and silently ignored, which is the one outcome the
            # prefix rule exists to prevent: the user reads their own header back and believes
            # the override is in effect.
            errors.append(
                f"line {header_line}: '{column}' is missing its prefix - write "
                f"'param_{column}' if you mean to override {PARAM_COLUMNS['param_' + column]} "
                f"for these samples. As written it would be recorded as design metadata and "
                f"never acted on."
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

    # Field counts and SampleID values. Reported even when the header is already wrong, so
    # one pass finds everything.
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

        # Trim Galore takes both adapters or auto-detects; one of the two is a setting that
        # cannot be acted on, so it is refused rather than half applied.
        present = [c for c in ADAPTER_COLUMNS if row.get(c)]
        if len(present) == 1:
            errors.append(
                f"line {lineno}: {present[0]} is set but "
                f"{[c for c in ADAPTER_COLUMNS if c not in present][0]} is not. Give both "
                f"adapter sequences for a sample, or neither and let the global setting apply."
            )

        # A pool is a whole number of individuals, and sensitivity divides by it. A blank cell
        # means "use the global poolSize"; anything else has to be a count.
        size = row.get(POOL_SIZE, "")
        if size and not (size.isdigit() and int(size) > 0):
            errors.append(
                f"line {lineno}: {POOL_SIZE} '{size}' is not a whole number of individuals. "
                f"It is how many individuals went into the pool, and sensitivity is "
                f"1 / (2 * diploidy * {POOL_SIZE}). Leave it blank to use the global poolSize."
            )

    # ONE POOL, ONE SIZE. Rows sharing an RG_Sample become a single VCF column, which gets a
    # single sensitivity - so the pipeline cannot honour two sizes for one pool, and picking
    # one silently would filter that column at a threshold the user never chose. A blank cell
    # is a disagreement too: it says "use the global", which is a different number again.
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
    # RG_Sample is filled in from SampleID when it is absent or blank, here rather than at
    # each consumer: it decides which VCF column a sample lands in, so a second place to
    # derive it is a second place for it to be derived differently. What comes out of this
    # function is the EFFECTIVE row.
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
