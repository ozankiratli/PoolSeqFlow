#!/bin/bash
# Checks that need no data: syntax, release packaging, version consistency.
# cost: static
# covers: PoolSeqFlow install/ lib/ dev/scripts/ modules/repo/index.tsv .gitattributes
# covers: analysis/citations.json citations/citations.json citations/references.bib
# covers: analysis/references.bib manual/references.bib
# covers: parameters.config.template metadata.csv.template multi-run.csv.example
# covers: .github/workflows/docs.yml .github/workflows/release.yml

# `nextflow lint` was brought to zero warnings during the post-2.2.0 audit. Held there
# deliberately: once the count is zero a new warning is a signal rather than noise.
test_nextflow_lint_is_clean() {
    have_tools || { skip_case "no conda environment"; return; }
    local out
    # Everything but modules/, which is linted below in the layout it runs in.
    out=$(cd "$REPO_ROOT" && PATH="$TEST_CONDA_ENV/bin:$PATH" \
          JAVA_HOME="$TEST_CONDA_ENV" JAVA_CMD="$TEST_CONDA_ENV/bin/java" \
          nextflow lint analysis scripts lib bin install \
                        poolseqflow.nf analysis.nf dryrun.nf nextflow.config 2>&1)
    assert_contains "$out" "had no errors" "lint should report no errors"
    assert_not_contains "$out" "warning" "lint should report no warnings"
}

# A MODULE IS LINTED WHERE IT RUNS, NOT WHERE GIT KEEPS IT.
#
# A module's source lives in modules/<name>/ and is installed into analysis/modules/<name>/, and
# its `include` of the frame is written '../../lib/nf/...' - correct from the STORE and
# meaningless from the source directory. That is the cost of the store and the sources being
# different places, which is deliberate: while they were one directory the modules shipped inside
# every release because they were sources sitting in the install path.
#
# So the check is not "skip the modules" but "assemble the layout a module actually sees". Linting
# them in modules/ would report errors that say nothing, and linting nothing at all would let a
# real one through.
test_every_module_lints_in_the_store_layout() {
    have_tools || { skip_case "no conda environment"; return; }
    local sb; sb=$(guard_path "$TEST_TMPDIR/module-lint")
    rm -rf "$sb"; mkdir -p "$sb/analysis/modules"
    cp -r "$REPO_ROOT/analysis/lib" "$sb/analysis/"
    cp -r "$REPO_ROOT/scripts" "$sb/"
    cp "$REPO_ROOT/nextflow.config" "$sb/"
    local found=0 dir
    for dir in "$REPO_ROOT"/modules/*/; do
        [ -f "$dir/main.nf" ] || continue        # modules/lib holds libraries, not modules
        cp -r "$dir" "$sb/analysis/modules/"
        found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { fail_case "no module sources found under modules/"; return; }

    local out
    out=$(cd "$sb" && PATH="$TEST_CONDA_ENV/bin:$PATH" \
          JAVA_HOME="$TEST_CONDA_ENV" JAVA_CMD="$TEST_CONDA_ENV/bin/java" \
          nextflow lint "$sb/analysis/modules" 2>&1)
    assert_contains "$out" "had no errors" "modules should lint in the store layout:"$'\n'"$out"
    assert_not_contains "$out" "had errors" "no module should report an error:"$'\n'"$out"
}

test_shell_scripts_parse() {
    local script bad=0
    while read -r script; do
        bash -n "$script" 2>/dev/null || { fail_case "bash -n failed: ${script#"$REPO_ROOT"/}"; bad=1; }
    done < <(
        find "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/install" "$REPO_ROOT/dev" \
             "$REPO_ROOT/test" -name '*.sh' -type f 2>/dev/null
        # The wrappers carry no .sh suffix, so the find above cannot reach them. Read from
        # the same list the installer deploys them by.
        eval "$(sed -n '/^WRAPPERS=/p' "$REPO_ROOT/PoolSeqFlow")"
        for w in $WRAPPERS; do echo "$REPO_ROOT/$w"; done
    )
    [ "$bad" -eq 0 ]
}

# PYTHONDONTWRITEBYTECODE keeps this from scattering __pycache__ through the working tree:
# a test suite must not leave the repository dirtier than it found it.
test_python_helpers_compile() {
    local script
    while read -r script; do
        PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile "$script" 2>/dev/null \
            || fail_case "py_compile failed: ${script#"$REPO_ROOT"/}"
    done < <(find "$REPO_ROOT/bin" "$REPO_ROOT/test/tools" -name '*.py' -type f 2>/dev/null)
}

# EVERY PYTHON THE SUITE RUNS IMPORTS THE STANDARD LIBRARY AND THE REPOSITORY'S OWN SCRIPTS, AND
# NOTHING ELSE. The static suites run on whichever python3 the shell finds, which is the active
# conda environment's when there is one, and neither PoolSeqFlow environment carries a Python
# package the pipeline does not need. The site case imported PyYAML, passed every run made with
# the system Python, which has it, and failed the 3.3.0 prep run on 2026-10-08, launched with the
# analysis environment active; this is the case that would have caught it first.
#
# Read: every .py under bin/, test/tools/ and dev/scripts/, and the Python each suite and module
# test hands python3 in a heredoc or with -c, in single or double quotes. A snippet the shell's
# quoting leaves unparsable is read for its import lines instead of skipped. The scan is first shown
# one planted import of each form, and has to find at least twenty snippets, so one that stopped
# reading what it looks at fails here. The double-quoted form was missing until a review on
# 2026-10-08 planted one and the case passed.
test_every_python_the_suite_runs_imports_the_standard_library_alone() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - 2>&1 <<'PY'
import ast, glob, pathlib, re, sys

if not hasattr(sys, "stdlib_module_names"):
    print("python3 is %s, and the scan needs 3.10 or later" % sys.version.split()[0])
    sys.exit(0)
STANDARD = set(sys.stdlib_module_names)
OWN = {p.stem for d in ("bin", "test/tools", "dev/scripts") for p in pathlib.Path(d).glob("*.py")}
HEREDOC = re.compile(r"python3?\b[^\n]*<<-?\s*['\"]?(\w+)['\"]?\n(.*?)\n\s*\1\n", re.S)
DASH_C = re.compile(r"python3?\s+-c\s+'([^']*)'", re.S)
DASH_C_DOUBLE = re.compile(r'python3?\s+-c\s+"((?:[^"\\]|\\.)*)"', re.S)
IMPORT_LINE = re.compile(r"^\s*(?:import\s+([\w.]+(?:\s*,\s*[\w.]+)*)|from\s+(\w+)[\w.]*\s+import\b)", re.M)

def imports(source):
    try:
        tree = ast.parse(source)
    except SyntaxError:
        names = set()
        for listed, origin in IMPORT_LINE.findall(source):
            names |= {origin} if origin else {n.strip().split(".")[0] for n in listed.split(",")}
        return names - STANDARD - OWN
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            names.add(node.module.split(".")[0])
    return names - STANDARD - OWN

def embedded(text):
    for match in HEREDOC.finditer(text):
        yield match.group(2)
    for match in DASH_C.finditer(text):
        yield match.group(1)
    for match in DASH_C_DOUBLE.finditer(text):
        yield match.group(1).replace('\\"', '"')

# Spelled with a placeholder, or the scan of this very file would find the planted import in it.
planted = ("x=$(PYTHON - <<'PY'\nimport yaml\nPY\n)\n"
           "y=$(PYTHON -c 'from numpy import x; f(\"$z\")')\n"
           "z=$(PYTHON -c \"import requests; print(\\\"$z\\\")\")\n").replace("PYTHON", "python3")
seen = set()
for source in embedded(planted):
    seen |= imports(source)
if seen != {"yaml", "numpy", "requests"}:
    print("the scan found %s in three planted imports, not yaml, numpy and requests" % sorted(seen))
    sys.exit(0)

problems, snippets = [], 0
for path in sorted(glob.glob("bin/*.py") + glob.glob("test/tools/*.py") + glob.glob("dev/scripts/*.py")):
    for name in sorted(imports(open(path).read())):
        problems.append("%s imports %s" % (path, name))
for path in sorted(glob.glob("test/suites/*.sh") + glob.glob("test/lib/*.sh")
                   + glob.glob("modules/*/test/*.sh")):
    for source in embedded(open(path).read()):
        snippets += 1
        for name in sorted(imports(source)):
            problems.append("%s runs Python importing %s" % (path, name))
if snippets < 20:
    problems.append("only %d Python snippets found in the suites; the scan has stopped reading them"
                    % snippets)
print("\n".join(problems) if problems else "OK")
PY
)
    assert_eq "OK" "$out" "nothing the suite runs needs a Python package the environments lack"
}

# bin/__pycache__ was tracked, and shipped inside the release tarball, until it was caught.
# Checked against the index rather than the archive, because test/ is export-ignore'd and
# bytecode committed there would never show up in a tarball listing.
test_no_compiled_python_is_tracked() {
    local tracked
    tracked=$(cd "$REPO_ROOT" && git ls-files | grep -E '__pycache__|\.pyc$')
    assert_eq "" "$tracked" "compiled Python should not be tracked"
}

# What `git archive` would put in a release built from the tree as it stands, rather than from
# HEAD. A payload item is added to the working tree first and committed afterwards, so reading
# HEAD reports every such addition as missing - red for exactly as long as the change is being
# reviewed, and green once it is committed and nobody is looking.
#
# The index is a throwaway under TEST_TMPDIR: `git add` here must never stage anything in the
# repository the suite is testing.
working_tree_tree() {
    local idx tree
    idx=$(guard_path "$TEST_TMPDIR/archive-index")
    rm -f "$idx"
    (
        cd "$REPO_ROOT" || exit 1
        export GIT_INDEX_FILE="$idx"
        git read-tree HEAD && git add -A .
    ) >/dev/null 2>&1 || return 1
    tree=$(cd "$REPO_ROOT" && GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null) || return 1
    [ -n "$tree" ] || return 1
    printf '%s' "$tree"
}

working_tree_archive() {
    local tree; tree=$(working_tree_tree) || return 1
    (cd "$REPO_ROOT" && git archive "$tree" 2>/dev/null | tar -t 2>/dev/null)
}

# The release tarball is built with `git archive`, and .gitattributes decides what it holds.
# Development material must stay out of it; anything a run needs must stay in.
test_release_archive_excludes_development_material() {
    local listing
    listing=$(working_tree_archive)
    [ -n "$listing" ] || { fail_case "git archive produced nothing"; return; }
    local unwanted
    for unwanted in "test/" "dev/" "docs/" ".github/" "mkdocs.yml" "__pycache__" \
                    ".claude/" "CLAUDE.md"; do
        assert_not_contains "$listing" "$unwanted" "release tarball should not carry $unwanted"
    done
}

# AN UNMATCHED GLOB IS HANDED TO THE LOOP BODY, and these loops hand it straight to
# atomic_mv.sh, which refuses a source that is not there and takes the task down with it under
# `set -eo pipefail`. Seven loops in 2_trim_reads.nf had no guard. The live one is
# `*_unpaired_*`: Trim Galore writes those only when it discards a mate, so a run where every
# pair survived trimming died on the pattern itself. Reproduced before it was fixed -
# `atomic_mv: source not found: *_unpaired_*`.
#
# One-line loops, which is how all of these are written. The multi-line one in 9_completion.nf
# carries the same guard inside its body and is not matched here.
test_glob_loops_publishing_artifacts_are_guarded() {
    local loops unguarded
    loops=$(cd "$REPO_ROOT" && grep -n 'for [A-Za-z_]* in [^;]*\*[^;]*; *do' scripts/*.nf \
                | grep 'atomic_mv\.sh' || true)
    # A POSITIVE CONTROL. The assertion below is about an absence, so a change to how these
    # loops are written empties the search and the case passes over nothing at all.
    [ -n "$loops" ] || { fail_case "no glob loops calling atomic_mv.sh were found at all"; return; }
    unguarded=$(printf '%s\n' "$loops" | grep -v '\[ -e ' || true)
    [ -z "$unguarded" ] || fail_case \
        "glob loops calling atomic_mv.sh with no existence guard:"$'\n'"$unguarded"
}

# THE RELEASE GATE ITSELF, run here rather than only in CI.
#
# dev/scripts/verify-archive.sh is what stands between a broken tarball and a published release,
# and nothing in this suite ran it - only ci.yml and release.yml did. That is how its hand-kept
# file lists drifted twice with nobody noticing: they named six of the thirteen helpers in bin/
# and nothing at all under analysis/lib, which every analysis module imports. It enumerates from
# the ref now, and running it here catches the next drift before a pull request instead of in
# one.
#
# Against a tree object built from the WORKING TREE, for the same reason the cases above are: a
# payload item is added before it is committed, and reading HEAD would call every such addition
# missing for exactly as long as it is under review.
test_the_release_archive_gate_passes() {
    local tree out log status
    tree=$(working_tree_tree) || { fail_case "could not write a working tree object"; return; }
    out=$(guard_path "$TEST_TMPDIR/gate-dist")
    rm -rf "$out"
    log=$(cd "$REPO_ROOT" && bash dev/scripts/verify-archive.sh "$tree" "$out" 2>&1)
    status=$?
    assert_status 0 "$status" "the release gate should pass on the working tree:"$'\n'"$log"
}

# The module catalogue is read over the network, from the repository, so that a module
# published after a release is installable into it. A copy inside the tarball would be a second
# answer to what can be installed, frozen on the day the release was built.
test_the_module_catalogue_never_reaches_a_release() {
    local index="modules/repo/index.tsv"
    [ -f "$REPO_ROOT/$index" ] || { fail_case "$index is missing"; return; }
    # The archive itself, not `git check-attr`: the catalogue is covered by a directory pattern
    # now, and check-attr reports `unspecified` for a file inside one even though git archive
    # excludes it - `test/run_tests.sh` answers the same way. What matters is the tarball.
    local listing; listing=$(working_tree_archive)
    [ -n "$listing" ] || { fail_case "git archive produced nothing"; return; }
    assert_not_contains "$listing" "modules/repo" \
        "the catalogue and the tarballs beside it must not reach a release"
    # And the release must not be able to fall back to a copy of its own: a frozen catalogue
    # inside a tarball would be a second answer to what can be installed.
    assert_not_contains "$listing" "index.tsv" "nor any copy of it under another name"
}

# EVERY PUBLISHED ROW MUST HAVE ITS TARBALL, AND THE CHECKSUM MUST BE THAT TARBALL'S.
#
# The catalogue and the files it advertises are deployed together, from one directory, so a row
# whose tarball never landed is a 404 for everyone who runs `modules install` between the two
# deploys. install verifies the checksum before unpacking anything, so a stale one is not a
# security hole - it is an install that refuses with nothing the user can do about it.
#
# Only rows pointing into this repository are checked. A third-party row would name a host
# nothing here can see, and asserting on that would fail for a reason that is not ours.
test_every_catalogue_row_has_the_tarball_it_advertises() {
    local index="$REPO_ROOT/modules/repo/index.tsv"
    [ -f "$index" ] || { fail_case "modules/repo/index.tsv is missing"; return; }
    command -v sha256sum > /dev/null 2>&1 || { skip_case "no sha256sum"; return; }

    local rows=0 name version url sha file
    while IFS=$'\t' read -r name _kind version _contract _frame _env url sha _summary; do
        case "$name" in ''|'#'*|name) continue ;; esac
        case "$url" in *"/modules-repo/"*) ;; *) continue ;; esac
        rows=$((rows + 1))
        file="$REPO_ROOT/modules/repo/${url##*/}"
        [ -f "$file" ] || { fail_case "$name $version: the catalogue names ${url##*/}, which is not in modules/repo/"
                            continue; }
        local actual; actual=$(sha256sum "$file" | awk '{print $1}')
        assert_eq "$sha" "$actual" "$name $version: the row's sha256 is not ${url##*/}'s"
    done < "$index"

    # A catalogue with no rows of ours passes this vacuously, which is true of an unpublished
    # one and must not be mistaken for a check that ran.
    [ "$rows" -gt 0 ] || skip_case "no rows pointing into this repository yet"
}

# The wrapper matches columns by name out of this header row, so a name that is absent from it
# reads as an empty field in every row rather than as an error.
test_the_module_catalogue_header_is_the_one_the_wrapper_reads() {
    local header wanted column
    header=$(grep -v '^[[:space:]]*#' "$REPO_ROOT/modules/repo/index.tsv" \
             | grep -v '^[[:space:]]*$' | head -1)
    # Taken from the wrapper rather than written out here: the columns are matched by name, so
    # the coupling to assert is that every name it looks for is in the header - not that the
    # header is a particular string, which would only say the two literals were typed alike.
    wanted=$(sed -n 's/^MODULE_INDEX_COLUMNS="\(.*\)"$/\1/p' "$REPO_ROOT/lib/wrapper_lib.sh")
    assert_eq "yes" "$([ -n "$wanted" ] && echo yes)" "the wrapper should name the columns it reads"
    for column in $wanted; do
        printf '%s' "$header" | tr '\t' '\n' | grep -qxF "$column" \
            || fail_case "the catalogue has no '$column' column, and the wrapper reads one"
    done
    # And the header is tab-separated, which is what makes those names findable at all.
    assert_contains "$header" "$(printf '\t')" "the header should be tab-separated"
}

# The catalogue is fetched from the default branch at RUN TIME, so a release meets whatever is
# there years later. The layout number is what lets it refuse a file whose columns have moved
# instead of reading the wrong field out of each row; the test above cannot protect a wrapper
# that has already shipped.
test_the_module_catalogue_declares_its_layout_and_its_version() {
    local index="$REPO_ROOT/modules/repo/index.tsv"
    local format version supported
    format=$(sed -n 's|^#![[:space:]]*index-format:[[:space:]]*\(.*\)$|\1|p' "$index" | head -1 | tr -d ' ')
    version=$(sed -n 's|^#![[:space:]]*index-version:[[:space:]]*\(.*\)$|\1|p' "$index" | head -1 | tr -d ' ')
    supported=$(sed -n 's|^MODULE_INDEX_FORMAT="\(.*\)"$|\1|p' "$REPO_ROOT/lib/wrapper_lib.sh" | head -1)
    assert_eq "$supported" "$format" "the catalogue's layout vs the one the wrapper reads"
    case "$version" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9]) ;;
        *) fail_case "the catalogue version must be YYYYMMDD.NNN, got '$version'" ;;
    esac
}

# Nothing in the pipeline forces a version bump, and this project has had a hand-kept list
# drift twice. These are what catch it.
test_the_analysis_version_scripts_are_there_and_runnable() {
    local script
    for script in bump-analysis-version.sh check-analysis-versions.sh; do
        assert_file "$REPO_ROOT/dev/scripts/$script" "dev/scripts/$script should exist"
        [ -x "$REPO_ROOT/dev/scripts/$script" ] || fail_case "dev/scripts/$script is not executable"
        bash -n "$REPO_ROOT/dev/scripts/$script" 2>/dev/null || fail_case "dev/scripts/$script does not parse"
    done
    # Named without a target it explains itself rather than guessing one.
    local out; out=$("$REPO_ROOT/dev/scripts/bump-analysis-version.sh" 2>&1 || true)
    assert_contains "$out" "frame" "usage should name the frame target"
    assert_contains "$out" "index" "and the index target"
    assert_contains "$out" "module" "and the module target"
    assert_contains "$out" "--pending" "and the way to bump all of them"
}

