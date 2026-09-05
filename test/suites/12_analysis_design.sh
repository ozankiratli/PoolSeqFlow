#!/bin/bash
# The experimental design, and the pools every frequency is read against.
# cost: jvm
# covers: analysis/lib/nf/design.nf analysis/lib/nf/pools.nf
# covers: analysis.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# EVERY analysis records the design the project was in, so a project whose design contradicts
# itself publishes nothing - not only the analyses that read one. The refusal is at DAG-build,
# ahead of the identity check, so it is what a case sees even when it has also moved the
# metadata the guard watches.
test_a_pool_whose_rows_disagree_on_an_experimental_column_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_time
TestSample1,PoolA,T1
TestSample2,PoolA,T2'
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "one pool with two timepoints is not a design"
    local out; out=$(analysis_output)
    assert_contains "$out" "the pool 'PoolA' is given more than one exp_time" \
        "the refusal names the column and the pool"
    assert_contains "$out" "'T1' on TestSample1" "and which row said what"
    assert_contains "$out" "'T2' on TestSample2" "for both of them"
    assert_contains "$out" "is not an experimental variable" \
        "and tells the user what belongs in an unprefixed column instead"
}

# A blank cell means no value, which is a third answer rather than agreement with either - the
# same rule param_poolSize follows.
test_a_blank_experimental_cell_is_a_disagreement() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_treatment
TestSample1,PoolA,control
TestSample2,PoolA,'
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a blank cell must not pass as agreement"
    assert_contains "$(analysis_output)" "'(blank)' on TestSample2" \
        "and the refusal says which row left it empty"
}

# exp_ columns refine no step's identity, so two runs reading DIFFERENT metadata files still
# produce the same tables and share one results directory. The check runs across a target's
# members for exactly that reason: neither file disagrees with itself.
test_two_runs_sharing_a_directory_are_checked_against_each_other() {
    analysis_ready multi || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_time
TestSample1,PoolA,T1'
    printf '%s\n' 'SampleID,RG_Sample,exp_time' 'TestSample1,PoolA,T2' \
        > "$ANALYSIS_SB/main/metadata_b.csv"
    cat > "$ANALYSIS_SB/main/runs.csv" <<'TABLE'
RunID,annotate,metadataFile
lenient_a,true,metadata.csv
lenient_b,true,metadata_b.csv
TABLE
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "two runs in one directory must agree about the pool they share"
    local out; out=$(analysis_output)
    assert_contains "$out" "the pool 'PoolA' is given more than one exp_time" \
        "even though neither file disagrees with itself"
}

test_the_verification_report_states_the_design() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the fixture's design is consistent"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "EXPERIMENTAL DESIGN:       6 pools from 6 libraries" \
        "the report counts the pools and the libraries merged into them"
    assert_contains "$report" "exp_population (3 levels), exp_time (2 levels)" \
        "and names each variable with how many levels it has"
    assert_contains "$report" "TIME VARIABLE:         exp_time, categorical" \
        "and says how the time axis was read"
    assert_contains "$report" "SERIES:                conditions   exp_population" \
        "and what a repeated measurement is"
    assert_contains "$report" "SERIES:                biological   (none declared)" \
        "with every key column placed under a role, declared or not"
    assert_contains "$report" "3 series over 2 timepoints" "and the shape it found"
}

# A project with no exp_ columns and one whose metadata was never copied both have no design,
# and they are not the same thing - the second is a project set up somewhere the CSV is not.
test_the_report_tells_no_design_from_no_metadata() {
    analysis_ready single || return
    rm -f "$ANALYSIS_SB/main/analysis.config"
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,population
TestSample1,PoolA,Pop1'
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "1 pools from 1 libraries, no exp_ columns" \
        "an unprefixed column is not an experimental variable"
    assert_contains "$report" "TIME VARIABLE:         none" \
        "and with no time column nothing is a trajectory"

    analysis_ready single || return
    rm -f "$ANALYSIS_SB/main/metadata.csv" "$ANALYSIS_SB/main/analysis.config"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "no metadata rows" \
        "and a missing file says so rather than reporting an empty design"
}

# ---------------------------------------------------------------------------------------
# The pools, which every frequency in a published table is read against. A module gets these
# off its target: poolSizes() and ploidy live in the pipeline's scripts, which a module does
# not import.
#
# The detection limits below are hand-computed from 1/(2*ploidy*poolSize), which is a third
# copy of the equation - the Groovy one in resolve_parameters.nf and the awk one in
# bin/filterFalsePositives.sh are tied together by 05_helpers, and these numbers tie this one
# to both.
test_the_verification_report_states_the_pool_sizes() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the fixture's pools are consistent"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "POOL SIZES:                ploidy 2, 6 pools of 100 individuals" \
        "the report gives the size every pool was filtered against"
    assert_contains "$report" "200 chromosomes, frequencies above 0.0025" \
        "with the chromosome count and the detection limit derived from it"
}

# A pool that sets param_poolSize is a different size from one that takes the global, and the
# n_chrom every diversity estimate scales by moves with it.
test_pools_of_different_sizes_are_reported_apart() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,param_poolSize,exp_population,exp_time
TestSample1,PoolA,,Pop1,T1
TestSample2,PoolB,25,Pop1,T2'
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "ploidy 2, 2 pools" "the sizes are no longer one number"
    assert_contains "$report" "PoolA: 100 individuals, 200 chromosomes, frequencies above 0.0025" \
        "the pool with a blank cell takes the run's own poolSize"
    assert_contains "$report" "PoolB: 25 individuals, 50 chromosomes, frequencies above 0.01" \
        "and the one that sets param_poolSize is measured and reported on its own"
}
