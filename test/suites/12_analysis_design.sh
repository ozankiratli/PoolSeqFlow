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
    assert_contains "$out" "attribute one to the row it came from" \
        "and tells the user what belongs in an unprefixed column, and why nothing can use it"
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
    assert_contains "$report" "REPLICATION:           conditions   exp_population" \
        "and what a repeated measurement is"
    assert_contains "$report" "REPLICATION:           biological   (none declared)" \
        "with every key column placed under a role, declared or not"
    assert_contains "$report" "3 series over 2 timepoints" "and the shape it found"
}

# ---------------------------------------------------------------------------------------
# Units without a time axis. THE BUG: units, conditions and roles were computed inside the time
# branch, so a project with no time course reported zero independent units - and degrees of
# freedom come from that number. A one-off comparison is the commonest design there is.

# The pools ARE the units when nothing declares otherwise. RG_Sample already decided what was
# merged into one pool, so two pools are two things until a technicalRep column says they are one
# material measured twice.
test_an_untimed_project_has_units_and_conditions() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_treatment
TestSample1,PoolA,control
TestSample2,PoolB,control
TestSample3,PoolC,control
TestSample4,PoolD,treated
TestSample5,PoolE,treated
TestSample6,PoolF,treated'
    analysis_write_metadata_config "$ANALYSIS_SB" ""
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a design with no time course is still a design"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "TIME VARIABLE:         none" "there is no time axis"
    assert_contains "$report" "REPLICATION:               2 conditions, 3 biological replicates each, 1 technical" \
        "and three pools a side are three replicates, not one"
    assert_contains "$report" "REPLICATION:               6 independent units from 6 pools" \
        "which is the number every standard error is computed from"
    assert_not_contains "$report" "SERIES:" "and nothing claims a trajectory"
}

# The same six pools with the lane declared: three cages sequenced twice is THREE units, and
# calling it six is pseudo-replication that roughly halves every standard error.
test_a_technical_column_merges_untimed_pools_into_one_unit() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_cage,exp_lane
TestSample1,PoolA,A,L1
TestSample2,PoolB,A,L2
TestSample3,PoolC,B,L1
TestSample4,PoolD,B,L2
TestSample5,PoolE,C,L1
TestSample6,PoolF,C,L2'
    analysis_write_analysis_config "$ANALYSIS_SB" "" \
        "            biologicalRep = ['exp_cage']
            technicalRep  = ['exp_lane']"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a crossed untimed design should resolve"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "REPLICATION:               1 condition, 3 biological replicates each, 2 technical" \
        "the cages are the replicates and the lanes are the repeats of each"
    assert_contains "$report" "REPLICATION:               3 independent units from 6 pools" \
        "so six pools carry three units"
    assert_contains "$report" "REPLICATION:                   A  (2)" "and each unit names its pools"
}

# THE MISASSIGNMENT NOTHING CAN CATCH, without a time axis to make it visible. Leave the lane
# out of technicalRep and it is read as a condition - the count doubles, silently. So every key
# column is printed under a role here too.
test_an_undeclared_technical_column_is_visible_as_a_condition() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_cage,exp_lane
TestSample1,PoolA,A,L1
TestSample2,PoolB,A,L2
TestSample3,PoolC,B,L1
TestSample4,PoolD,B,L2'
    analysis_write_metadata_config "$ANALYSIS_SB" ""
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "REPLICATION:           conditions   exp_cage, exp_lane" \
        "the undeclared lane shows up as a condition, where it can be seen"
    assert_contains "$report" "REPLICATION:           technical    (none declared)" \
        "beside the empty list that should have held it"
    assert_contains "$report" "4 independent units from 4 pools" \
        "and the doubled count is printed rather than left to be inferred"
}

# A project with no exp_ columns at all still has units, because a module counting degrees of
# freedom must not be handed a zero it cannot tell from an unanswered question.
test_units_survive_a_project_with_no_experimental_columns() {
    analysis_ready single || return
    rm -f "$ANALYSIS_SB/main/analysis.config"
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample
TestSample1,PoolA
TestSample2,PoolB'
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "REPLICATION:           no exp_ columns, so every pool stands alone" \
        "the absence of a design is stated"
    assert_contains "$report" "2 independent units from 2 pools" "and the pools are still units"
}

