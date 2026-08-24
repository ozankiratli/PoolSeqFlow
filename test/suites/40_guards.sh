#!/bin/bash
# The step 0 change guards: what invalidates existing outputs and what merely gets recorded.
#
# These run step 0 alone rather than the whole pipeline, so they are cheap. What they are
# about is the distinction the parameter check draws between a value the user changed and a
# parameter the release introduced - a plain diff could not tell those apart, and treating
# every release that adds a parameter as a user change told every existing project to delete
# its results.

GUARD_SB=""
GUARDS_BASELINE=""

# A verified project, built once for the whole suite: .poolseqflow_params and
# .poolseqflow_versions exist and describe a completed check.
#
# Built once and copied because a step 0 run costs about 21 seconds - Nextflow startup, flat,
# whether or not anything is cached - while copying the sandbox costs 22 milliseconds. Every
# case having its own baseline run was most of this suite's runtime and tested nothing.
guards_baseline() {
    [ -n "$GUARDS_BASELINE" ] && return 0
    local sb status
    sb=$(make_pipeline_sandbox "guards-baseline")
    write_sandbox_config "$sb"
    status=$(run_verify_only "$sb")
    [ "$status" = "0" ] || return 1
    GUARDS_BASELINE="$sb"
    return 0
}

# A fresh copy of that baseline for one case to mutate.
#
# The config is rewritten for the copy's own paths. That is safe precisely because the
# manifest is path-independent - analysisParams() excludes mainDir, storageDir and every
# dir.* entry - so the stored manifest still matches after the move. If that ever stops being
# true, these cases fail loudly rather than drifting.
guards_ready() {
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi
    if ! guards_baseline; then
        fail_case "the baseline verification failed; see $TEST_TMPDIR/guards-baseline/run.out"
        return 1
    fi
    GUARD_SB=$(guard_path "$TEST_TMPDIR/guards")
    rm -rf "$GUARD_SB"
    cp -a "$GUARDS_BASELINE" "$GUARD_SB"
    write_sandbox_config "$GUARD_SB"
    return 0
}

# The published report, found via the config the case actually wrote rather than a fixed
# path. Cases that repoint storageDir move the report with it, and reading the old location
# would quietly return the previous run's report - which looks like a passing assertion.
guard_report() {
    local store
    store=$(sed -n 's|^    storageDir *= *"\(.*\)"|\1|p' "$GUARD_SB/main/parameters.config" | head -1)
    [ -n "$store" ] || { echo "test harness: could not read storageDir from the sandbox config" >&2; return 1; }
    cat "$store/Output/Reports/0_verify_environment.txt" 2>/dev/null
}

# Rewrite the recorded release so the next run looks like an upgrade. The parameter check
# reads the last line of .poolseqflow_versions to decide whether a change in the parameter
# SET came from a release or from the user editing their own config.
pretend_earlier_release() {
    printf '2.1.0\t2026-01-01\n' > "$GUARD_SB/store/.poolseqflow_versions"
}

# Drop a key from the stored manifest, standing in for a release that did not have it.
forget_stored_parameter() {
    grep -v "^$1=" "$GUARD_SB/store/.poolseqflow_params" > "$GUARD_SB/store/.tmp_params"
    mv "$GUARD_SB/store/.tmp_params" "$GUARD_SB/store/.poolseqflow_params"
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

# Computed parameters are a convenience, not a policy: a value written in parameters.config
# is used exactly as written, and it also feeds whatever is computed from it. Pinning
# cores.samtools must therefore move cores.javaGc with it, or pinning one thing would
# silently strand the things below it.
#
# Checked through the trace's cpus column, because the cores scope is excluded from the
# change-guard manifest and so cannot be read out of run_parameters.txt. BuildSnpEffDb
# declares `cpus { params.cores.javaGc }`, which makes the resolved value observable.
test_a_pinned_core_count_cascades_into_the_values_computed_from_it() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status cpus
    sb=$(make_pipeline_sandbox "pinned-cores")
    : > "$sb/store/.step0_token"
    # threads is 4 in the sandbox, so samtools would compute to 1 and javaGc to 2. The pin
    # is deliberately small: process.resourceLimits caps cpus at `threads`, so a javaGc above
    # 4 would be clamped on the way to the trace and the test would measure the ceiling
    # rather than the resolution.
    write_sandbox_config "$sb" 's|^    cores {|    cores {\n        samtools = 2|'
    status=$(run_dictionaries_only "$sb")
    assert_status 0 "$status" "the dictionaries should build; see $sb/run.out"
    cpus=$(awk -F'\t' 'NR > 1 { split($4, a, " "); if (a[1] == "BuildDictionaries:BuildSnpEffDb") print $10 }' \
           "$sb/store/Output/Reports/PoolSeqFlow_pipeline_trace.txt" 2>/dev/null)
    assert_eq "3" "$cpus" "javaGc should be the pinned samtools + 1, not the computed 1 + 1"
}