# EVERYTHING BEHIND, BUMPED AT ONCE. Step 4 of a release named six targets behind on 2026-10-08,
# one bump command each; Z asked for one command. --pending takes its list from the gate's own
# "bump it:" lines, so it cannot bump something the gate did not name or miss something it did,
# and it runs the gate again before it says it is done.
#
# In a repository of its own holding both scripts, as the gate reads the tree around it. A module,
# a library, the frame and a catalogue row are each changed without a bump; one --pending must move
# all four and leave the gate passing, a second must change nothing, and a gate that cannot run
# must stop it before it bumps anything.
test_every_pending_analysis_version_is_bumped_at_once() {
    local sb out status today
    sb=$(guard_path "$TEST_TMPDIR/version-pending")
    rm -rf "$sb"; mkdir -p "$sb/dev/scripts" "$sb/analysis/lib/nf" "$sb/modules/demo" \
                           "$sb/modules/lib/shared" "$sb/modules/repo"
    cp "$REPO_ROOT/dev/scripts/check-analysis-versions.sh" "$REPO_ROOT/dev/scripts/bump-analysis-version.sh" \
       "$sb/dev/scripts/"
    printf 'frame {}\n' > "$sb/analysis/frame.config"
    printf '20260101.001\n' > "$sb/analysis/frame.version"
    printf 'def one() { 1 }\n' > "$sb/analysis/lib/nf/thing.nf"
    printf '#!index-format: 1\n#!index-version: 20260101.001\n' > "$sb/modules/repo/index.tsv"
    printf '{"name": "demo", "version": "20260101.001"}\n' > "$sb/modules/demo/manifest.json"
    printf 'workflow {}\n' > "$sb/modules/demo/main.nf"
    printf '{"name": "shared", "kind": "library", "version": "20260101.001"}\n' \
        > "$sb/modules/lib/shared/manifest.json"
    printf 'shared <- function() 1\n' > "$sb/modules/lib/shared/shared.R"
    (cd "$sb" && git init -q . && git add -A \
        && GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base \
               --date='2026-01-01T00:00:00Z') > /dev/null 2>&1 \
        || { fail_case "could not build a repository to bump in"; return; }

    printf 'process P {}\n' >> "$sb/modules/demo/main.nf"
    printf 'shared <- function() 2\n' >> "$sb/modules/lib/shared/shared.R"
    printf 'def two() { 2 }\n' >> "$sb/analysis/lib/nf/thing.nf"
    printf 'demo\tmodule\t20260101.001\n' >> "$sb/modules/repo/index.tsv"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_eq "4" "$(grep -c 'bump it:' <<< "$out")" "the gate names all four behind:"$'\n'"$out"

    today=$(date -u +%Y%m%d)
    status=0
    out=$(cd "$sb" && bash dev/scripts/bump-analysis-version.sh --pending 2>&1) || status=$?
    assert_status 0 "$status" "one --pending bumps them all and the gate then passes:"$'\n'"$out"
    assert_contains "$out" "module demo: 20260101.001 -> $today.001" "the module, named as it moved"
    assert_contains "$out" "module shared: 20260101.001 -> $today.001" "the library"
    assert_contains "$out" "frame: 20260101.001 -> $today.001" "the frame"
    assert_contains "$out" "index: 20260101.001 -> $today.001" "and the catalogue's header"
    assert_contains "$out" "up to date" "and says the gate passes"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1) \
        || fail_case "the gate does not pass after --pending:"$'\n'"$out"

    local before; before=$(cd "$sb" && cat analysis/frame.version modules/*/manifest.json \
                                             modules/lib/*/manifest.json modules/repo/index.tsv)
    status=0
    out=$(cd "$sb" && bash dev/scripts/bump-analysis-version.sh --pending 2>&1) || status=$?
    assert_status 0 "$status" "a second --pending succeeds"
    assert_contains "$out" "Nothing is behind" "having nothing to do"
    assert_eq "$before" "$(cd "$sb" && cat analysis/frame.version modules/*/manifest.json \
                                         modules/lib/*/manifest.json modules/repo/index.tsv)" \
        "and changes nothing"

    printf 'process Q {}\n' >> "$sb/modules/demo/main.nf"
    rm "$sb/dev/scripts/check-analysis-versions.sh"
    status=0
    out=$(cd "$sb" && bash dev/scripts/bump-analysis-version.sh --pending 2>&1) || status=$?
    assert_status 1 "$status" "with no gate to ask it stops"
    assert_contains "$out" "named nothing to bump" "saying the gate gave it nothing"
    assert_contains "$(cat "$sb/modules/demo/manifest.json")" "\"$today.001\"" "and bumps nothing"
}

# THE FRAME VERSION MOVES WITH A CHANGE AND NEVER WITH THE CALENDAR.
#
# check-analysis-versions.sh answered `date -u` for a dirty tree, so an uncommitted frame change
# went BEHIND again at every midnight and asked for a fresh stamp from a frame nobody had
# touched since. Work sits uncommitted in this project for as long as it is under review, which
# is exactly how long that lasted.
#
# In a repository of its own, because the script takes its root from its own location and the
# answer depends on whether the tree it reads is dirty - which this one's is not, most days.
test_the_frame_version_moves_with_a_change_and_not_with_the_calendar() {
    local sb; sb=$(guard_path "$TEST_TMPDIR/version-rule")
    rm -rf "$sb"; mkdir -p "$sb/dev/scripts" "$sb/analysis/lib/nf" \
                           "$sb/modules/demo/test" "$sb/modules/repo" \
                           "$sb/analysis/modules/ghost"
    cp "$REPO_ROOT/dev/scripts/check-analysis-versions.sh" "$sb/dev/scripts/"
    printf 'frame {}\n' > "$sb/analysis/frame.config"
    printf '20260101.001\n' > "$sb/analysis/frame.version"
    printf 'def one() { 1 }\n' > "$sb/analysis/lib/nf/thing.nf"
    printf '#!index-format: 1\n#!index-version: 20260101.001\n' > "$sb/modules/repo/index.tsv"
    printf '{"name": "demo", "version": "20260101.001"}\n' > "$sb/modules/demo/manifest.json"
    printf 'workflow {}\n' > "$sb/modules/demo/main.nf"
    printf 'echo case\n' > "$sb/modules/demo/test/demo.sh"
    # `ghost` is planted in the INSTALL STORE, which the gate must not read. The store is
    # gitignored and empty in a checkout, so a loop pointed at it iterates nothing and reports
    # every module fine - which is exactly what happened and went undetected, because this
    # fixture used to plant `demo` there too and so agreed with the bug.
    printf '{"name": "ghost", "version": "20260101.001"}\n' > "$sb/analysis/modules/ghost/manifest.json"
    printf 'workflow {}\n' > "$sb/analysis/modules/ghost/main.nf"
    # Committed AS OF the day the version names, because a clean tree is compared against the
    # commit date and this fixture would otherwise say the frame changed today.
    (cd "$sb" && git init -q . && git add -A \
        && GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base \
               --date='2026-01-01T00:00:00Z') > /dev/null 2>&1 \
        || { fail_case "could not build a repository to check in"; return; }

    local out
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1)
    assert_contains "$out" "up to date" "an untouched frame needs no new version:"$'\n'"$out"

    printf 'def two() { 2 }\n' >> "$sb/analysis/lib/nf/thing.nf"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_contains "$out" "BEHIND" "a changed frame with a stale version:"$'\n'"$out"

    # The version now names THE DAY THE CHANGE WAS MADE, which is January and not today. This
    # is the assertion that fails if the dirty answer goes back to being today's date.
    touch -d '2026-01-02T00:00:00Z' "$sb/analysis/lib/nf/thing.nf"
    printf '20260102.001\n' > "$sb/analysis/frame.version"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1)
    assert_contains "$out" "up to date" \
        "a bump dated to the change stays good however long it sits:"$'\n'"$out"

    # A MODULE'S OWN CASES ARE NOT THE MODULE. publish-module.sh drops test/ from the tarball,
    # so nothing there reaches a published module - and the manifest version is what an
    # installation and every published result record the module by. Fixing a case must not move
    # it; touching what the module computes must.
    printf 'echo another case\n' >> "$sb/modules/demo/test/demo.sh"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1)
    assert_not_contains "$out" "module 'demo'" \
        "a module's test changing is not the module changing:"$'\n'"$out"

    printf 'process P {}\n' >> "$sb/modules/demo/main.nf"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_contains "$out" "module 'demo'" \
        "but its main.nf changing is:"$'\n'"$out"

    # And the store is still not a source, however stale what sits in it looks. `ghost` has
    # been changed and never bumped for the whole of this case; a gate reading the store would
    # have named it by now.
    printf 'process Q {}\n' >> "$sb/analysis/modules/ghost/main.nf"
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_not_contains "$out" "ghost" \
        "the install store is not checked for version bumps:"$'\n'"$out"
}

