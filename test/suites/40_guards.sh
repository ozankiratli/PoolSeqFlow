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

# Rewrite the recorded release so the next run looks like an upgrade.
pretend_earlier_release() {
    printf '2.1.0\t2026-01-01\n' > "$GUARD_SB/store/Output/.poolseqflow_version"
}

# Drop a key from the stored manifest, standing in for a release that did not have it.
forget_stored_parameter() {
    grep -v "^$1=" "$GUARD_SB/store/Output/.poolseqflow_params" > "$GUARD_SB/store/Output/.tmp_params"
    mv "$GUARD_SB/store/Output/.tmp_params" "$GUARD_SB/store/Output/.poolseqflow_params"
}

test_an_unchanged_project_passes() {
    guards_ready || return
    local status; status=$(run_verify_only "$GUARD_SB")
    assert_status 0 "$status" "a second verification with the same config should pass"
    assert_contains "$(guard_report)" "parameters.config unchanged since the outputs" \
        "should say nothing changed"
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
    assert_contains "$report" "parameters.config has CHANGED" "should name the file that moved"
    assert_contains "$report" "poolSize" "should name the parameter"
    assert_contains "$report" "was  100" "should show the recorded value"
    assert_contains "$report" "now  40" "should show the new value"
    assert_contains "$report" "STATUS=FAIL" "the stage should record a failure"
}

# THE EXECUTION DEFAULTS A PROJECT MAY REPLACE, and until E6g it could replace none of them.
#
# nextflow.config's includeConfig sat ABOVE its own assignments and Nextflow is later-wins, so
# conda.enabled, cleanup and the whole process block were set again from the installation after
# the project's config had already been read. MEASURED before the fix: a project asking for
# errorStrategy = 'ignore', maxRetries = 99, cleanup = false and conda.enabled = false got
# 'finish', 3, true and true - silently, while the config went on advertising the alternatives
# in a comment beside each one. Editing the installation was the only route, and an installation
# is replaced wholesale on the next upgrade.
#
# workDir and env.PATH stay below the include and stay the installation's. Both read a parameter,
# so they cannot move; both are also structural, and a project that repointed either would lose
# the helpers in bin/ or put work/ outside the roots clean and reset know about.
test_a_project_can_replace_the_execution_defaults() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb flat
    sb=$(make_pipeline_sandbox "exec-defaults")
    write_sandbox_config "$sb"
    cat >> "$sb/main/parameters.config" <<'OVERRIDE'

cleanup = false
conda.enabled = false
process {
    errorStrategy = 'ignore'
    maxRetries = 99
}
workDir = '/tmp/somewhere-the-project-picked'
OVERRIDE
    flat=$(sandbox_config_flat "$sb")
    [ -n "$flat" ] || { fail_case "nextflow config produced nothing for $sb"; return; }

    assert_contains "$flat" "cleanup = false"          "a project must be able to keep work/"
    assert_contains "$flat" "conda.enabled = false"    "and to run without conda"
    assert_contains "$flat" "process.errorStrategy = 'ignore'" \
        "and to choose how a failed task is handled"
    assert_contains "$flat" "process.maxRetries = 99"  "and how often one is retried"

    # Still derived, from below the include, out of the project's own two numbers.
    assert_contains "$flat" "process.resourceLimits.cpus = 4" \
        "while the resource ceiling stays computed"
    # And workDir stays the installation's even when the project names one, which is what the
    # manual promises: clean and reset look for it under mainDir and nowhere else.
    assert_contains "$flat" "workDir = '$sb/main/work'" \
        "workDir must stay under mainDir"
    assert_not_contains "$flat" "somewhere-the-project-picked" \
        "a project must not be able to move the work directory out of mainDir"
}

# THE HELPERS' OWN DEPENDENCIES ARE VERIFIED LIKE ANY OTHER TOOL. bin/atomic_mv.sh copies an
# artifact with rsync, compares the copy against its source with diff, and only then removes the
# source; find lists what a results folder holds. All three are called by bare name from bin/,
# which reads no Nextflow settings, so a machine without rsync does not fail at step 0 - it fails
# at the first move between volumes, which is hours into a run.
#
# They joined the software block when atomic_mv.sh started using them, and nothing checked that
# they stayed in it.
test_the_helper_dependencies_are_verified_at_step_0() {
    guards_ready || return
    local status report tool
    status=$(run_verify_only "$GUARD_SB")
    assert_status 0 "$status" "the baseline should verify"
    report=$(guard_report)
    for tool in rsync diff find; do
        assert_contains "$report" "Installed: $tool" \
            "step 0 should verify $tool, which the helpers in bin/ call by bare name"
    done
}

# capBAM.histogramMax IS DELIBERATELY OUT OF THE MANIFEST, and it is the only tuning parameter
# that is. It bounds how deep step 5 LOOKS, not what it decides: samtools reports only the
# depths that occur, and a run whose histogram would be truncated stops instead of choosing, so
# every value a run completes at gives the same histogram and the same ceiling.
#
# Recording it would make it useless. The only remedy for a truncated histogram is to raise it,
# and a project that had recorded the old value would answer that with "parameters.config has
# CHANGED ... ./PoolSeqFlow reset" - demanding every result be thrown away to apply the fix the
# failure had just asked for.
test_the_histogram_ceiling_is_not_a_tracked_parameter() {
    guards_ready || return
    local recorded status report
    recorded=$(cat "$GUARD_SB/store/Output/.poolseqflow_params")
    assert_not_contains "$recorded" "capBAM.histogramMax" \
        "the histogram ceiling must not reach the recorded manifest"
    assert_contains "$recorded" "capBAM.maxDepth" \
        "while the ceiling it decides most certainly does"

    write_sandbox_config "$GUARD_SB" 's|^        histogramMax    = 100000|        histogramMax    = 250000|'
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 0 "$status" "raising it must not invalidate results already produced"
    assert_contains "$report" "parameters.config unchanged since the outputs" \
        "and the guard should not see the change at all"
}

