#!/bin/bash
# The ./PoolSeqFlow wrapper's environment handling, against a stub conda.
#
# These run entirely against the fake conda in lib/sandbox.sh. Nothing here creates,
# activates or removes a real environment: a test suite that could delete an operator's
# install is not worth having.

VERSIONED_ENV="PoolSeqFlow-$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)"

# The whole point of naming environments after the release: an older shared environment
# must not be silently borrowed, because the pinned tools are part of what made a result.
test_run_refuses_to_fall_back_to_the_legacy_environment() {
    run_launcher_with_envs "base PoolSeqFlow" check
    assert_status 1 "$LAUNCHER_STATUS" "check should fail when this version's env is absent"
    assert_contains "$LAUNCHER_OUTPUT" "$VERSIONED_ENV" "should name the environment it wanted"
    assert_contains "$LAUNCHER_OUTPUT" "kept every version in one environment" \
        "should explain what the legacy env is"
    assert_contains "$LAUNCHER_OUTPUT" "does not use it" "should be explicit that it is not borrowed"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate PoolSeqFlow" \
        "must not activate anything when the versioned env is missing"
}

test_run_lists_other_versions_without_using_them() {
    run_launcher_with_envs "base PoolSeqFlow-0.1.0 PoolSeqFlow-9.9.9" check
    assert_status 1 "$LAUNCHER_STATUS" "check should fail"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list other installed versions"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-9.9.9" "should list other installed versions"
    assert_contains "$LAUNCHER_OUTPUT" "install" "should say how to fix it"
}

test_check_activates_when_the_matching_environment_exists() {
    run_launcher_with_envs "base $VERSIONED_ENV" check
    assert_status 0 "$LAUNCHER_STATUS" "check should succeed"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate $VERSIONED_ENV" \
        "should activate this version's environment"
    assert_contains "$LAUNCHER_OUTPUT" "STUB check_install ran" "should go on to verify the install"
}

# `conda env create` takes its name from environment.yml unless -n overrides it. Without the
# override every release lands in one environment again, which is the bug being fixed.
test_install_creates_the_versioned_name_explicitly() {
    run_launcher_with_envs "base" install
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env create -n $VERSIONED_ENV" \
        "install must pass -n to override the name: key in environment.yml"
}

PSF_VERSION="${VERSIONED_ENV#PoolSeqFlow-}"

# `install` deploys the code as well as the environment. The two are versioned together
# because the pinned tools are part of what produced a result, so a payload without its
# matching environment reproduces nothing.
test_install_deploys_the_pipeline_and_wrappers() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "install should succeed"
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_file "$dest/poolseqflow.nf"   "the pipeline should be deployed"
    assert_file "$dest/PoolSeqFlow"      "the wrapper should be deployed beside it"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" "a versioned wrapper should go on PATH"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow"              "so should the plain one"
    # The message is the whole point of the PATH note: a prefix nobody has on PATH gives
    # commands that cannot be found by name, with nothing to say why.
    assert_contains "$LAUNCHER_OUTPUT" "$LAUNCHER_PREFIX/bin" "should name the wrapper directory"
    assert_contains "$LAUNCHER_OUTPUT" "PATH" "should say something about PATH"
}

# The deployed copy is reached through a symlink, so it carries its own location rather than
# resolving one. The copy in a clone must stay unstamped, or a checkout would point at an
# installation instead of itself.
test_the_deployed_wrapper_is_stamped_and_the_source_is_not() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_contains "$(grep '^POOLSEQFLOW_INSTALLED_HOME=' "$dest/PoolSeqFlow")" "$dest" \
        "the installed wrapper should know its own payload"
    assert_eq 'POOLSEQFLOW_INSTALLED_HOME=""' \
        "$(grep '^POOLSEQFLOW_INSTALLED_HOME=' "$REPO_ROOT/PoolSeqFlow")" \
        "the source wrapper must stay unstamped"
}

