#!/usr/bin/env python3
"""Which suites cover a change.

    dev/scripts/select-tests.py                 # against the working tree
    dev/scripts/select-tests.py --ref HEAD~3    # against a commit
    dev/scripts/select-tests.py scripts/7_vcf2freq.nf modules/lib/n_eff/n_eff.R
    dev/scripts/select-tests.py --command       # print the run_tests.sh line and nothing else

HOW IT DECIDES, in two halves.

The FILE GRAPH IS DERIVED, never declared: `include { x } from './y.nf'`, a shell `source`, and
a bare call to a helper in bin/ are all read out of the sources. A change to a file selects
everything that reaches it, transitively - so editing analysis/lib/nf/plan.nf selects every
module and every entry script that imports it, without anybody maintaining a list.

WHAT A SUITE COVERS IS DECLARED, in its own header as `# covers: <path> <path>`, because no
parser can see it. 00_static refuses a source file no suite claims, which is what stops this
returning "nothing to run" for a file everybody forgot.

IT ERRS WIDE. A file it cannot classify selects everything, and so does a change to the
harness or to this script. A selection that is too big costs minutes; one that is too small
costs a bug nobody was looking for.

ERRING WIDE IS FOR A FILE IT CANNOT CLASSIFY, not for a request it cannot read. A named path
that does not exist, and an argument that looks like an option it does not have, both exit 2
rather than selecting anything: "nothing to run" has to mean the graph was asked and answered.
"""

import os
import re
import subprocess
import sys

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip() or "."

# A change to any of these means the selection itself cannot be trusted, so everything runs.
EVERYTHING = ("test/lib/", "test/run_tests.sh", "dev/scripts/select-tests.py",
              "nextflow.config", "test/tools/")

INCLUDE = re.compile(r"include\s*\{[^}]*\}\s*from\s*'([^']+)'")
SOURCE = re.compile(r"^\s*(?:source|\.)\s+\"?\$\{?[A-Za-z_]+\}?/([^\"\s]+\.sh)")
COVERS = re.compile(r"^# covers:\s*(.+)$", re.M)


def suites():
    """Every suite file, with the source paths its header claims."""
    found = {}
    roots = [os.path.join(ROOT, "test", "suites")]
    modules = os.path.join(ROOT, "modules")
    if os.path.isdir(modules):
        roots += [os.path.join(modules, m, "test") for m in sorted(os.listdir(modules))]
    for directory in roots:
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if not name.endswith(".sh"):
                continue
            path = os.path.join(directory, name)
            head = open(path, encoding="utf-8").read(4000)
            claims = []
            for line in COVERS.findall(head):
                claims += line.split()
            found[name[:-3]] = claims
    return found


def sources():
    """Every file a change could land in, relative to the repository root."""
    listed = subprocess.run(["git", "ls-files"], capture_output=True, text=True, cwd=ROOT)
    extra = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"],
                           capture_output=True, text=True, cwd=ROOT)
    # Only what is actually THERE. `git ls-files` reads the index, which still names a file
    # that has been moved or deleted in the working tree until the change is staged - and a
    # path nothing can land in any more is not a source. Without this, every check built on
    # sources() reports files that do not exist.
    return [p for p in (listed.stdout + extra.stdout).split("\n")
            if p and os.path.exists(os.path.join(ROOT, p))]