# A PROJECT BELONGS TO ONE RELEASE, and this is checked before anything else and on its own.
#
# Z, 2026-08-28: *"Nobody should ever resume to a pipeline using a different version. That needs
# a block on its own. Reset and re-run."* This REVERSES the earlier rule, under which a version
# was recorded and never enforced so that an upgrade would not invalidate finished results. The
# reasoning that overturned it: completed steps are skipped by looking for output files, so
# continuing into another release leaves one set of results built by two versions of the code
# with nothing on disk saying which is which.
test_a_different_release_blocks_the_run() {
    guards_ready || return
    pretend_earlier_release
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "resuming a project under another release must stop the run"
    assert_contains "$report" "produced by 2.1.0" "naming the release that made the results"
    assert_contains "$report" "A project belongs to one release" "and why that is the end of it"
    assert_contains "$report" "./PoolSeqFlow reset" "with the one remedy there is"

    # ON ITS OWN, and that is the point of the wording. Everything else is skipped: the
    # parameter SET moves between releases, so comparing it here would add a second, wrong
    # explanation - "you edited your own config" - on top of the right one.
    assert_not_contains "$report" "RUN PARAMETERS:        parameters.config" \
        "the parameter comparison must not run once the release check has fired"

    # And it does not clear itself: the recorded release is left alone, so the next run says
    # the same thing rather than quietly adopting.
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "and it should still block on the next run"
}

# The parameter set changing WITHIN one release is the user editing their own config, and what
# that does to existing outputs is not knowable. This is now the only way a set change can
# reach the comparison at all, since a release change blocks above it.
test_a_parameter_added_without_a_release_change_fails_the_run() {
    guards_ready || return
    forget_stored_parameter "poolSize"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "an added parameter should fail"
    assert_contains "$report" "parameters.config has CHANGED" "should say which file moved"
    assert_contains "$report" "added    poolSize" "should list the parameter"

    # A rejected change must still be there on the next run - adopting it would make the
    # failure clear itself and the second run silently succeed.
    status=$(run_verify_only "$GUARD_SB")
    assert_status 1 "$status" "and should still fail on the next run, not clear itself"
}

# What the guard does NOT compare, and it is deliberate: where files live and how much of the
# machine to use cannot change a single number in the results, so a project that moves to
# another disk or runs on a bigger node must not be told to delete itself. Z, 2026-08-28:
# "Ignore resources and paths". This is the reason the comparison is on resolved values rather
# than a diff of the file - analysisParams() is where that exclusion list lives.
test_resources_and_paths_may_change_freely() {
    guards_ready || return
    write_sandbox_config "$GUARD_SB" 's|^    threads .*|    threads         = 2|' 
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 0 "$status" "a thread count is not an analysis parameter"
    assert_contains "$report" "parameters.config unchanged since the outputs" \
        "and should not even be reported as a difference"
    # Put it back, so the shared sandbox is left as the other cases expect it.
    write_sandbox_config "$GUARD_SB"
}

# `threads` stands for the whole excluded set here - it is the one users really do change, it
# cascades into the whole cores ladder, and it is a top-level line so the substitution is
# verifiable. The families themselves are listed in analysisParams().

# THE COPIES THEMSELVES. The comparison is on resolved values, but what is kept beside the
# results is the file the user actually wrote - comments, layout and all - because that is what
# you would cite and what tells you months later why a value was what it was.
# Its own sandbox rather than the shared one: the copy records the configuration of the last
# clean pass, and the shared sandbox is deliberately edited by the cases around this one.
test_the_configuration_is_kept_beside_the_results() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status
    sb=$(make_pipeline_sandbox "kept-config")
    write_sandbox_config "$sb"
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "a fresh project should pass; see $sb/run.out"

    local stored="$sb/store/Output/.parameters.config"
    assert_file "$stored" "parameters.config should be kept beside the results"
    assert_eq "$(cat "$sb/main/parameters.config")" "$(cat "$stored")" \
        "and kept verbatim - comments, layout and all"
    assert_no_file "$sb/store/Output/.multirun.csv" \
        "a single run has no table, so nothing should be recorded for one"
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
        's|^        callOptions|        mpileupOptions = "PINNED -d 99"\n        callOptions|'
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "a fresh project should verify; see $sb/run.out"
    params=$(cat "$sb/store/Output/run_parameters.txt" 2>/dev/null)
    assert_contains "$params" "variantCall.mpileupOptions=PINNED -d 99" \
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
    # A real project, not an empty directory: mainDir holds the inputs now, so pointing it
    # somewhere empty would fail on the missing reference and never reach the check at issue.
    rm -rf "$GUARD_SB/install/inner"
    cp -a "$GUARD_SB/main" "$GUARD_SB/install/inner"
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
    cp -r "$REPO_ROOT/test/data/base/." "$sb/main2"/
    sed -e "s|^    mainDir .*|    mainDir         = \"$sb/main2\"|" \
        -e "s|^    storageDir .*|    storageDir      = \"$sb/store2\"|" \
        -e "s|^    poolSize .*|    poolSize        = 250|" \
        "$sb/main/parameters.config" > "$sb/main2/parameters.config"

    status1=$(run_verify_only "$sb")
    status2=$(SANDBOX_PROJECT_DIR="$sb/main2" SANDBOX_RUN_OUT="$sb/run2.out" run_verify_only "$sb")

    assert_status 0 "$status1" "the first project should verify; see $sb/run.out"
    assert_status 0 "$status2" "the second should verify against the same installation; see $sb/run2.out"

    assert_contains "$(cat "$sb/store/Output/.poolseqflow_params" 2>/dev/null)" "poolSize=100" \
        "the first project should record its own parameters"
    assert_contains "$(cat "$sb/store2/Output/.poolseqflow_params" 2>/dev/null)" "poolSize=250" \
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
    cp -r "$GUARD_SB/main/Data" "$GUARD_SB/main/OtherData"
    write_sandbox_config "$GUARD_SB" "s|^    dataSource .*|    dataSource      = 'OtherData'|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "a different dataSource should fail against existing outputs"
    assert_contains "$report" "dataSource" "should name dataSource as the difference"
}