# By version order, not install order: reinstalling an older release must not capture the
# plain name and quietly become what `PoolSeqFlow run` means.
test_the_plain_wrapper_points_at_the_newest_version() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "the first install should succeed"
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    mkdir -p "$LAUNCHER_PREFIX/opt/PoolSeqFlow-99.9.9"
    : > "$LAUNCHER_PREFIX/opt/PoolSeqFlow-99.9.9/PoolSeqFlow"
    ( cd "$sb" && PATH="$sb/stub/bin:$PATH" POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
      ./PoolSeqFlow install ) >/dev/null 2>&1
    assert_contains "$(readlink "$LAUNCHER_PREFIX/bin/PoolSeqFlow")" "PoolSeqFlow-99.9.9" \
        "the plain wrapper should follow the highest version, not the last installed"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" \
        "this version's own wrapper should still be there"
}

# Both halves go, and nothing is left on PATH pointing at a directory that no longer exists.
test_uninstall_removes_the_pipeline_as_well_as_the_environment() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" ./PoolSeqFlow uninstall 2>&1 )
    assert_contains "$out" "Removed" "should say the pipeline was removed"
    assert_count 0 "$(find "$LAUNCHER_PREFIX/opt" -maxdepth 1 -name 'PoolSeqFlow-*' | wc -l)" \
        "the payload should be gone"
    assert_count 0 "$(find "$LAUNCHER_PREFIX/bin" -maxdepth 1 -name 'PoolSeqFlow*' | wc -l)" \
        "and so should both wrappers, rather than dangling"
}

# Removing one version must leave the others alone, and must leave the plain wrapper pointing
# at a version that still exists rather than at the hole it just made. An older version is
# uninstalled by calling its OWN wrapper - each copy knows only the version it belongs to.
test_uninstall_leaves_the_other_installed_versions_alone() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    # An OLDER version alongside, wrappers and all, as its own `install` would have left it.
    # Older rather than newer on purpose: removing the newest is the case where the plain
    # wrapper has to be repointed, and a newer sibling would leave it correct by accident.
    mkdir -p "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0"
    : > "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0/PoolSeqFlow"
    ln -sfn "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0/PoolSeqFlow" \
            "$LAUNCHER_PREFIX/bin/PoolSeqFlow-0.1.0"

    assert_contains "$(readlink "$LAUNCHER_PREFIX/bin/PoolSeqFlow")" "PoolSeqFlow-$PSF_VERSION" \
        "before uninstalling, the plain wrapper should point at the newest"
    # Called by its versioned name, which names the version and so needs no prompt.
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
        "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" uninstall 2>&1 )
    assert_contains "$out" "Removed" "should remove the version its wrapper belongs to"
    assert_no_file "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION/PoolSeqFlow" \
        "its own payload should be gone"
    assert_no_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" \
        "and its own wrapper with it"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0" "the other version must stay installed"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-0.1.0" "and keep its own wrapper"
    assert_contains "$(readlink "$LAUNCHER_PREFIX/bin/PoolSeqFlow")" "PoolSeqFlow-0.1.0" \
        "the plain wrapper must fall back to the version that is left, not dangle"
}

# With several installed and nothing attached to ask, picking one would be guessing at which
# installation to delete. It refuses and names the command that is exact instead.
test_uninstall_refuses_to_choose_a_version_without_a_terminal() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    mkdir -p "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0"
    : > "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0/PoolSeqFlow"

    local out status
    out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
           ./PoolSeqFlow uninstall 2>&1 ) && status=0 || status=$?
    assert_status 1 "$status" "should refuse rather than pick one"
    assert_contains "$out" "PoolSeqFlow-0.1.0" "should list what is installed"
    assert_contains "$out" "PoolSeqFlow-<version> uninstall" "should name the exact command"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION" "and must remove nothing"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0" "and must remove nothing"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "and attempt no removal"
}

