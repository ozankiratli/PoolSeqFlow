#!/bin/bash
# The time axis, and the date parsing behind it.
# cost: jvm
# covers: analysis/lib/nf/time.nf analysis/lib/nf/design.nf
# covers: analysis.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# Time is not guessed. 20240307 reads as a number as readily as a date, which keeps the order
# right and makes every interval wrong, so the kind is asked for rather than detected.
test_a_time_column_without_a_kind_refuses() {
    analysis_ready single || return
    rm -f "$ANALYSIS_SB/main/analysis.config"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a project with exp_time and no kind must stop"
    local out; out=$(analysis_output)
    assert_contains "$out" "analysis.timeVar.kind is not set" "the refusal names the setting"
    assert_contains "$out" "numerical, categorical, datetime" "and lists what it may be"
}

test_a_kind_with_no_time_column_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population
TestSample1,PoolA,Pop1'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'numerical'; unit = 'generation' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a setting that cannot apply must be refused where it is written"
    assert_contains "$(analysis_output)" "has no exp_time column" "naming the column it looked for"
}

# Anything outside the exp_ prefix escapes the pool-agreement refusal, and one pool could then
# carry two timepoints with nothing to stop it.
test_a_time_column_outside_the_prefix_refuses() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { column = 'timepoint'; kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "the time variable has to be an exp_ column"
    assert_contains "$(analysis_output)" "has to be an exp_ column" "and the refusal says why"
}

# A numerical axis is an interval scale, so a rate is meaningful and has to be labelled.
test_numerical_time_requires_a_unit() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'numerical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "numerical time with no unit must stop"
    local out; out=$(analysis_output)
    assert_contains "$out" "no unit is set" "the refusal names what is missing"
    assert_contains "$out" "generation, passage, cycle" "and lists the units it takes"
}

# A unit asserts that the spacing between levels means something, which is exactly what
# categorical time does not have.
test_a_unit_on_categorical_time_refuses() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; unit = 'generation' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a spacing categorical time does not have must not be asserted"
    assert_contains "$(analysis_output)" "categorical time is an order and nothing more" \
        "and the refusal says what to do instead"
}

# THE T10 PROBLEM. Alphabetically T10 sorts between T1 and T2, and every trajectory built on
# that order is wrong with nothing to show for it.
test_numerical_time_orders_by_number_not_by_string() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,1
TestSample2,PoolB,Pop1,10
TestSample3,PoolC,Pop1,2'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'numerical'; unit = 'generation' }
        series { by = ['exp_population'] }"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "TIME VARIABLE:         exp_time, numerical, in generations" \
        "the report says how time was read"
    assert_contains "$report" "1.0  2.0  10.0" "and 10 comes last, where a string sort puts it second"
}

# The natural-sort warning. It cannot catch pre/post - nothing can - but T1 T10 T2 buried in a
# long list is the case that slides past the eye, and two plausible orderings disagreeing is a
# fact rather than a guess.
test_alphabetical_time_warns_when_a_number_sort_disagrees() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,T1
TestSample2,PoolB,Pop1,T10
TestSample3,PoolC,Pop1,T2'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical' }"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "alphabetical order" "the note says which order was used"
    assert_contains "$report" "T1  T10  T2" "showing what that gives"
    assert_contains "$report" "T1  T2  T10" "beside what reading the digits as numbers would give"
}

test_an_explicit_order_that_misses_a_level_refuses() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'categorical'; order = ['T1'] }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a level with nowhere to go must stop the run"
    assert_contains "$(analysis_output)" "does not include 'T2'" "naming the level it left out"
}

# ---------------------------------------------------------------------------------------
# Dates. The parser configuration was measured rather than assumed; each of these is one of
# the measurements.
test_datetime_time_parses_and_positions_in_days() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time
TestSample1,PoolA,Pop1,07/03/2024
TestSample2,PoolB,Pop1,11/04/2024'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'datetime'; format = 'dd/MM/yyyy' }
        series { by = ['exp_population'] }"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    # Echoed as ISO, which is the only thing that catches a user who meant July 3rd. No check can.
    assert_contains "$report" "2024-03-07T00:00  2024-04-11T00:00" \
        "the resolved dates are echoed, so an ambiguous pattern is visible"
    assert_contains "$report" "'dd/MM/yyyy' (en)" "with the pattern and locale that read them"
}

# `yyyy` is year-of-era and cannot resolve under a strict parser; `uuuu` is the proleptic year.
# Everyone writes yyyy, so both are accepted - they differ only before year 1.
test_a_yyyy_pattern_is_accepted() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_time
TestSample1,PoolA,2024-03-07
TestSample2,PoolB,2024-04-11'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'datetime'; format = 'yyyy-MM-dd' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the pattern everyone writes has to work"
}

# A lenient parser turns 2024-02-31 into 2024-02-29 and says nothing, which is a typo silently
# corrected into a date that sorts perfectly.
test_an_impossible_date_refuses_rather_than_being_corrected() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_time
TestSample1,PoolA,2024-02-31
TestSample2,PoolB,2024-04-11'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'datetime'; format = 'yyyy-MM-dd' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "31 February must not become 29 February"
    assert_contains "$(analysis_output)" "2024-02-31" "and the refusal names the value"
}

# A researcher writes their metadata in their own language. Parsing is locale-aware; what gets
# published is ISO and a number, so the output is the same either way.
test_a_month_name_is_read_in_the_projects_own_locale() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_time
TestSample1,PoolA,5 décembre 2011
TestSample2,PoolB,7 mars 2012'
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'datetime'; format = 'd MMMM yyyy'; locale = 'fr' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "French month names should read under locale fr"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "2011-12-05T00:00  2012-03-07T00:00" \
        "and are published as ISO whatever language wrote them"
}

# forLanguageTag does NOT fall back to English for an unknown tag: it returns a locale with no
# month names, which then refuses every value with a message about the value.
test_an_unknown_locale_is_refused_by_name() {
    analysis_ready single || return
    analysis_write_analysis_config "$ANALYSIS_SB" "        timeVar { kind = 'datetime'; format = 'yyyy-MM-dd'; locale = 'xx' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a locale this Java does not have must be named as the problem"
    assert_contains "$(analysis_output)" "not a locale this Java knows" \
        "rather than failing later on a value that is perfectly good"
}