# THE RELEASE GATE REFUSES TO ANSWER RATHER THAN ANSWERING WRONGLY.
#
# A shallow clone does not make the checker quiet, which is what makes this worth a case. The
# grafted tip reads as having created every file, so the module and catalogue checks see the
# version line as added in that commit and report a missed bump as fine - measured, with a
# module changed two commits earlier and never bumped. release.yml's checkout was shallow, which
# is exactly how the gate would have been wired in.
#
# The same repository serves both halves, so it is built once.
test_the_release_gate_refuses_what_it_cannot_check() {
    local sb out
    sb=$(guard_path "$TEST_TMPDIR/release-gate")
    rm -rf "$sb"; mkdir -p "$sb/origin/dev/scripts" "$sb/origin/analysis/lib/nf" \
                           "$sb/origin/modules/repo"
    cp "$REPO_ROOT/dev/scripts/check-analysis-versions.sh" "$sb/origin/dev/scripts/"
    printf 'frame {}\n' > "$sb/origin/analysis/frame.config"
    printf '20260101.001\n' > "$sb/origin/analysis/frame.version"
    printf 'def one() { 1 }\n' > "$sb/origin/analysis/lib/nf/thing.nf"
    printf '#!index-format: 1\n#!index-version: 20260101.001\n' > "$sb/origin/modules/repo/index.tsv"
    # Two commits, because a shallow clone of a one-commit repository is not shallow.
    (cd "$sb/origin" && git init -q . && git add -A \
        && GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base --date='2026-01-01T00:00:00Z' \
        && printf 'def two() { 2 }\n' >> analysis/lib/nf/thing.nf \
        && printf '20260102.001\n' > analysis/frame.version \
        && git add -A \
        && GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm second --date='2026-01-02T00:00:00Z') \
        > /dev/null 2>&1 \
        || { fail_case "could not build a repository to check in"; return; }

    # The control: with history and a clean tree it answers, and answers yes.
    out=$(cd "$sb/origin" && bash dev/scripts/check-analysis-versions.sh --release 2>&1)
    assert_contains "$out" "up to date" \
        "a clean tree with history should pass the gate:"$'\n'"$out"

    # A shallow clone: every check would pass by having asked nothing.
    if ! git clone -q --depth 1 "file://$sb/origin" "$sb/shallow" > /dev/null 2>&1; then
        fail_case "could not make a shallow clone"
    else
        out=$(cd "$sb/shallow" && bash dev/scripts/check-analysis-versions.sh --release 2>&1 || true)
        assert_contains "$out" "REFUSED" "a shallow clone must be refused:"$'\n'"$out"
        assert_contains "$out" "fetch-depth" "and say how to fix the checkout"
        # Without --release it stays usable: a developer's clone is their business.
        out=$(cd "$sb/shallow" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
        assert_not_contains "$out" "REFUSED" "while the everyday run is not refused"
    fi

    # An uncommitted change under analysis/ is dated by mtime, which on a fresh checkout is
    # checkout time and says nothing about when the work was done.
    printf 'def three() { 3 }\n' >> "$sb/origin/analysis/lib/nf/thing.nf"
    out=$(cd "$sb/origin" && bash dev/scripts/check-analysis-versions.sh --release 2>&1 || true)
    assert_contains "$out" "REFUSED" "a dirty analysis/ must be refused at a release:"$'\n'"$out"
    assert_contains "$out" "thing.nf" "naming what is uncommitted"
}

# THE MODULE CHECK MUST BITE ON A CLEAN TREE, WHICH IS THE ONLY STATE A RELEASE IS EVER IN.
# It used to run only against uncommitted work, so every module passed a release unexamined.
test_a_committed_module_change_without_a_version_bump_is_caught() {
    local sb out
    sb=$(guard_path "$TEST_TMPDIR/module-version-committed")
    rm -rf "$sb"; mkdir -p "$sb/dev/scripts" "$sb/analysis/lib/nf" \
                           "$sb/modules/demo/test" "$sb/modules/lib/helper" "$sb/modules/repo"
    cp "$REPO_ROOT/dev/scripts/check-analysis-versions.sh" "$sb/dev/scripts/"
    printf 'frame {}\n' > "$sb/analysis/frame.config"
    printf '20260101.001\n' > "$sb/analysis/frame.version"
    printf 'def one() { 1 }\n' > "$sb/analysis/lib/nf/thing.nf"
    printf '#!index-format: 1\n#!index-version: 20260101.001\n' > "$sb/modules/repo/index.tsv"
    printf '{"name": "demo", "version": "20260101.001"}\n' > "$sb/modules/demo/manifest.json"
    printf 'workflow {}\n' > "$sb/modules/demo/main.nf"
    printf 'echo case\n' > "$sb/modules/demo/test/demo.sh"
    # A library carries a manifest and a version exactly like a module and is published the
    # same way, so it is owed the same check under the other half of the glob.
    printf '{"name": "helper", "kind": "library", "version": "20260101.001"}\n' \
        > "$sb/modules/lib/helper/manifest.json"
    printf 'h <- function() 1\n' > "$sb/modules/lib/helper/helper.R"
    (cd "$sb" && git init -q . && git add -A \
        && GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base --date='2026-01-01T00:00:00Z') \
        > /dev/null 2>&1 \
        || { fail_case "could not build a repository to check in"; return; }

    # Commit a change to what the module computes, and do not move its version.
    (cd "$sb" && printf 'process P {}\n' >> modules/demo/main.nf && git add -A \
        && GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm 'change demo' \
               --date='2026-01-02T00:00:00Z') > /dev/null 2>&1
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_contains "$out" "module 'demo'" \
        "a committed module change with a stale version must be caught:"$'\n'"$out"

    # And a commit that moves the version along with the change is not reported.
    (cd "$sb" && printf 'process Q {}\n' >> modules/demo/main.nf \
        && printf '{"name": "demo", "version": "20260103.001"}\n' > modules/demo/manifest.json \
        && git add -A \
        && GIT_COMMITTER_DATE='2026-01-03T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm 'change demo and bump' \
               --date='2026-01-03T00:00:00Z') > /dev/null 2>&1
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_not_contains "$out" "module 'demo'" \
        "while a change committed with its bump is not:"$'\n'"$out"

    # A module's own cases are not the module: publish-module.sh drops test/ from the tarball,
    # so nothing there reaches a published module.
    (cd "$sb" && printf 'echo more\n' >> modules/demo/test/demo.sh && git add -A \
        && GIT_COMMITTER_DATE='2026-01-04T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm 'a case only' \
               --date='2026-01-04T00:00:00Z') > /dev/null 2>&1
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_not_contains "$out" "module 'demo'" \
        "and a commit touching only its cases is not the module changing:"$'\n'"$out"

    # The same question of a LIBRARY, which is the half of the glob a module never exercises.
    (cd "$sb" && printf 'i <- function() 2\n' >> modules/lib/helper/helper.R && git add -A \
        && GIT_COMMITTER_DATE='2026-01-05T00:00:00Z' \
           git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm 'change helper' \
               --date='2026-01-05T00:00:00Z') > /dev/null 2>&1
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh 2>&1 || true)
    assert_contains "$out" "helper" \
        "a committed library change with a stale version must be caught too:"$'\n'"$out"
}

# A repository of its own for publish-module.sh, which takes its root from `git rev-parse`, builds
# from HEAD and writes into modules/repo/. Three modules and a library: beta is in the catalogue
# already, and alpha, delta and the library gamma are pending, in that order, which is the order
# --list prints them. alpha also has a row for an older version, so a catalogue matched on the
# name alone would call it published. Both alpha and gamma carry a test/ directory, which no
# tarball ships. bump-analysis-version.sh comes along because every publish calls it.
#
# Two commits a day apart, the second touching only delta. HEAD's time is then not the time alpha
# last changed, which is what alpha's tarball is stamped with, so a batch that stamped with HEAD's
# time would build a different tarball than a single publish does. The first commit alone could
# not tell the two apart.
publish_sandbox() {   # path
    local sb="$1" m
    rm -rf "$sb"; mkdir -p "$sb/dev/scripts" "$sb/modules/repo" "$sb/modules/alpha/test" \
                           "$sb/modules/beta" "$sb/modules/delta" "$sb/modules/lib/gamma/test"
    cp "$REPO_ROOT/dev/scripts/publish-module.sh" "$REPO_ROOT/dev/scripts/bump-analysis-version.sh" \
       "$sb/dev/scripts/"
    {
        printf '#!index-format: 1\n#!index-version: 20260101.001\n'
        printf 'name\tkind\tversion\tcontract\tframe\tenvironment\turl\tsha256\tsummary\n'
        printf 'alpha\tmodule\t20251231.001\tfreq-1\t20251231.001\t3.0.0\thttps://example.invalid/alpha-20251231.001.tar.gz\t%064d\talpha\n' 0
        printf 'beta\tmodule\t20260101.001\tfreq-1\t20260101.001\t3.0.0\thttps://example.invalid/beta-20260101.001.tar.gz\t%064d\tbeta\n' 0
    } > "$sb/modules/repo/index.tsv"
    for m in alpha beta delta; do
        printf '{"name": "%s", "kind": "module", "version": "20260101.001", "contract": "freq-1", "frame": "20260101.001", "environment": "3.0.0", "summary": "%s"}\n' \
            "$m" "$m" > "$sb/modules/$m/manifest.json"
        printf 'workflow {}\n' > "$sb/modules/$m/main.nf"
        printf '{}\n' > "$sb/modules/$m/citations.json"
    done
    printf 'echo case\n' > "$sb/modules/alpha/test/alpha.sh"
    printf '{"name": "gamma", "kind": "library", "version": "20260101.002", "frame": "20260101.001", "environment": "3.0.0", "summary": "gamma"}\n' \
        > "$sb/modules/lib/gamma/manifest.json"
    printf 'g <- function() 1\n' > "$sb/modules/lib/gamma/gamma.R"
    printf 'echo case\n' > "$sb/modules/lib/gamma/test/gamma.sh"
    (cd "$sb" && git init -q . && git add -A && sandbox_commit base 2026-01-01 \
        && printf 'process P {}\n' >> modules/delta/main.nf && git add -A \
        && sandbox_commit 'change delta' 2026-01-02) > /dev/null 2>&1
}

# Commits what is staged in the current repository, dated to the given day. Signing is turned off
# because a machine that signs by default, with no signer to hand, would fail the commit and skip
# every case built on it.
sandbox_commit() {   # message day
    GIT_COMMITTER_DATE="$2T00:00:00Z" \
        git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
            commit -qm "$1" --date="$2T00:00:00Z"
}

# How many catalogue rows name a module, at one version when one is given.
catalogue_rows() {   # index name [version]
    awk -F'\t' -v n="$2" -v v="${3-}" '$1 == n && (v == "" || $3 == v)' "$1" | wc -l | tr -d ' '
}

# Runs a sandbox's publish-module.sh from the given directory with its two streams kept apart:
# PM_OUT, PM_ERR and PM_STATUS. PM_SCRIPT is the script's path from that directory.
publish_run() {   # dir args...
    local dir="$1"; shift
    PM_STATUS=0
    (cd "$dir" && bash "${PM_SCRIPT:-dev/scripts/publish-module.sh}" "$@") \
        > "$TEST_TMPDIR/publish.out" 2> "$TEST_TMPDIR/publish.err" || PM_STATUS=$?
    PM_OUT=$(cat "$TEST_TMPDIR/publish.out")
    PM_ERR=$(cat "$TEST_TMPDIR/publish.err")
}

# --all-pending publishes what --list calls UNPUBLISHED, each through the single publish, and
# nothing else. Run from a subdirectory by a relative path, because the script changes to the
# repository root before it calls itself once per module, and a path taken from $0 stops
# resolving there.
test_publish_all_pending_publishes_what_list_names() {
    local sb index before m batch_sha single_sha
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    index="$sb/modules/repo/index.tsv"

    publish_run "$sb" --list
    assert_status 0 "$PM_STATUS" "--list should succeed:"$'\n'"$PM_ERR"
    assert_contains "$PM_OUT" "UNPUBLISHED    alpha 20260101.001" \
        "a row for an older version leaves alpha pending:"$'\n'"$PM_OUT"
    assert_contains "$PM_OUT" "published      beta 20260101.001" "beta is published"
    assert_contains "$PM_OUT" "UNPUBLISHED    gamma 20260101.002" "the library under modules/lib/ is listed"
    assert_contains "$PM_OUT" "3 to publish" "it counts what is left"
    assert_contains "$PM_OUT" "--all-pending" "and says how to publish all of it"

    PM_SCRIPT=../dev/scripts/publish-module.sh publish_run "$sb/modules" --all-pending
    assert_status 0 "$PM_STATUS" "--all-pending should publish all three:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_eq "" "$PM_ERR" "and say nothing on stderr when nothing went wrong"
    assert_contains "$PM_OUT" "Publishing 3 from HEAD" "it says how many it is about to publish"
    for m in alpha-20260101.001 delta-20260101.001 gamma-20260101.002; do
        assert_file "$sb/modules/repo/$m.tar.gz" "a tarball for $m"
    done
    assert_no_file "$sb/modules/repo/beta-20260101.001.tar.gz" "and none for what was published already"
    assert_count 1 "$(catalogue_rows "$index" alpha 20260101.001)" "catalogue rows for alpha's new version"
    assert_count 1 "$(catalogue_rows "$index" alpha 20251231.001)" "and its old row is left alone"
    for m in beta delta gamma; do
        assert_count 1 "$(catalogue_rows "$index" "$m")" "catalogue rows naming $m"
    done
    assert_contains "$PM_OUT" "Published 3: alpha delta gamma" "the summary names all three"
    assert_count 1 "$(grep -c '^Nothing is committed' <<< "$PM_OUT")" \
        "the closing note is said once, not once per module"
    assert_contains "$PM_OUT" "Published module alpha 20260101.001" "each publish's own report reaches stdout"
    assert_contains "$PM_OUT" "tarball : modules/repo/alpha-20260101.001.tar.gz" "with its tarball"
    assert_count 0 "$(grep -c '^$' "$index")" "and the catalogue gains no blank line"
    # What the tarball holds: no test/, and every member stamped with the day alpha last changed,
    # which is not HEAD's day.
    assert_count 0 "$(tar -tzf "$sb/modules/repo/alpha-20260101.001.tar.gz" | grep -c '/test')" \
        "alpha's tarball leaves out its test/"
    assert_eq "2026-01-01" \
        "$(TZ=UTC tar --full-time -tvzf "$sb/modules/repo/alpha-20260101.001.tar.gz" | awk '{ print $4 }' | sort -u)" \
        "and is stamped with the commit that last touched alpha"

    # Nothing is left, so a second run publishes nothing, changes nothing and succeeds.
    before=$(cat "$index")
    publish_run "$sb" --all-pending
    assert_status 0 "$PM_STATUS" "a run with nothing pending succeeds:"$'\n'"$PM_ERR"
    assert_eq "Everything in the tree is in the catalogue." "$PM_OUT" "and says only that"
    assert_eq "$before" "$(cat "$index")" "and leaves the catalogue alone"

    # The batch exists to make what single publishes make, so the bytes are compared: the same
    # module published alone, from the same commit, after the batch's work is put back.
    batch_sha=$(sha256sum "$sb/modules/repo/alpha-20260101.001.tar.gz" | awk '{print $1}')
    (cd "$sb" && git checkout -q -- modules/repo/index.tsv && rm -f modules/repo/*.tar.gz)
    publish_run "$sb" alpha
    single_sha=$(sha256sum "$sb/modules/repo/alpha-20260101.001.tar.gz" 2>/dev/null | awk '{print $1}')
    assert_eq "$batch_sha" "$single_sha" "the batch should build the tarball a single publish builds"
    assert_contains "$PM_OUT" "Nothing is committed" "and a single publish still closes with the note"

    # Always HEAD, because the pending set is read from the working tree and only HEAD matches it.
    publish_run "$sb" --all-pending HEAD
    assert_status 1 "$PM_STATUS" "--all-pending takes no ref:"$'\n'"$PM_OUT"
    assert_contains "$PM_ERR" "takes no ref" "and says so on stderr"
}

# A publish builds from HEAD while --list reads the working tree, so a pending source that differs
# from HEAD would be listed with one content and published with another. Refused before anything
# is written, whether the difference is changed, staged or untracked, and with the repository set
# to status.showUntrackedFiles=no, under which a plain git status shows no untracked file at all.
# One differing source is refused as surely as several. A module already published is not
# pending, so its own uncommitted change blocks nothing. A directory whose name holds a space is
# checked under its whole name, which a listing split on spaces would cut. A change under test/
# alone is not the module, for a module or a library, because the tarball drops test/. And a git
# status that fails is refused, since its empty output would read as clean.
test_publish_all_pending_refuses_a_source_that_differs_from_head() {
    local sb before
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending-dirty")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    git -C "$sb" config status.showUntrackedFiles no
    printf 'process P {}\n' >> "$sb/modules/alpha/main.nf"
    printf 'h <- function() 2\n' >> "$sb/modules/lib/gamma/gamma.R"
    git -C "$sb" add modules/lib/gamma/gamma.R
    printf 'process Q {}\n' > "$sb/modules/delta/extra.nf"
    mkdir -p "$sb/modules/epsilon" "$sb/modules/zeta draft"
    printf '{"name": "epsilon", "version": "20260101.001"}\n' > "$sb/modules/epsilon/manifest.json"
    printf '{"name": "zeta draft", "version": "20260101.001"}\n' > "$sb/modules/zeta draft/manifest.json"
    printf 'process R {}\n' >> "$sb/modules/beta/main.nf"
    before=$(cat "$sb/modules/repo/index.tsv")

    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" \
        "a pending source that differs from HEAD must be refused:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "modules/alpha/" "naming the changed one, on stderr"
    assert_contains "$PM_ERR" "modules/lib/gamma/" "the staged one"
    assert_contains "$PM_ERR" "modules/delta/" "the one holding a file git does not track"
    assert_contains "$PM_ERR" "modules/epsilon/" "the one HEAD does not have"
    assert_contains "$PM_ERR" "modules/zeta draft/" "and the one whose name holds a space, whole"
    assert_not_contains "$PM_ERR" "modules/beta/" "but not the published one"
    assert_eq "" "$PM_OUT" "with nothing on stdout"
    assert_eq "$before" "$(cat "$sb/modules/repo/index.tsv")" "nothing may reach the catalogue"
    assert_eq "" "$(find "$sb/modules/repo" -name '*.tar.gz')" "and no tarball may be written"

    (cd "$sb" && git checkout -q HEAD -- modules/lib/gamma \
        && rm -rf modules/epsilon "modules/zeta draft" modules/delta/extra.nf)
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "one differing source is refused too:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "modules/alpha/" "naming it"
    assert_not_contains "$PM_ERR" "modules/delta/" "and only it"

    git -C "$sb" checkout -q HEAD -- modules/alpha
    printf 'echo another case\n' >> "$sb/modules/alpha/test/alpha.sh"
    printf 'echo another case\n' >> "$sb/modules/lib/gamma/test/gamma.sh"
    publish_run "$sb" --all-pending
    assert_status 0 "$PM_STATUS" \
        "test/ alone, and a published module's change, block nothing:"$'\n'"$PM_ERR"

    (cd "$sb" && git checkout -q -- modules/repo/index.tsv && rm -f modules/repo/*.tar.gz)
    head -c 20 "$sb/.git/index" > "$sb/index.cut" && mv "$sb/index.cut" "$sb/.git/index"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "a git status that fails must be refused:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "git status failed" "saying so"
    assert_eq "" "$(find "$sb/modules/repo" -name '*.tar.gz')" "before anything is written"
}

# It stops at the first module that fails and says what this run published and what is still
# pending, read back from the catalogue, on stderr beneath the failing publish's own reason.
# Failures on both sides of the row. A tarball already on disk for a version with no row makes a
# publish refuse before it writes anything, and the report names the file, which nothing else
# would ever remove. A refused index bump fails a publish after its row is written, and counting
# along the loop would report that module as still pending. When that bump was the last thing a
# run did, with #!index-version as HEAD has it, no later run would move the version, so the
# report says to. The bump is made to refuse by setting the day's counter to 999, past which
# bump-analysis-version.sh refuses another change.
test_publish_all_pending_stops_and_reads_back_what_it_published() {
    local sb index today
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending-stop")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    index="$sb/modules/repo/index.tsv"

    # In the middle: alpha is published, delta refuses, gamma is not reached.
    : > "$sb/modules/repo/delta-20260101.001.tar.gz"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "a module that refuses stops the batch:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "delta-20260101.001.tar.gz already exists" \
        "the refusing publish's own reason reaches stderr"
    assert_contains "$PM_ERR" "STOPPED at delta." "the batch names where it stopped"
    assert_contains "$PM_ERR" "Published by this run, and uncommitted: alpha" "what it published first"
    assert_contains "$PM_ERR" "Still pending: delta gamma" "what is left"
    assert_contains "$PM_ERR" "Delete them first:"$'\n'"    modules/repo/delta-20260101.001.tar.gz" \
        "the file in the way"
    assert_contains "$PM_ERR" "run --all-pending again" "and what to do next"
    assert_no_file "$sb/modules/repo/gamma-20260101.002.tar.gz" "nothing after it is attempted"

    # Fixed, the next run starts from what is still pending, so alpha is not published twice.
    rm -f "$sb/modules/repo/delta-20260101.001.tar.gz"
    publish_run "$sb" --all-pending
    assert_status 0 "$PM_STATUS" "the rerun should publish the rest:"$'\n'"$PM_ERR"
    assert_contains "$PM_OUT" "Published 2: delta gamma" "and only the rest"
    assert_count 1 "$(catalogue_rows "$index" alpha 20260101.001)" "catalogue rows for alpha's version"

    # At the first module, nothing was published by this run.
    (cd "$sb" && git checkout -q -- modules/repo/index.tsv && rm -f modules/repo/*.tar.gz)
    : > "$sb/modules/repo/alpha-20260101.001.tar.gz"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "the first module refusing stops the batch:"$'\n'"$PM_ERR"
    assert_not_contains "$PM_ERR" "Published by this run" "with nothing published by this run"
    assert_contains "$PM_ERR" "Still pending: alpha delta gamma" "and everything still pending"

    # The same file committed may have been deployed and installed, so it is not offered for
    # deletion.
    (cd "$sb" && git add modules/repo/alpha-20260101.001.tar.gz \
        && sandbox_commit 'a tarball once committed' 2026-01-03) > /dev/null 2>&1
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "a committed tarball in the way stops the batch:"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "Bump the module's version" "as a published version"
    assert_not_contains "$PM_ERR" "Delete them first" "and is not offered for deletion"
    (cd "$sb" && git rm -q modules/repo/alpha-20260101.001.tar.gz \
        && sandbox_commit 'and removed' 2026-01-03) > /dev/null 2>&1

    # After the row. The day is read twice, here and by the bump, so a run straddling midnight UTC
    # would see the bump succeed and this half fail.
    (cd "$sb" && git checkout -q -- modules/repo/index.tsv && rm -f modules/repo/*.tar.gz)
    today=$(date -u +%Y%m%d)
    sed -i "s/^#!index-version: .*/#!index-version: $today.999/" "$index"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "a refused index bump stops the batch:"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "STOPPED at alpha." "at alpha"
    assert_count 1 "$(catalogue_rows "$index" alpha 20260101.001)" "with alpha's row written"
    assert_contains "$PM_ERR" "Published by this run, and uncommitted: alpha" \
        "so alpha is reported published, read back from the catalogue"
    assert_contains "$PM_ERR" "Still pending: delta gamma" "and only what follows it as pending"

    # The same, with HEAD itself at the 999th change, so #!index-version has not moved at all. With
    # delta and gamma left, the rerun moves it as it publishes them, so the report does not send
    # anyone to move it by hand.
    local sb2
    sb2=$(guard_path "$TEST_TMPDIR/publish-all-pending-stop-999")
    publish_sandbox "$sb2" || { fail_case "could not build a second repository"; return; }
    sed -i "s/^#!index-version: .*/#!index-version: $today.999/" "$sb2/modules/repo/index.tsv"
    (cd "$sb2" && git add -A && sandbox_commit 'the day at its 999th change' 2026-01-03) > /dev/null 2>&1
    publish_run "$sb2" --all-pending
    assert_status 1 "$PM_STATUS" "the bump refused at the first module stops the batch:"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "Still pending: delta gamma" "with two left"
    assert_not_contains "$PM_ERR" "bump-analysis-version.sh index" \
        "so moving the version by hand is not the advice"
    assert_contains "$PM_ERR" "run --all-pending again" "running it again is"

    # After the row of the last module pending, with HEAD at the 999th change: the row is in,
    # nothing is left for a rerun to do, and the version has not moved.
    (cd "$sb" && git checkout -q -- modules/repo/index.tsv && rm -f modules/repo/*.tar.gz)
    publish_run "$sb" alpha
    publish_run "$sb" delta
    sed -i "s/^#!index-version: .*/#!index-version: $today.999/" "$index"
    (cd "$sb" && git add -A && sandbox_commit 'alpha and delta published' 2026-01-03) > /dev/null 2>&1
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "the last module's bump refused stops the batch:"$'\n'"$PM_ERR"
    assert_contains "$PM_OUT" "Publishing 1 from HEAD" "with one module pending"
    assert_contains "$PM_ERR" "Published by this run, and uncommitted: gamma" "which is published"
    assert_not_contains "$PM_ERR" "Still pending" "with nothing left pending"
    assert_not_contains "$PM_ERR" "run --all-pending again" "so a rerun is not the advice"
    assert_contains "$PM_ERR" "dev/scripts/bump-analysis-version.sh index" "moving the version is"
}

# What it cannot read, it refuses before writing anything. A manifest with no version is one
# --list shows as NO MANIFEST and a single publish refuses, so a batch that passed over it would
# report everything published. A directory with no manifest at all is not a module and is not
# read. A catalogue with no header row, or one without a name column, cannot say what is
# published, and read as empty it would call every module pending.
test_publish_all_pending_refuses_what_it_cannot_read() {
    local sb index before
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending-unreadable")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    index="$sb/modules/repo/index.tsv"
    mkdir -p "$sb/modules/zeta" "$sb/modules/eta" "$sb/modules/notes"
    printf '{"name": "zeta"}\n' > "$sb/modules/zeta/manifest.json"
    printf '{"name": "eta", "vers\n' > "$sb/modules/eta/manifest.json"
    printf 'not a module\n' > "$sb/modules/notes/README"
    (cd "$sb" && git add -A && sandbox_commit 'zeta, eta and notes' 2026-01-03) > /dev/null 2>&1
    before=$(cat "$index")

    publish_run "$sb" --list
    assert_status 0 "$PM_STATUS" "--list still lists:"$'\n'"$PM_ERR"
    assert_contains "$PM_OUT" "NO MANIFEST    modules/zeta/" "the manifest with no version:"$'\n'"$PM_OUT"
    assert_contains "$PM_OUT" "NO MANIFEST    modules/eta/" "the one that does not parse"
    assert_contains "$PM_OUT" "2 with no name or version to read" "counted apart from what is left"
    assert_contains "$PM_OUT" "3 to publish, one at a time" "which counts only the readable ones"
    assert_not_contains "$PM_OUT" "all of them with" "and does not offer the batch that would refuse"
    assert_not_contains "$PM_OUT" "modules/notes" "and nothing for a directory with no manifest"

    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "an unreadable manifest must stop the batch:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "modules/zeta/" "naming it"
    assert_contains "$PM_ERR" "modules/eta/" "and the one that does not parse"
    assert_not_contains "$PM_ERR" "modules/notes" "and only those"
    assert_eq "$before" "$(cat "$index")" "nothing may reach the catalogue"
    assert_eq "" "$(find "$sb/modules/repo" -name '*.tar.gz')" "and no tarball may be written"

    # Everything else published, it is still not everything.
    publish_run "$sb" alpha; publish_run "$sb" delta; publish_run "$sb" gamma
    publish_run "$sb" --list
    assert_not_contains "$PM_OUT" "Everything in the tree is in the catalogue" \
        "--list must not call the tree published while a manifest cannot be read:"$'\n'"$PM_OUT"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "and neither may --all-pending:"$'\n'"$PM_OUT"

    (cd "$sb" && git checkout -q -- modules/repo/index.tsv && rm -f modules/repo/*.tar.gz \
        && rm -rf modules/zeta modules/eta)
    printf '#!index-format: 1\n#!index-version: 20260101.001\n' > "$index"
    publish_run "$sb" --list
    assert_status 1 "$PM_STATUS" "--list must refuse a catalogue with no header row:"$'\n'"$PM_OUT"
    assert_contains "$PM_ERR" "no header row naming 'name' and 'version'" "and say why"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "so must --all-pending:"$'\n'"$PM_OUT"
    publish_run "$sb" alpha
    assert_status 1 "$PM_STATUS" "and a single publish:"$'\n'"$PM_OUT"
    assert_contains "$PM_ERR" "not the layout this script writes" "saying why rather than stopping silently"
    assert_eq "" "$(find "$sb/modules/repo" -name '*.tar.gz')" "all of them before writing anything"

    printf '#!index-format: 1\n#!index-version: 20260101.001\nkind\tversion\n' > "$index"
    publish_run "$sb" --list
    assert_status 1 "$PM_STATUS" "--list must refuse a header row without a name column:"$'\n'"$PM_OUT"
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "and so must --all-pending:"$'\n'"$PM_OUT"
    printf '#!index-format: 1\n#!index-version: 20260101.001\nname\tkind\n' > "$index"
    publish_run "$sb" --list
    assert_status 1 "$PM_STATUS" "and a header row without a version column:"$'\n'"$PM_OUT"
}

# A publish is asked for by name and finds modules/<name> before modules/lib/<name>, so a pending
# library that shares a module's name could never be published, and the batch would publish the
# module twice. Refused before anything is written.
test_publish_all_pending_refuses_a_name_two_directories_share() {
    local sb before
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending-shared")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    mkdir -p "$sb/modules/lib/delta"
    printf '{"name": "delta", "kind": "library", "version": "20260101.003", "frame": "20260101.001", "environment": "3.0.0", "summary": "a library called delta"}\n' \
        > "$sb/modules/lib/delta/manifest.json"
    (cd "$sb" && git add -A && sandbox_commit 'a library called delta' 2026-01-03) > /dev/null 2>&1
    before=$(cat "$sb/modules/repo/index.tsv")

    publish_run "$sb" --list
    assert_not_contains "$PM_OUT" "all of them with" \
        "--list must not offer the batch that would refuse:"$'\n'"$PM_OUT"
    assert_contains "$PM_OUT" "no two directories share" "and says what it is waiting for"

    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "a shared name must stop the batch:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "modules/delta/" "naming the module"
    assert_contains "$PM_ERR" "modules/lib/delta/" "and the library"
    assert_not_contains "$PM_ERR" "modules/alpha/" "and nothing else"
    assert_eq "$before" "$(cat "$sb/modules/repo/index.tsv")" "nothing may reach the catalogue"
    assert_eq "" "$(find "$sb/modules/repo" -name '*.tar.gz')" "and no tarball may be written"
}

# Every publish reporting success is not taken as every row being there: the catalogue is read
# back after the last one. Nothing in a sound tree produces a success without a row any more, so
# the fixture makes one. Its bump-analysis-version.sh, which every publish calls once its row is
# appended, deletes that row instead.
test_publish_all_pending_reads_back_what_it_reports_published() {
    local sb
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending-readback")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    cat > "$sb/dev/scripts/bump-analysis-version.sh" <<'STUB'
#!/usr/bin/env bash
sed -i '$d' "$(git rev-parse --show-toplevel)/modules/repo/index.tsv"
STUB

    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "a success with no row behind it must be caught:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_not_contains "$PM_OUT" "Published 3" "and not reported as published"
    assert_contains "$PM_ERR" "the catalogue has no row for some of them" "it says what it found"
    assert_contains "$PM_ERR" "Still pending: alpha delta gamma" "and what is still pending"

    # A catalogue that cannot be read back at all: this stand-in deletes the header row, so the
    # next publish stops and the read-back has nothing to read. An empty answer would have called
    # every module published.
    publish_sandbox "$sb" || { fail_case "could not rebuild the repository"; return; }
    cat > "$sb/dev/scripts/bump-analysis-version.sh" <<'STUB'
#!/usr/bin/env bash
sed -i '/^name\tkind/d' "$(git rev-parse --show-toplevel)/modules/repo/index.tsv"
STUB
    publish_run "$sb" --all-pending
    assert_status 1 "$PM_STATUS" "an unreadable catalogue stops the batch:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_ERR" "could not be read back" "saying what it does not know"
    assert_not_contains "$PM_ERR" "Published by this run" "rather than calling anything published"
}

# The batch runs this script once per module, so it has to find itself however it was started.
# With CDPATH exported, a `cd dev/scripts` goes to the first directory on CDPATH that holds one,
# so a decoy there catches a script that finds itself with cd. Read from standard input there is
# no file to run, which --all-pending refuses while --list carries on as it always did.
test_publish_all_pending_finds_itself_however_it_is_run() {
    local sb out err status
    sb=$(guard_path "$TEST_TMPDIR/publish-all-pending-self")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    mkdir -p "$sb/decoy/dev/scripts"

    CDPATH="$sb/decoy" publish_run "$sb" --all-pending
    assert_status 0 "$PM_STATUS" "an exported CDPATH must not send it astray:"$'\n'"$PM_OUT"$'\n'"$PM_ERR"
    assert_contains "$PM_OUT" "Published 3: alpha delta gamma" "and it publishes all three"

    status=0
    out=$(cd "$sb" && bash -s -- --list < dev/scripts/publish-module.sh 2>&1) || status=$?
    assert_status 0 "$status" "--list read from standard input still works:"$'\n'"$out"
    assert_contains "$out" "Everything in the tree is in the catalogue" "and lists"
    status=0
    err=$(cd "$sb" && bash -s -- --all-pending < dev/scripts/publish-module.sh 2>&1 > /dev/null) || status=$?
    assert_status 1 "$status" "--all-pending read from standard input must refuse:"$'\n'"$err"
    assert_contains "$err" "from its file" "saying why"
}

# A single publish refuses what it cannot finish before it writes anything, and says what a file
# in its way is. A catalogue header it does not write used to be found after the tarball was
# written, leaving one that every later publish refused as already published. A tarball with no
# row is named as left over, not as published. A manifest whose name is not its directory's is
# refused, because the frame would refuse the module. And a catalogue whose last line has no
# newline gets one, so the new row does not land on the end of a published one.
test_publish_writes_nothing_it_cannot_finish() {
    local sb index
    sb=$(guard_path "$TEST_TMPDIR/publish-single")
    publish_sandbox "$sb" || { fail_case "could not build a repository to publish from"; return; }
    index="$sb/modules/repo/index.tsv"

    sed -i 's/\tsummary$/\tsummary\tlicense/' "$index"
    publish_run "$sb" alpha
    assert_status 1 "$PM_STATUS" "a header it does not write must be refused:"$'\n'"$PM_OUT"
    assert_contains "$PM_ERR" "not the layout this script writes" "saying so"
    assert_no_file "$sb/modules/repo/alpha-20260101.001.tar.gz" "before any tarball is written"
    git -C "$sb" checkout -q -- modules/repo/index.tsv

    : > "$sb/modules/repo/alpha-20260101.001.tar.gz"
    publish_run "$sb" alpha
    assert_status 1 "$PM_STATUS" "a tarball already on disk is refused"
    assert_contains "$PM_ERR" "left over from a publish that did not finish" "and with no row it is left over"
    assert_not_contains "$PM_ERR" "Bump the module's version" "not published"
    rm -f "$sb/modules/repo/alpha-20260101.001.tar.gz"
    : > "$sb/modules/repo/beta-20260101.001.tar.gz"
    publish_run "$sb" beta
    assert_contains "$PM_ERR" "Bump the module's version" "while one with its row is published"
    rm -f "$sb/modules/repo/beta-20260101.001.tar.gz"
    publish_run "$sb" beta
    assert_status 1 "$PM_STATUS" "a row with no tarball beside it is refused too"
    assert_contains "$PM_ERR" "already has a row for beta 20260101.001" "as already published"

    # Committed and then taken out of the catalogue, a tarball may have been installed.
    : > "$sb/modules/repo/alpha-20260101.001.tar.gz"
    (cd "$sb" && git add modules/repo && sandbox_commit 'a tarball once committed' 2026-01-03) > /dev/null 2>&1
    publish_run "$sb" alpha
    assert_contains "$PM_ERR" "Bump the module's version" "a committed tarball with no row is published"
    assert_not_contains "$PM_ERR" "left over" "not left over"
    (cd "$sb" && git rm -q modules/repo/alpha-20260101.001.tar.gz \
        && sandbox_commit 'and removed' 2026-01-03) > /dev/null 2>&1

    printf '%s' "$(cat "$index")" > "$index.tmp" && mv "$index.tmp" "$index"
    publish_run "$sb" alpha
    assert_status 0 "$PM_STATUS" "a catalogue with no final newline still takes a row:"$'\n'"$PM_ERR"
    assert_eq 9 "$(awk -F'\t' '$1 == "beta" { print NF }' "$index")" "and the row before it keeps nine columns"
    assert_count 1 "$(catalogue_rows "$index" alpha 20260101.001)" "with alpha's own row after it"

    (cd "$sb" && sed -i 's/"name": "delta"/"name": "omega"/' modules/delta/manifest.json \
        && sed -i 's/"name": "gamma"/"name": "kappa"/' modules/lib/gamma/manifest.json \
        && git add -A && sandbox_commit 'delta and gamma call themselves something else' 2026-01-03) \
        > /dev/null 2>&1
    publish_run "$sb" delta
    assert_status 1 "$PM_STATUS" "a manifest naming another module must be refused:"$'\n'"$PM_OUT"
    assert_contains "$PM_ERR" "calls it 'omega'" "naming both"
    assert_no_file "$sb/modules/repo/delta-20260101.001.tar.gz" "and writing nothing"
    publish_run "$sb" gamma
    assert_status 1 "$PM_STATUS" "and so must a library's:"$'\n'"$PM_OUT"
    assert_contains "$PM_ERR" "calls it 'kappa'" "naming both"

    # The refusals a single publish has always had, each before anything is written.
    publish_run "$sb" nosuch
    assert_contains "$PM_ERR" "no module or library 'nosuch'" "an unknown name"
    (cd "$sb" && sed -i 's/"frame": "20260101.001", //' modules/beta/manifest.json \
        && printf '{"name": "alpha", "kind": "module", "version": "20260101.002", "contract": "freq-1", "frame": "20260101.001", "environment": "3.0.0", "summary": "with\\ta tab"}\n' \
            > modules/alpha/manifest.json \
        && git add -A && sandbox_commit 'beta loses frame, alpha gains a tab' 2026-01-04) > /dev/null 2>&1
    publish_run "$sb" beta
    assert_contains "$PM_ERR" "beta's manifest has no frame" "a missing field"
    publish_run "$sb" alpha
    assert_contains "$PM_ERR" "a manifest field contains a tab" "a tab in a field"
    (cd "$sb" && git rm -q modules/alpha/main.nf \
        && sed -i 's/with\\ta tab/alpha/' modules/alpha/manifest.json \
        && git add -A && sandbox_commit 'alpha loses main.nf' 2026-01-05) > /dev/null 2>&1
    publish_run "$sb" alpha
    assert_contains "$PM_ERR" "alpha has no main.nf" "a module without main.nf"
    assert_eq "modules/repo/alpha-20260101.001.tar.gz" "$(cd "$sb" && find modules/repo -name '*.tar.gz')" \
        "none of them writing a tarball: the only one is alpha's, from the newline check"
}

# The site deploys only for a released version: after release.yml publishes one, or when the
# workflow is run by hand on main, and either way only once the version the commit declares has a
# published release. A push to main and a pull request build and deploy nothing, so a release
# that fails at its tag leaves the site as it was. The v3.3.0 tag failed release.yml on
# 2026-10-07 after the merge had already deployed its manual and CHANGELOG.
#
# Asked twice: of the workflow's structure, every path to the deploy; and of the release check's
# own script, run against a stand-in gh answering published, draft and missing, which also records
# what it was asked. Every job is read for the Pages actions, not only the two named ones, and the
# build's gate is compared whole. A review on 2026-10-08 found four edits this case passed: the
# gate's && made ||, a second job deploying Pages ungated, the release looked up without its v,
# and draft read from another field, so that a draft release would deploy.
#
# The workflows are read by test/tools/workflow_yaml.py and asked as JSON. This case imported
# PyYAML until the 3.3.0 prep run on 2026-10-08, which failed it with ModuleNotFoundError: the
# suite runs on whichever python3 the shell finds, that shell had the analysis environment active,
# and neither PoolSeqFlow environment carries PyYAML. Every earlier run had used a system Python
# that happened to have it.
test_the_site_deploys_only_for_a_released_version() {
    local out sb answer status workflow
    sb=$(guard_path "$TEST_TMPDIR/site-release-check")
    rm -rf "$sb"; mkdir -p "$sb/bin" "$sb/tree"
    for workflow in docs release; do
        python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$REPO_ROOT/.github/workflows/$workflow.yml" \
            > "$sb/$workflow.json" 2> "$sb/$workflow.err" \
            || { fail_case "$workflow.yml could not be read: $(cat "$sb/$workflow.err")"; return; }
    done
    out=$(python3 - "$sb/docs.json" "$sb/release.json" 2>&1 <<'PY'
import json, sys
docs = json.load(open(sys.argv[1]))
release = json.load(open(sys.argv[2]))
on = docs["on"]
build, deploy = docs["jobs"]["build"], docs["jobs"]["deploy"]
problems = []
def need(ok, message):
    if not ok:
        problems.append(message)
need(deploy.get("if") == "needs.build.outputs.deploy == 'true'",
     "the deploy job runs on something besides the build's decision: %r" % deploy.get("if"))
need(deploy.get("needs") == "build", "the deploy job does not wait for the build")
need(build.get("outputs", {}).get("deploy") == "${{ steps.released.outputs.deploy }}",
     "the build's deploy output does not come from the release check")
check = [s for s in build["steps"] if s.get("id") == "released"]
need(len(check) == 1, "no single step with id 'released'")
if check:
    need(check[0].get("if") == "github.event_name == 'workflow_run' || github.event_name == 'workflow_dispatch'",
         "the release check runs for other events: %r" % check[0].get("if"))
for name, job in docs["jobs"].items():
    for step in job.get("steps") or []:
        uses = str(step.get("uses", ""))
        if uses.startswith("actions/deploy-pages"):
            need(name == "deploy", "%s runs in the job %r, which is not the gated deploy" % (uses, name))
        if uses.startswith(("actions/upload-pages-artifact", "actions/configure-pages")):
            need(name == "build" and step.get("if") == "steps.released.outputs.deploy == 'true'",
                 "%s runs in the job %r without the release check" % (uses, name))
gate = " ".join((build.get("if") or "").split())
need(gate == "github.event_name != 'workflow_run' || (github.event.workflow_run.conclusion == "
             "'success' && github.event.workflow_run.event == 'push')",
     "a failed release.yml, or one run by hand, reaches the build: %r" % gate)
need(on.get("workflow_run", {}).get("workflows") == [release["name"]],
     "workflow_run does not follow release.yml by its name, %r" % release["name"])
print("\n".join(problems) if problems else "OK")
PY
)
    assert_eq "OK" "$out" "every path to the deploy goes through the release check"

    python3 -c 'import json, sys
steps = json.load(open(sys.argv[1]))["jobs"]["build"]["steps"]
print([s for s in steps if s.get("id") == "released"][0]["run"])' \
        "$sb/docs.json" > "$sb/check.sh" 2>&1
    printf 'VERSION="9.9.9"\n' > "$sb/tree/PoolSeqFlow"
    : > "$sb/gh.args"
    for answer in false true missing; do
        {
            printf '#!/usr/bin/env bash\n'
            printf 'printf "%%s\\n" "$*" >> %q\n' "$sb/gh.args"
            if [ "$answer" = missing ]; then
                printf 'echo "release not found" >&2\nexit 1\n'
            else
                printf 'echo %s\n' "$answer"
            fi
        } > "$sb/bin/gh"
        chmod +x "$sb/bin/gh"
        : > "$sb/output"
        status=0
        (cd "$sb/tree" && PATH="$sb/bin:$PATH" GITHUB_OUTPUT="$sb/output" GITHUB_REPOSITORY=o/r \
            bash -eo pipefail "$sb/check.sh") > /dev/null 2>&1 || status=$?
        if [ "$answer" = false ]; then
            assert_status 0 "$status" "a published release deploys"
            assert_eq "deploy=true" "$(cat "$sb/output")" "and says so"
        else
            assert_status 1 "$status" "a release that is $answer must not deploy"
            assert_eq "" "$(cat "$sb/output")" "and says nothing to deploy"
        fi
    done
    assert_eq "release view v9.9.9 --repo o/r --json isDraft --jq .isDraft" "$(sort -u "$sb/gh.args")" \
        "every time, gh is asked whether this version's tag is a draft"
}

# THE READER THE CASE ABOVE RESTS ON. Every construct the workflows use, with the value each must
# come back as: the folded `if:` with a line indented past the others, which keeps its line break;
# a literal `run:` holding a blank line, a `#` line and a `: ` that are all script, ended by a
# comment indented between the step's keys and the script; a sequence of mappings; a sequence at
# its key's own indentation; flow sequences, empty and quoted; both quoted styles and a quoted key;
# two keys with no value in a row; a comment after a value; an empty item and a block item; and a
# folded block opening on an empty line and holding a line indented past the others. A second
# file, written by printf so no line of this one ends in spaces an editor could strip, holds a
# white-space-only line wider than its block, whose spaces past the block are text, and a block
# ending the file with no line break, which gains none.
#
# The expected values are YAML's: PyYAML read both files the same way on 2026-10-08, as it read
# all three workflow files. Then each kind of syntax the reader does not take, refused at the line
# and for the reason named: a refusal for some other reason, or at another line, would hide that
# the rule it names had stopped working.
#
# The first version of this case passed with 42 of the reader's own rules mutated away, among them
# two keys in a row read as one inside the other and a comment after a value read into it; its
# refusals asserted only that something was refused somewhere. A review found it on 2026-10-08.
test_the_workflow_reader_reads_what_the_workflows_use_and_refuses_the_rest() {
    local sb out want
    sb=$(guard_path "$TEST_TMPDIR/workflow-reader")
    rm -rf "$sb"; mkdir -p "$sb"
    cat > "$sb/sample.yml" <<'YAML'
# a comment
name: Sample flow
"quoted key": value
escaped: "say \"hi\" \\ to a\/b\tand\n"
empty: |
on:
  push:
    branches: [main, "dev", 'v*']
    tags: []
  pull_request:
  workflow_dispatch:
jobs:
  build:
    if: >-
      a ||
      (b &&
       c)
    runs-on: ubuntu-latest   # a comment after a value
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.sha }}
      - name: 'It''s quoted'
        id: released
        run: |
          echo "a: b"   # not a comment

          # a script comment
          exit 0
         # a comment between the step's keys and its script, which ends the script
      - plain item
      -
      - |
        a block item
    list:
    - same-indent item
    strip: |-
      no newline
    folded: >

      one
      two
        spaced

      three
YAML
    out=$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$sb/sample.yml" 2>&1 \
          | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>&1)
    want=$(python3 -c 'import json; print(json.dumps({
        "name": "Sample flow",
        "quoted key": "value",
        "escaped": "say \"hi\" \\ to a/b\tand\n",
        "empty": "",
        "on": {"push": {"branches": ["main", "dev", "v*"], "tags": []},
               "pull_request": None, "workflow_dispatch": None},
        "jobs": {"build": {
            "if": "a || (b &&\n c)",
            "runs-on": "ubuntu-latest",
            "steps": [
                {"uses": "actions/checkout@v7", "with": {"ref": "${{ github.sha }}"}},
                {"name": "It'"'"'s quoted", "id": "released",
                 "run": "echo \"a: b\"   # not a comment\n\n# a script comment\nexit 0\n"},
                "plain item",
                None,
                "a block item\n"],
            "list": ["same-indent item"],
            "strip": "no newline",
            "folded": "\none two\n  spaced\n\nthree\n"}}}, sort_keys=True))')
    assert_eq "$want" "$out" "every construct the workflows use comes back as YAML reads it"

    printf 'spaced: |\n    x\n      \n    y\nend: |\n    last' > "$sb/edges.yml"
    out=$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$sb/edges.yml" 2>&1 \
          | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>&1)
    assert_eq '{"end": "last", "spaced": "x\n  \ny\n"}' "$out" \
        "spaces past a block's indentation are text, and a block ending the file gains no line break"
    printf 'a: |\n  x\n  ' > "$sb/edges.yml"
    assert_eq '{"a": "x\n"}' "$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$sb/edges.yml" 2>&1 \
          | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)))' 2>&1)" \
        "a block whose text ended before a last line of spaces keeps its line break"
    printf '# nothing but a comment\n' > "$sb/edges.yml"
    assert_eq "null" "$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$sb/edges.yml" 2>&1)" \
        "a document holding nothing is null"
    out=$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" 2>&1); status=$?
    assert_status 2 "$status" "no file to read is a usage mistake"
    assert_contains "$out" "usage: workflow_yaml.py" "and says how to call it"

    # what|line|the reason, as the refusal words it|the document, as printf %b writes it
    local -a refused=(
        "anchor|1|a value starting with '&'|a: &x 1"
        "alias|1|a value starting with '*'|a: *x"
        "tag|1|a value starting with '!'|a: !tag x"
        "flow mapping|1|a value starting with '{'|a: {}"
        "value starting with a dash|1|a value starting with '-'|needs: - build"
        "tab in the indentation|2|a tab in the indentation|a:\n\tb: 1"
        "tab on a white-space line of a block|3|a line of nothing but white space holding a tab|a: |\n  x\n\t\n  y"
        "document marker|1|a document marker|---\na: 1"
        "continued plain value|2|a value continued onto a second line|a: one\n  two"
        "repeated key|2|the key 'a' given twice|a: 1\na: 2"
        "keep chomping|1|a block scalar header this reader does not take|a: |+\n  x"
        "indentation indicator|1|a block scalar header this reader does not take|a: |2\n  x"
        "content after the document|2|content after the end of the document|- b\na: 1"
        "block line indented less|3|a block scalar line indented less than its first line|a: >\n   a\n  b"
        "sequence on one line|1|a sequence item holding a sequence on the same line|- - a"
        "key among sequence items|3|indented further than the mapping it belongs to|a:\n  - x\n  b: 1"
        "flow anchor|1|a flow sequence item starting with '&'|x: [&a b]"
        "flow alias|1|a flow sequence item starting with '*'|paths: [*.md]"
        "flow tag|1|a flow sequence item starting with '!'|paths: [!docs/**]"
        "flow pair|1|a flow sequence item holding ': '|x: [a: b]"
        "flow comment|1|a comment inside a flow sequence|x: [a #b, c]"
        "flow trailing comma|1|an empty item in a flow sequence|x: [a, b,]"
        "escape|1|an escape this reader does not take|a: \"\\\\z\""
        "character outside ASCII|1|a character outside printable ASCII, U+00E9|a: caf\xc3\xa9"
        "form feed|1|a character outside printable ASCII, U+000C|a: x\fy"
        "key inside a plain value|1|a plain value holding ': '|a: b: c"
        "unclosed quote|1|a quoted value that does not close on its line|a: \"x"
        "text after a quoted value|1|text after a quoted value|a: \"x\" y"
        "unclosed flow sequence|1|a flow sequence that does not close on its line|a: [x, "
        "flow sequence in a flow sequence|1|a flow sequence holding a collection|a: [x, [y]]"
        "flow item followed by text|1|a flow sequence item followed by something other than|a: [\"x\" y]"
        "flow item starting with a block indicator|1|a flow sequence item starting with '>'|a: [>x]"
        "line that is no key|2|expected a key|a: 1\nplain"
        "item among a mapping's keys|2|a sequence item among the keys of a mapping|a: 1\n- b"
        "item continued|2|a sequence item continued onto a second line|- a\n  b"
        "line inside a sequence's items|2|indented further than the sequence it belongs to|- a: 1\n b: 2"
        "wide white space before a block's text|2|a line of white space before the block scalar's first line|a: |\n      \n  x"
        "indented document|1|the document starts indented|  a: 1"
    )
    local entry what line reason status
    for entry in "${refused[@]}"; do
        what=${entry%%|*}; entry=${entry#*|}
        line=${entry%%|*}; entry=${entry#*|}
        reason=${entry%%|*}
        printf '%b\n' "${entry#*|}" > "$sb/refused.yml"
        status=0
        out=$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$sb/refused.yml" 2>&1 >/dev/null) || status=$?
        assert_status 1 "$status" "a $what is refused"
        assert_contains "$out" "refused.yml:$line: $reason" "at line $line, for what it is: $what"
    done
    printf '%b' 'name: caf\xe9\n' > "$sb/refused.yml"
    status=0
    out=$(python3 "$REPO_ROOT/test/tools/workflow_yaml.py" "$sb/refused.yml" 2>&1 >/dev/null) || status=$?
    assert_status 1 "$status" "a file that is not UTF-8 is refused"
    assert_contains "$out" "refused.yml: not UTF-8 text" "by name, not with a traceback"
}

# dev/scripts/clean-release-scratch.sh run from a copy in the sandbox repository $1, with its
# stand-ins first on PATH and its working directories searched for under $1/../tmp and
# $1/../shm. Sets RS_STATUS and RS_OUT.
RS_STATUS=0
RS_OUT=""
release_scratch_run() {
    local repo="$1"; shift
    RS_STATUS=0
    RS_OUT=$(cd "$repo/.." && PATH="$repo/../bin:$PATH" RELEASE_SCRATCH_ROOTS="$repo/../tmp $repo/../shm" \
             bash "$repo/dev/scripts/clean-release-scratch.sh" "$@" 2>&1) || RS_STATUS=$?
}

# THE RELEASE CLEANUP REMOVES WHAT A RELEASE LEFT, AND NOTHING ELSE. Z asked for it on 2026-10-08,
# after a release cycle had left seven working directories and an orphaned scratch environment
# across /tmp and /dev/shm, the oldest four days old.
#
# Run against a sandbox and stand-ins only: a copy of the script in a repository of its own, so
# its .tmp/release-review is the sandbox's; roots of the sandbox's own; and a ps and a conda on
# PATH, so no real process is read and no real environment is listed or removed. The case first
# proves PATH finds the stand-ins, and stops if it does not.
#
# Asked: a dry run removes nothing; a release script still running stops it before anything goes;
# then it removes each working directory, one holding a read-only directory included, the step 1
# scratch, and each scratch environment whose run is over, and leaves every decoy beside them: a
# name one character short, a file where a directory would be, another directory, the installed
# environments and base, a scratch environment whose run is still going, and a name that only
# begins like one.
test_the_release_cleanup_removes_what_a_release_left_and_nothing_else() {
    local sb repo removed
    sb=$(guard_path "$TEST_TMPDIR/release-scratch")
    rm -rf "$sb"
    repo="$sb/repo"
    mkdir -p "$sb/bin" "$sb/tmp" "$sb/shm" "$repo/dev/scripts" "$repo/.tmp/release-review" "$repo/.tmp/other"
    cp "$REPO_ROOT/dev/scripts/clean-release-scratch.sh" "$repo/dev/scripts/"

    cat > "$sb/bin/ps" <<'PS'
#!/usr/bin/env bash
# The process table is ps.table beside this, "pid args" a line. No process has a parent.
table="$(dirname "$0")/ps.table"
case "$*" in
    "-eo pid=,args=") cat "$table" ;;
    "-o ppid= -p "*) ;;
    "-p "*) awk -v p="$2" '$1 == p { found = 1 } END { exit !found }' "$table" ;;
    *) echo "stand-in ps cannot answer: $*" >&2; exit 2 ;;
esac
PS
    cat > "$sb/bin/conda" <<'CONDA'
#!/usr/bin/env bash
# The environments are conda.envs beside this, a name a line. A removal takes one out of it and
# adds it to conda.removed.
dir="$(dirname "$0")"
case "$1 $2" in
    "env list")
        printf '# conda environments:\n#\n'
        awk '{ printf "%-32s /envs/%s\n", $1, $1 }' "$dir/conda.envs" ;;
    "env remove")
        grep -vxF "$4" "$dir/conda.envs" > "$dir/conda.envs.new"
        mv "$dir/conda.envs.new" "$dir/conda.envs"
        echo "$4" >> "$dir/conda.removed" ;;
    *) echo "stand-in conda cannot answer: $*" >&2; exit 2 ;;
esac
CONDA
    chmod +x "$sb/bin/ps" "$sb/bin/conda"
    if [ "$(PATH="$sb/bin:$PATH" bash -c 'command -v conda; command -v ps' | tr '\n' ' ')" \
         != "$sb/bin/conda $sb/bin/ps " ]; then
        fail_case "PATH does not find the stand-in conda and ps first; nothing was run"
        return
    fi
    printf '%s\n' base PoolSeqFlow-3.2.0 PoolSeqFlow-3.2.0-analysis poolseqflow-validation \
        PoolSeqFlow-update PoolSeqFlow-update-analysis PoolSeqFlow-update-old PoolSeqFlow-floorcheck \
        PoolSeqFlow-modulecheck-111 PoolSeqFlow-modulecheck-222 \
        PoolSeqFlow-suite-333 PoolSeqFlow-suite-333-analysis PoolSeqFlow-suite-444 > "$sb/bin/conda.envs"
    printf '222 sleep 600\n444 sleep 600\n' > "$sb/bin/ps.table"

    mkdir -p "$sb/tmp/poolseqflow-test.AbC123/ro" "$sb/shm/poolseqflow-test-xdev.XyZ789" \
             "$sb/tmp/poolseqflow-test.AbC12" "$sb/tmp/keep-me"
    : > "$sb/tmp/poolseqflow-test.AbC123/ro/f"
    chmod a-w "$sb/tmp/poolseqflow-test.AbC123/ro"
    : > "$sb/tmp/poolseqflow-test.DeF456"
    : > "$repo/.tmp/release-review/notes.txt"
    : > "$repo/.tmp/other/keep.txt"

    release_scratch_run "$repo" --dry-run
    assert_status 0 "$RS_STATUS" "a dry run succeeds:"$'\n'"$RS_OUT"
    assert_contains "$RS_OUT" "would remove $sb/tmp/poolseqflow-test.AbC123" "and names a working directory"
    assert_contains "$RS_OUT" "would remove the conda environment PoolSeqFlow-update-analysis" "and an environment"
    assert_dir "$sb/tmp/poolseqflow-test.AbC123" "while removing nothing"
    assert_no_file "$sb/bin/conda.removed" "not an environment either"

    printf '555 bash test/run_tests.sh --suite 00_static\n' >> "$sb/bin/ps.table"
    release_scratch_run "$repo"
    assert_status 1 "$RS_STATUS" "a suite run still going stops it"
    assert_contains "$RS_OUT" "555  bash test/run_tests.sh" "naming the process"
    assert_dir "$sb/shm/poolseqflow-test-xdev.XyZ789" "before anything is removed"
    assert_no_file "$sb/bin/conda.removed" "environments included"
    sed -i '/^555 /d' "$sb/bin/ps.table"

    release_scratch_run "$repo"
    assert_status 0 "$RS_STATUS" "with nothing running it removes what it found:"$'\n'"$RS_OUT"
    assert_no_file "$sb/tmp/poolseqflow-test.AbC123" "the working directory, read-only directory and all"
    assert_no_file "$sb/shm/poolseqflow-test-xdev.XyZ789" "and its second filesystem"
    assert_no_file "$repo/.tmp/release-review" "and the step 1 scratch"
    assert_dir "$sb/tmp/poolseqflow-test.AbC12" "but not a name one character short"
    assert_file "$sb/tmp/poolseqflow-test.DeF456" "nor a file under a working directory's name"
    assert_dir "$sb/tmp/keep-me" "nor any other directory"
    assert_file "$repo/.tmp/other/keep.txt" "nor the rest of .tmp"
    removed=$(sort "$sb/bin/conda.removed" 2>/dev/null | tr '\n' ' ')
    assert_eq "PoolSeqFlow-floorcheck PoolSeqFlow-modulecheck-111 PoolSeqFlow-suite-333 PoolSeqFlow-suite-333-analysis PoolSeqFlow-update PoolSeqFlow-update-analysis " \
        "$removed" "exactly the scratch environments whose runs are over"

    release_scratch_run "$repo"
    assert_status 0 "$RS_STATUS" "a second run succeeds"
    assert_contains "$RS_OUT" "Nothing to remove." "having nothing left to do"

    release_scratch_run "$repo" --everything
    assert_status 2 "$RS_STATUS" "an unknown argument is a usage mistake"
}

# A case that could not run fails the run, except under --fast, which leaves cases out on purpose.
# A case that failed before it skipped is reported as the failure even there. And a --case that
# matches no case stops the run, where it used to report PASS over nothing. The harness is driven
# in a shell of its own, so its counters are not this run's.
test_a_case_that_cannot_run_fails_the_run() {
    local out status
    out=$(bash -c '
        source "$1/test/lib/harness.sh"
        CURRENT_SUITE=probe
        test_skips() { skip_case "no such environment"; }
        test_fails_then_skips() { fail_case "broke"; skip_case "--fast"; }
        TEST_FAST=0 run_case test_skips
        echo "outside: failed=$TESTS_FAILED skipped=$TESTS_SKIPPED"
        TESTS_FAILED=0; TESTS_SKIPPED=0
        TEST_FAST=1 run_case test_skips
        echo "fast: failed=$TESTS_FAILED skipped=$TESTS_SKIPPED"
        TESTS_FAILED=0; TESTS_SKIPPED=0
        TEST_FAST=1 run_case test_fails_then_skips
        echo "fast after a failure: failed=$TESTS_FAILED skipped=$TESTS_SKIPPED"
    ' _ "$REPO_ROOT" 2>&1)
    assert_contains "$out" "could not run: no such environment" \
        "outside --fast a skip is reported as a failure:"$'\n'"$out"
    assert_contains "$out" "outside: failed=1 skipped=0" "and counted as one"
    assert_contains "$out" "fast: failed=0 skipped=1" "under --fast it stays a skip"
    assert_contains "$out" "fast after a failure: failed=1 skipped=0" "unless the case had already failed"

    status=0
    out=$(bash "$REPO_ROOT/test/run_tests.sh" --suite 00_static --case no_case_is_called_this 2>&1) \
        || status=$?
    assert_status 2 "$status" "a --case that matches nothing stops the run:"$'\n'"$out"
    assert_contains "$out" "no case matches" "saying so"
}

# A manifest as the repository writes them, one key a line, which is what the release gate reads:
# it asks whether a commit's diff adds a version line, so a manifest on one line would show one
# for any change at all.
floor_manifest() {   # name version environment [kind]
    printf '{\n  "name": "%s",\n' "$1"
    [ -z "${4-}" ] || printf '  "kind": "%s",\n' "$4"
    printf '  "version": "%s",\n  "environment": "%s"\n}\n' "$2" "$3"
}

# raise-module-floors.sh moves the version of every manifest whose floor it raises, so the
# version-bump commit that carries the floors passes the release gate. It did not, and the v3.3.0
# tag failed release.yml on 2026-10-07: step 2's version bumps had been committed and merged by
# then, so the floors were six module changes in a commit that moved no version. Built as a
# release is: a tag, step 2's bumps committed after it, the release version written, the floors
# raised and committed, and the gate asked what release.yml asks it.
test_raising_a_floor_moves_the_version_and_passes_the_release_gate() {
    local sb out status
    sb=$(guard_path "$TEST_TMPDIR/raise-floors")
    rm -rf "$sb"; mkdir -p "$sb/dev/scripts" "$sb/analysis/lib/nf" "$sb/modules/repo" \
                           "$sb/modules/demo" "$sb/modules/still" "$sb/modules/lib/helper"
    cp "$REPO_ROOT/dev/scripts/raise-module-floors.sh" "$REPO_ROOT/dev/scripts/bump-analysis-version.sh" \
       "$REPO_ROOT/dev/scripts/check-analysis-versions.sh" "$sb/dev/scripts/"
    printf '# Version: 1.0.0\nVERSION="1.0.0"\n' > "$sb/PoolSeqFlow"
    printf 'frame {}\n' > "$sb/analysis/frame.config"
    printf '20260101.001\n' > "$sb/analysis/frame.version"
    printf 'def one() { 1 }\n' > "$sb/analysis/lib/nf/thing.nf"
    printf '#!index-format: 1\n#!index-version: 20260101.001\n' > "$sb/modules/repo/index.tsv"
    floor_manifest demo 20260101.001 1.0.0 > "$sb/modules/demo/manifest.json"
    floor_manifest still 20260101.001 1.0.0 > "$sb/modules/still/manifest.json"
    floor_manifest helper 20260101.001 1.0.0 library > "$sb/modules/lib/helper/manifest.json"
    (cd "$sb" && git init -q . && git add -A && sandbox_commit base 2026-01-01 && git tag v1.0.0 \
        && floor_manifest demo 20260102.001 1.0.0 > modules/demo/manifest.json \
        && floor_manifest helper 20260102.001 1.0.0 library > modules/lib/helper/manifest.json \
        && git add -A && sandbox_commit 'step 2 moves demo and helper' 2026-01-02) > /dev/null 2>&1 \
        || { fail_case "could not build a repository to raise floors in"; return; }

    printf '# Version: 1.1.0\nVERSION="1.1.0"\n' > "$sb/PoolSeqFlow"
    out=$(cd "$sb" && bash dev/scripts/raise-module-floors.sh --dry-run 2>&1)
    assert_contains "$out" "demo" "--dry-run names what it would raise:"$'\n'"$out"
    assert_eq "" "$(git -C "$sb" status --porcelain -- modules)" "and writes nothing"

    # A bump refused partway: the library's version sits at the day's 999th change, past which
    # bump-analysis-version.sh refuses another. Its floor has to stay where it was, or the rerun
    # would find it raised and never move the version. The day is read twice, here and by the
    # bump, so a run straddling midnight UTC would fail this half.
    floor_manifest helper "$(date -u +%Y%m%d).999" 1.0.0 library > "$sb/modules/lib/helper/manifest.json"
    status=0
    out=$(cd "$sb" && bash dev/scripts/raise-module-floors.sh 2>&1) || status=$?
    assert_status 1 "$status" "a refused version bump must stop it:"$'\n'"$out"
    assert_contains "$out" "so its floor was left at 1.0.0" "saying the floor was left"
    assert_contains "$(cat "$sb/modules/lib/helper/manifest.json")" '"environment": "1.0.0"' "and leaving it"
    assert_contains "$out" "1.0.0 -> 1.1.0, version 20260102.001 -> " \
        "while demo, before it, was raised and its version moved"

    floor_manifest helper 20260102.001 1.0.0 library > "$sb/modules/lib/helper/manifest.json"
    status=0
    out=$(cd "$sb" && bash dev/scripts/raise-module-floors.sh 2>&1) || status=$?
    assert_status 0 "$status" "the rerun should finish the job:"$'\n'"$out"
    assert_contains "$out" "already 1.1.0" "leaving demo as it was"
    assert_contains "$out" "1 manifest(s) changed" "and counting the one it changed"
    assert_contains "$(cat "$sb/modules/demo/manifest.json")" '"environment": "1.1.0"' "demo's floor is raised"
    assert_not_contains "$(cat "$sb/modules/demo/manifest.json")" '"version": "20260102.001"' \
        "and its version moved:"$'\n'"$out"
    assert_contains "$(cat "$sb/modules/lib/helper/manifest.json")" '"environment": "1.1.0"' "the library's floor too"
    assert_not_contains "$(cat "$sb/modules/lib/helper/manifest.json")" '"version": "20260102.001"' "and its version"
    assert_eq "$(floor_manifest still 20260101.001 1.0.0)" "$(cat "$sb/modules/still/manifest.json")" \
        "what was not republished is left alone"

    (cd "$sb" && git add -A && sandbox_commit 'Version bump v1.1.0' 2026-01-03) > /dev/null 2>&1
    status=0
    out=$(cd "$sb" && bash dev/scripts/check-analysis-versions.sh --release 2>&1) || status=$?
    assert_status 0 "$status" "the version-bump commit must pass the release gate:"$'\n'"$out"

    out=$(cd "$sb" && bash dev/scripts/raise-module-floors.sh 2>&1) || true
    assert_eq "" "$(git -C "$sb" status --porcelain -- modules)" "a second run moves nothing:"$'\n'"$out"
}

test_release_archive_carries_the_runtime() {
    local listing
    listing=$(working_tree_archive)
    [ -n "$listing" ] || { fail_case "git archive produced nothing"; return; }
    local needed
    for needed in "poolseqflow.nf" "nextflow.config" "parameters.config.template" \
                  "PoolSeqFlow" "analysis.nf" "metadata.csv.template" \
                  "scripts/" "bin/" "lib/" "analysis/" "install/" "citations/"; do
        assert_contains "$listing" "$needed" "release tarball must carry $needed"
    done
    # Named files and not only their directories: a directory traveling empty would satisfy
    # every line above, and each of these is read at run time by something that does not check.
    for needed in "citations/citations.json" "bin/check_install.sh" "bin/check_project.sh" \
                  "install/environment.yml"; do
        assert_contains "$listing" "$needed" "release tarball must carry $needed"
    done
}

# The built site is development material and stays out; the manual it is generated from
# ships, so a download carries its own documentation with no network and no site visit.
# The attribute is checked directly as well as the listing: it is the rule that has to hold.
test_release_archive_carries_the_manual() {
    local manual="manual/PoolSeqFlow-manual.md"
    [ -f "$REPO_ROOT/$manual" ] || { fail_case "$manual is missing"; return; }
    local attr
    attr=$(cd "$REPO_ROOT" && git check-attr export-ignore -- "$manual")
    assert_contains "$attr" "unspecified" "the manual must not be export-ignore'd out of a release"

    local listing
    listing=$(working_tree_archive)
    [ -n "$listing" ] || { fail_case "git archive produced nothing"; return; }
    assert_contains "$listing" "$manual" "release tarball must carry the manual"
}

# Parses the manual, resolves every cross-reference and rebuilds the nav in memory. Catches
# a link to a heading that no longer exists, two headings competing for one anchor, and a
# nav left behind by a page that moved - none of which are visible until the site is built.
test_manual_is_valid_and_the_nav_is_current() {
    local out status
    out=$(cd "$REPO_ROOT" && python3 dev/scripts/build_docs.py --check 2>&1)
    status=$?
    assert_eq "0" "$status" "the manual does not generate cleanly:"$'\n'"$out"
}

# The version is written in three places - twice in the wrapper and once in the manifest -
# and they have to agree, or release.yml refuses to publish. Cheaper to catch here than in CI.
test_version_is_consistent_everywhere_it_is_written() {
    local launcher_var launcher_hdr manifest
    launcher_var=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    launcher_hdr=$(sed -n 's/^# Version: *//p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    manifest=$(sed -n "s/.*version *= *'\([0-9][0-9.]*\)'.*/\1/p" "$REPO_ROOT/nextflow.config" | head -1)
    assert_eq "$launcher_var" "$launcher_hdr" "launcher VERSION vs its # Version: header"
    assert_eq "$launcher_var" "$manifest" "launcher VERSION vs nextflow.config manifest"
}

# Every `## [x.y.z]` section needs a matching link definition, or the rendered changelog has
# dead references. Two were missing before the audit added them.
test_changelog_sections_all_have_link_definitions() {
    local section
    while read -r section; do
        [ -n "$section" ] || continue
        grep -q "^\[$section\]: " "$REPO_ROOT/CHANGELOG.md" \
            || fail_case "CHANGELOG has a [$section] section with no link definition"
    done < <(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$REPO_ROOT/CHANGELOG.md")
}

# environment.yml shipped `prefix: /home/<maintainer>/...` inside the release tarball for
# several versions. Nothing should carry an absolute home path into a user's download.
test_environment_yml_carries_no_absolute_home_path() {
    local f hits
    for f in environment.yml environment-analysis.yml; do
        hits=$(grep -n "/home/\|/Users/" "$REPO_ROOT/install/$f" || true)
        assert_eq "" "$hits" "$f should not contain an absolute home path"
    done
}

# Without a name: key, `conda env create -f` refuses unless given -n. That is deliberate:
# environments are named after the release, and a fixed name in the file is an invitation
# to build an unversioned one that the launcher then declines to use.
test_environment_yml_has_no_name_or_prefix_key() {
    local f
    for f in environment.yml environment-analysis.yml; do
        assert_eq "" "$(grep -c '^name:' "$REPO_ROOT/install/$f" | grep -v '^0$')" \
            "$f should have no name: key"
        assert_eq "" "$(grep -c '^prefix:' "$REPO_ROOT/install/$f" | grep -v '^0$')" \
            "$f should have no prefix: key"
    done
}

# A PACKAGE MUST NOT LEAVE A SHIPPED ENVIRONMENT FILE WITHOUT SOMEBODY SAYING SO.
#
# export-environment.sh regenerates these from a LIVE environment, so anything the file asked
# for that the environment did not actually hold is dropped at the next export, silently and
# permanently. typst went that way on 2026-09-09: it was added to the analysis spec on
# 2026-09-04, the maintainer's environment predated that and never had it, and the first pinned
# export wrote a release whose analysis environment could not typeset the PDF report every
# published analysis carries.
#
# The baseline is the last release TAG where the file existed there, so the answer does not
# move with every commit. environment-analysis.yml did NOT exist at v2.2.0 - the analysis layer
# is new in 3.0 - and against a tag alone this case compared nothing for the very file typst
# left, and passed. It falls back to HEAD, which is what has teeth right after an export and
# before the commit: exactly where the drop happens.
#
# A package that genuinely goes is a decision. Committing the removal is what records it.
test_no_package_leaves_a_shipped_environment_file() {
    local f

    # Bare names out of the dependencies: block only, so the channel list is not read as
    # packages, and only up to the first '=', because a version moves at every release.
    local names='/^dependencies:/ { d = 1; next }
                 /^[a-z]/         { d = 0 }
                 d && /^ *- / { sub(/^ *- */, ""); sub(/[=<> ].*/, ""); if ($0 != "") print }'

    local tag; tag=$(cd "$REPO_ROOT" && git tag --sort=-v:refname | head -1)
    local checked=0
    for f in environment.yml environment-analysis.yml; do
        local base was gone
        base=""
        if [ -n "$tag" ]; then
            was=$(cd "$REPO_ROOT" && git show "$tag:install/$f" 2>/dev/null | awk "$names" | sort -u)
            [ -n "$was" ] && base="$tag"
        fi
        if [ -z "$base" ]; then
            was=$(cd "$REPO_ROOT" && git show "HEAD:install/$f" 2>/dev/null | awk "$names" | sort -u)
            [ -n "$was" ] && base="HEAD"
        fi
        [ -n "$base" ] || continue         # the file is new and has no committed form yet
        checked=$((checked + 1))
        gone=$(comm -23 <(printf '%s\n' "$was") \
                        <(awk "$names" "$REPO_ROOT/install/$f" | sort -u))
        assert_eq "" "$gone" \
            "$f names fewer packages than at $base; these left:"$'\n'"$gone"
    done

    # A baseline neither file could be compared against is a pass over nothing.
    assert_eq "2" "$checked" "both environment files should have had a baseline to compare against"
}

# A SHIPPED ENVIRONMENT MUST NOT REQUIRE A NEWER HOST THAN THE RELEASE PROMISES.
#
# v3.1.1 shipped environment-analysis.yml pinning sysroot_linux-64=2.39, which declares
# `__glibc >=2.39` - a constraint on the machine, not on anything installable. It solved on the
# machine that froze it (glibc 2.44) and could not be solved on any older one, so the analysis
# layer was uninstallable on most clusters and every check in this suite passed. Reported from a
# cluster on 2026-09-21.
#
# The comparison here is written with `sort -V` where export-environment.sh walks the fields in
# awk, on purpose: two implementations of one comparison that share nothing cannot both be wrong
# in the same way. A test that called the script's own function would agree with it about 2.9
# being newer than 2.28.
test_no_shipped_environment_outruns_the_host_floor() {
    local f floor declared script_floor found newer checked=0

    script_floor=$(sed -n 's/^HOST_GLIBC_FLOOR="\(.*\)"$/\1/p' \
                   "$REPO_ROOT/dev/scripts/export-environment.sh" | head -1)
    if [ -z "$script_floor" ]; then
        fail_case "export-environment.sh should declare HOST_GLIBC_FLOOR"
        return
    fi

    for f in environment.yml environment-analysis.yml; do
        checked=$((checked + 1))

        # The floor the file itself states. Read from the file rather than assumed, because the
        # file is what ships and a user reading the error needs it to be true there.
        declared=$(sed -n 's/^# host-glibc-floor: *\(.*\)$/\1/p' "$REPO_ROOT/install/$f" | head -1)
        assert_eq "$script_floor" "$declared" \
            "install/$f should declare host-glibc-floor $script_floor; re-export it"

        # sysroot_linux-64's version IS the glibc it targets, which is what makes this readable
        # without asking conda anything. A package that raises the floor some other way carries
        # the constraint in its conda metadata rather than in its version, so it is invisible to
        # any textual check and needs a release-time pass against real conda.
        found=$(sed -n 's/^ *- *sysroot_linux-64=\([^=]*\).*$/\1/p' "$REPO_ROOT/install/$f" | head -1)
        [ -n "$found" ] || continue

        newer=$(printf '%s\n%s\n' "$found" "$script_floor" | sort -V | tail -1)
        if [ "$newer" = "$found" ] && [ "$found" != "$script_floor" ]; then
            fail_case "install/$f pins sysroot_linux-64=$found, above the floor of $script_floor."$'\n'"No host below glibc $found can install this release."
        fi
    done

    assert_eq "2" "$checked" "both environment files should have been read"
}

# The tool list a user is told to expect and the one that is pinned have to agree, and the
# epilogue that tells them how to fix a broken install has to name the right environment.
test_check_install_hint_uses_the_versioned_environment() {
    local out version status
    version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    # No ENV_NAME exported, which is the case the fallback exists for; and the pipeline's tools
    # taken off PATH, because check_install.sh prints the epilogue ONLY when a check fails and
    # exits 0 before reaching it otherwise. Read against the machine's own PATH this asserted on
    # a branch it never entered, so it passed where the install was broken and failed where it
    # worked. /usr/bin:/bin because an empty PATH kills the script at `dirname` long before the
    # summary.
    out=$(cd "$REPO_ROOT" && env -u ENV_NAME PATH=/usr/bin:/bin bash bin/check_install.sh 2>&1)
    status=$?
    # The precondition, asserted rather than assumed: a machine carrying every tool on the bare
    # PATH would otherwise fail below on an empty string, which reads like a broken epilogue.
    if [ "$status" -eq 0 ]; then
        fail_case "every check passed with the tools off PATH, so the epilogue was never reached"
        return
    fi
    # Compared as a whole line. A substring check for "conda activate PoolSeqFlow" matches
    # the versioned name too, so it can neither confirm nor deny anything useful here.
    local activate_line
    activate_line=$(printf '%s\n' "$out" | sed -n 's/^ *\(conda activate .*\)$/\1/p' | head -1)
    assert_eq "conda activate PoolSeqFlow-$version" "$activate_line" \
        "the how-to-fix epilogue should name this version's environment exactly"
}

# A malformed version has to be refused before anything is cloned, updated or exported.
# This runs no conda commands - the check is ahead of them.
# prep-version.sh sources lib/wrapper_lib.sh and calls into it at its step 2, which sits on the
# far side of an hour of solving and updating. It names what it needs in WRAPPER_LIB_NEEDS and
# refuses at once when one of them is absent, so a function that moves costs a second instead of
# an hour. That guard is only worth having while the list matches the calls under it, which is
# what this checks - in both directions, because a list that has drifted is a guard covering
# nothing while reading as one that covers everything.
#
# The malformed-version case below cannot catch this: it exits at the version regex, which is
# twenty lines before the source.
test_prep_version_declares_what_it_takes_from_wrapper_lib() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import pathlib, re

DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{", re.M)
script = pathlib.Path("dev/scripts/prep-version.sh").read_text(encoding="utf-8")
lib = pathlib.Path("lib/wrapper_lib.sh").read_text(encoding="utf-8")

defined = set(DEF.findall(lib))
own = set(DEF.findall(script))

found = re.search(r'^WRAPPER_LIB_NEEDS="([^"]*)"', script, re.M)
if not found:
    print("prep-version.sh declares no WRAPPER_LIB_NEEDS, so nothing holds the list honest")
    raise SystemExit
declared = found.group(1).split()

for name in declared:
    if name not in defined:
        print("declares %s(), which lib/wrapper_lib.sh does not define" % name)

# Comments go, and the declaration itself with them: the names in it are a list, not calls. Only
# names that ARE functions in wrapper_lib are looked for, so a bare word cannot cry wolf.
body = re.sub(r"^\s*#.*$", "", script, flags=re.M)
body = re.sub(r"^WRAPPER_LIB_NEEDS=.*$", "", body, flags=re.M)
for name in sorted(defined):
    if name in own or name in declared:
        continue
    if re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(name), body):
        print("calls %s() from lib/wrapper_lib.sh without declaring it" % name)
PY
)
    assert_eq "" "$out" \
        "prep-version.sh must declare what it takes from wrapper_lib:"$'\n'"$out"
}

test_prep_version_rejects_a_malformed_version() {
    local out status
    for bad in "" "2.3" "v2.3.0" "2.3.0-rc1"; do
        out=$(cd "$REPO_ROOT" && bash dev/scripts/prep-version.sh "$bad" 2>&1)
        status=$?
        assert_status 1 "$status" "'$bad' should be refused"
        assert_contains "$out" "Usage:" "'$bad' should print usage"
    done
}

# Release-prep logs are one machine's package solve on one day. They must not become
# history, and the broad `!test/**` style re-inclusions elsewhere make that worth asserting.
# THE RELEASE BODY IS THIS VERSION'S CHANGELOG SECTION, and release.yml publishes whatever the
# extractor prints. A tag build is the expensive place to discover the section is missing, so the
# same extractor is the gate in release.yml's version step - this checks it answers here first.
#
# The executable bit is checked because release.yml calls the script bare. A file committed
# 100644 passes every other check in this suite and dies with "Permission denied" in the first
# step of a tag build.
test_the_release_body_extracts_for_this_version() {
    local script="$REPO_ROOT/dev/scripts/changelog-section.sh"
    [ -x "$script" ] || { fail_case "dev/scripts/changelog-section.sh is not executable"; return; }

    local version; version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    local out status
    out=$(cd "$REPO_ROOT" && "$script" "$version" 2>&1) && status=0 || status=$?
    assert_status 0 "$status" "the changelog has no section for $version:"$'\n'"$out"
    assert_contains "$out" "## [$version]" "the section should start with its own heading"

    # A version the changelog does not describe must fail, not print an empty body.
    out=$(cd "$REPO_ROOT" && "$script" 99.99.99 2>&1) && status=0 || status=$?
    assert_status 1 "$status" "an absent section should be refused"
    assert_contains "$out" "no '## [99.99.99]' section" "and should say what is missing"

    # The standing tail release.yml appends, and its authoring comment, which must not reach a
    # reader: the sed that strips it is anchored on a line that has to stay a line of its own.
    local tail_file="$REPO_ROOT/dev/release-notes-tail.md"
    [ -f "$tail_file" ] || { fail_case "dev/release-notes-tail.md is missing"; return; }
    assert_contains "$(sed -n '/^-->$/p' "$tail_file")" "-->" \
        "the tail's comment must close on a line of its own, or the sed strips the whole file"
    local rendered; rendered=$(sed "1,/^-->$/d" "$tail_file")
    assert_not_contains "$rendered" "<!--" "the authoring comment must not reach the release body"
    assert_contains "$rendered" "@VERSION@" "the tail should carry the placeholders release.yml fills"
}

test_release_prep_logs_are_not_tracked() {
    local ignored
    ignored=$(cd "$REPO_ROOT" && git check-ignore dev/logs/example/summary.txt 2>/dev/null)
    assert_contains "$ignored" "dev/logs" "dev/logs/ should be gitignored"
    assert_eq "" "$(cd "$REPO_ROOT" && git ls-files dev/logs)" "no prep log should be tracked"
}

# The committed fixture must be reproducible from the generator, or the reference outputs
# cannot be regenerated after a change to it.
# Two lists describe the same thing and must not drift: PAYLOAD_ITEMS in the wrapper decides
# what `install` deploys, and .gitattributes decides what `git archive` puts in a release
# tarball. A file added to the release but not to PAYLOAD_ITEMS goes missing from every
# installation; one added the other way makes `install` refuse a downloaded copy as incomplete.
test_install_payload_matches_the_release_archive() {
    local archive payload
    archive=$(working_tree_archive | sed 's|/.*||' | sort -u)
    # Evaluated rather than parsed: the assignment spans a line continuation, and letting the
    # shell join it is exact where a regex would be approximate.
    payload=$(eval "$(sed -n '/^PAYLOAD_ITEMS=/,/[^\\]$/p' "$REPO_ROOT/PoolSeqFlow")"
              printf '%s\n' $PAYLOAD_ITEMS | sort)
    assert_eq "$archive" "$payload" \
        "PAYLOAD_ITEMS and the release archive should list the same top-level entries"
}

# ONE DIRECTORY PER WORKFLOW (Z, 2026-08-28). Every log file name already carries the step, the
# process and the sample it belongs to, so a per-process directory repeated what the name said
# and cost a level of nesting in the one tree users are asked to read.
#
# Authored, so it is checked here: a new process that gives itself a subdirectory - by copying
# an older one, which is how step 2 ended up with its two halves at different depths - fails
# this rather than turning up in someone's log tree months later. The one-writer-per-file rule
# is carried by the file NAME, which is what makes the flattening safe.
test_every_process_logs_into_its_workflows_own_directory() {
    local declared offenders
    declared=$(grep -rh 'dir_log = "' "$REPO_ROOT"/scripts/*.nf "$REPO_ROOT"/dryrun.nf \
                | sed 's|.*dir_log = "||; s|".*||' | sort -u)
    # A POSITIVE CONTROL, for the same reason: the assertion is about an absence, and a change
    # to how dir_log is written would empty the extraction rather than fail the case.
    [ -n "$declared" ] || { fail_case "no dir_log assignments were found at all"; return; }
    offenders=$(printf '%s\n' "$declared" \
                | grep -vE '^[$]\{(run\.dir\.logs|params\.dir\.allLogs)\}/[0-9A-Za-z_]+$' || true)
    assert_eq "" "$offenders" \
        "a log directory should be the workflow's own, with nothing nested below it"
}

# The read group tag table exists twice, and has to: bin/parse_metadata.py refuses an unknown
# RG_ column before anything runs, and scripts/metadata.nf renders the tag into the BAM header.
# Neither side can do the other's job from where it sits.
#
# So they are checked instead. A tag added to one and not the other would be a column that
# validates and then silently vanishes from every read group - or one that is refused despite
# being rendered - and both failures are invisible until someone reads a BAM header.
test_the_read_group_tag_table_is_the_same_on_both_sides() {
    local python_side groovy_side
    python_side=$(sed -n '/^RG_TAGS = {/,/^}/p' "$REPO_ROOT/bin/parse_metadata.py" \
                  | sed -n 's/.*"\(RG_[A-Za-z]*\)": "\([A-Z][A-Z]\)".*/\1=\2/p' | sort)
    groovy_side=$(sed -n "/^def rgTagMap()/,/^}/p" "$REPO_ROOT/scripts/metadata.nf" \
                  | sed -n "s/.*'\(RG_[A-Za-z]*\)' *: *'\([A-Z][A-Z]\)'.*/\1=\2/p" | sort)
    [ -n "$python_side" ] || { fail_case "could not read RG_TAGS out of bin/parse_metadata.py"; return; }
    assert_eq "$python_side" "$groovy_side" \
        "the parser and the pipeline should accept the same read group tags"
}

# The per-sample parameter table exists twice for the same reason as the tag table, and the
# failure it guards against is worse. A param_ column the parser accepts and the pipeline does
# not act on is a setting the user has written down, can see in their own file, and believes is
# in effect - and nothing anywhere reports that it was ignored.
test_the_per_sample_parameter_table_is_the_same_on_both_sides() {
    local python_side groovy_side
    python_side=$(sed -n '/^PARAM_COLUMNS = {/,/^}/p' "$REPO_ROOT/bin/parse_metadata.py" \
                  | sed -n 's/.*"\(param_[A-Za-z0-9]*\)": "\([A-Za-z0-9._]*\)".*/\1=\2/p' | sort)
    groovy_side=$(sed -n "/^def paramColumns()/,/^}/p" "$REPO_ROOT/scripts/metadata.nf" \
                  | sed -n "s/.*'\(param_[A-Za-z0-9]*\)' *: *'\([A-Za-z0-9._]*\)'.*/\1=\2/p" | sort)
    [ -n "$python_side" ] || { fail_case "could not read PARAM_COLUMNS out of bin/parse_metadata.py"; return; }
    assert_eq "$python_side" "$groovy_side" \
        "the parser and the pipeline should agree on which parameters a row may override"
}

# Each param_ column names a real parameter, or the table is documenting something that does
# not exist. Checked against the template rather than against a list here, so adding a column
# for a parameter that was never added to parameters.config fails.
test_every_per_sample_parameter_names_a_real_parameter() {
    local leaf parameter checked=0
    # Fed by a redirect rather than a pipe. The last stage of a pipeline runs in a subshell, so
    # `... | while read` reaches fail_case but its CASE_FAILED never returns to run_case - this
    # case reported PASS for any template at all until 2026-09-23.
    while read -r parameter; do
        checked=$((checked + 1))
        leaf="${parameter##*.}"
        grep -qE "^[[:space:]]*${leaf}[[:space:]]*=" "$REPO_ROOT/parameters.config.template" \
            || fail_case "param_ column overrides '$parameter', which parameters.config.template does not define"
    done < <(sed -n '/^PARAM_COLUMNS = {/,/^}/p' "$REPO_ROOT/bin/parse_metadata.py" \
        | sed -n 's/.*"param_[A-Za-z0-9]*": "\([A-Za-z0-9._]*\)".*/\1/p')
    # An extraction that matches nothing would otherwise pass over an empty loop.
    [ "$checked" -gt 0 ] || fail_case "no param_ columns found in bin/parse_metadata.py"
}

# EVERY citations.json IS GENERATED, and this is what stops one being edited by hand.
#
# A person edits the references.bib beside it, because entries are pasted from publishers and
# BibTeX is the format they arrive in. The JSON is what write_citations.py reads inside every
# published analysis - and a hand-edit there would be silently discarded the next time anyone
# ran the compiler, taking a citation out of somebody's methods section with it.
test_every_citations_file_matches_its_bibtex() {
    local out status=0
    out=$(python3 "$REPO_ROOT/dev/scripts/bib2citations.py" --check 2>&1) || status=$?
    assert_status 0 "$status" "a citations.json is out of date with its .bib:"$'\n'"$out"
}

# THE BIBLIOGRAPHY IS A SUPERSET OF WHAT THE ANALYSIS LAYER CITES, and this is what keeps it
# one. A module declares the method it implements in its own citations.json, which reaches the
# user as CITATIONS.md beside their results; the manual's Bibliography is where the reading
# behind that choice lives. A reference in one and not the other is a reader who can see a DOI
# and not why it is there, and nothing else would notice.
#
# By DOI, because that is the identifier both sides carry and neither side formats. Entries
# without one - an R package, mostly - are the tools table's business rather than this.
test_every_analysis_citation_is_in_the_bibliography() {
    local manual="$REPO_ROOT/manual/PoolSeqFlow-manual.md"
    local missing file doi
    missing=""
    for file in "$REPO_ROOT"/analysis/citations.json "$REPO_ROOT"/modules/*/citations.json; do
        [ -f "$file" ] || continue
        while read -r doi; do
            [ -n "$doi" ] || continue
            grep -qF "$doi" "$manual" || missing="$missing  $doi (${file#$REPO_ROOT/})"$'\n'
        done <<< "$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for key, entry in data.items():
    if key.startswith("_") or not isinstance(entry, dict):
        continue
    if entry.get("doi"):
        print(entry["doi"])
' "$file")"
    done
    assert_eq "" "$missing" "cited by a module and absent from the manual's Bibliography:"$'\n'"$missing"
}

test_fixture_generator_is_deterministic() {
    local out
    out="$TEST_TMPDIR/fixture-determinism"
    python3 "$REPO_ROOT/test/tools/make_fixture.py" "$out" >/dev/null 2>&1 \
        || { fail_case "generator failed"; return; }
    diff -r "$REPO_ROOT/test/data/base" "$out" >/dev/null 2>&1 \
        || fail_case "regenerating the fixture with the default seed did not reproduce test/data/base"
}

# Every parameter one step file reads, INCLUDING the ones it reads through a helper.
#
# poolSize reached step 7 only as poolSizeArgument(run) -> poolSizes(run) -> run.poolSize, so a
# grep of the step file alone never saw it and it went undeclared in stepParameterMap(). Two runs
# of different pool sizes then shared one results directory and the tables of one were filtered at
# the other's thresholds. Helpers are followed to any depth, since that chain is two deep.
step_parameter_reads() {
    python3 - "$1" <<'READS'
import glob, os, re, sys

step_file = sys.argv[1]
scripts = os.path.dirname(os.path.abspath(step_file))
all_source = "\n".join(open(p, encoding="utf-8").read()
                       for p in sorted(glob.glob(os.path.join(scripts, "*.nf"))))

READ = re.compile(r"run\.([A-Za-z_][A-Za-z0-9_.]*)")
# A helper handed the run map. Nextflow's own take it too, and read nothing.
CALL = re.compile(r"\b([a-z][A-Za-z0-9_]*)\s*\(\s*run\b")
SKIP = {"val", "tuple", "path", "file", "println"}
COMMENT = re.compile(r"//[^\n]*")


def body_of(name):
    found = re.search(r"^def %s\s*\(" % re.escape(name), all_source, re.M)
    if not found:
        return ""
    start = all_source.find("{", found.end())
    if start < 0:
        return ""
    depth, i = 0, start
    while i < len(all_source):
        if all_source[i] == "{":
            depth += 1
        elif all_source[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return all_source[start:i]


text = COMMENT.sub("", open(step_file, encoding="utf-8").read())
names = set(READ.findall(text))
pending, seen = set(CALL.findall(text)) - SKIP, set()
while pending:
    name = pending.pop()
    seen.add(name)
    body = COMMENT.sub("", body_of(name))
    names |= set(READ.findall(body))
    pending |= set(CALL.findall(body)) - SKIP - seen

print("\n".join(sorted(name.rstrip(".") for name in names if name.rstrip("."))))
READS
}

# Every parameter stepParameterMap() declares for one step, read FROM INSIDE THAT FUNCTION and
# nowhere else.
#
# variants.nf holds a second map of the same shape. stepFolders() has `        7: ['dir.subpath.
# vcf', 'dir.subpath.freq'],` - eight spaces, the step number, a bracket - so a search of the
# whole file for the first match was correct only while stepParameterMap() happened to be defined
# above it. Reorder the two and this would compare the reads against the FOLDER map, losing nine
# of step 7's ten declarations at once and reporting them as undeclared: a check that fails loudly
# for a reason that has nothing to do with what it is checking.
#
# The entry is taken by matching brackets rather than by line shape, because three of the seven
# entries fit on one line and a line-based reader ran two of them together - which made the check
# PASS, one step's declarations covering the next one's reads.
step_declared_parameters() {
    python3 - "$1" "$2" <<'DECLARED'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
step = sys.argv[2]


def balanced(source, start, opener, closer):
    depth, i = 0, start
    while i < len(source):
        if source[i] == opener:
            depth += 1
        elif source[i] == closer:
            depth -= 1
            if depth == 0:
                return source[start:i]
        i += 1
    return ""


found = re.search(r"^def stepParameterMap\s*\(", text, re.M)
if not found:
    sys.exit("scripts/variants.nf has no stepParameterMap()")
scope = balanced(text, text.find("{", found.end()), "{", "}")
if not scope:
    sys.exit("stepParameterMap() has no balanced body")

entry = re.search(r"^        %s: \[" % re.escape(step), scope, re.M)
if not entry:
    sys.exit("stepParameterMap() has no entry for step " + step)
body = re.sub(r"//[^\n]*", "", balanced(scope, entry.end() - 1, "[", "]"))
print("\n".join(sorted(set(re.findall(r"'([^']*)'", body)))))
DECLARED
}

# THE PARAMETER MAP AGAINST THE SOURCE IT DESCRIBES.
#
# stepParameterMap() in scripts/variants.nf decides which runs may share a step's work, and
# getting it wrong is the failure class this project keeps finding: name too few parameters and
# a run silently reuses reads trimmed to someone else's settings, with nothing downstream able
# to tell. The map is AUTHORED, because it has to be reviewable - a regex cannot see that
# `run.reference` stands for step 1's output rather than for a setting of its own. So it is
# checked from the other side instead: every parameter a step actually reads must be declared,
# excluded by an explicit family, or named below as represented some other way.
#
# The two lists this compares answer different questions and are allowed to disagree - the map
# also declares `dir.subpath.*`, which no step reads directly and which analysisParams()
# excludes - so the check is one-directional. A declaration with no read is fine; a read with
# no declaration is not.
test_step_parameter_map_covers_what_each_step_reads() {
    local variants="$REPO_ROOT/scripts/variants.nf"
    local step file declared reads name missing=""

    # Families analysisParams() excludes, for the reasons recorded there: where files live, how
    # many cores to use, where a tool is installed, and which run this is. `dir.subpath` is the
    # deliberate exception - it is half of an artifact's identity - so it is NOT excluded here.
    local excluded='^(dir\.(output|outputs|utilized|logs|data|references|dictionaries|snpEff|search)|cores\.|software\.|java\.|runId$|threads$)'

    # Read by a step but represented in the map by something other than its own name. Each of
    # these is a path into a directory step 1 writes, or a file step 0 repairs, so what decides
    # sharing is the identity of what is found there rather than the string itself.
    local indirect='^(reference|referenceFa|referenceFile|referencePath|gff|gffFile|gffPath|metadataPath|snpEff\.db)$'

    # The same, for what a step reads through a helper rather than by name. `metadata` is the
    # parsed rows, and the map names the COLUMNS each step depends on in metadataColumnsPerStep()
    # instead - the rows carry more than any step reads. `trim_galore.quality` is read only to
    # rebuild trim_galore.options for a row that sets both adapters, and options is declared;
    # step 0 refuses the one case where the two come apart, which is a pinned options string with
    # per-sample adapters under it.
    local through='^(metadata(\..*)?|trim_galore\.quality)$'

    for step in 2 3 4 5 6 7 8; do
        file=$(ls "$REPO_ROOT"/scripts/${step}_*.nf 2>/dev/null | head -1)
        [ -n "$file" ] || { fail_case "no source file for step $step"; continue; }

        # stderr folded in, so a refusal from the helper becomes the reason this case gives rather
        # than a line on the terminal and an empty list here. The old inline version did not read
        # the status at all: a missing entry left `declared` empty and every one of the step's
        # reads was reported undeclared, which named ten problems for one cause.
        declared=$(step_declared_parameters "$variants" "$step" 2>&1) \
            || { fail_case "$declared"; continue; }

        reads=$(step_parameter_reads "$file" \
                | grep -Ev "$excluded" | grep -Ev "$indirect" | grep -Ev "$through")

        while read -r name; do
            [ -n "$name" ] || continue
            printf '%s\n' "$declared" | grep -qx "$name" \
                || missing="$missing step $step: $name\n"
        done <<< "$reads"
    done

    if [ -n "$missing" ]; then
        fail_case "parameters read but not declared in stepParameterMap():"$'\n'"$(printf "$missing")"
    fi
}

# THE SAME CHECK FOR STEP 0, against checkParameterMap().
#
# A step-0 stage now runs once per distinct value of what it reads, so an undeclared parameter
# means one run's verdict is used for a run whose value differs - and catching exactly that
# value being wrong is what the stage is for. The failure is worse here than for a step: a run
# whose reference is missing would be told, by a task that never looked at it, that it is there.
#
# Same shape as the step check above and same direction: a declaration with no read is fine, a
# read with no declaration is not. Processes take their work item as `check`, so `check.x` is a
# read and `run.x` - which only VerifyAll still has - is not this check's business.
test_check_parameter_map_covers_what_each_stage_reads() {
    local verify="$REPO_ROOT/scripts/0_verify_environment.nf"
    local stage declared reads name missing=""

    # The item's own bookkeeping rather than a parameter: which runs it answers for, the key it
    # was grouped by, and everything the two analysis-keyed stages carry precomputed.
    # `storageDir` is free because checkKey() prefixes every key with it, so no group can ever
    # straddle two storage roots.
    local excluded='^(checkKey|checkTag|members|memberTokens|manifest|dir$|storageDir$)'

    for stage in CheckReference CheckGFF SkipGFFCheck CheckData CheckTrimParameters CheckDirectories; do
        declared=$(STAGE="$stage" python3 -c '
import os, re, sys
text = open(sys.argv[1]).read()
stage = os.environ["STAGE"]
start = re.search(r"^        %s *: \[" % stage, text, re.M)
if not start:
    sys.exit("no map entry for " + stage)
i, depth = start.end() - 1, 0
while i < len(text):
    if text[i] == "[": depth += 1
    elif text[i] == "]":
        depth -= 1
        if depth == 0: break
    i += 1
body = re.sub(r"//[^\n]*", "", text[start.end() - 1:i])
print("\n".join(sorted(set(re.findall(r"'"'"'([^'"'"']*)'"'"'", body)))))
' "$verify")

        # The process body, by matching braces from its declaration - the file holds eleven of
        # them and a line-based reader would run one stage into the next, which is the mistake
        # the step check above already made once.
        reads=$(STAGE="$stage" python3 -c '
import os, re, sys
text = open(sys.argv[1]).read()
start = re.search(r"^process %s \{" % os.environ["STAGE"], text, re.M)
if not start:
    sys.exit("no process " + os.environ["STAGE"])
i, depth = start.end() - 1, 0
while i < len(text):
    if text[i] == "{": depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0: break
    i += 1
body = re.sub(r"//[^\n]*", "", text[start.end() - 1:i])
print("\n".join(sorted(set(re.findall(r"check\.([A-Za-z_][A-Za-z0-9_.]*)", body)))))
' "$verify" | sed 's/\.$//' | sort -u | grep -Ev "$excluded")

        while read -r name; do
            [ -n "$name" ] || continue
            printf '%s\n' "$declared" | grep -qx "$name" \
                || missing="$missing $stage: $name\n"
        done <<< "$reads"
    done

    if [ -n "$missing" ]; then
        fail_case "parameters read but not declared in checkParameterMap():"$'\n'"$(printf "$missing")"
    fi
}

# stepFolders() against stepParameterMap(), for the report that tells a user what is in a
# shared directory.
#
# The two lists are allowed to differ - stepFolders names side outputs that no step reads, and
# stepParameterMap names parameters that are not folders - but only in ONE direction. A folder
# that already appears in a step's identity must appear here too, or the report would tell
# someone that Shared_1 holds nothing while the step that owns it writes there.
test_step_folders_covers_every_subpath_in_the_parameter_map() {
    local variants="$REPO_ROOT/scripts/variants.nf"
    local missing
    missing=$(python3 -c '
import re, sys

text = open(sys.argv[1]).read()

def block(header):
    start = re.search(r"^def %s\(\) \{" % header, text, re.M)
    if not start:
        sys.exit("no function " + header)
    i, depth = start.end() - 1, 0
    while i < len(text):
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    return text[start.end() - 1:i]

def entries(body):
    # One map entry per "<step>: [ ... ]", by matching brackets so an entry spanning lines
    # cannot run into the next one.
    out = {}
    for m in re.finditer(r"^ +(\d+): \[", body, re.M):
        i, depth = m.end() - 1, 0
        while i < len(body):
            if body[i] == "[": depth += 1
            elif body[i] == "]":
                depth -= 1
                if depth == 0: break
            i += 1
        chunk = re.sub(r"//[^\n]*", "", body[m.end() - 1:i])
        out[m.group(1)] = set(re.findall(r"(dir\.subpath\.[A-Za-z0-9_.]+)", chunk))
    return out

declared = entries(block("stepParameterMap"))
folders = entries(block("stepFolders"))
for step, names in sorted(declared.items()):
    for name in sorted(names - folders.get(step, set())):
        print("step %s: %s" % (step, name))
' "$variants")

    if [ -n "$missing" ]; then
        fail_case "folders in stepParameterMap() but not in stepFolders():"$'\n'"$missing"
    fi
}

# Every published analysis links each file it holds to the section of the manual that says how to
# read it. A dead link is silent - the folder is written, the anchor is wrong, and nobody finds
# out until they follow it. Authored on one side and verified from the other, the way the step
# parameter map is.
# A published analysis carries the libraries the module used folded into its own script, and the
# manifest's `libraries` is the list that gets fetched and folded. Two ways for it to be wrong,
# and only one of them is loud: a library the module CALLS and does not declare breaks the run,
# while one it declares and never calls is installed beside a result it did not compute, holds
# that library in the store against uninstall, and travels in the published script - which is
# quiet, and is what rule 15 exists to stop.
#
# The list used to live in each main.nf as libraryFiles(); it is the manifest's now, so the
# question is which LIBRARY owns a called function rather than which file declares it.
test_a_module_publishes_the_library_it_calls() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import json, pathlib, re, sys

libdir = pathlib.Path("modules/lib")
DEFINES = re.compile(r"^([A-Za-z._][A-Za-z0-9._]*)\s*<-\s*function", re.M)

# Which library provides which function. A library is a directory of .R files and the functions
# in them are what a module calls; nothing maps a function to a library except this.
owner = {}
for lib in sorted(p for p in libdir.glob("*") if p.is_dir()):
    for f in sorted(lib.glob("*.R")):
        for fn in DEFINES.findall(f.read_text(encoding="utf-8")):
            owner[fn] = lib.name

mods = sorted(p for p in pathlib.Path("modules").glob("*") if p.is_dir() and p.name != "lib"
              and (p / "manifest.json").exists())
if not owner or not mods:
    print("nothing to check: %d functions across the libraries, %d modules"
          % (len(owner), len(mods)))
    sys.exit(0)

for mod in mods:
    manifest = json.loads((mod / "manifest.json").read_text(encoding="utf-8"))
    declared = set(manifest.get("libraries", []))
    source = mod / (mod.name + ".R")
    if not source.exists():
        print("%s: has a manifest and no %s to call a library from" % (mod, source.name))
        continue
    text = source.read_text(encoding="utf-8")
    # A call, not a mention: the name followed by an open bracket, outside a comment.
    called = {owner[fn] for fn in owner
              if re.search(r"^[^#\n]*\b%s\(" % re.escape(fn), text, re.M)}

    for lib in sorted(called - declared):
        print("%s: calls %s and does not declare it in libraries" % (source, lib))
    for lib in sorted(declared - called):
        if (libdir / lib).is_dir():
            print("%s: declares %s and %s calls nothing from it"
                  % (mod / "manifest.json", lib, source.name))
        else:
            print("%s: declares %s, which modules/lib does not have"
                  % (mod / "manifest.json", lib))
PY
)
    assert_eq "" "$out" "a module must declare exactly the libraries it calls:"$'\n'"$out"
}

# EVERY SOURCE FILE IS REACHED BY SOME SUITE.
#
# dev/scripts/select-tests.py answers "what should I run for this change" from what each suite
# declares it runs, expanded through the include graph. A file no suite reaches has no answer,
# and the tool falls back to running everything - correct, but it means the file is silently
# outside every focused run, which is the failure this whole arrangement exists to prevent.
#
# It is checked here rather than left to the tool, because the tool only sees the files a
# change happened to touch. This sees all of them.
test_every_source_file_is_reached_by_a_suite() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import os, subprocess, sys
sys.path.insert(0, "dev/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("sel", "dev/scripts/select-tests.py")
sel = importlib.util.module_from_spec(spec); spec.loader.exec_module(sel)

claims, edges, tracked = sel.suites(), sel.graph(), sel.sources()
reached = set()
for declared in claims.values():
    reached |= sel.footprint(declared, edges, tracked)

# What a change can land in and matters to a run. The manual, the notes and the suite itself
# are not sources in this sense; the suite's own machinery is covered by EVERYTHING.
SKIP = ("test/", "dev/", "manual/", "docs/", ".github/", ".claude/", ".tmp/")
for path in sorted(tracked):
    if path.startswith(SKIP) or os.path.splitext(path)[1] not in (
            ".nf", ".sh", ".py", ".awk", ".R", ".Rmd", ".cpp"):
        continue
    if path not in reached:
        print("  %s is reached by no suite" % path)
PY
)
    assert_eq "" "$out" "every source file must be reached by some suite:"$'\n'"$out"
}

# THE SCRATCH ENVIRONMENTS OF A FULL RUN ARE REMOVED BY THE CODE PATH THAT BUILT THEM.
#
# From 2026-10-04 to 2026-10-06 the runner called build_scratch_env inside $(...), so the names it
# recorded for removal were recorded in a child shell and lost: the cleanup removed nothing,
# printed nothing, and every full run left its pair behind, five pairs before anyone read a run
# to its end. The check written with the cleanup set SCRATCH_ENVS by hand, which proved the
# removal and never the recording. This calls build_scratch_pair, the function the runner calls,
# against a stub conda whose `env create` succeeds and lists nothing - so both builds fail at the
# probe, which is the case the early recording is for - and reads what the stub was asked to
# remove.
#
# IN A FRESH BASH, NEVER A SUBSHELL. During a full run the runner holds conda's shell function,
# which a subshell inherits and which PATH cannot override, and a subshell's $$ is the runner's
# own: the names built here would be the live run's, removed by the real conda. A new process has
# a pid of its own and no function, and the script refuses to go on unless conda is the stub.
scratch_envs_in_isolation() {
    local stub="$1" body="$2"
    PATH="$stub/bin:$PATH" REPO_ROOT="$REPO_ROOT" TEST_TMPDIR="$stub" bash -c '
        [ "$(command -v conda)" = "$TEST_TMPDIR/bin/conda" ] || { echo "NOT THE STUB"; exit 99; }
        source "$REPO_ROOT/test/lib/scratch_envs.sh"
        echo "pid $$"
        '"$body"
}

test_a_full_run_removes_the_environments_it_built() {
    local stub="$TEST_TMPDIR/scratch-envs" said pid
    make_stub_conda "$stub"
    # The analysis environment is left active, as a full run leaves it: its last suites are the
    # analysis ones, and conda refuses to remove an active environment.
    said=$(scratch_envs_in_isolation "$stub" '
        TEST_CONDA_ENV_GIVEN=0 TEST_ANALYSIS_ENV_GIVEN=0
        build_scratch_pair 2> /dev/null
        CONDA_PREFIX="/fake/envs/PoolSeqFlow-suite-$$-analysis"
        remove_scratch_envs')
    assert_not_contains "$said" "NOT THE STUB" "the case must run against the stub conda alone"
    pid=$(printf '%s\n' "$said" | sed -n 's/^pid //p')
    assert_contains "$(cat "$stub/conda.log")" "env remove --name PoolSeqFlow-suite-$pid --yes" \
                    "the tools environment the pair built must be removed"
    assert_contains "$(cat "$stub/conda.log")" \
                    "env remove --name PoolSeqFlow-suite-$pid-analysis --yes" \
                    "and the analysis one"
    assert_contains "$said" "removing the scratch environment PoolSeqFlow-suite-$pid" \
                    "and the run must say so"
    # The deactivation must come before the removal of the environment it deactivates.
    local order
    order=$(grep -nE '^deactivate|^env remove --name PoolSeqFlow-suite-[0-9]+-analysis ' \
                "$stub/conda.log" | cut -d: -f2 | cut -d' ' -f1 | paste -sd' ')
    assert_eq "deactivate env" "$order" \
              "the active analysis environment must be deactivated before it is removed"

    # The two calls in the runner itself, which the lines above cannot see: the build as a
    # statement of its own, and the removal in the cleanup at exit. Wrapping the first in $(...)
    # is the defect this case exists for.
    local runner="$REPO_ROOT/test/run_tests.sh"
    grep -qE '^[[:space:]]*build_scratch_pair[[:space:]]*$' "$runner" \
        || fail_case "test/run_tests.sh must call build_scratch_pair as a statement of its own"
    grep -qE '^[[:space:]]*remove_scratch_envs[[:space:]]*$' "$runner" \
        || fail_case "test/run_tests.sh must remove the scratch environments at exit"
    if grep -qE '\$\([[:space:]]*(build_scratch_pair|build_scratch_env)' "$runner"; then
        fail_case "test/run_tests.sh captures a scratch build in \$(...), whose names are then lost"
    fi
}

# AND A FULL RUN SWEEPS UP WHAT A KILLED ONE LEFT. An exit trap cannot run when a run is killed
# outright, so the next full run removes every PoolSeqFlow-suite-<pid> environment whose run is
# gone. A pid still running is someone's live run and stays, and nothing of another naming is
# touched: PoolSeqFlow-<version> is what a user runs, and a name that only begins like a scratch
# one is not one.
test_a_full_run_removes_what_an_earlier_run_left() {
    local stub="$TEST_TMPDIR/scratch-sweep" said log gone
    # A pid that has certainly finished: one this case started and waited for.
    sleep 0 &
    gone=$!
    wait "$gone"
    make_stub_conda "$stub" "PoolSeqFlow-suite-$gone" "PoolSeqFlow-suite-$gone-analysis" \
        "PoolSeqFlow-suite-$$" "PoolSeqFlow-3.2.0" "PoolSeqFlow-3.2.0-analysis" \
        "PoolSeqFlow-suite-x"
    said=$(scratch_envs_in_isolation "$stub" 'sweep_scratch_envs')
    assert_not_contains "$said" "NOT THE STUB" "the case must run against the stub conda alone"
    log=$(cat "$stub/conda.log")
    assert_contains "$log" "env remove --name PoolSeqFlow-suite-$gone --yes" \
                    "an environment whose run is gone must be removed"
    assert_contains "$log" "env remove --name PoolSeqFlow-suite-$gone-analysis --yes" \
                    "and its analysis twin"
    assert_contains "$said" "removing PoolSeqFlow-suite-$gone, left behind by a run" \
                    "and the run must say so"
    assert_not_contains "$log" "env remove --name PoolSeqFlow-suite-$$ --yes" \
                        "a live run's environment must stay"
    assert_not_contains "$log" "env remove --name PoolSeqFlow-3.2.0" \
                        "and a release environment is never touched"
    assert_not_contains "$log" "env remove --name PoolSeqFlow-suite-x" \
                        "nor a name that only begins like a scratch one"
}

# A path a suite claims but that is not there any more. The claim then silently covers nothing,
# and the suite stops being selected for the thing it was written to cover.
test_every_path_a_suite_claims_exists() {
    local suite name claim bad=""
    for suite in "$REPO_ROOT"/test/suites/*.sh "$REPO_ROOT"/modules/*/test/*.sh; do
        [ -f "$suite" ] || continue
        name=$(basename "$suite" .sh)
        while read -r claim; do
            [ -n "$claim" ] || continue
            [ -e "$REPO_ROOT/$claim" ] \
                || bad="$bad"$'\n'"  $name claims $claim, which does not exist"
        done < <(sed -n '1,16s/^# covers: *//p' "$suite" | tr ' ' '\n')
    done
    assert_eq "" "$bad" "every claimed path must exist:$bad"
}

# EVERY SUITE SAYS WHAT IT MAY COST, in one of three words.
#
# `--cost static` has to be trustworthy or nobody will use it, and an undeclared suite reads as
# `pipeline` - safe, but silently outside every cheap run. A misspelt class is worse: it matches
# no filter at all and the suite simply never runs.
test_every_suite_declares_what_it_costs() {
    local suite name declared bad=""
    for suite in "$REPO_ROOT"/test/suites/*.sh "$REPO_ROOT"/modules/*/test/*.sh; do
        [ -f "$suite" ] || continue
        name=$(basename "$suite" .sh)
        declared=$(sed -n '1,12s/^# cost: *//p' "$suite" | head -1)
        case "$declared" in
            static|jvm|pipeline) ;;
            "") bad="$bad"$'\n'"  $name declares no cost" ;;
            *)  bad="$bad"$'\n'"  $name declares '$declared', which is not static, jvm or pipeline" ;;
        esac
    done
    assert_eq "" "$bad" "every suite must declare its cost:$bad"
}

# A `static` suite must complete with nothing installed, which is the whole promise of the
# class. What breaks that is a case that BUILDS something - a baseline, a step-0 run, a module
# invocation - because those have nothing to skip to. Asking `have_tools` and skipping is fine
# and is how 00_static holds its own lint case.
test_a_static_suite_builds_nothing() {
    local suite name declared builder bad=""
    for suite in "$REPO_ROOT"/test/suites/*.sh "$REPO_ROOT"/modules/*/test/*.sh; do
        [ -f "$suite" ] || continue
        declared=$(sed -n '1,12s/^# cost: *//p' "$suite" | head -1)
        [ "$declared" = "static" ] || continue
        name=$(basename "$suite" .sh)
        # Held in a variable, and wrapped so that no forbidden name ever begins a line: the
        # pattern below reads a name at the start of a statement as a call, and this case has
        # to say the names out loud without being caught saying them.
        local builders="analysis_ready analysis_writer_ready run_pipeline run_step0"
        builders="$builders run_analysis run_module run_verify_only run_complete"
        for builder in $builders; do
            # In CALL position - at the start of a statement, or inside $( ) - so that this
            # case's own list of the names does not count as calling them.
            grep -qE "(^[[:space:]]*|\\\$\\()${builder}([[:space:]]|\\)|\$)" "$suite" \
                && bad="$bad"$'\n'"  $name is declared static and calls $builder"
        done
    done
    assert_eq "" "$bad" "a static suite must build nothing:$bad"
}

# EVERY HELPER A SUITE CALLS IS DEFINED SOMEWHERE IT CAN SEE.
#
# This is what a suite being SPLIT breaks: a case moves to a new file and the helper it calls
# stays behind, or goes to a third file, and nothing says so until that case runs - which for
# the analysis layer is half an hour away. Resolving the names statically costs a second and
# catches the whole class.
#
# It cannot catch a case that depended on the ORDER cases ran in. Nothing static can; that is
# what the suite itself is for.
test_every_helper_a_suite_calls_is_defined() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import pathlib, re

DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{", re.M)

def defs(path):
    return set(DEF.findall(pathlib.Path(path).read_text(encoding="utf-8")))

# Everything sourced before any suite runs, and so visible to all of them.
shared = set()
for path in ["test/run_tests.sh", "test/lib/harness.sh", "test/lib/sandbox.sh",
             "test/lib/analysis.sh"]:
    shared |= defs(path)

suites = sorted(pathlib.Path("test/suites").glob("*.sh"))
suites += sorted(pathlib.Path(".").glob("modules/*/test/*.sh"))

# Only names that ARE functions somewhere are looked for. A bare word in a heredoc is not a
# call, and guessing which words are calls is what makes a checker like this cry wolf.
elsewhere = {}
for suite in suites:
    for name in defs(suite):
        elsewhere.setdefault(name, []).append(str(suite))

for suite in suites:
    here = defs(suite)
    body = re.sub(r"^\s*#.*$", "", pathlib.Path(suite).read_text(encoding="utf-8"), flags=re.M)
    for name, homes in sorted(elsewhere.items()):
        if name in here or name in shared or name.startswith("test_"):
            continue
        if re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(name), body):
            print("%s: uses %s(), defined only in %s" % (suite, name, ", ".join(homes)))
PY
)
    assert_eq "" "$out" "every helper a suite calls must be defined:"$'\n'"$out"
}