# The metadata guard has to look on BOTH volumes, and this is the case that shows why it is not
# a cosmetic point.
#
# Everywhere else in this pipeline a wrong answer to "does this artifact exist" costs redundant
# work. Here it costs the guard itself: the branch that fires when there are no BAMs and no VCF
# reads the situation as "nothing has consumed metadata.csv yet, so an edit is free" and RECORDS A
# NEW BASELINE. From 3.0 the cleaned BAMs live on the working volume until both of their
# consumers are done, so a run interrupted between cleaning and calling leaves exactly that
# state - and a guard that only looked in permanent storage would adopt an edited metadata.csv as
# the baseline for BAMs that carry the old tags. Nothing later could detect it, because the
# baseline would now say they agree.
#
# The assertion that matters is the second one. Failing the run is the visible half; leaving the
# stored baseline alone is the half that keeps the next run honest.
test_a_metadata_edit_is_caught_when_the_bams_are_not_yet_promoted() {
    guards_ready || return
    local before after status report

    before=$(md5sum < "$GUARD_SB/store/Output/.poolseqflow_metadata")

    # Cleaned but not yet promoted: on the working volume, absent from permanent storage.
    # Existence is all the guard tests, so an empty file stands in for the BAM.
    mkdir -p "$GUARD_SB/main/Utilized/Ready"
    : > "$GUARD_SB/main/Utilized/Ready/TestSample1_ready.bam"
    [ -e "$GUARD_SB/store/Output/Ready" ] && fail_case "storage should hold no ready BAMs for this case"

    # Change a tag value, which is the kind of edit that invalidates the BAMs.
    sed -i '2s/,/_EDITED,/2' "$GUARD_SB/main/metadata.csv"

    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)

    assert_status 1 "$status" "an edit against unpromoted BAMs should fail the run"
    assert_contains "$report" "METADATA CHANGE CHECK: FAIL" "the change should be reported"

    after=$(md5sum < "$GUARD_SB/store/Output/.poolseqflow_metadata")
    assert_eq "$before" "$after" \
        "the stored baseline must not be overwritten - doing so hides the mismatch for good"
}

# A POOL SIZE IS NOT A READ GROUP, and the guard has to say so.
#
# param_poolSize is compared by the same guard as the RG_ columns, because both change a result.
# But they invalidate different things: a read group is baked into every BAM, while a pool size
# only sets the false-positive filter's threshold - step 7, downstream of everything expensive.
# Reported through the tag branch it would tell someone to delete every BAM and realign the
# whole project to change one number.
#
# The second assertion is the one that matters. Failing the run is right either way; naming the
# right files is what makes the failure actionable.
test_a_pool_size_edit_does_not_ask_for_the_bams_back() {
    guards_ready || return
    local status report

    # Something must have consumed the file already, or the guard adopts the edit as a new
    # baseline and passes - which is correct, and is why the existing edit case plants one too.
    # Existence is all it tests, so an empty file stands in for the BAM.
    mkdir -p "$GUARD_SB/main/Utilized/Ready"
    : > "$GUARD_SB/main/Utilized/Ready/TestSample1_ready.bam"

    # Add the column with a value, against a baseline recorded without it. The guard renders a
    # param_poolSize field for every row whether the column exists or not, so this is a value
    # change on that field alone and nothing else moves.
    awk -F, -v OFS=, 'NR==1 { print $0, "param_poolSize"; next } { print $0, "40" }' \
        "$GUARD_SB/main/metadata.csv" > "$GUARD_SB/main/metadata.new" \
        && mv "$GUARD_SB/main/metadata.new" "$GUARD_SB/main/metadata.csv"

    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)

    assert_status 1 "$status" "a pool size edit should still stop the run"
    assert_contains "$report" "Pool sizes have CHANGED" "and be named for what it is"
    assert_contains "$report" "METADATA CHANGE CHECK: FAIL" "the change should be reported"
    assert_contains "$report" "Frequencies" "step 7's own output is what has to go"
    assert_not_contains "$report" "Output/Ready" \
        "a pool size does not reach the BAMs and must not ask for them"
}