# Once technicalRep IS declared, it has to resolve the pools it applies to. A group that is
# partly told apart and partly not is neither one unit nor several, and guessing either way
# changes every degree of freedom in the project.
test_pools_a_declared_technical_column_cannot_tell_apart_refuse() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_cage,exp_lane
TestSample1,PoolA,A,L1
TestSample2,PoolB,A,L1
TestSample3,PoolC,A,L2'
    analysis_write_analysis_config "$ANALYSIS_SB" "" \
        "            biologicalRep = ['exp_cage']
            technicalRep  = ['exp_lane']"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a group that cannot be partitioned must stop the run"
    local out; out=$(analysis_output)
    assert_contains "$out" "L1: PoolA, PoolB" "naming the pools it cannot tell apart"
    assert_contains "$out" "partly one unit and partly several" "and why that is not resolvable"
    assert_contains "$out" "give the rows the same" \
        "with merging them offered beside declaring a column, as the timed refusal does"
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
# Missing values. A blank cell always means no value; missingValueEncoding is for the other
# spellings of it, and it is the setting most able to remove data quietly - a pattern wider than
# the user meant leaves fewer levels, shorter series and dropped pools, none of which is an error
# anywhere downstream.

# NA AND A BLANK CELL AGREE once NA is declared. Without reading the encoding first, this pool
# would be refused as a contradiction on a file the user wrote consistently.
test_an_encoded_missing_value_agrees_with_a_blank_cell() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_treatment
TestSample1,PoolA,NA
TestSample2,PoolA,'
    analysis_write_metadata_config "$ANALYSIS_SB" "            missingValueEncoding = ['NA']"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "NA and blank are one answer once NA is declared: $(analysis_output)"
}

# MATCHING IS CASE SENSITIVE, so a level genuinely called `na` stays a level. Folding case would
# be convenient until the project whose population codes include one, where it would delete a real
# level and leave a smaller design with nothing to say so.
test_the_missing_encoding_is_case_sensitive_and_reported() {
    analysis_ready single || return
    # On a pt_ column, so the encoding is checked apart from the series machinery: blanking a
    # series key legitimately makes the series ragged, and that refusal would fire first.
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_population,exp_time,pt_score
TestSample1,TestSample1,Pop1,T1,NA
TestSample2,TestSample2,Pop1,T2,na
TestSample3,TestSample3,Pop2,T1,9.1
TestSample4,TestSample4,Pop2,T2,10.0
TestSample5,TestSample5,Pop3,T1,11.2
TestSample6,TestSample6,Pop3,T2,8.7'
    analysis_write_metadata_config "$ANALYSIS_SB" "            missingValueEncoding = ['NA']
$ANALYSIS_TIME_BLOCK"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "read 1 cell as having no value" \
        "only the exact spelling is taken, so lowercase na survives as a value"
    assert_contains "$report" "pt_score: TestSample1 'NA'" \
        "and the report names the cell it blanked, its column and its pool"
}

# A PATTERN THAT MATCHES EVERYTHING is refused rather than obeyed: it would blank every
# experimental and phenotype cell in the project and leave an analysis with no design at all.
test_a_missing_encoding_matching_everything_refuses() {
    analysis_ready single || return
    analysis_write_metadata_config "$ANALYSIS_SB" "            missingValueEncoding = ['*']"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a pattern matching everything must not be obeyed"
    assert_contains "$(analysis_output)" "matches every value" "and the refusal says why"
}

# THE SCOPES REFUSE THEIR OWN UNKNOWN KEYS, which is what the extra levels buy. A reader asks for
# the key it wants by name, so before this nesting a misspelling sat in the file unread while the
# project ran on a default nobody chose.
test_a_misspelt_metadata_setting_refuses() {
    analysis_ready single || return
    analysis_write_metadata_config "$ANALYSIS_SB" "            timevar { kind = 'categorical' }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "timevar with a small v must not be read as timeVar"
    local out; out=$(analysis_output)
    assert_contains "$out" "analysis.metadata is given a setting it does not have: timevar" \
        "the refusal names the key and the scope it was written in"
    assert_contains "$out" "missingValueEncoding" "and lists what that scope does have"
}

