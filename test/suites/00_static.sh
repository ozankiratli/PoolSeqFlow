#!/bin/bash
# Checks that need no data: syntax, release packaging, version consistency.

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
        find "$REPO_ROOT/bin" "$REPO_ROOT/install" "$REPO_ROOT/dev" "$REPO_ROOT/test" \
             -name '*.sh' -type f 2>/dev/null
        echo "$REPO_ROOT/PoolSeqFlow"
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

# The release tarball is built with `git archive`, and .gitattributes decides what it holds.
# Development material must stay out of it; anything a run needs must stay in.
test_release_archive_excludes_development_material() {
    local listing
    listing=$(cd "$REPO_ROOT" && git archive HEAD 2>/dev/null | tar -t 2>/dev/null)
    [ -n "$listing" ] || { skip_case "git archive produced nothing"; return; }
    local unwanted
    for unwanted in "test/" "dev/" "docs/" ".github/" "mkdocs.yml" "__pycache__"; do
        assert_not_contains "$listing" "$unwanted" "release tarball should not carry $unwanted"
    done
}

test_release_archive_carries_the_runtime() {
    local listing
    listing=$(cd "$REPO_ROOT" && git archive HEAD 2>/dev/null | tar -t 2>/dev/null)
    [ -n "$listing" ] || { skip_case "git archive produced nothing"; return; }
    local needed
    for needed in "poolseqflow.nf" "nextflow.config" "parameters.config.template" \
                  "PoolSeqFlow" "metadata.csv.template" "scripts/" "bin/" "install/"; do
        assert_contains "$listing" "$needed" "release tarball must carry $needed"
    done
}

# The version is written in three places and they have to agree, or release.yml refuses to
# publish. Cheaper to catch here than in CI.
test_version_is_consistent_across_all_three_places() {
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
    local hits
    hits=$(grep -n "/home/\|/Users/" "$REPO_ROOT/install/environment.yml" || true)
    assert_eq "" "$hits" "environment.yml should not contain an absolute home path"
}

# Without a name: key, `conda env create -f` refuses unless given -n. That is deliberate:
# environments are named after the release, and a fixed name in the file is an invitation
# to build an unversioned one that the launcher then declines to use.
test_environment_yml_has_no_name_or_prefix_key() {
    assert_eq "" "$(grep -c '^name:' "$REPO_ROOT/install/environment.yml" | grep -v '^0$')" \
        "environment.yml should have no name: key"
    assert_eq "" "$(grep -c '^prefix:' "$REPO_ROOT/install/environment.yml" | grep -v '^0$')" \
        "environment.yml should have no prefix: key"
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
    archive=$(cd "$REPO_ROOT" && git archive HEAD | tar -t | sed 's|/.*||' | sort -u)
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

test_fixture_generator_is_deterministic() {
    local out
    out="$TEST_TMPDIR/fixture-determinism"
    python3 "$REPO_ROOT/test/tools/make_fixture.py" "$out" >/dev/null 2>&1 \
        || { fail_case "generator failed"; return; }
    diff -r "$REPO_ROOT/test/data/base" "$out" >/dev/null 2>&1 \
        || fail_case "regenerating the fixture with the default seed did not reproduce test/data/base"
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

        reads=$(grep -o 'run\.[A-Za-z_][A-Za-z0-9_.]*' "$file" | sed 's/^run\.//; s/\.$//' \
                | sort -u | grep -Ev "$excluded" | grep -Ev "$indirect")

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
