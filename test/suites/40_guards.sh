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
    cp -r "$GUARD_SB/main/Data" "$GUARD_SB/main/OtherData"
    write_sandbox_config "$GUARD_SB" "s|^    dataSource .*|    dataSource      = 'OtherData'|"
    local status report
    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)
    assert_status 1 "$status" "a different dataSource should fail against existing outputs"
    assert_contains "$report" "dataSource" "should name dataSource as the difference"
}

# The RGTags guard has to look on BOTH volumes, and this is the case that shows why it is not
# a cosmetic point.
#
# Everywhere else in this pipeline a wrong answer to "does this artifact exist" costs redundant
# work. Here it costs the guard itself: the branch that fires when there are no BAMs and no VCF
# reads the situation as "nothing has consumed RGTags.csv yet, so an edit is free" and RECORDS A
# NEW BASELINE. From 3.0 the cleaned BAMs live on the working volume until both of their
# consumers are done, so a run interrupted between cleaning and calling leaves exactly that
# state - and a guard that only looked in permanent storage would adopt an edited RGTags.csv as
# the baseline for BAMs that carry the old tags. Nothing later could detect it, because the
# baseline would now say they agree.
#
# The assertion that matters is the second one. Failing the run is the visible half; leaving the
# stored baseline alone is the half that keeps the next run honest.
test_an_rgtags_edit_is_caught_when_the_bams_are_not_yet_promoted() {
    guards_ready || return
    local before after status report

    before=$(md5sum < "$GUARD_SB/store/.poolseqflow_rgtags")

    # Cleaned but not yet promoted: on the working volume, absent from permanent storage.
    # Existence is all the guard tests, so an empty file stands in for the BAM.
    mkdir -p "$GUARD_SB/main/Utilized/Ready"
    : > "$GUARD_SB/main/Utilized/Ready/TestSample1_ready.bam"
    [ -e "$GUARD_SB/store/Output/Ready" ] && fail_case "storage should hold no ready BAMs for this case"

    # Change a tag value, which is the kind of edit that invalidates the BAMs.
    sed -i '2s/,/_EDITED,/2' "$GUARD_SB/main/RGTags.csv"

    status=$(run_verify_only "$GUARD_SB")
    report=$(guard_report)

    assert_status 1 "$status" "an edit against unpromoted BAMs should fail the run"
    assert_contains "$report" "RGTAGS CHANGE CHECK:   FAIL" "the change should be reported"

    after=$(md5sum < "$GUARD_SB/store/.poolseqflow_rgtags")
    assert_eq "$before" "$after" \
        "the stored baseline must not be overwritten - doing so hides the mismatch for good"
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
RunID,referenceFile,gffFile,trim_galore.quality,bcftools.mpileupOptions
refA,reference.fasta.gz,reference.gff.gz,,
refB,reference.fasta.gz,reference.gff.gz,30,"-B -C 50 -q 30 -Q 30 -d 4000 -a AD,DP,SP,INFO/AD -Ou"
')
    status=$(run_verify_only "$sb")
    assert_status 0 "$status" "a valid table should pass step 0; see $sb/run.out"
    # Under multiRun each run publishes its own report under its own storageDir - there is no
    # longer one at the base. The multi-run stage describes the whole invocation, so its
    # section is the same in every run's copy; refA's is read here because one of them has to
    # be.
    report=$(cat "$sb/store/refA/Output/Reports/0_verify_environment.txt")

    assert_contains "$report" "2 runs"      "the run count should be reported"
    assert_contains "$report" "refA -> $sb/store/refA" "each run's storageDir should be named"
    assert_contains "$report" "refB -> $sb/store/refB" "and defaulted from RunID"
    assert_contains "$report" "trim_galore.quality = 30" "what differs should be listed"

    # A blank cell means inherit, so it must not be reported as something refA sets.
    assert_not_contains "$report" "refA
MULTI-RUN CHECK:           trim_galore.quality" "a blank cell is not an override"

    # Pinning a derived value is allowed and is why there is no column whitelist - but it
    # detaches that value from whatever it was computed from, which is worth saying once
    # here rather than leaving someone to find it in a result months later.
    assert_contains "$report" "replace a value the pipeline would compute" \
        "an override of a derived parameter should be called out"
    assert_contains "$report" "bcftools.mpileupOptions" "by name"

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
RunID,poolSize,trim_galore.quality,bcftools.maxDepth,bcftools.mpileupOptions,threads,referenceFile
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
    assert_contains "$out" "RUN depth bcftools.mpileupOptions=-B -C 50 -q 30 -Q 30 -d 4000 -a AD,DP,SP,INFO/AD -Ou" \
        "bcftools.maxDepth must re-derive mpileupOptions"

    # A row setting a DERIVED value directly wins, even against its own input in the same row.
    # This is why the row is applied twice, and why there is no column whitelist.
    assert_contains "$out" "RUN pinned bcftools.mpileupOptions=-B -C 50 -q 30 -Q 30 -d 999 -a AD,DP,SP,INFO/AD -Ou" \
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
    assert_contains "$out" "RUN pool storageDir=$sb/store/pool"        "each run gets its own storage"
    assert_contains "$out" "RUN pool dir.utilized=$sb/main/Utilized_pool" "and its own working tree"
    assert_contains "$out" "RUN pool dir.output.vcf=$sb/store/pool/Output/VCF" "with the tree hung off it"
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
