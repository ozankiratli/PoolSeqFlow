#!/bin/bash
# Which results an invocation covers, and which directory each lands in.
# cost: jvm
# covers: analysis/lib/nf/plan.nf
# covers: analysis.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# ---------------------------------------------------------------------------------------
# Which results an invocation covers.
test_every_run_maps_onto_its_own_results_directory() {
    analysis_ready multi || return
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the default selection should verify"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "analysis.runs = 'all'" "the default is every run"
    assert_contains "$report" "3 of 3 runs, in 2 results directories" \
        "three runs producing two sets of tables"
    assert_contains "$report" "selected: lenient_a, lenient_b" "the two that share a directory"
    assert_contains "$report" "selected: strict" "and the one that does not"
}

# Naming one run reaches a directory that also holds another's results, and the report has to
# say so - the analysis is of the directory, not of the run.
test_selecting_one_run_names_the_others_sharing_its_directory() {
    analysis_ready multi || return
    analysis_select "'lenient_a'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "selecting one run should verify"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "1 of 3 runs, in 1 results directory" "one directory covered"
    assert_contains "$report" "selected: lenient_a" "the run that was asked for"
    assert_contains "$report" "also the results of lenient_b" "and the one that was not"
    assert_not_contains "$report" "selected: strict" "the run not selected is not covered"
}

test_selecting_several_runs_covers_each_directory_once() {
    analysis_ready multi || return
    analysis_select "['lenient_a', 'lenient_b']"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "2 of 3 runs, in 1 results directory" \
        "two runs sharing a directory are analysed once"
    # The label lines only. What sits under a directory is indented further, and a plain
    # substring match counts those too.
    assert_count 1 "$(printf '%s\n' "$report" | grep -cE '^RUN SELECTION: {13}[^ ]')" \
        "one directory should be listed"
}

test_selecting_a_run_that_is_not_in_the_table_refuses() {
    analysis_ready multi || return
    analysis_select "['lenient_a', 'nope']"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "an unknown run name must stop the run"
    assert_contains "$(analysis_output)" "does not: nope" "naming what it could not find"
    assert_contains "$(analysis_output)" "lenient_a, lenient_b, strict" \
        "and listing the runs there are"
}

test_an_empty_selection_refuses() {
    analysis_ready multi || return
    analysis_select "[]"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "selecting nothing must stop the run"
    assert_contains "$(analysis_output)" "empty list, so it selects nothing" "and say so"
}

# A single run has no name anywhere - not in a directory, not in the table there isn't - so a
# selection naming one is a misunderstanding worth refusing rather than ignoring.
test_a_single_run_project_refuses_a_named_run() {
    analysis_ready single || return
    analysis_select "'lenient_a'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "there are no run names to select"
    assert_contains "$(analysis_output)" "this project is a single run" "should say why"
    assert_contains "$(analysis_output)" "multiRun = false" "and where that is decided"
}