# The multi-run table, checked before any compute is spent on it.
#
# These build their own sandbox rather than copying the shared baseline. Flipping multiRun on
# a copy would change the parameter SET against a manifest recorded without it, so the run
# would fail the change guard instead of reaching the check under test - a real behaviour, and
# the wrong one to be measuring here.
multirun_sandbox() {
    local name="$1" table="$2" sb
    sb=$(make_pipeline_sandbox "$name")
    printf '%s' "$table" > "$sb/main/runs.csv"
    write_sandbox_config "$sb" 's|^    multiRun .*|    multiRun        = true|'
    printf '%s' "$sb"
}

# What the table expands to has to be visible before it starts costing hours: which runs
# exist, where each one's results will go, and what actually differs between them.
test_a_multirun_table_is_reported_before_anything_runs() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report
    sb=$(multirun_sandbox "multirun-ok" '# same reads, two references
RunID,referenceFile,gffFile,trim_galore.quality,variantCall.mpileupOptions
refA,reference.fasta.gz,reference.gff.gz,,
refB,reference.fasta.gz,reference.gff.gz,30,"-B -C 50 -q 30 -Q 30 -d 4000 -a AD,DP,SP,INFO/AD -Ou"
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "a valid table should pass step 0; see $sb/run.out"
    # Under multiRun each run publishes its own report under its own storageDir - there is no
    # longer one at the base. The multi-run stage describes the whole invocation, so its
    # section is the same in every run's copy; refA's is read here because one of them has to
    # be.
    report=$(cat "$sb/store/Output/refA/Reports/0_verify_environment.txt")

    assert_contains "$report" "2 runs"      "the run count should be reported"
    assert_contains "$report" "refA -> $sb/store/Output/refA" "each run's own results directory should be named"
    assert_contains "$report" "refB -> $sb/store/Output/refB" "and named from RunID"
    assert_contains "$report" "trim_galore.quality = 30" "what differs should be listed"

    # A blank cell means inherit, so it must not be reported as something refA sets.
    assert_not_contains "$report" "refA
MULTI-RUN CHECK:           trim_galore.quality" "a blank cell is not an override"

    # Pinning a derived value is allowed and is why there is no column whitelist - but it
    # detaches that value from whatever it was computed from, which is worth saying once
    # here rather than leaving someone to find it in a result months later.
    assert_contains "$report" "replace a value the pipeline would compute" \
        "an override of a derived parameter should be called out"
    assert_contains "$report" "variantCall.mpileupOptions" "by name"

    # The value contains commas. If the parsing were splitting on them this is where it
    # would show, as a mangled value rather than an error.
    assert_contains "$report" "-d 4000 -a AD,DP,SP,INFO/AD" "a quoted value should survive whole"
}

# An unusable table must stop the run before it costs anything. The whole point of checking is
# that the alternative is discovering it after the first alignment.
#
# WHERE THE REFUSAL COMES FROM CHANGED WITH E1u, and the assertion follows it. The table used
# to be checked only by step 0, which reported FAIL and let VerifyAll publish the report. Now
# the runs have to exist before the DAG can be built at all, so the resolver parses the table
# first and throws - EARLIER than step 0, not later. There is no published report because no
# task ran, so what is asserted is the console output.
#
# What must not change is the part the user cares about: every problem at once, with line
# numbers, in seconds. That is the same message either way, because both routes come from
# bin/parse_multirun.py.
test_an_unusable_multirun_table_stops_the_run() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out
    sb=$(multirun_sandbox "multirun-bad" 'RunID,params.poolSize
r1,10
r1,20
')
    status=$(run_verify_only "$sb")
    assert_status 1 "$status" "an unusable table should stop the run"
    out=$(cat "$sb/run.out")
    assert_contains "$out" "cannot be used as a multi-run table" "it should say what is wrong"
    assert_contains "$out" "write 'poolSize'"        "the params. prefix should be named"
    assert_contains "$out" "each run needs its own name" "and the duplicate RunID too"
    assert_contains "$out" "completed=0" "and nothing should have run first"
}

# What a run definition actually resolves to, across several kinds of divergence at once.
#
# One table, one JVM start, many scenarios: each row varies a different family of parameter,
# so this covers re-derivation, isolation between runs, per-run roots and type handling
# together. The alternative - a run per scenario - would cost 21 seconds each and tell us the
# same thing.
#
# The claim under test is the settled resolver semantics: apply the row, derive, apply the row
# again. Setting an INPUT to a derivation moves the derived value with it; setting a derived
# value directly wins outright. Both must hold at once, and neither may leak into another run.
test_run_definitions_resolve_each_kind_of_divergence() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out
    sb=$(make_pipeline_sandbox "rundefs")
    cat > "$sb/main/runs.csv" <<'TABLE'
