#!/usr/bin/env python3
"""British spellings in the repository, and what converting each would cost.

    dev/scripts/americanize.py                 report every hit, grouped by root
    dev/scripts/americanize.py --fix           rewrite the safe ones, in place
    dev/scripts/americanize.py --fix --all     rewrite the risky ones too
    dev/scripts/americanize.py <path>...       only these paths
    dev/scripts/americanize.py --selftest      check the roots against known cases

REPORTS BY DEFAULT AND CONVERTS ONLY WHEN ASKED, for the reason comment-audit.sh does the same:
a hit is a candidate and not a verdict. A blind rewrite over this repository breaks four kinds
of thing, and three of them break silently.

  1. IDENTIFIERS THAT CROSS FILES. A process name reaches the Nextflow trace, which the test
     harness reads back through task_count(); renaming one without its assertions leaves a suite
     that passes while measuring nothing. The modules' own `Analyse` was renamed to `Analyze` on
     2026-09-08 after checking that nothing read it, which is the check to repeat rather than the
     conclusion to reuse.
  2. THIRD-PARTY API. ggplot2 takes `colour` and `color` as synonyms, so those are safe; R's
     `grey()`/`gray()` likewise. Anything else from a package is not ours to spell.
  3. QUOTED TEXT. Journal names in references.bib and anything inside a citation `note` are
     someone else's spelling, not ours. Nothing below matches one today; check before adding.
  4. PUBLISHED SETTING NAMES. A setting is an API surface: renaming one after a release breaks
     every configuration file in the world. Those are free to change only before 3.0.0.

So the roots are split into a safe list and a risky one below, and --fix touches only the safe
list unless --all is given. The risky ones are reported with their context so the decision is
made by a person looking at the line.

--selftest checks the roots against known cases, and it earns its place: two real errors were
caught by it while this was being written.

WHAT THIS DOES NOT DO is decide the house style. That is Z's call and it is recorded in
CLAUDE.md; this only finds what disagrees with it.
"""

import argparse
import os
import re
import subprocess
import sys

# ROOTS, NOT WHOLE WORDS. Each key is matched anywhere it appears, so one entry covers every
# inflection: `behaviour` takes behaviours and behavioural, `normalis` takes normalise,
# normalised, normalising, normalisation and renormalise. Case is carried over from whatever
# was matched, so Behaviour and NORMALISED come back capitalised the same way.
#
# THE COST OF A ROOT IS THAT IT CAN LAND INSIDE AN UNRELATED WORD, and exactly one does here:
# `organis` is inside `organism`, which appears four times in a repository about populations of
# them. The negative lookahead is what keeps it from writing `organizm`. Anything added below
# needs the same check run against the tree before it is trusted.
#
# `centring` is its own entry because it does not contain `centre`.
ROOTS = {
    "behaviour": "behavior",
    "colour": "color",
    # ORDER MATTERS FOR THESE THREE, and they are applied in the order written. `centre` alone
    # turns `centred` into `centerd`: the -re to -er flip drops the vowel the American past
    # tense needs, so the longer form has to be taken first. `centring` does not contain
    # `centre` at all and needs an entry of its own. No other root here inflects that way.
    "centred": "centered",
    "centring": "centering",
    "centre": "center",
    "neighbour": "neighbor",
    "favour": "favor",
    "defence": "defense",
    "licence": "license",
    "practis": "practic",
    "vectoris": "vectoriz",
    "normalis": "normaliz",
    "initialis": "initializ",
    "summaris": "summariz",
    "recognis": "recogniz",
    "organis(?!m)": "organiz",
    "serialis": "serializ",
    "polaris": "polariz",
    "parameteris": "parameteriz",
    "labell": "label",
    "modell": "model",
    "cancell": "cancel",
    "travell": "travel",
    "grey": "gray",
    "fibre": "fiber",
    # British in every form, and neither is ever an identifier. The bare verb and the ambiguous
    # plural are in the risky table below, for reasons that do not apply to these two.
    "analysed": "analyzed",
    "analysing": "analyzing",
}

