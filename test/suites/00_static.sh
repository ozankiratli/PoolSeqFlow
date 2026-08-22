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
                  "PoolSeqFlow" "RGTags.csv.template" "scripts/" "bin/" "install/"; do
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

# The committed fixture must be reproducible from the generator, or the reference outputs
# cannot be regenerated after a change to it.
test_fixture_generator_is_deterministic() {
    local out
    out="$TEST_TMPDIR/fixture-determinism"
    python3 "$REPO_ROOT/test/tools/make_fixture.py" "$out" >/dev/null 2>&1 \
        || { fail_case "generator failed"; return; }
    diff -r "$REPO_ROOT/test/data/base" "$out" >/dev/null 2>&1 \
        || fail_case "regenerating the fixture with the default seed did not reproduce test/data/base"
}
