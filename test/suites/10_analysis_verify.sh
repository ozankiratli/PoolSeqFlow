#!/bin/bash
# Verification: what the frame checks before a module reads anything.
# cost: jvm
# covers: analysis/0_verify_analysis.nf analysis/lib/nf/citations.nf
# covers: analysis.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# ---------------------------------------------------------------------------------------
# Verification against a real project.
test_verify_passes_on_a_recorded_single_run_project() {
    analysis_ready single || return
    local status report
    status=$(run_analysis "$ANALYSIS_SB" verify)
    report=$(analysis_report "$ANALYSIS_SB")
    assert_status 0 "$status" "an unchanged project should verify"
    assert_contains "$report" "ANALYSIS VERIFICATION: SUCCESS" "and say so"
    assert_contains "$report" "parameters.config unchanged since the results were produced" \
        "the identity check should pass"
    assert_contains "$report" "single run - one results directory" \
        "a single run has no run names"
}

# The report says where the settings came from, and where a project's own would go.
test_verify_names_the_configuration_it_was_assembled_from() {
    analysis_ready single || return
    # The baseline carries an analysis.config because its metadata has a time column. Both go,
    # so this is a project that has written no settings at all.
    rm -f "$ANALYSIS_SB/main/analysis.config"
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population
TestSample1,TestSample1,Pop1'
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "analysis/frame.config" "the installation's frame"
    assert_contains "$report" "this project has no analysis.config" \
        "and that this project has none of its own"
    assert_contains "$report" "analysis/analysis.config.template" "naming what to copy"
}

test_a_project_with_no_results_refuses() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status
    sb=$(make_pipeline_sandbox "analysis-empty")
    write_sandbox_config "$sb"
    analysis_write_time_config "$sb"
    status=$(run_analysis "$sb" verify)
    assert_status 1 "$status" "there is nothing to analyse"
    local report; report=$(analysis_report "$sb")
    assert_contains "$report" "No results recorded in" "should say the project has none"
    assert_contains "$report" "PoolSeqFlow run" "and how to produce some"
}

# A project belongs to one release, and so do the tables in it: what a column means is the
# release's, so a module of one release reading another's results does not know what it has.
test_results_from_another_release_refuse() {
    analysis_ready single || return
    printf '2.1.0\t2026-01-01\n' > "$ANALYSIS_SB/store/Output/.poolseqflow_version"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "another release's results must stop the run"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "produced by PoolSeqFlow 2.1.0" "naming the release that made them"
    assert_contains "$report" "STATUS=FAIL" "the stage should record a failure"
}

# The guard that matters most: a module reads the tables and the settings together, so a
# parameter that has moved since the results were produced makes the analysis describe a run
# that never happened.
test_changed_parameters_refuse_and_name_what_moved() {
    analysis_ready single || return
    write_sandbox_config "$ANALYSIS_SB" 's|^    poolSize .*|    poolSize        = 250|'
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a changed setting must stop the run"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "parameters.config has CHANGED" "should name the file"
    assert_contains "$report" "poolSize" "and the parameter"
    assert_contains "$report" "was  100" "with the recorded value"
    assert_contains "$report" "now  250" "and the new one"
    # poolSize feeds it, so the guard catches the consequence as well as the cause.
    assert_contains "$report" "filterFalsePositives.sensitivity" \
        "and what the change re-derived"
}

# ---------------------------------------------------------------------------------------
# Against published results.
test_verify_counts_what_the_pipeline_published() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a project with results should verify"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "frequency tables   2" "the SNP and INDEL tables"
    assert_contains "$report" "depth tables       2" "and the depths beside them"
    assert_contains "$report" "ready BAMs         6" "one per sample"
    assert_contains "$report" "called VCF         1" "and the cohort's VCF"
    # The one class that does not sit at a top-level dir.output key. It is reached through
    # dir.output.report.depth, so a lookup that cannot follow a dotted name reports it MISSING.
    assert_contains "$report" "depth histograms   6" "the step 5 histograms, one per sample"
}

# The pipeline's dag, trace, timeline and report are the record of the run that produced
# these results. An analysis run writes four of its own and must not land on them - which it
# would, because they are named in nextflow.config and that is read by both entry points.
test_an_analysis_run_leaves_the_pipeline_session_reports_alone() {
    analysis_ready single || return
    analysis_plant_session_reports "$ANALYSIS_SB/store/Output"
    local reports before after
    reports="$ANALYSIS_SB/store/Output/Reports"
    before=$(md5sum "$reports"/PoolSeqFlow_pipeline_* 2>/dev/null | sort)
    [ -n "$before" ] || { fail_case "no session reports were planted to check"; return; }

    run_analysis "$ANALYSIS_SB" verify > /dev/null
    after=$(md5sum "$reports"/PoolSeqFlow_pipeline_* 2>/dev/null | sort)
    assert_eq "$before" "$after" "the pipeline's session reports must be untouched"
    assert_file "$ANALYSIS_SB/main/Analysis/Session/PoolSeqFlow_analysis_trace.txt" \
        "the analysis run keeps its own trace under Analysis/Session"
}
