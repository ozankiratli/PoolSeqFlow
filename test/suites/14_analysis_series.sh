#!/bin/bash
# Series, units and conditions: which pools are one thing measured repeatedly.
# cost: jvm
# covers: analysis/lib/nf/design.nf analysis/lib/nf/time.nf
# covers: analysis.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# ---------------------------------------------------------------------------------------
# Series: which pools are one thing measured repeatedly.
test_two_pools_at_one_timepoint_in_one_series_refuse() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,T1
TestSample2,PoolB,Pop1,T1'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a series has to be a function of time"
    local out; out=$(analysis_output)
    assert_contains "$out" "2 pools at the same exp_time" "the refusal counts them"
    assert_contains "$out" "'T1': PoolA, PoolB" "and names the timepoint and the pools"
}

test_a_series_key_naming_the_time_column_refuses() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }
        series { by = ['exp_time'] }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "time cannot identify what is being followed through time"
    assert_contains "$(analysis_output)" "which is the time column" "and the refusal says so"
}

# A ragged panel analysed as a complete one is a wrong answer that looks like a right one.
test_an_incomplete_series_refuses_by_default() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,T1
TestSample2,PoolB,Pop1,T2
TestSample3,PoolC,Pop2,T1'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "fail is the default and this panel is ragged"
    local out; out=$(analysis_output)
    assert_contains "$out" "Pop2 lacks T2" "naming the series and what it lacks"
    assert_contains "$out" "analysis.series.incomplete" "and the setting that decides what to do"
}

test_drop_leaves_the_incomplete_series_out() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,T1
TestSample2,PoolB,Pop1,T2
TestSample3,PoolC,Pop2,T1'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }
        series { incomplete = 'drop' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "drop should proceed on what is complete"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "1 series over 2 timepoints" "one series survives"
    assert_contains "$report" "Pop2 lacked T2" "and the note says what went and why"
}

# keepLeft cuts the timeline back from the start, keepRight from the end, and on a panel with a
# hole in the middle BOTH work and they discard different data. The choice is early drift
# against late response, not a mechanical one.
test_keepleft_and_keepright_cut_the_timeline_from_opposite_ends() {
    local metadata='SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,1
TestSample2,PoolB,Pop1,2
TestSample3,PoolC,Pop1,3
TestSample4,PoolD,Pop2,1
TestSample5,PoolE,Pop2,2'

    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$metadata"
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'numerical'; unit = 'generation' }
        series { incomplete = 'keepLeft' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "keepLeft should keep the shared start"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "2 series over 2 timepoints" "both series survive, shortened"
    assert_contains "$report" "kept 1, 2; dropped 3" "and the note says exactly what went"

    # The same panel from the other end: Pop2 has no third point, so there is no shared suffix.
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$metadata"
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'numerical'; unit = 'generation' }
        series { incomplete = 'keepRight' }"
    status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "keepRight has nothing to keep here"
    assert_contains "$(analysis_output)" "Try 'keepLeft'" "and the refusal points at the one that would work"
}

# Truncating to a single point leaves a legal-looking analysis with no time axis at all.
test_a_truncation_to_one_timepoint_is_reported_loudly() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,1
TestSample2,PoolB,Pop1,2
TestSample3,PoolC,Pop1,3
TestSample4,PoolD,Pop2,1'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'numerical'; unit = 'generation' }
        series { incomplete = 'keepLeft' }"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "SINGLE point" \
        "a one-point timeline has to be stated, not left to look like an analysis"
}

# A pool with no time value joins no series. Reported and counted; whether that is fatal is the
# module's to decide, because a sound project can legitimately have one.
test_a_pool_with_no_time_value_is_counted_and_excluded() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,T1
TestSample2,PoolB,Pop1,T2
TestSample3,PoolC,Pop2,'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a pool without a timepoint is not an error"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "have no exp_time and are in no series: PoolC" \
        "but it is named"
}

# Nextflow REPLACES a nested map rather than merging into it, so a project writing one sub-key
# would lose every other default in the scope - and fail as "no time column" on a project that
# plainly has one.
test_a_partly_written_scope_keeps_the_rest_of_its_defaults() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "column should still default to exp_time"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "TIME VARIABLE:         exp_time, categorical" \
        "the default column survives a scope that set only the kind"
}