# The rule for a package spec is written twice - the wrapper refuses one before it installs a
# module, the analysis frame refuses one before it runs it - and neither can call the other:
# one is shell reached without a JVM, the other is Groovy reached without a shell. So the two
# are checked against the same table of specs instead.
test_both_sides_agree_on_what_a_package_spec_may_be() {
    local shell_re groovy_re spec want got
    shell_re=$(sed -n "s/^MODULE_SPEC_RE='\^\(.*\)\\$'$/\1/p" "$REPO_ROOT/lib/wrapper_lib.sh")
    groovy_re=$(sed -n '/^def checkPackageSpec/,/^}/ s/.*==~ \/\(.*\)\/)).*/\1/p' \
        "$REPO_ROOT/analysis/lib/nf/modules.nf")
    # Named rather than compared to the empty string: a pattern neither side carries would
    # otherwise make the two agree by both being nothing.
    assert_eq "yes" "$([ -n "$shell_re" ] && echo yes)" "the wrapper should carry a spec pattern"
    assert_eq "yes" "$([ -n "$groovy_re" ] && echo yes)" "and so should readManifest"
    assert_eq "$groovy_re" "$shell_re" "and the two should be the same pattern"

    # Each entry is the spec and whether it is acceptable. The refusals are the point: the
    # first is unpinned, the second carries a build string, the third a range, the fourth a
    # channel the release rather than the module decides.
    while read -r spec want; do
        got=no
        printf '%s' "$spec" | grep -qE "^$shell_re\$" && got=yes
        assert_eq "$want" "$got" "the spec '$spec'"
    done <<'SPECS'
r-poolfstat=3.0.0 yes
r-base=4.4.1 yes
bwa=0.7.19 yes
r-poolfstat no
r-poolfstat=3.0.0=r44hb79369c_0 no
r-poolfstat>=3.0 no
conda-forge::r-poolfstat=3.0.0 no
SPECS
}