# The same one level up, where a module's scope now lives.
test_an_unknown_analysis_scope_key_refuses() {
    analysis_ready single || return
    cat > "$ANALYSIS_SB/main/analysis.config" <<'CFG'
params {
    analysis {
        basicstats {
            minReads = 3
        }
    }
}
CFG
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a module scope written at the analysis level must be refused"
    local out; out=$(analysis_output)
    assert_contains "$out" "does not have: basicstats" "naming the key that has no home there"
    assert_contains "$out" "analysis.modules.<name>" "and where a module's settings go instead"
}

# ---------------------------------------------------------------------------------------
# The phenotype. pt_ was refused until it was given this meaning, and it is separate from exp_
# because only an experimental variable identifies a series - a trait value differs per pool,
# so admitting one as a series key would leave every series a single timepoint long.

# The fixture's own design with a phenotype added: exp_population over three levels and exp_time
# over two, which is what keeps the series 3 x 2. Dropping either leaves every pool in one series
# and the series check refuses three pools at one timepoint before the phenotype is ever read.
ANALYSIS_PHENOTYPE_METADATA='SampleID,RG_Sample,exp_population,exp_time,pt_status,pt_wingspan,pt_wing,pt_resistance
TestSample1,TestSample1,Pop1,T1,affected,12.4,spotted,low
TestSample2,TestSample2,Pop1,T2,affected,13.8,striped,high
TestSample3,TestSample3,Pop2,T1,unaffected,9.1,curly,medium
TestSample4,TestSample4,Pop2,T2,unaffected,10.0,spotted,low
TestSample5,TestSample5,Pop3,T1,affected,11.2,striped,high
TestSample6,TestSample6,Pop3,T2,unaffected,8.7,curly,medium'

# A pt_ column is pool-level for the same reason an exp_ one is, and it is the whole reason
# analysis.phenotype.column is confined to the prefix: every column it can name has been
# through checkTargetDesign(). Written without this, one pool carries two phenotypes and the
# module fits whichever row it read first.
test_a_pool_whose_rows_disagree_on_a_phenotype_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,pt_wingspan
TestSample1,PoolA,12.4
TestSample2,PoolA,18.9'
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "one pool with two phenotype values is not a design"
    local out; out=$(analysis_output)
    assert_contains "$out" "the pool 'PoolA' is given more than one pt_wingspan" \
        "the refusal names the column and the pool"
    assert_contains "$out" "phenotype measured ON the pool" \
        "and says what kind of column it is, not exp_'s wording"
}

# The kind is never inferred: 0 and 1 read as numbers as readily as they encode two groups, so
# a project that declares a column and no kind stops rather than guessing one.
test_a_phenotype_with_no_kind_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_wingspan {
                levels = ['small', 'large']
            }
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a phenotype with no kind must not be guessed at"
    assert_contains "$(analysis_output)" "analysis.metadata.phenotypes.pt_wingspan.kind is not set" \
        "and the refusal says which setting is missing, by its full path"
}

# NEXTFLOW DROPS AN EMPTY CONFIG BLOCK. `pt_wingspan { }` reaches params as nothing at all - the
# key is absent, not present and empty - so the frame cannot tell it from a column nobody wrote
# about and CANNOT refuse it. Measured 2026-09-07; the same is true of an empty covariate block.
# What saves it is the undeclared warning, which names any pt_ column with no scale.
test_an_empty_declaration_block_reaches_the_frame_as_nothing() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_wingspan {
            }
        }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "an empty block is invisible, so there is nothing to refuse"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "PHENOTYPE:             none - analysis.metadata.phenotypes declares no column" \
        "the block declared nothing the frame could see"
    assert_contains "$report" \
        "pt_status, pt_wingspan, pt_wing, pt_resistance are phenotype columns this project records and does not declare" \
        "and every one is named as undeclared, which is the only defence there is"
}

# Outside the prefix a column escapes the pool-agreement refusal above, so the two rules are
# one mechanism: this is what makes 'every column it can name is checked' true.
test_a_phenotype_outside_the_prefix_refuses() {
    analysis_ready single || return
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            exp_population {
                kind   = 'quantitative'
            }
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "only a pt_ column may be the phenotype"
    assert_contains "$(analysis_output)" "has to be a pt_ column" \
        "and the refusal says why: agreeing across the rows of one pool"
}