# each row diverges in a different way
RunID,poolSize,trim_galore.quality,variantCall.maxDepth,variantCall.mpileupOptions,threads,referenceFile
base,,,,,,
pool,50,,,,,
trim,,30,,,,
depth,,,4000,,,
pinned,,,4000,"-B -C 50 -q 30 -Q 30 -d 999 -a AD,DP,SP,INFO/AD -Ou",,
cores,,,,,2,
ref,,,,,,other.fasta.gz
TABLE
    write_sandbox_config "$sb" 's|^    multiRun .*|    multiRun        = true|'
    status=$(run_definitions_only "$sb")
    assert_status 0 "$status" "run definitions should resolve; see $sb/run.out"
    out=$(cat "$sb/run.out")

    # Nothing set: the base run must match parameters.config exactly.
    assert_contains "$out" "RUN base poolSize=100"              "an empty row inherits"
    assert_contains "$out" "RUN base filterFalsePositives.sensitivity=0.0025" "and its derived values"

    # An INPUT to a derivation moves the derived value. 1/(2*2*50) = 0.005.
    assert_contains "$out" "RUN pool poolSize=50"               "the row's own value"
    assert_contains "$out" "RUN pool filterFalsePositives.sensitivity=0.005" \
        "poolSize must re-derive sensitivity"
    # ...and must not leak sideways.
    assert_contains "$out" "RUN trim poolSize=100"              "another run keeps the base value"

    # Same again through a different derivation family.
    assert_contains "$out" "RUN trim trim_galore.quality=30"    "the row's own value"
    assert_contains "$out" "RUN trim trim_galore.options=--fastqc --paired --retain_unpaired -q 30 " \
        "trim_galore.quality must re-derive options"
    assert_contains "$out" "RUN depth variantCall.mpileupOptions=-B -C 50 -q 30 -Q 30 -d 4000 -a AD,DP,SP,INFO/AD -Ou" \
        "variantCall.maxDepth must re-derive mpileupOptions"

    # A row setting a DERIVED value directly wins, even against its own input in the same row.
    # This is why the row is applied twice, and why there is no column whitelist.
    assert_contains "$out" "RUN pinned variantCall.mpileupOptions=-B -C 50 -q 30 -Q 30 -d 999 -a AD,DP,SP,INFO/AD -Ou" \
        "a pinned derived value must survive its own derivation"

    # threads drives the cores ladder, per run.
    assert_contains "$out" "RUN cores threads=2"    "threads is varyable like anything else"
    assert_contains "$out" "RUN cores cores.bwa=2"  "and re-derives the cores ladder"
    assert_contains "$out" "RUN base cores.bwa=4"   "without disturbing the others"

    # A different reference moves everything downstream of it, including snpEff's database
    # name, and the dictionaries stay keyed by reference rather than by run.
    assert_contains "$out" "RUN ref reference=$sb/main/Reference/Dictionaries/other.fasta" \
        "referenceFile must re-derive the dictionary path"
    assert_contains "$out" "RUN ref dir.dictionaries=$sb/main/Reference/Dictionaries" \
        "dictionaries are shared between runs, keyed by reference name"

    # Per-run roots. Utilized_<RunID> is load-bearing: dir.utilized hangs off mainDir and runs
    # share mainDir, so without the suffix every run would write Test.vcf to one path and the
    # second run's skip check would symlink the first run's file.
    assert_contains "$out" "RUN pool storageDir=$sb/store"             "runs share one storage root"
    assert_contains "$out" "RUN pool dir.utilized=$sb/main/Utilized_pool" "and its own working tree"
    assert_contains "$out" "RUN pool dir.output.vcf=$sb/store/Output/pool/VCF" "and are named inside its one tree"
}

# The drift guard for the one piece of duplicated logic in the resolver.
#
# deriveRunPaths() recomputes what parameters.config computes, because config interpolation
# runs once at parse time against one set of values while a run needs its own. The config's
# copy cannot be removed either - `nextflow config -flat` is how the wrapper learns the paths
# clean and reset delete. So for a single run the two must agree exactly, and nothing but this
# case keeps them in step: drift would send one run's output somewhere its own config does not
# name, silently.
test_the_resolver_reproduces_what_the_config_computed() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out drift
    sb=$(make_pipeline_sandbox "rundefs-single")
    write_sandbox_config "$sb"
    status=$(run_definitions_only "$sb")
    assert_status 0 "$status" "a single run should resolve; see $sb/run.out"
    out=$(cat "$sb/run.out")

    drift=$(printf '%s' "$out" | grep '^DRIFT ' || true)
    [ -z "$drift" ] || fail_case "resolver and config disagree: $drift"
    assert_contains "$out" "AGREE dir.output.vcf" "the check should actually have run"

    # Settled rule 3: a single run has no RunID and nothing is suffixed.
    assert_contains "$out" "RUN null dir.utilized=$sb/main/Utilized" "no suffix without multiRun"
    assert_contains "$out" "RUN null storageDir=$sb/store"           "and no run subdirectory"
}

# A DERIVED VALUE THE PROJECT PINNED IS USED AS WRITTEN, which the manual promises and the
# resolver used to break. deriveRunPaths() recomputed the config's derivations unconditionally,
# and for a single run that can only ever discard a hand-written value: every input it reads is
# the one the config already used, so the recomputation reproduces the config's own answer in
# every other case.
#
# It is silent when it goes wrong. The run carries 1/(2*diploidy*poolSize) while the config beside
# the results says 0.001, and both look like ordinary numbers.
#
# All three of the values it derives, in one project: they are the whole set that is not a path,
# and the paths cannot be pinned at all - dir.outputs and dir.logs carry the run id.
test_a_pinned_derived_value_survives_the_resolver() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out
    sb=$(make_pipeline_sandbox "rundefs-pinned")
    write_sandbox_config "$sb" \
        's|^        sensitivity .*|        sensitivity     = 0.001|' \
        's|^    referenceFa .*|    referenceFa     = "unpacked.fasta"|' \
        's|^        db .*|        db              = "custom.gff"|'
    status=$(run_definitions_only "$sb")
    assert_status 0 "$status" "a pinned derived value should resolve; see $sb/run.out"
    out=$(cat "$sb/run.out")

    assert_contains "$out" "RUN null filterFalsePositives.sensitivity=0.001" \
        "the run must carry what the project wrote"
    assert_contains "$out" "AGREE filterFalsePositives.sensitivity" \
        "and agree with the config it was read from"
    assert_contains "$out" "RUN null referenceFa=unpacked.fasta" "the same for a filename"
    assert_contains "$out" "AGREE referenceFa" "which the config also states"
    assert_contains "$out" "RUN null snpEff.db=custom.gff" "and for the database name"
    assert_contains "$out" "AGREE snpEff.db" "which the config also states"
}