# The compatibility fields every module and library declares, checked for the SOURCES this
# repository publishes from. Nothing here ships inside a release any more, so `environment` is a
# minimum its author sets when the module's needs change - not this release, and not something a
# version bump rewrites. What is still checkable is that the fields are present and well formed,
# and that nothing declares a `frame` newer than the frame in this checkout, which would be a
# module this repository could not itself run.
test_every_shipped_manifest_declares_its_compatibility() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import json, pathlib, re

frame = [line.strip() for line in
         pathlib.Path("analysis/frame.version").read_text(encoding="utf-8").splitlines()
         if line.strip() and not line.startswith("#")][0]

def parts(version):
    return [int(n) for n in version.split(".")]

paths = (sorted(pathlib.Path("modules").glob("*/manifest.json"))
         + sorted(pathlib.Path("modules/lib").glob("*/manifest.json")))
if not paths:
    print("no module or library source found, so this case checked nothing")
for path in paths:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    for field in ("license", "frame", "environment"):
        if not str(manifest.get(field, "")).strip():
            print("%s: no '%s'" % (path, field))
    if re.fullmatch(r"\d{8}\.\d{3}", str(manifest.get("frame", ""))):
        if parts(str(manifest["frame"])) > parts(frame):
            print("%s: needs frame %s, and this release's is %s"
                  % (path, manifest["frame"], frame))
    elif "frame" in manifest:
        print("%s: gives frame as '%s', which is not YYYYMMDD.NNN" % (path, manifest["frame"]))
    if "environment" in manifest and not re.fullmatch(r"\d+(\.\d+)*", str(manifest["environment"])):
        print("%s: gives environment as '%s', which is not a release version"
              % (path, manifest["environment"]))
    for spec in manifest.get("packages", []):
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*=[A-Za-z0-9][A-Za-z0-9._+]*", str(spec)):
            print("%s: '%s' is not a pinned conda spec" % (path, spec))