# levels order the two groups of a binary phenotype and decide which is 1, so they set the SIGN
# of every slope reported against it. Taking whichever sorts first would reverse half of them
# silently, which is why binary without levels is refused rather than defaulted.
test_a_binary_phenotype_without_levels_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_status {
                kind   = 'binary'
            }
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a binary phenotype must declare which level is 1"
    assert_contains "$(analysis_output)" "decides the SIGN of every effect" \
        "and the refusal says what is at stake rather than only naming the setting"
}

# A value the declared kind cannot hold stops the run and names the pool that has it. Dropping
# it instead would publish an analysis over a subset nobody chose.
test_a_quantitative_phenotype_refuses_a_value_that_is_not_a_number() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" \
        "${ANALYSIS_PHENOTYPE_METADATA/,affected,13.8,/,affected,large,}"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_wingspan {
                kind   = 'quantitative'
            }
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "'large' is not a quantitative phenotype"
    local out; out=$(analysis_output)
    assert_contains "$out" "TestSample2" "the refusal names the pool that has it"
    assert_contains "$out" "'large'" "and the value it could not read"
}

# THE ECHO-BACK, which does more work than any check here. A reversed binary encoding is legal,
# silent, and reverses every slope; no check can tell [control, case] from [case, control].
# Printing each pool's written value beside the number it became is the only place a user sees
# it. Same defence as the time levels printed in the order the analysis will use them.
test_the_report_states_the_phenotype_as_it_resolved() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_status {
                kind   = 'binary'
                levels = ['unaffected', 'affected']
            }
        }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a declared binary phenotype is a sound design"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "PHENOTYPE:                 pt_status, binary, 'unaffected' absent and 'affected' present" \
        "the report states the encoding rather than leaving it to be inferred"
    assert_contains "$report" "TestSample1  affected -> 1.0" \
        "and every pool's written value beside the number it became"
    assert_contains "$report" "TestSample3  unaffected -> 0.0" "for both levels"
}

# A NOMINAL PHENOTYPE CARRIES NO NUMBER, and that is the point rather than an omission. Wing types
# spotted, striped and curly have an index each, and a slope fitted on that index would assert
# curly is twice as far from spotted as striped is. Null makes "no trend may be fitted here"
# something a module checks instead of something its author remembers - the same mechanism
# categorical time uses when it sets position to null.
test_a_nominal_phenotype_gets_a_group_and_no_value() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_wing {
                kind   = 'nominal'
                levels = ['spotted', 'striped', 'curly']
            }
        }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "three unordered wing types are a sound design"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "pt_wing, nominal, unordered: spotted, striped, curly" \
        "the report says the scale is unordered"
    assert_contains "$report" "fits no trend" \
        "and states what may not be done with it, rather than leaving a column of nulls"
    assert_contains "$report" "TestSample1  spotted -> group 0" \
        "each pool resolves to a group and not to a number"
}

# ORDERED AND UNORDERED ARE DIFFERENT KINDS because they permit different things. An ordinal scale
# keeps a position, so a trend is fittable; scoring it as a number is the user's assertion that the
# steps are equal, which is exactly what the declaration records.
test_an_ordinal_phenotype_keeps_its_order() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_resistance {
                kind   = 'ordinal'
                levels = ['low', 'medium', 'high']
            }
        }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "an ordered scale is a sound design"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "pt_resistance, ordinal, in this order: low < medium < high" \
        "the report prints the order it will use"
    assert_contains "$report" "TestSample1  low -> 0.0" "the lowest level sits at 0"
    assert_contains "$report" "TestSample2  high -> 2.0" "and the highest at its rank"
}

# BINARY IS PRESENCE AND ABSENCE, not "two groups". Two host plants or two collection sites are
# nominal with two levels; neither is the absence of the other. The declaration is what a module
# reads to know a case/control method applies, so a third level leaves it meaning nothing.
test_a_binary_phenotype_takes_exactly_two_levels() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_wing {
                kind   = 'binary'
                levels = ['spotted', 'striped', 'curly']
            }
        }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "three levels are not a presence and an absence"
    local out; out=$(analysis_output)
    assert_contains "$out" "presence and absence" "the refusal says what binary means"
    assert_contains "$out" "this is 'nominal'" "and names the kind that fits instead"
}

