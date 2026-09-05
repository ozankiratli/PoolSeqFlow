#!/bin/bash
# Checks that need no data: syntax, release packaging, version consistency.
# cost: static
# covers: PoolSeqFlow install/ dev/scripts/ analysis/modules-index.tsv .gitattributes
# covers: analysis/citations.json install/citations.json install/references.bib
# covers: analysis/references.bib manual/references.bib

# `nextflow lint` was brought to zero warnings during the post-2.2.0 audit. Held there
# deliberately: once the count is zero a new warning is a signal rather than noise.
test_nextflow_lint_is_clean() {
    have_tools || { skip_case "no conda environment"; return; }
    local out
    out=$(cd "$REPO_ROOT" && PATH="$TEST_CONDA_ENV/bin:$PATH" \
          JAVA_HOME="$TEST_CONDA_ENV" JAVA_CMD="$TEST_CONDA_ENV/bin/java" \
          nextflow lint . 2>&1)
    assert_contains "$out" "had no errors" "lint should report no errors"
    assert_not_contains "$out" "warning" "lint should report no warnings"
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
    [ -n "$listing" ] || { skip_case "git archive produced nothing"; return; }
    local unwanted
    for unwanted in "test/" "dev/" "docs/" ".github/" "mkdocs.yml" "__pycache__"; do
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
    local unguarded
    unguarded=$(cd "$REPO_ROOT" && grep -n 'for [A-Za-z_]* in [^;]*\*[^;]*; *do' scripts/*.nf \
                | grep 'atomic_mv\.sh' | grep -v '\[ -e ' || true)
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
    tree=$(working_tree_tree) || { skip_case "could not write a working tree object"; return; }
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
    local index="analysis/modules-index.tsv"
    [ -f "$REPO_ROOT/$index" ] || { fail_case "$index is missing"; return; }
    local attr; attr=$(cd "$REPO_ROOT" && git check-attr export-ignore -- "$index")
    assert_contains "$attr" "set" "the catalogue must be export-ignore'd out of a release"
    local listing; listing=$(working_tree_archive)
    [ -n "$listing" ] || { skip_case "git archive produced nothing"; return; }
    assert_not_contains "$listing" "modules-index" "and must not appear in the tarball"
}

# Its columns are what the wrapper reads by position, so a reordered header would install the
# wrong thing from the right row.
test_the_module_catalogue_header_is_the_one_the_wrapper_reads() {
    local header
    header=$(grep -v '^[[:space:]]*#' "$REPO_ROOT/analysis/modules-index.tsv" \
             | grep -v '^[[:space:]]*$' | head -1)
    assert_eq "$(printf 'name\tversion\tcontract\turl\tsha256\tsummary')" "$header" \
        "the catalogue's columns"
}

# The catalogue is fetched from the default branch at RUN TIME, so a release meets whatever is
# there years later. The layout number is what lets it refuse a file whose columns have moved
# instead of reading the wrong field out of each row; the test above cannot protect a wrapper
# that has already shipped.
test_the_module_catalogue_declares_its_layout_and_its_version() {
    local index="$REPO_ROOT/analysis/modules-index.tsv"
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
}

test_release_archive_carries_the_runtime() {
    local listing
    listing=$(working_tree_archive)
    [ -n "$listing" ] || { skip_case "git archive produced nothing"; return; }
    local needed
    for needed in "poolseqflow.nf" "nextflow.config" "parameters.config.template" \
                  "PoolSeqFlow" "analysis.nf" "metadata.csv.template" \
                  "scripts/" "bin/" "lib/" "analysis/" "install/"; do
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
    [ -n "$listing" ] || { skip_case "git archive produced nothing"; return; }
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

# The tool list a user is told to expect and the one that is pinned have to agree, and the
# epilogue that tells them how to fix a broken install has to name the right environment.
test_check_install_hint_uses_the_versioned_environment() {
    local out version
    version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    # Run standalone, with no ENV_NAME exported, which is the case the fallback exists for.
    out=$(cd "$REPO_ROOT" && env -u ENV_NAME bash install/check_install.sh 2>&1)
    # Compared as a whole line. A substring check for "conda activate PoolSeqFlow" matches
    # the versioned name too, so it can neither confirm nor deny anything useful here.
    local activate_line
    activate_line=$(printf '%s\n' "$out" | sed -n 's/^ *\(conda activate .*\)$/\1/p' | head -1)
    assert_eq "conda activate PoolSeqFlow-$version" "$activate_line" \
        "the how-to-fix epilogue should name this version's environment exactly"
}

# A malformed version has to be refused before anything is cloned, updated or exported.
# This runs no conda commands - the check is ahead of them.
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
    local offenders
    offenders=$(grep -rh 'dir_log = "' "$REPO_ROOT"/scripts/*.nf "$REPO_ROOT"/dryrun.nf \
                | sed 's|.*dir_log = "||; s|".*||' \
                | grep -vE '^[$]\{(run\.dir\.logs|params\.dir\.allLogs)\}/[0-9A-Za-z_]+$' \
                | sort -u)
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
    local leaf
    sed -n '/^PARAM_COLUMNS = {/,/^}/p' "$REPO_ROOT/bin/parse_metadata.py" \
        | sed -n 's/.*"param_[A-Za-z0-9]*": "\([A-Za-z0-9._]*\)".*/\1/p' \
        | while read -r parameter; do
            leaf="${parameter##*.}"
            grep -qE "^[[:space:]]*${leaf}[[:space:]]*=" "$REPO_ROOT/parameters.config.template" \
                || fail_case "param_ column overrides '$parameter', which parameters.config.template does not define"
        done
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
    for file in "$REPO_ROOT"/analysis/citations.json "$REPO_ROOT"/analysis/modules/*/citations.json; do
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

        # The step's entry, taken by matching brackets rather than by line shape: three of the
        # seven entries fit on one line, and a line-based reader silently ran two of them
        # together - which made the check pass because one step's declarations covered the
        # next one's reads.
        declared=$(STEP="$step" python3 -c '
import os, re, sys
text = open(sys.argv[1]).read()
step = os.environ["STEP"]
start = re.search(r"^        %s: \[" % step, text, re.M)
if not start:
    sys.exit("no map entry for step " + step)
i, depth = start.end() - 1, 0
while i < len(text):
    if text[i] == "[": depth += 1
    elif text[i] == "]":
        depth -= 1
        if depth == 0: break
    i += 1
body = re.sub(r"//[^\n]*", "", text[start.end() - 1:i])
print("\n".join(sorted(set(re.findall(r"'"'"'([^'"'"']*)'"'"'", body)))))
' "$variants")

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
# A published analysis carries the shared library folded into the module's own script, and
# libraryFiles() is the list that gets folded. Two ways for it to be wrong, and only one of them
# is loud: a function the module CALLS and does not list breaks the run, while a function it
# lists and never calls travels beside a result it did not compute - which is quiet, and is what
# rule 15 exists to stop.
test_a_module_publishes_the_library_it_calls() {
    local out
    out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import pathlib, re

available = {p.stem for p in pathlib.Path("analysis/lib/R").glob("*.R")}

for main in sorted(pathlib.Path("analysis/modules").glob("*/main.nf")):
    block = re.search(r"def libraryFiles\(\)\s*\{(.*?)\n\}", main.read_text(encoding="utf-8"), re.S)
    if not block:
        continue
    listed = [name[:-2] for name in re.findall(r"'([^']+\.R)'", block.group(1))]

    source = main.parent / (main.parent.name + ".R")
    if not source.exists():
        print("%s: lists library files and has no %s to call them from" % (main, source.name))
        continue
    text = source.read_text(encoding="utf-8")
    # A call, not a mention: the name followed by an open bracket, outside a comment.
    called = {fn for fn in available
              if re.search(r"^[^#\n]*\b%s\(" % re.escape(fn), text, re.M)}

    for fn in sorted(called - set(listed)):
        print("%s: calls %s() and does not list %s.R" % (source, fn, fn))
    for fn in sorted(set(listed) - called):
        print("%s: lists %s.R and %s never calls %s()" % (main, fn, source.name, fn))
    for fn in sorted(set(listed) - available):
        print("%s: lists %s.R, which analysis/lib/R does not have" % (main, fn))
PY
)
    assert_eq "" "$out" "a module must publish exactly the library it calls:"$'\n'"$out"
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

# A path a suite claims but that is not there any more. The claim then silently covers nothing,
# and the suite stops being selected for the thing it was written to cover.
test_every_path_a_suite_claims_exists() {
    local suite name claim bad=""
    for suite in "$REPO_ROOT"/test/suites/*.sh "$REPO_ROOT"/analysis/modules/*/test/*.sh; do
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
    for suite in "$REPO_ROOT"/test/suites/*.sh "$REPO_ROOT"/analysis/modules/*/test/*.sh; do
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
    for suite in "$REPO_ROOT"/test/suites/*.sh "$REPO_ROOT"/analysis/modules/*/test/*.sh; do
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
suites += sorted(pathlib.Path(".").glob("analysis/modules/*/test/*.sh"))

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
for path in sorted(pathlib.Path("analysis/modules").glob("*/manifest.json")):
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