PY
)
    assert_eq "" "$out" "every module and library manifest declares what it runs on:"$'\n'"$out"
}

# A module's own report is knitted from its directory by name, and readManifest() refuses a
# declared one that is not there - at the user's run, after publishing, which is too late to
# learn it. The same two checks, on the source. Fails when no module declares one, because then
# it checks nothing and a renamed key would pass it.
test_every_declared_module_report_is_there() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import json, pathlib, re

declared = 0
for path in sorted(pathlib.Path("modules").glob("*/manifest.json")):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    report = str(manifest.get("report", "")).strip()
    if not report:
        continue
    declared += 1
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.Rmd", report):
        print("%s: gives report as '%s', which is not an .Rmd name" % (path, report))
    elif not (path.parent / report).is_file():
        print("%s: declares report '%s', and %s has no such file" % (path, report, path.parent))
if declared == 0:
    print("no module declares a report, so this case checked nothing")
PY
)
    assert_eq "" "$out" "every module's declared report is in its directory:"$'\n'"$out"
}

test_every_declared_manual_anchor_exists() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import json, pathlib, re, sys
sys.path.insert(0, "dev/scripts")
import build_docs

have = set()
for line in pathlib.Path("manual/PoolSeqFlow-manual.md").read_text(encoding="utf-8").splitlines():
    heading = build_docs.HEADING.match(line)
    if heading:
        have.add(build_docs.heading_anchor(heading.group(2)))