# The other half of the same property: a project that pins nothing must still have every one of
# them derived. A pin test that answers yes too readily leaves a run carrying a stale value, which
# is the failure the case above cannot see.
test_an_unpinned_derived_value_is_still_derived_per_run() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out
    sb=$(multirun_sandbox "rundefs-unpinned" 'RunID,poolSize,referenceFile,gffFile
base,,,
other,25,other.fasta.gz,other.gff.gz
')
    status=$(run_definitions_only "$sb")
    assert_status 0 "$status" "the table should resolve; see $sb/run.out"
    out=$(cat "$sb/run.out")

    assert_contains "$out" "RUN base filterFalsePositives.sensitivity=0.0025" "the base run derives"
    assert_contains "$out" "RUN other filterFalsePositives.sensitivity=0.01" \
        "and a row setting poolSize re-derives from its own"
    assert_contains "$out" "RUN other referenceFa=other.fasta" \
        "a row setting referenceFile re-derives the decompressed name"
    assert_contains "$out" "RUN other snpEff.db=other.gff" "and the database name follows its GFF"
}

# Step 1 writes to mainDir, which every run shares, so two runs naming one reference resolve
# to one set of output paths. Building it once would give one of them a dictionary made to the
# other's settings, and nothing downstream could detect that. Building it twice is not an
# option either - atomic_mv.sh has no locking, so that is a race on the user's own reference
# directory. Which of the two settings should win is the user's decision, so it is refused.
#
# Runs the real entry point, and costs no more than a JVM start: the check happens while the
# DAG is being built, so the run dies before the first task is submitted.
test_multi_run_refuses_a_shared_dictionary_two_runs_disagree_about() {
    have_tools || { skip_case "no conda environment"; return; }
    local sb status out
    sb=$(make_pipeline_sandbox "dictionary-conflict")
    write_sandbox_config "$sb" 's|^    multiRun .*|    multiRun        = true|'
    cat > "$sb/main/runs.csv" <<'TABLE'
RunID,snpEff.buildOptions
a,
b,-gff3 -v
TABLE
    status=$(run_pipeline "$sb")
    out=$(cat "$sb/run.out")

    assert_status 1 "$status" "a disagreement about a shared dictionary should stop the run"
    assert_contains "$out" "build their dictionaries in the same place but disagree" \
        "and should say what the problem is"
    assert_contains "$out" "snpEff.buildOptions" "naming the parameter they disagree about"
    assert_contains "$out" "'a' and 'b'" "and the two runs involved"
    assert_contains "$out" "completed=0" "nothing should have been computed before it stopped"
}

# The cohort completeness guard. bcftools calls whatever samples it is handed and writes a VCF
# that looks entirely normal with a column missing, so a short cohort is a wrong ANSWER rather
# than a failure - and no later step could detect it. Checked at the gather point, where the
# number of samples the run started with is still known.
test_variant_calling_refuses_a_short_cohort() {
    have_tools || { skip_case "no conda environment"; return; }
    local sb status out
    sb=$(make_pipeline_sandbox "short-cohort")
    write_sandbox_config "$sb"
    status=$(run_multirun_guards "$sb")
    out=$(cat "$sb/run.out")

    assert_status 1 "$status" "a short cohort should stop the run"
    assert_contains "$out" "received 3 ready BAM(s) but the run started with 4" \
        "and should say how many it expected"
    assert_contains "$out" "s1, s2, s3" "and which samples it did get"

    # Beside it, because the same entry script proves it: two runs that agree about their
    # dictionary share one build rather than racing for it.
    assert_contains "$out" "GROUPS 1" "runs that agree should share a single dictionary build"
}

# THE TERMINAL RUN-COMPLETENESS ASSERTION.
#
# Nothing else in the pipeline counts runs. Every fan-back the variant expansions replaced was
# a join, and a join drops an unmatched key silently: the run produces no VCF, no tables and no
# promotion for that run, and reports SUCCESS. An expansion cannot drop a run - but the whole
# reason this check exists is that if it ever did, nothing would say so.
#
# Exercised against a channel one variant short, through the same operators and the same
# function the entry point uses. What is asserted is both halves: that the run FAILS, and that
# it says which run went missing - an exception thrown inside an operator closure reaches
# Nextflow wrapped in an InvocationTargetException whose own message is null, so a guard that
# only threw would fail the run with "Unexpected error" and a line number.
test_a_run_that_produces_nothing_fails_the_invocation() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out
    sb=$(multirun_sandbox "run-completeness" 'RunID,vcffilter.minDP
r1,4
r2,6
')
    status=$(run_completeness_guard "$sb")
    out=$(cat "$sb/run.out")

    assert_status 1 "$status" "a missing run should stop the invocation; see $sb/run.out"
    assert_contains "$out" "produced no frequency tables for: r1" "and should name it"
    assert_contains "$out" "must reach the end" "and say why that is fatal"
}