test_install_reports_environments_left_from_other_versions() {
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0" install
    assert_contains "$LAUNCHER_OUTPUT" "Other PoolSeqFlow environments" "should report what else is installed"
    assert_contains "$LAUNCHER_OUTPUT" "unversioned" "the legacy env should be labelled, not called a version"
    assert_contains "$LAUNCHER_OUTPUT" "uninstall_all" "should offer the bulk removal command"
}

test_list_marks_the_current_version() {
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0 $VERSIONED_ENV" list
    assert_status 0 "$LAUNCHER_STATUS" "list should succeed"
    assert_contains "$LAUNCHER_OUTPUT" "* $VERSIONED_ENV" "should mark this copy's environment"
    assert_contains "$LAUNCHER_OUTPUT" "unversioned" "should annotate the legacy environment"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list other versions"
}

test_list_says_so_when_nothing_is_installed() {
    run_launcher_with_envs "base" list
    assert_status 0 "$LAUNCHER_STATUS" "list should succeed with no environments"
    assert_contains "$LAUNCHER_OUTPUT" "No PoolSeqFlow conda environments" "should say none are installed"
}

# `conda env remove` on an absent environment exits non-zero, and under set -e that used to
# surface as a raw conda error with no hint about what was actually installed.
test_uninstall_explains_itself_when_the_environment_is_absent() {
    run_launcher_with_envs "base PoolSeqFlow-0.1.0" uninstall
    assert_status 1 "$LAUNCHER_STATUS" "uninstall should fail"
    assert_contains "$LAUNCHER_OUTPUT" "is not installed" "should say the environment is not there"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list what is installed instead"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "must not attempt a removal"
}

test_uninstall_all_removes_every_poolseqflow_environment() {
    local log
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0 $VERSIONED_ENV" uninstall_all <<< "y"
    log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env remove -n PoolSeqFlow " "should remove the legacy environment"
    assert_contains "$log" "env remove -n PoolSeqFlow-0.1.0" "should remove other versions"
    assert_contains "$log" "env remove -n $VERSIONED_ENV" "should remove this version too"
}

test_uninstall_all_aborts_on_a_negative_answer() {
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0" uninstall_all <<< "n"
    assert_status 1 "$LAUNCHER_STATUS" "declining should exit non-zero"
    assert_contains "$LAUNCHER_OUTPUT" "Aborted" "should say it aborted"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "must remove nothing"
}

# Piped into a script or run from CI there is no one to answer, and silence must not be
# taken for consent.
test_uninstall_all_aborts_without_a_terminal() {
    run_launcher_with_envs "base PoolSeqFlow" uninstall_all < /dev/null
    assert_status 1 "$LAUNCHER_STATUS" "no confirmation should exit non-zero"
    assert_contains "$LAUNCHER_OUTPUT" "no confirmation received" "should say why it stopped"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "must remove nothing"
}

# The wrapper takes exactly one subcommand; parameters.config.template documents that.
test_wrapper_rejects_extra_arguments() {
    run_launcher_with_envs "base" uninstall all
    assert_status 1 "$LAUNCHER_STATUS" "two arguments should be refused"
    run_launcher_with_envs "base"
    assert_status 1 "$LAUNCHER_STATUS" "no argument should be refused"
    run_launcher_with_envs "base" nonsense_command
    assert_status 1 "$LAUNCHER_STATUS" "an unknown subcommand should be refused"
}