# Roots that are also identifiers or that a regex cannot judge. Each is reported with its line so
# a person decides; --all converts them anyway.
#
# `analyse` CANNOT BE SHORTENED TO `analys`, which is inside `analysis` - 1763 of those here.
#
# `analyse` CANNOT BE SHORTENED TO `analys`, which is inside `analysis` - 1763 of those here. And
# it carries a lookahead because the bare root is inside `analyses`: without it every plural is
# reported twice and the count reads as work left over when there is none.
#
# `catalogue` IS ON NEITHER LIST, and that is the finding rather than an omission. Merriam
# Webster gives "catalog also catalogue": both are current American English, so there is nothing
# here to correct. It is also this project's name for a specific thing - the shell variable
# `catalogue`, the functions `modules_catalogue` and `modules_catalogue_stamped`, six test case
# names and the wrapper's own output - so converting it renames fourteen identifiers to settle a
# preference. Listing it at all invites a later pass to "fix" it.
RISKY = {
    "analyse(?!s)": "analyze",
    "analyses": "analyzes",
}

# Why each risky root is risky, printed beside its hits.
WHY = {
    "analyse(?!s)":
        "the bare root is what a process or function gets named, so a hit here may be an "
        "identifier rather than a spelling. The modules' own process was renamed to `Analyze` "
        "on 2026-09-08 after checking that nothing read it back out of a trace; repeat that "
        "check rather than assuming it of a new one",
    "analyses":
        "USUALLY NOT AN ERROR: it is the plural of `analysis`, which is correct American "
        "English, and only rarely the British verb. Measured over this tree, 25 of 27 were the "
        "noun. Read every one before touching it",
}

# Paths never scanned. docs/ and dist/ are generated and .git is not text.
#
# `.claude/development-notes/` IS IN SCOPE. Z, 2026-09-08: "I think we can and should rewrite
# the development notes, even though they are dated, we are not changing meaning." A note is
# never rewritten to follow the code, which is what keeps it trustworthy as a record; a spelling
# is not a claim about the code, so normalising one alters nothing the note asserts. That
# includes the words quoted from Z inside them.
#
# This file is excluded, or the root lists above report themselves on every run.
SKIP_DIRS = {".git", "docs", "dist", "work", ".nextflow", "__pycache__", "node_modules"}
SKIP_PATHS = {os.path.join("dev", "scripts", "americanize.py")}
SKIP_SUFFIX = {".png", ".jpg", ".gz", ".bam", ".bai", ".pdf", ".ico", ".woff", ".woff2"}


def tracked_files(paths):
    """Everything git knows about, tracked or newly added, under `paths`."""
    out = []
    for args in (["git", "ls-files", "-z"], ["git", "ls-files", "-z", "--others",
                                             "--exclude-standard"]):
        try:
            blob = subprocess.run(args + list(paths), capture_output=True, check=True).stdout
        except subprocess.CalledProcessError:
            return []
        out += [name for name in blob.decode().split("\0") if name]

    keep = []
    for name in sorted(set(out)):
        parts = name.split(os.sep)
        if any(part in SKIP_DIRS for part in parts):
            continue
        if name in SKIP_PATHS:
            continue
        if os.path.splitext(name)[1] in SKIP_SUFFIX:
            continue
        keep.append(name)
    return keep


def hits_in(text, table):
    """Every (line number, root, line) a root matches.

    NO WORD BOUNDARIES. A root is matched wherever it appears, which is the whole point of it:
    `normalis` has to reach normalised and normalisation, and `colour` has to reach recoloured.
    A key may carry regex of its own - the lookahead on `organis` - so it is used raw.
    """
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for british in table:
            if re.search(british, line, re.IGNORECASE):
                found.append((number, british, line))
    return found


def convert(text, table):
    """Every root replaced, carrying over the case of whatever was matched.

    The match is the ROOT and not the word, so `Normalised` matches `Normalis` and comes back
    `Normalized` with the `ed` untouched, and `ORGANISED` comes back `ORGANIZED`.
    """
    def cased(american, matched):
        if matched.isupper():
            return american.upper()
        if matched[:1].isupper():
            return american[:1].upper() + american[1:]
        return american

    for british, american in table.items():
        text = re.sub(british,
                      lambda m, a=american: cased(a, m.group(0)),
                      text, flags=re.IGNORECASE)
    return text