# An option string written out in parameters.config is passed through untouched. This is the
# half of the arrangement that matters most: the values above it exist to build a sensible
# default, not to constrain what can be run.
test_a_pinned_option_string_is_used_verbatim() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status params
    sb=$(make_pipeline_sandbox "pinned-options")
    write_sandbox_config "$sb" \
        's|^        maxDepth        = 2000|        maxDepth        = 2000\n        mpileupOptions = "PINNED -d 99"|'
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "a fresh project should verify; see $sb/run.out"
    params=$(cat "$sb/store/Output/run_parameters.txt" 2>/dev/null)
    assert_contains "$params" "bcftools.mpileupOptions=PINNED -d 99" \
        "the written option string should reach the run untouched"
    assert_not_contains "$params" "-a AD,DP,SP,INFO/AD" \
        "the composed default should not have been used"
}

# mainDir and storageDir are two storage tiers. Outputs are written to the first and
# promoted to the second as the steps that consume them finish, which cannot mean anything
# if both name one directory.
test_equal_main_and_storage_directories_fail() {
    guards_ready || return
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB/main\"|"
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
    # '..' back out of storageDir and down into mainDir - a different string for the
    # directory mainDir already names.
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB/store/../main\"|"
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "a '..' spelling of mainDir should be caught"
    assert_contains "$(guard_report)" "are the same directory" "should resolve before comparing"

    # And through a symlink, where the two strings have nothing in common at all.
    ln -sfn "$GUARD_SB/main" "$GUARD_SB/store/tierlink"
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB/store/tierlink\"|"
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "a symlink to mainDir should be caught"
    assert_contains "$(guard_report)" "are the same directory" "should follow the symlink"
    rm -f "$GUARD_SB/store/tierlink"
}

# Two genuinely different directories are the normal case and must not be flagged. Identity
# is the problem, not proximity: the sandbox's roots are siblings under one parent, and that
# is as it should be.
test_distinct_directories_pass() {
    guards_ready || return
    # Run rather than reading the copied baseline report: that one was produced in the
    # baseline sandbox, under different paths, so asserting against it would prove nothing
    # about this case's configuration.
    local status report
    status=$(run_verify_only "$GUARD_SB")
    assert_status 0 "$status" "distinct directories should verify cleanly"
    report=$(guard_report)
    assert_contains "$report" "The two storage tiers are distinct" "siblings should not be flagged"
    assert_contains "$report" "DIRECTORY CHECK:       STATUS=PASS" "the stage should pass"
}

# The installation is a tool, not a workspace: one copy serves any number of projects, and an
# upgrade replaces it wholesale. A project kept inside it would not survive that, so this is
# refused outright rather than warned about.
test_maindir_may_not_be_the_installation() {
    guards_ready || return
    write_sandbox_config "$GUARD_SB" "s|^    mainDir .*|    mainDir         = \"$GUARD_SB/install\"|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "mainDir pointing at the installation should fail"
    assert_contains "$report" "is the PoolSeqFlow installation itself" "should say what is wrong"
    assert_contains "$report" "DIRECTORY CHECK:       STATUS=FAIL" "the stage should record a failure"
}