# A DECLARED LEVEL NO POOL HAS IS KEPT, not refused: a group not yet sequenced is legitimate. A
# misspelling is indistinguishable from it, which is why it is reported rather than passed over.
test_a_phenotype_level_no_pool_has_is_reported() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_PHENOTYPE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
        phenotypes {
            pt_wing {
                kind   = 'nominal'
                levels = ['spotted', 'striped', 'curly', 'plain']
            }
        }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a level nobody has yet must not stop the run"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "names plain, which no pool" \
        "but it is reported, because a misspelling looks exactly like it"
}

# ---------------------------------------------------------------------------------------
# Covariates. Measured on the pool and neither set nor the response, so they get a prefix of
# their own - an exp_ column identifies a series, and a temperature recorded at each timepoint
# would leave every series one point long, quietly.

ANALYSIS_COVARIATE_METADATA='SampleID,RG_Sample,exp_population,exp_time,cov_temperature,cov_site,cov_technician
TestSample1,TestSample1,Pop1,T1,21.5,coastal,Ada
TestSample2,TestSample2,Pop1,T2,22.1,coastal,Ada
TestSample3,TestSample3,Pop2,T1,18.0,inland,Grace
TestSample4,TestSample4,Pop2,T2,19.4,inland,Grace
TestSample5,TestSample5,Pop3,T1,25.2,montane,Ada
TestSample6,TestSample6,Pop3,T2,24.8,montane,Grace'

# A COVARIATE MAY VARY WITHIN A POOL, and that is the difference between it and the other two.
# Two libraries of one pool really can have been handled by two people or reared at two
# temperatures - a circumstance, not a contradiction - so it is recorded rather than refused. The
# pool then has NO value for it, because it genuinely has none, and nothing is averaged or picked.
test_a_covariate_may_vary_within_a_pool() {
    analysis_ready single || return
    # The baseline declares a categorical exp_time, and this fixture has no such column.
    rm -f "$ANALYSIS_SB/main/analysis.config"
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_treatment,cov_technician
TestSample1,PoolA,control,Ada
TestSample2,PoolA,control,Grace'
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "two technicians for one pool is a fact, not a contradiction: $(analysis_output)"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "PoolA cov_technician: Ada, Grace" \
        "the report names the pool, the column and what it held"
    assert_contains "$report" "Nothing is averaged and nothing is chosen for you" \
        "and says what was done with it, which is nothing"
}

# The same shape on an exp_ column is still a hard refusal. You cannot have SET two treatments for
# one pool, so that disagreement is a contradiction and there is nothing to record.
test_an_experimental_column_may_not_vary_within_a_pool() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,exp_treatment
TestSample1,PoolA,control
TestSample2,PoolA,treated'
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "one pool cannot have had two treatments"
    assert_contains "$(analysis_output)" "Record it under cov_" \
        "and the refusal offers the prefix that IS allowed to vary"
}

# ADDING A COVARIATE MUST NOT DISSOLVE THE SERIES. This is the whole reason cov_ is not exp_: the
# fixture's series are 3 x 2, and a temperature that differs at every timepoint would make six
# series of one if it were a key. Written as exp_temperature this case fails.
test_a_covariate_is_never_a_series_key() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "three covariates must not disturb the design: $(analysis_output)"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "3 series over 2 timepoints" \
        "the series are what they were before the covariates existed"
}

# A DECLARED COVARIATE GETS A SCALE, on the phenotype's four kinds. The frame itself adjusts for
# nothing; what a scale buys is a typed value a module can compute with, and a report line that
# shows the high-phenotype pools were also the warm ones.
test_a_declared_covariate_is_reported_with_its_scale() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
            covariates {
                cov_temperature {
                    kind = 'quantitative'
                }
                cov_site {
                kind   = 'nominal'
                levels = ['coastal', 'inland', 'montane']
                }
            }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "two declared covariates are a sound design: $(analysis_output)"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "COVARIATES:            2 declared" "the report counts them"
    assert_contains "$report" "cov_temperature, quantitative" "and names each with its scale"
    assert_contains "$report" "6 pools, 18.0 to 25.2" "giving a range for a measurement"
    assert_contains "$report" "cov_site, nominal: coastal, inland, montane" \
        "and the groups for an unordered one"
    assert_contains "$report" "coastal (2), inland (2), montane (2)" "with how many pools each holds"
}