# THE SAME GUARD, AFTER THE SHARED BAMs HAVE BEEN PROMOTED - and this is the case that was
# actually broken between E1x and E1y.
#
# Once several runs share step 4, the ready BAMs are promoted to the GROUP's directory:
# Output/All_Runs/Ready, which appears in no member's own Output/ and in no member's own
# Utilized_. So the two roots the guard probed - the run's Output and the working root the
# analysis handed it - were both empty on every invocation after the first promotion, the
# no-BAMs-and-no-VCF branch fired, and an edited metadata.csv was adopted as the baseline for
# BAMs still carrying the old tags. Exit 0, PASS, and nothing later could detect it.
#
# The guard is now keyed to the step-6 variant and probes that variant's directories on both
# volumes, which is why this test asserts the pre-fix roots are empty: without that, an
# implementation that quietly went back to looking at the run's own tree would still pass.
test_a_metadata_edit_is_caught_after_a_shared_bam_is_promoted() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report before after stored
    # Two runs that diverge at step 7, so they share the called VCF and everything under it.
    sb=$(multirun_sandbox "metadata-shared" 'RunID,vcffilter.minQUAL
early,30
late,1000
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "the first pass should record a baseline; see $sb/run.out"

    stored="$sb/store/Output/All_Runs/.poolseqflow_metadata"
    assert_file "$stored" "the baseline belongs in the directory holding the VCF it describes"
    before=$(md5sum < "$stored")

    # The promoted shared BAM. Existence is all the guard tests, so an empty file will do.
    mkdir -p "$sb/store/Output/All_Runs/Ready"
    : > "$sb/store/Output/All_Runs/Ready/TestSample1_ready.bam"

    # ...and it is in neither place the guard used to look.
    local run
    for run in early late; do
        [ -e "$sb/store/Output/$run/Ready" ] \
            && fail_case "$run's own Output should hold no ready BAMs - that is the whole case"
    done
    [ -n "$(find "$sb/main" -path '*Utilized*/Ready/*' -print -quit 2>/dev/null)" ] \
        && fail_case "no working root should hold a ready BAM either"

    sed -i '2s/,/_EDITED,/2' "$sb/main/metadata.csv"

    status=$(run_verify_only "$sb")
    report=$(cat "$sb/store/Output/early/Reports/0_verify_environment.txt")

    assert_status 1 "$status" "an edit against promoted shared BAMs should fail the run"
    assert_contains "$report" "METADATA CHANGE CHECK: FAIL" "the change should be reported"
    assert_contains "$report" "$sb/store/Output/All_Runs/Ready" \
        "and should name the group's directory as where the old tags are"

    after=$(md5sum < "$stored")
    assert_eq "$before" "$after" \
        "the stored baseline must not be overwritten - doing so hides the mismatch for good"
}

# A Shared_<N> NAME CAN COME TO MEAN A DIFFERENT GROUP, and a plain manifest diff cannot see it.
#
# The number is assigned in order of appearance, so editing the table can leave Shared_1
# describing two different runs than the ones whose results are already in it. The manifest
# would then be compared against a directory built for somebody else, and the answer - some
# parameters added, some removed - reads as an edit to parameters.config and is not one. It also
# wants the opposite advice: `reset` throws the whole analysis away, when what is stale is one
# directory.
#
# The stored copy of the table sees it directly: the edit that moved the boundary IS the change,
# so there is nothing to infer from a member list and no separate check to build. That is what
# Z\'s "copy the files and compare them" buys over anything derived - this case cost a whole
# extra process under the per-directory manifest, and costs nothing here.
test_a_regrouped_shared_directory_is_refused() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report members
    # a and b agree at step 7, c does not - so Shared_1 is {a, b}.
    sb=$(multirun_sandbox "regrouped" 'RunID,vcffilter.minQUAL
a,30
b,30
c,1000
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "the first pass should pass; see $sb/run.out"
    members="$sb/store/Output/Shared_1/members.txt"
    assert_eq "a
b" "$(cat "$members" 2>/dev/null)" "Shared_1 should record the pair that formed it"

    # Move the boundary: now b agrees with c instead, so Shared_1 is {b, c} - the same
    # directory, the same name, a different group.
    printf 'RunID,vcffilter.minQUAL\na,30\nb,1000\nc,1000\n' > "$sb/main/runs.csv"
    status=$(run_verify_only "$sb")
    report=$(cat "$sb/store/Output/a/Reports/0_verify_environment.txt")

    assert_status 1 "$status" "a table edit that regroups a shared directory should stop the run"
    assert_contains "$report" "runs.csv has CHANGED" "naming the file that moved"
    assert_contains "$report" "now  b,1000" "and the row that moved the boundary"
    assert_contains "$report" "can also move work between directories" \
        "and saying that a regrouping is what makes this one matter"

    # members.txt is a RECORD and is rewritten every run, so it now names the new grouping.
    # What must not move is the stored table: adopting it would clear the failure.
    assert_eq "b
c" "$(cat "$members" 2>/dev/null)" "the members file follows the grouping the plan describes"
    assert_contains "$(cat "$sb/store/Output/.multirun.csv")" "b,30" \
        "while the stored table still holds what produced the results, so the failure repeats"
}

