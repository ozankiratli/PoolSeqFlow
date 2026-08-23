#!/bin/bash
# The step 0 change guards: what invalidates existing outputs and what merely gets recorded.
#
# These run step 0 alone rather than the whole pipeline, so they are cheap. What they are
# about is the distinction the parameter check draws between a value the user changed and a
# parameter the release introduced - a plain diff could not tell those apart, and treating
# every release that adds a parameter as a user change told every existing project to delete
# its results.

GUARD_SB=""

# A sandbox that has already been verified once, so .poolseqflow_params and
# .poolseqflow_versions exist and describe a completed check.
guards_ready() {
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi
    GUARD_SB=$(make_pipeline_sandbox "guards")
    write_sandbox_config "$GUARD_SB"
    local status; status=$(run_verify_only "$GUARD_SB")
    if [ "$status" != "0" ]; then
        fail_case "the baseline verification failed (status $status); see $GUARD_SB/run.out"
        return 1
    fi
    return 0
}

# The published report, found via the config the case actually wrote rather than a fixed
# path. Cases that repoint storageDir move the report with it, and reading the old location
# would quietly return the previous run's report - which looks like a passing assertion.
guard_report() {
    local store
    store=$(sed -n 's|^    storageDir *= *"\(.*\)"|\1|p' "$GUARD_SB/parameters.config" | head -1)
    [ -n "$store" ] || { echo "test harness: could not read storageDir from the sandbox config" >&2; return 1; }
    cat "$store/Output/Reports/0_verify_environment.txt" 2>/dev/null
}

# Rewrite the recorded release so the next run looks like an upgrade. The parameter check
# reads the last line of .poolseqflow_versions to decide whether a change in the parameter
# SET came from a release or from the user editing their own config.
pretend_earlier_release() {
    printf '2.1.0\t2026-01-01\n' > "$GUARD_SB/proj/.poolseqflow_versions"
}

# Drop a key from the stored manifest, standing in for a release that did not have it.
forget_stored_parameter() {
    grep -v "^$1=" "$GUARD_SB/proj/.poolseqflow_params" > "$GUARD_SB/proj/.tmp_params"
    mv "$GUARD_SB/proj/.tmp_params" "$GUARD_SB/proj/.poolseqflow_params"
}

test_an_unchanged_project_passes() {
    guards_ready || return
    local status; status=$(run_verify_only "$GUARD_SB")
    assert_status 0 "$status" "a second verification with the same config should pass"
    assert_contains "$(guard_report)" "Unchanged since the outputs" "should say nothing changed"
}

# The case the guard exists for: a parameter that existed before now holds a different
# value, so the outputs on disk were produced with different settings.
test_a_changed_parameter_value_fails_the_run() {
    guards_ready || return
    write_sandbox_config "$GUARD_SB" 's|^    poolSize .*|    poolSize        = 40|'
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "a changed value should fail the run"
    assert_contains "$report" "CHANGED since the existing outputs" "should name the class of problem"
    assert_contains "$report" "poolSize" "should name the parameter"
    assert_contains "$report" "was  100" "should show the recorded value"
    assert_contains "$report" "now  40" "should show the new value"
    assert_contains "$report" "STATUS=FAIL" "the stage should record a failure"
}

# A release that introduces a parameter must not invalidate outputs that were produced
# before it existed. This used to fail every project on every upgrade, with a remedy that
# said to delete the results.
test_a_parameter_added_by_a_release_is_recorded_and_the_run_continues() {
    guards_ready || return
    pretend_earlier_release
    forget_stored_parameter "poolSize"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 0 "$status" "a parameter added by a release should not fail the run"
    assert_contains "$report" "The set of parameters changed between 2.1.0" "should name the earlier release"
    assert_contains "$report" "added    poolSize" "should list the parameter as added"
    assert_not_contains "$report" "STATUS=FAIL" "the stage should not record a failure"
}

# The same difference, without a release change, is the user editing their own config -
# and what that does to existing outputs is not knowable.
test_a_parameter_added_without_a_release_change_fails_the_run() {
    guards_ready || return
    forget_stored_parameter "poolSize"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "an added parameter with no release change should fail"
    assert_contains "$report" "without a release change" "should say why this one is different"
    assert_contains "$report" "added    poolSize" "should still list the parameter"
}

# The notice belongs on the upgrade run only. Adopting the new manifest is what stops it
# repeating, and a failed check must NOT adopt - otherwise the failure clears itself and the
# second run silently succeeds.
test_the_release_notice_appears_once_but_a_failure_does_not_clear_itself() {
    guards_ready || return
    pretend_earlier_release
    forget_stored_parameter "poolSize"
    run_verify_only "$GUARD_SB" > /dev/null
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 0 "$status" "the run after an adoption should pass"
    assert_contains "$report" "Unchanged since the outputs" "the manifest should have been adopted"
    assert_not_contains "$report" "The set of parameters changed" "the notice should not repeat"

    # Now the failing side: a rejected change must still be there on the next run.
    write_sandbox_config "$GUARD_SB" 's|^    diploidy .*|    diploidy        = 4|'
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "the changed value should fail"
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "and should still fail on the next run, not clear itself"
}

# mainDir and storageDir are two storage tiers. Outputs are written to the first and
# promoted to the second as the steps that consume them finish, which cannot mean anything
# if both name one directory.
test_equal_main_and_storage_directories_fail() {
    guards_ready || return
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB\"|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "one directory for both tiers should fail"
    assert_contains "$report" "are the same directory" "should say what is wrong"
    assert_contains "$report" "DIRECTORY CHECK:       STATUS=FAIL" "the stage should record a failure"
}

# The same directory has many spellings. A string comparison passes on every one of them,
# which is why the check resolves both paths first.
test_the_same_directory_spelled_differently_is_still_caught() {
    guards_ready || return
    local status
    # '..' back out of the child directory lands on mainDir again.
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB/proj/..\"|"
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "a '..' spelling of mainDir should be caught"
    assert_contains "$(guard_report)" "are the same directory" "should resolve before comparing"

    # And through a symlink, where the two strings have nothing in common at all.
    ln -sfn "$GUARD_SB" "$GUARD_SB/proj/tierlink"
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB/proj/tierlink\"|"
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "a symlink to mainDir should be caught"
    assert_contains "$(guard_report)" "are the same directory" "should follow the symlink"
    rm -f "$GUARD_SB/proj/tierlink"
}

# Two genuinely different directories are the normal case and must not be flagged - the
# fixture nests storageDir inside mainDir, which is fine: containment is not the problem,
# identity is.
test_distinct_directories_pass_even_when_nested() {
    guards_ready || return
    local report; report=$(guard_report)
    assert_contains "$report" "The two storage tiers are distinct" "nesting should not be flagged"
    assert_contains "$report" "DIRECTORY CHECK:       STATUS=PASS" "the stage should pass"
}

# dataSource names the subdirectory the reads come from, so two datasets under one
# storageDir are two different analyses. It was excluded from the manifest, so both passed
# and the second run reused the first dataset's trimmed reads - step 2 keys its skip test on
# the sample id alone, and nothing recorded which data produced a set of outputs.
test_pointing_at_a_different_dataset_is_caught() {
    guards_ready || return
    cp -r "$GUARD_SB/proj/Data" "$GUARD_SB/proj/OtherData"
    write_sandbox_config "$GUARD_SB" "s|^    dataSource .*|    dataSource      = 'OtherData'|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "a different dataSource should fail against existing outputs"
    assert_contains "$report" "dataSource" "should name dataSource as the difference"
}