def graph():
    """path -> the paths it reads. Reversed by `reaches` into "who is affected by a change"."""
    edges = {}
    for path in sources():
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full) or os.path.splitext(path)[1] not in (".nf", ".sh", ".config"):
            continue
        try:
            text = open(full, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        here = set()
        for target in INCLUDE.findall(text):
            here.add(os.path.normpath(os.path.join(os.path.dirname(path), target)))
        for target in SOURCE.findall(text):
            for base in ("", "test", "lib"):
                candidate = os.path.normpath(os.path.join(base, target))
                if os.path.isfile(os.path.join(ROOT, candidate)):
                    here.add(candidate)
        # A helper is called by bare name off nextflow.config's PATH, so the reference is the
        # name and nothing else. Matching on the file's own basename is what finds it.
        for helper in os.listdir(os.path.join(ROOT, "bin")):
            if re.search(r"(?<![\w./])%s(?![\w])" % re.escape(helper), text):
                here.add("bin/" + helper)
        edges[path] = here - {path}
    return edges


def under(claim, path):
    return path == claim or path.startswith(claim.rstrip("/") + "/")


def footprint(declared, edges, everything):
    """Everything a suite depends on: what it declares, plus what those read, transitively.

    FORWARD ONLY, and it has to be. Reading upwards under-selects - a change to plan.nf misses
    the suite that covers design.nf, though both run through the same entry script. Reading
    both ways over-selects to uselessness: bin/atomic_mv.sh is named by twelve .nf files, so an
    undirected walk connects the whole repository to itself and every change selects everything.
    Forward from what a suite RUNS is the direction that answers "could this change reach it".
    """
    seed = {p for p in everything for claim in declared if under(claim, p)}
    seen, queue = set(seed), list(seed)
    while queue:
        path = queue.pop()
        for target in edges.get(path, ()):
            if target not in seen:
                seen.add(target)
                queue.append(target)
    return seen


def main():
    args = [a for a in sys.argv[1:]]
    as_command = "--command" in args
    args = [a for a in args if a != "--command"]
    ref = None
    if "--ref" in args:
        i = args.index("--ref")
        ref = args[i + 1]
        del args[i:i + 2]

    if args:
        # A MALFORMED REQUEST IS AN ERROR, NOT AN EMPTY ANSWER. Both of these used to fall
        # through to "nothing to run", which reads as "no suite covers this change" and is the
        # one answer this script must never give by accident: an argument starting with - is a
        # mistyped option rather than a path, and a path that does not exist matches no suite's
        # footprint. `--changed` is run_tests.sh's flag and was read here as a filename.
        unknown = [a for a in args if a.startswith("-")]
        if unknown:
            print("select-tests.py: unknown option %s" % unknown[0], file=sys.stderr)
            print("  Arguments are paths. The options are --command and --ref <ref>, and with",
                  file=sys.stderr)
            print("  no arguments it reads whatever git reports as changed.", file=sys.stderr)
            return 2
        absent = [a for a in args
                  if not (os.path.exists(a) or os.path.exists(os.path.join(ROOT, a)))]
        if absent:
            print("select-tests.py: no such file: %s" % absent[0], file=sys.stderr)
            print("  Paths are read from the repository root. One that does not exist is in no",
                  file=sys.stderr)
            print("  suite's footprint, so the answer would be 'nothing to run'.",
                  file=sys.stderr)
            return 2
        changed = args
    else:
        cmd = ["git", "diff", "--name-only"] + ([ref] if ref else ["HEAD"])
        changed = [p for p in subprocess.run(cmd, capture_output=True, text=True,
                                             cwd=ROOT).stdout.split("\n") if p]
        changed += [p for p in subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True, text=True, cwd=ROOT).stdout.split("\n") if p]

    claims = suites()
    everything = sorted(claims)

    if not changed:
        print("nothing changed" if not as_command else "")
        return 0

    wide = [p for p in changed if any(p.startswith(e) for e in EVERYTHING)]
    if wide:
        chosen, why = everything, "%s changed, and it decides what runs" % wide[0]
    else:
        edges, tracked = graph(), sources()
        prints = {s: footprint(d, edges, tracked) for s, d in claims.items()}
        chosen = sorted(s for s, seen in prints.items()
                        if any(c in seen for c in changed))
        why = "%d file(s) changed" % len(changed)
        # A source file no suite depends on selects everything, because the alternative is
        # answering "nothing to run" for a file nobody is testing.
        claimed = set().union(*prints.values()) if prints else set()
        orphan = [p for p in changed if p not in claimed
                  and os.path.splitext(p)[1] in (".nf", ".sh", ".py", ".awk", ".R", ".Rmd",
                                                 ".cpp")]
        if orphan:
            chosen, why = everything, "no suite reaches %s" % orphan[0]

    if as_command:
        print(" ".join("--suite %s" % s for s in chosen))
        return 0

    print("# %s" % why)
    for suite in chosen:
        print("  %s" % suite)
    print("\ntest/run_tests.sh %s" % " ".join("--suite %s" % s for s in chosen)
          if chosen else "\nnothing to run")
    return 0


if __name__ == "__main__":
    sys.exit(main())