# What each root must and must not do. A root is a blunt instrument and two of these caught real
# errors on the way in: every inflection came back unchanged while the roots were still being
# matched as whole words, and `centre` turned `centred` into `centerd`. A line whose second
# element is None must come back untouched.
SELFTEST = [
    ("The organism is diploid.", None),
    ("analysis analyses parameter parameters", None),
    ("organised ORGANISED Organising organisation",
     "organized ORGANIZED Organizing organization"),
    ("behaviour behaviours behavioural BEHAVIOUR", "behavior behaviors behavioral BEHAVIOR"),
    ("normalise normalised normalising normalisation renormalise",
     "normalize normalized normalizing normalization renormalize"),
    ("double centring, centred on the centre; two centres",
     "double centering, centered on the center; two centers"),
    ("labelled labelling relabelled", "labeled labeling relabeled"),
    ("colour colours coloured Colouring recoloured", "color colors colored Coloring recolored"),
    ("grey60 neighbouring re-polarises vectorised practise licence fibre defences",
     "gray60 neighboring re-polarizes vectorized practice license fiber defenses"),
    ("modelling cancelled travelling summarising recognised initialised serialised",
     "modeling canceled traveling summarizing recognized initialized serialized"),
]


def selftest():
    failed = 0
    for text, want in SELFTEST:
        expect = text if want is None else want
        got = convert(text, ROOTS)
        if got != expect:
            failed += 1
            print("FAIL %s\n     got  %s\n     want %s" % (text, got, expect))
    if failed:
        print("\n%d of %d failed" % (failed, len(SELFTEST)))
        return 1
    print("%d conversions correct" % len(SELFTEST))
    return 0


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("paths", nargs="*", default=["."])
    parser.add_argument("--fix", action="store_true")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args()

    if args.help:
        sys.stdout.write(__doc__)
        return 0
    if args.selftest:
        return selftest()

    root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, check=True).stdout.decode().strip()
    os.chdir(root)

    table = dict(ROOTS)
    if args.all:
        table.update(RISKY)

    safe_hits, risky_hits, changed = {}, {}, []
    for name in tracked_files(args.paths or ["."]):
        try:
            with open(name, encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, OSError):
            continue

        for number, term, line in hits_in(text, ROOTS):
            safe_hits.setdefault(term, []).append((name, number, line.strip()))
        if not args.all:
            for number, term, line in hits_in(text, RISKY):
                risky_hits.setdefault(term, []).append((name, number, line.strip()))

        if args.fix:
            rewritten = convert(text, table)
            if rewritten != text:
                with open(name, "w", encoding="utf-8") as handle:
                    handle.write(rewritten)
                changed.append(name)

    if args.fix:
        for name in changed:
            print("rewrote %s" % name)
        print("\n%d file(s) rewritten%s." % (len(changed),
                                             "" if args.all else ", risky terms left alone"))
        if not args.all and risky_hits:
            print("Run without --fix to see what was left, or add --all to take those too.")
        return 0

    total = 0
    for term in sorted(safe_hits):
        rows = safe_hits[term]
        total += len(rows)
        print("\n%s -> %s   (%d)" % (term, ROOTS[term], len(rows)))
        for name, number, line in rows[:6]:
            print("    %s:%d  %s" % (name, number, line[:96]))
        if len(rows) > 6:
            print("    ... and %d more" % (len(rows) - 6))

    for term in sorted(risky_hits):
        rows = risky_hits[term]
        print("\n%s -> %s   (%d)  NOT REWRITTEN BY --fix" % (term, RISKY[term], len(rows)))
        print("    %s" % WHY.get(term, "risky"))
        for name, number, line in rows[:4]:
            print("    %s:%d  %s" % (name, number, line[:96]))
        if len(rows) > 4:
            print("    ... and %d more" % (len(rows) - 4))

    print("\n%d safe hit(s), %d risky."
          % (total, sum(len(v) for v in risky_hits.values())))
    print("--fix rewrites the safe ones. Read the risky ones by hand.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