# Everything `init` writes is something you then edit, so a second run must leave it alone.
test_init_populates_a_project_without_overwriting() {
    local proj out
    proj=$(guard_path "$TEST_TMPDIR/init-project")
    rm -rf "$proj"; mkdir -p "$proj"

    out=$(cd "$proj" && POOLSEQFLOW_HOME="$REPO_ROOT" bash "$REPO_ROOT/PoolSeqFlow" init 2>&1)
    assert_contains "$out" "created  parameters.config" "should create the config"
    assert_contains "$out" "created  metadata.csv.example" "should copy the metadata example"
    [ -d "$proj/Data" ] || fail_case "init should create Data/"
    [ -d "$proj/Reference" ] || fail_case "init should create Reference/"
    # metadata.csv is a table describing the experiment, so the user writes it.
    if [ -e "$proj/metadata.csv" ]; then
        fail_case "init must not write metadata.csv"
    fi

    echo "# edited by the user" >> "$proj/parameters.config"
    out=$(cd "$proj" && POOLSEQFLOW_HOME="$REPO_ROOT" bash "$REPO_ROOT/PoolSeqFlow" init 2>&1)
    assert_contains "$out" "0 created, 4 already present" "a second init should change nothing"
    assert_contains "$(cat "$proj/parameters.config")" "edited by the user" \
        "a second init must not overwrite a file you have edited"
}

# multi-run.csv.example is documentation, not a template: the runs and the parameters that
# differ between them are the whole content of a table, so only the user can write one.
test_init_multi_switches_multirun_on_without_inventing_a_table() {
    local proj out
    proj=$(guard_path "$TEST_TMPDIR/init-multi-project")
    rm -rf "$proj"; mkdir -p "$proj"

    out=$(cd "$proj" && POOLSEQFLOW_HOME="$REPO_ROOT" bash "$REPO_ROOT/PoolSeqFlow" init_multi 2>&1)
    assert_contains "$(grep -E '^[[:space:]]*multiRun[[:space:]]*=' "$proj/parameters.config")" \
        "true" "init_multi should switch multiRun on"
    assert_contains "$out" "multi-run.csv.example" "should point at the rules for writing a table"
    [ -f "$proj/multi-run.csv.example" ] || fail_case "init_multi should leave the example beside you"
    if [ -e "$proj/runs.csv" ]; then
        fail_case "init_multi must not invent a run table"
    fi
}

# A project inside the installation does not survive an upgrade, and the installation may be
# read-only or shared between users. Refused outright rather than left to fail later.
test_init_refuses_to_populate_inside_the_installation() {
    local inst out status
    inst=$(guard_path "$TEST_TMPDIR/init-install")
    rm -rf "$inst"; mkdir -p "$inst"
    cp "$REPO_ROOT/PoolSeqFlow" "$REPO_ROOT/parameters.config.template" \
       "$REPO_ROOT/metadata.csv.template" "$inst/"
    : > "$inst/poolseqflow.nf"

    out=$(cd "$inst" && POOLSEQFLOW_HOME="$inst" bash "$inst/PoolSeqFlow" init 2>&1) && status=0 || status=$?
    assert_status 1 "$status" "init inside the installation should be refused"
    assert_contains "$out" "not a project" "should say what is wrong"
    if [ -d "$inst/Data" ]; then
        fail_case "it must not have populated the installation"
    fi
}

# Every advertised subcommand must exist, and every implemented one must be advertised.
test_usage_and_implementation_agree() {
    local usage_line advertised implemented
    usage_line=$(sed -n 's/.*Usage: \$0 {\(.*\)}.*/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    advertised=$(printf '%s' "$usage_line" | tr '|' '\n' | sort)
    implemented=$(sed -n 's/^    \([a-z_|]*\))$/\1/p' "$REPO_ROOT/PoolSeqFlow" \
                  | tr '|' '\n' | grep -v '^\*$' | sort)
    local cmd
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        printf '%s\n' "$implemented" | grep -qx "$cmd" \
            || fail_case "usage advertises '$cmd' but no case arm implements it"
    done < <(printf '%s\n' "$advertised")
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        # `resume` is an accepted deprecated alias, deliberately not advertised.
        [ "$cmd" = "resume" ] && continue
        printf '%s\n' "$advertised" | grep -qx "$cmd" \
            || fail_case "'$cmd' is implemented but not advertised in usage"
    done < <(printf '%s\n' "$implemented")
}