# The frame's own outputs, and then every module installed in this checkout.
declared = [("analysis/lib/nf/outputs.nf", a) for a in
            re.findall(r"anchor\s*:\s*'([^']+)'",
                       pathlib.Path("analysis/lib/nf/outputs.nf").read_text(encoding="utf-8"))]
for path in sorted(pathlib.Path("modules").glob("*/manifest.json")):
    for entry in json.loads(path.read_text(encoding="utf-8")).get("outputs", []):
        if entry.get("anchor"):
            declared.append((str(path), entry["anchor"]))

if not declared:
    print("no anchors were declared anywhere, so this case checked nothing")
for where, anchor in declared:
    if anchor not in have:
        print("%s: #%s is not a heading of the manual" % (where, anchor))
PY
)
    assert_eq "" "$out" "every declared manual anchor must exist:"$'\n'"$out"
}

# THE COMPLETION OFFERS EXACTLY WHAT THE WRAPPER DISPATCHES, and this is checked by running the
# completion rather than by reading its source, so how the list is written cannot fool it.
#
# A hand-kept list beside a `case` is the shape that rots: the wrapper gains a verb, the
# completion does not, and nothing says so. Strict equality both ways, with no exception list -
# an exception list is the next thing to go stale.
test_the_completion_offers_every_verb_the_wrapper_takes() {
    local dispatched offered
    dispatched=$(sed -n '/^case "\?\$COMMAND"\?/,/^esac/p' "$REPO_ROOT/PoolSeqFlow" \
        | sed -n 's/^    \([a-z_|]*\))$/\1/p' | tr '|' '\n' | sort -u)
    offered=$(bash -c '
        . "$1/lib/poolseqflow-completion.bash"
        COMP_WORDS=(PoolSeqFlow ""); COMP_CWORD=1
        _poolseqflow
        printf "%s\n" "${COMPREPLY[@]}"' _ "$REPO_ROOT" | sort -u)

    [ -n "$dispatched" ] || { fail_case "no verbs were extracted from the wrapper's case"; return; }
    [ -n "$offered" ] || { fail_case "the bash completion offered nothing at all"; return; }
    assert_eq "$dispatched" "$offered" "the bash completion and the wrapper must agree"

    # THE ZSH COMPLETION IS A SECOND LIST AND HAS TO AGREE TOO. It is native rather than a
    # bash completion run through bashcompinit, because that emulates `compgen` and the
    # emulation ignores the `--` prefix argument - so a shared file offers every candidate
    # whatever has been typed. Two files is the cost of that, and this is what keeps them
    # from drifting apart or from the wrapper.
    local zsh_offered
    zsh_offered=$(sed -n "/^    verbs=(/,/^    )/p" "$REPO_ROOT/lib/_PoolSeqFlow" \
        | sed -n "s/^        '\([a-z_]*\):.*/\1/p" | sort -u)
    [ -n "$zsh_offered" ] || { fail_case "the zsh completion offered nothing at all"; return; }
    assert_eq "$dispatched" "$zsh_offered" "the zsh completion and the wrapper must agree"
}

# The second level, for the two subcommands that have a fixed set. `analysis` also offers the
# installed modules, which vary by machine, so only the fixed words are compared.
test_the_completion_offers_the_subcommands_each_verb_takes() {
    local out
    out=$(bash -c '
        . "$1/lib/poolseqflow-completion.bash"
        reply() { COMP_WORDS=("${@:2}" ""); COMP_CWORD=$1; _poolseqflow; printf "%s\n" "${COMPREPLY[@]}"; }
        printf "check: %s\n" "$(reply 2 PoolSeqFlow check | sort | tr "\n" " ")"
        printf "modules: %s\n" "$(reply 3 PoolSeqFlow analysis modules | sort | tr "\n" " ")"
        printf "init: %s\n" "$(reply 2 PoolSeqFlow init | sort | tr "\n" " ")"
        printf "uninstall: %s\n" "$(reply 2 PoolSeqFlow uninstall | sort | tr "\n" " ")"
        printf "modules install: %s\n" "$(reply 4 PoolSeqFlow analysis modules install | sort | tr "\n" " ")"
        ' _ "$REPO_ROOT")

    assert_contains "$out" "check: install project " \
        "check takes the two targets its usage names"
    assert_contains "$out" "modules: available install list uninstall " \
        "analysis modules takes the four verbs its usage names"
    assert_contains "$out" "init: multi " "init takes the one word its usage names"
    assert_contains "$out" "uninstall: all " "uninstall takes the one word its usage names"
    assert_contains "$out" "modules install: all " \
        "modules install offers the one fixed word it takes, and no catalogue name"
    assert_contains "$(cat "$REPO_ROOT/lib/_PoolSeqFlow")" "(all:every module published for this release)" \
        "and zsh offers it too"
}