# AN UNDECLARED cov_ COLUMN IS NOT AN ERROR - a covariate kept for the record is a legitimate
# thing. But "kept on purpose" and "forgot to declare it" look identical in the file, so the one
# thing the frame can do is say which columns are in that state.
test_an_undeclared_covariate_is_recorded_and_named() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
            covariates {
                cov_temperature {
                    kind = 'quantitative'
                }
            }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "an undeclared covariate must not stop the run"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "cov_site, cov_technician" \
        "and both undeclared columns are named"
}

# Declaring a column outside the prefix would put a row-level fact where a pool-level one belongs,
# and the agreement refusal would never have seen it.
test_a_covariate_declaration_outside_the_prefix_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
            covariates {
                exp_population {
                    kind = 'nominal'
                levels = ['Pop1', 'Pop2', 'Pop3']
                }
            }"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "only a cov_ column may be declared a covariate"
    assert_contains "$(analysis_output)" "has to be a cov_ column" "and the refusal says so"
}

# WHAT A COLUMN HOLDS AND WHAT IT DOES ARE TWO SETTINGS. analysis.metadata.covariates gives it a
# scale; analysis.design.covariates says whether a module may put it in a model. Left
# unset every declared covariate is in the design, so declaring one is the whole of opting in.
test_every_declared_covariate_is_in_the_design_by_default() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_metadata_config "$ANALYSIS_SB" "$ANALYSIS_TIME_BLOCK
            covariates {
                cov_temperature { kind = 'quantitative' }
            }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "an unset design covariate list is the ordinary case: $(analysis_output)"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "1 declared, 1 in the design" "the two counts agree by default"
    assert_contains "$report" "cov_temperature, quantitative  [in the design]" \
        "and each covariate says which it is"
}

# Each covariate in the design costs a degree of freedom, and at six pools there are four. So a
# covariate kept for provenance has to be excludable - and the exclusion goes on the record,
# because leaving one out is as much a decision as putting one in.
test_the_design_can_leave_a_declared_covariate_out() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_analysis_config "$ANALYSIS_SB" \
        "$ANALYSIS_TIME_BLOCK
            covariates {
                cov_temperature { kind = 'quantitative' }
                cov_site        { kind = 'nominal'; levels = ['coastal', 'inland', 'montane'] }
            }" \
        "            covariates = ['cov_temperature']"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "naming one of two covariates is a sound design: $(analysis_output)"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "2 declared, 1 in the design" "the counts differ and both are printed"
    assert_contains "$report" "cov_site, nominal: coastal, inland, montane  [on the record only]" \
        "the excluded one is still resolved and still reported"
    assert_contains "$report" "leaves cov_site out" "and the exclusion is in the design notes"
}

# A column with no scale has no value a model could take, so naming one in the design is a
# request that cannot be met - and silently dropping it would spend a degree of freedom on
# nothing, or none on something the user asked for.
test_a_design_covariate_with_no_scale_refuses() {
    analysis_ready single || return
    analysis_write_metadata "$ANALYSIS_SB" "$ANALYSIS_COVARIATE_METADATA"
    analysis_write_analysis_config "$ANALYSIS_SB" \
        "$ANALYSIS_TIME_BLOCK
            covariates {
                cov_temperature { kind = 'quantitative' }
            }" \
        "            covariates = ['cov_site']"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a covariate with no scale cannot be in a model"
    local out; out=$(analysis_output)
    assert_contains "$out" "which has no declared scale" "the refusal says what is missing"
    assert_contains "$out" "analysis.metadata.covariates.cov_site { kind =" \
        "and shows the declaration that would fix it"
}

# A project with no phenotype is the ordinary case and must not look like a broken one.
test_the_report_says_when_there_is_no_phenotype() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    assert_contains "$(analysis_report "$ANALYSIS_SB")" \
        "PHENOTYPE:             none - analysis.metadata.phenotypes declares no column" \
        "and says so plainly"
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