# The same rule for the other root, and the worse case of the two: an upgrade replaces the
# installation, so results kept inside it go with it - along with the manifests recording
# what produced them.
test_storagedir_may_not_be_the_installation() {
    guards_ready || return
    write_sandbox_config "$GUARD_SB" "s|^    storageDir .*|    storageDir      = \"$GUARD_SB/install\"|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "storageDir pointing at the installation should fail"
    assert_contains "$report" "storageDir is the PoolSeqFlow installation itself" \
        "should say what is wrong"
    assert_contains "$report" "DIRECTORY CHECK:       STATUS=FAIL" "the stage should record a failure"
    # The failed run still publishes its report, which lands wherever storageDir pointed.
    # Clear it so it cannot be mistaken for part of the installation by a later case.
    rm -rf "$GUARD_SB/install/Output" "$GUARD_SB/install/Logs"
}

# Containment is a different matter from identity. Nothing collides, so the run proceeds -
# but the lifetimes differ sharply enough that it is said out loud rather than discovered
# during an upgrade.
test_maindir_inside_the_installation_warns_but_runs() {
    guards_ready || return
    mkdir -p "$GUARD_SB/install/inner"
    write_sandbox_config "$GUARD_SB" "s|^    mainDir .*|    mainDir         = \"$GUARD_SB/install/inner\"|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 0 "$status" "containment should not stop the run"
    assert_contains "$report" "mainDir is inside the installation" "should warn about the containment"
    assert_contains "$report" "DIRECTORY CHECK:       STATUS=PASS" "but it should still pass"
}

# The point of separating the installation from the project: one copy of the code, any number
# of projects, each with its own settings and its own results. Until 3.0 this was impossible -
# parameters.config was read from beside the pipeline, so an installation was a single
# project and switching meant editing the file in place.
#
# poolSize differs between the two so the assertion can tell configurations apart. If the
# second project were somehow reading the first one's config, both manifests would agree.
test_two_projects_share_one_installation() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status1 status2
    sb=$(make_pipeline_sandbox "twoprojects")
    write_sandbox_config "$sb"

    # A second project beside the first, with its own data and its own storage, sharing the
    # installation. Derived from the first config so the sandbox's threads/memory carry over.
    mkdir -p "$sb/main2" "$sb/store2"
    cp -r "$REPO_ROOT/test/data/base/." "$sb/store2"/
    sed -e "s|^    mainDir .*|    mainDir         = \"$sb/main2\"|" \
        -e "s|^    storageDir .*|    storageDir      = \"$sb/store2\"|" \
        -e "s|^    poolSize .*|    poolSize        = 250|" \
        "$sb/main/parameters.config" > "$sb/main2/parameters.config"

    status1=$(run_verify_only "$sb")
    status2=$(SANDBOX_PROJECT_DIR="$sb/main2" SANDBOX_RUN_OUT="$sb/run2.out" run_verify_only "$sb")

    assert_status 0 "$status1" "the first project should verify; see $sb/run.out"
    assert_status 0 "$status2" "the second should verify against the same installation; see $sb/run2.out"

    assert_contains "$(cat "$sb/store/.poolseqflow_params" 2>/dev/null)" "poolSize=100" \
        "the first project should record its own parameters"
    assert_contains "$(cat "$sb/store2/.poolseqflow_params" 2>/dev/null)" "poolSize=250" \
        "the second project should record its own, not the first's"

    # Neither run may write into the installation. Nextflow's cache follows the launch
    # directory and work/ follows mainDir, so both belong to the project.
    assert_count 0 "$(find "$sb/install" -maxdepth 1 -name '.nextflow*' -o -maxdepth 1 -name 'work' | wc -l)" \
        "a run must leave no state in the installation"
}

# dataSource names the subdirectory the reads come from, so two datasets under one
# storageDir are two different analyses. It was excluded from the manifest, so both passed
# and the second run reused the first dataset's trimmed reads - step 2 keys its skip test on
# the sample id alone, and nothing recorded which data produced a set of outputs.
test_pointing_at_a_different_dataset_is_caught() {
    guards_ready || return
    cp -r "$GUARD_SB/store/Data" "$GUARD_SB/store/OtherData"
    write_sandbox_config "$GUARD_SB" "s|^    dataSource .*|    dataSource      = 'OtherData'|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "a different dataSource should fail against existing outputs"
    assert_contains "$report" "dataSource" "should name dataSource as the difference"
}
