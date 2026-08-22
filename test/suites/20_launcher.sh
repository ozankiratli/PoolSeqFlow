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