# WHAT STEP 7 FILTERS WITH HAS TO BE IN STEP 7'S IDENTITY, and poolSize was not.
#
# The filter derives each pool's threshold from poolSize and diploidy, and a pool whose
# param_poolSize cell is blank takes the run's own poolSize. Only the derived sensitivity stood
# for it in the identity, so a project pinning sensitivity by hand made two runs of different
# pool sizes agree at step 7 and share one results directory - which then held one run's tables
# filtered at the other's thresholds, with nothing in the folder saying so.
test_a_pinned_sensitivity_does_not_merge_runs_of_different_pool_sizes() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report
    sb=$(multirun_sandbox "pinned-sensitivity" 'RunID,poolSize,filterFalsePositives.sensitivity
small,100,0.0025
large,200,0.0025
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "pinning a derived value is allowed; see $sb/run.out"
    report=$(cat "$sb/store/Output/small/Reports/0_verify_environment.txt")

    assert_contains "$report" "small belongs to small alone" \
        "the run whose pools are one size filters for itself"
    assert_contains "$report" "large belongs to large alone" "and so does the other"
    assert_no_file "$sb/store/Output/Shared_1/Frequencies" \
        "and neither writes its tables into what they share"
}

# A PER-SAMPLE CAP THAT DIVIDES NOTHING IS A WRONG NUMBER, NOT AN ERROR.
#
# param_capMaxDepth is listed in metadataColumnsPerStep()[5], but a column listed there reaches
# the variant key only through a stepIdentity() branch, and step 5 has none of its own. Without
# one the column is accepted from the user, compared by the change guard, and still divides
# nothing - so two runs whose only difference is one sample's cap share a step-6 variant and
# therefore one VCF, called at whichever cap happened to arrive first.
#
# Two runs over the same reads and the same reference, differing only in a metadata file that
# caps one sample. Everything before the cap is decided is still shared; step 5 onward is not.
test_a_per_sample_cap_splits_the_runs_that_disagree() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report
    sb=$(multirun_sandbox "per-sample-cap" 'RunID,metadataFile
plain,metadata.csv
capped,metadata_capped.csv
')
    # The same rows in the same order, with a cap on one sample. Only the new column moves:
    # metadataProjection renders a column that is not in the file as an empty value, so steps
    # 2, 4 and 7 see the two files as identical.
    awk -F, -v OFS=, 'NR==1 { print $0, "param_capMaxDepth"; next }
                      { print $0, ($1 == "TestSample3" ? 500 : "") }' \
        "$sb/main/metadata.csv" > "$sb/main/metadata_capped.csv"

    status=$(run_verify_only "$sb")
    report=$(cat "$sb/store/Output/plain/Reports/0_verify_environment.txt")

    assert_status 0 "$status" "the table should pass step 0; see $sb/run.out"
    assert_contains "$report" "All_Runs is a shared directory" \
        "the reads, the alignments and the ready BAMs are the same either way"
    assert_contains "$report" "plain belongs to plain alone" \
        "a run whose caps differ needs its own VCF"
    assert_contains "$report" "steps 5, 6, 7, 8" \
        "the split has to start where the cap is decided and carry the VCF with it"
    assert_not_contains "$report" "identical at every step" \
        "a cap that divides nothing would leave the two runs sharing one VCF"
}

# THE REPRODUCIBILITY RULE. Z, 2026-08-28: *"the parameter file being the same with what it was
# in the beginning and the parameters that are set for each run being kept as they are."*
#
# The two files the user wrote are copied beside the results and compared, so a run cannot change
# its own settings whatever it shares. E1y briefly recorded what each RESULTS DIRECTORY's members
# AGREE about instead, and under that rule this test passes at step 2 and the run continues: the
# three runs share one directory, so changing one of them left every recorded value untouched.
test_a_run_may_not_change_its_own_parameters_even_when_it_shares_everything() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report
    sb=$(multirun_sandbox "reproducibility" 'RunID,poolSize
a,
b,
c,
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "three identical runs should pass; see $sb/run.out"
    assert_file "$sb/store/Output/.multirun.csv" "the table should be kept beside the results"

    # One cell, for one run, and nothing in parameters.config.
    printf 'RunID,poolSize\na,\nb,\nc,25\n' > "$sb/main/runs.csv"
    status=$(run_verify_only "$sb")
    report=$(cat "$sb/store/Output/a/Reports/0_verify_environment.txt")

    assert_status 1 "$status" "a run changing its own parameters must stop the run"
    assert_contains "$report" "runs.csv has CHANGED" "naming the file that moved"
    assert_contains "$report" "was  c," "and the row it was"
    assert_contains "$report" "now  c,25" "and the row it is now"
    assert_contains "$report" "parameters.config unchanged" "while the other file is untouched"

    assert_eq "$(printf 'RunID,poolSize\na,\nb,\nc,')" "$(cat "$sb/store/Output/.multirun.csv")" \
        "the stored table must not be adopted, or the failure would clear itself"
}

# The same rule against Z's own example: the references are permuted between runs. Every value
# that appears in the table still appears in it, and every run still has a different one from its
# neighbours - so nothing about the SET of parameters changed, only which run holds which.
test_permuting_a_column_between_runs_stops_the_run() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status report
    sb=$(multirun_sandbox "permuted" 'RunID,poolSize
a,50
b,100
c,200
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "three differing runs should pass the first time; see $sb/run.out"

    printf 'RunID,poolSize\na,200\nb,50\nc,100\n' > "$sb/main/runs.csv"
    status=$(run_verify_only "$sb")
    report=$(cat "$sb/store/Output/a/Reports/0_verify_environment.txt")

    assert_status 1 "$status" "the same values in a different order are still a change"
    assert_contains "$report" "was  a,50"  "for the run that held the old value"
    assert_contains "$report" "now  a,200" "and now holds another run\'s"
}