test_an_unknown_key_in_a_nested_scope_refuses() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; ordering = ['T1'] }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a misspelled sub-key must not be ignored"
    local out; out=$(analysis_output)
    assert_contains "$out" "does not have: ordering" "the refusal names the key"
    assert_contains "$out" "column, format, kind, locale, order, unit" "and lists the ones it has"
}

# Both lists take more than one column. Lane and sequencing run are two technical dimensions of
# one biological unit, and the unit is what a module counts.
test_technical_replicates_roll_up_into_independent_units() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_REPLICATE_METADATA"
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; order = ['T1', 'T2'] }
        series {
            biologicalRep = ['exp_rep']
            technicalRep  = ['exp_lane', 'exp_seqrun']
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a crossed technical design should resolve"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "SERIES:                technical    exp_lane, exp_seqrun" \
        "both technical dimensions are named"
    assert_contains "$report" "8 series over 2 timepoints, from 2 independent units" \
        "16 pools make 8 series, and dropping both technical columns leaves 2 units"
    assert_contains "$report" "1 condition, 2 biological replicates each, 4 technical" \
        "counted per unit, since 2 lanes by 2 runs is 4 and not 2"
}

# THE MISASSIGNMENT NOTHING CAN CATCH. Leave a technical column out of technicalRep and it is
# read as a condition - one treatment becomes four, and a test gets strata that are the same
# DNA. So every key column is printed under a role, which is the only defence there is.
test_every_key_column_is_printed_under_a_role() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_REPLICATE_METADATA"
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; order = ['T1', 'T2'] }
        series {
            biologicalRep = ['exp_rep']
            technicalRep  = ['exp_lane']
        }"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "SERIES:                conditions   exp_treatment, exp_seqrun" \
        "the forgotten column shows up as a condition, where it can be seen"
    assert_contains "$report" "2 conditions" "and the count it produces is visible beside it"
}

test_a_replicate_column_outside_the_series_key_refuses() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; order = ['T1', 'T2'] }
        series { biologicalRep = ['exp_cage'] }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "naming a column that identifies nothing must stop the run"
    assert_contains "$(analysis_output)" "which does not identify a series" \
        "and the refusal says what the key actually holds"
}

# A column is independent or it is not; it cannot be both, and the difference is what degrees of
# freedom are counted from.
test_a_column_named_as_both_kinds_of_replicate_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_REPLICATE_METADATA"
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; order = ['T1', 'T2'] }
        series {
            biologicalRep = ['exp_rep', 'exp_lane']
            technicalRep  = ['exp_lane']
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "one column cannot be both kinds of replicate"
    assert_contains "$(analysis_output)" "carry degrees of freedom; technical replicates" \
        "and the refusal says what the difference is"
}

# Technical replication is legitimately unbalanced - one sample sequenced twice for validation
# and another once - so a single number would be a plausible-looking lie.
test_an_unbalanced_technical_design_is_reported_as_a_range() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_treatment,exp_rep,exp_lane,exp_time
S1,P1,control,1,L1,T1
S2,P2,control,1,L1,T2
S3,P3,control,1,L2,T1
S4,P4,control,1,L2,T2
S5,P5,control,2,L1,T1
S6,P6,control,2,L1,T2'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; order = ['T1', 'T2'] }
        series {
            biologicalRep = ['exp_rep']
            technicalRep  = ['exp_lane']
        }"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "1-2 technical" \
        "one unit was sequenced twice and the other once"
}

# The same-key-same-timepoint refusal is ambiguous between the two remedies, and offering only
# one of them is wrong half the time: technical replicates that were meant to be merged belong
# under one RG_Sample, not in a new exp_ column.
test_the_duplicate_pool_refusal_offers_both_remedies() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,T1
TestSample2,PoolB,Pop1,T1'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "two pools at one point is still a refusal"
    local out; out=$(analysis_output)
    assert_contains "$out" "analysis.series.biologicalRep or technicalRep" \
        "one remedy is to tell them apart and declare what they are"
    assert_contains "$out" "give the rows the same" \
        "and the other is to merge them, which is the pipeline's job and not a series"
}
