#!/bin/bash
# The analysis layer: what it ships as, which results an invocation covers, and what it
# refuses before computing anything.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 30_pipeline's business, and running it here would
# cost minutes to produce files this suite only ever counts. Published artifacts are planted
# instead; what cannot be planted is the identity record beside the results, because
# .poolseqflow_params holds the manifest exactly as the pipeline resolves it and a hand-written
# copy would be a second definition of it. Step 0 alone writes that record, once per project
# shape, and every case works from a copy.
#
# The static cases at the top are about the layer's SEPARATION from the pipeline - it may read
# the pipeline, the pipeline may never read it - and cost nothing at all.

ANALYSIS_SB=""
ANALYSIS_BASELINE_SINGLE=""
ANALYSIS_BASELINE_MULTI=""

# The multi-run table these cases use. lenient_a and lenient_b differ only in `annotate`,
# which belongs to step 8 alone, so they are one variant at step 7 and share a results
# directory. strict changes a step-7 filter and gets its own. That split is the whole point:
# selecting one run must reach a directory that also holds another run's results.
analysis_write_runs_table() {
    cat > "$1/main/runs.csv" <<'TABLE'
RunID,annotate,vcffilter.minDP
lenient_a,true,
lenient_b,false,
strict,true,40
TABLE
}

# A multi-run config. The two multiRun settings are part of the recorded manifest, so a copy
# of a baseline has to be rewritten with them or the parameter guard reports a change the
# test made rather than the one it is about.
analysis_write_multi_config() {
    write_sandbox_config "$1" \
        's|^    multiRun .*|    multiRun        = true|' \
        "s|^    multiRunFile .*|    multiRunFile    = 'runs.csv'|"
}

# A single-run project whose identity the pipeline has recorded. Step 0 alone writes
# .poolseqflow_version and .poolseqflow_params, which is everything the identity check reads,
# and costs about a fifth of a full run.
analysis_baseline_single() {
    [ -n "$ANALYSIS_BASELINE_SINGLE" ] && return 0
    local sb status
    sb=$(make_pipeline_sandbox "analysis-single")
    write_sandbox_config "$sb"
    status=$(run_verify_only "$sb")
    [ "$status" = "0" ] || return 1
    ANALYSIS_BASELINE_SINGLE="$sb"
    return 0
}

# The same for three runs, which also records .multirun.csv.
analysis_baseline_multi() {
    [ -n "$ANALYSIS_BASELINE_MULTI" ] && return 0
    local sb status
    sb=$(make_pipeline_sandbox "analysis-multi")
    analysis_write_runs_table "$sb"
    analysis_write_multi_config "$sb"
    status=$(run_verify_only "$sb")
    [ "$status" = "0" ] || return 1
    ANALYSIS_BASELINE_MULTI="$sb"
    return 0
}

# What a completed run would have left in a results directory. The analysis layer counts these
# files and never opens them, so empty ones answer exactly the question the count asks.
analysis_plant_results() {
    local out="$1" name
    mkdir -p "$out/Frequencies" "$out/VCF" "$out/Ready" "$out/Reports"
    for name in Test_snp Test_indel; do
        : > "$out/Frequencies/${name}_freq.tsv"
        : > "$out/Frequencies/${name}_depth.tsv"
    done
    : > "$out/VCF/Test.vcf"
    for name in 1 2 3 4 5 6; do
        : > "$out/Ready/TestSample${name}_ready.bam"
        : > "$out/Ready/TestSample${name}_ready.bam.bai"
    done
}

# The four session files a pipeline run leaves in Output/Reports, with content of their own so
# that an analysis run landing on them is visible as a changed checksum rather than a changed
# timestamp.
analysis_plant_session_reports() {
    local reports="$1/Reports" name
    mkdir -p "$reports"
    for name in trace.txt report.html timeline.html dag.html; do
        printf 'the pipeline wrote this\n' > "$reports/PoolSeqFlow_pipeline_${name}"
    done
}

# A fresh copy of one baseline for a case to mutate.
analysis_ready() {
    local which="$1" baseline
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi

    case "$which" in
        single) analysis_baseline_single && baseline="$ANALYSIS_BASELINE_SINGLE" ;;
        multi)  analysis_baseline_multi  && baseline="$ANALYSIS_BASELINE_MULTI" ;;
        *)      fail_case "unknown baseline '$which'"; return 1 ;;
    esac
    if [ -z "${baseline:-}" ]; then
        fail_case "the $which baseline could not be built; see $TEST_TMPDIR/analysis-$which/run.out"
        return 1
    fi

    ANALYSIS_SB=$(guard_path "$TEST_TMPDIR/analysis")
    rm -rf "$ANALYSIS_SB"
    cp -a "$baseline" "$ANALYSIS_SB"
    if [ "$which" = "multi" ]; then
        analysis_write_multi_config "$ANALYSIS_SB"
    else
        write_sandbox_config "$ANALYSIS_SB"
    fi
    return 0
}

# Install a module into the sandbox's own module store. Takes the name and the manifest body,
# so a case can write a malformed one on purpose, and optionally the main.nf a case needs the
# module to be.
#
# Nothing ships a module: the release carries the frame and an empty store, and a case that
# needs one makes it here.
analysis_install_module() {
    local name="$1" manifest="$2" dir
    dir="$ANALYSIS_SB/install/analysis/modules/$name"
    mkdir -p "$dir"
    printf '%s\n' "$manifest" > "$dir/manifest.json"
    if [ -n "${3:-}" ]; then
        printf '%s\n' "$3" > "$dir/main.nf"
    else
        printf '%s\n' 'nextflow.enable.dsl=2' 'workflow { println "module ran" }' > "$dir/main.nf"
    fi
}

# Write the project's analysis.config with one run selection in it.
analysis_select() {
    printf 'params {\n    analysis {\n        runs = %s\n    }\n}\n' "$1" \
        > "$ANALYSIS_SB/main/analysis.config"
}

# The same for the results folder name.
analysis_folder_name() {
    printf 'params {\n    analysis {\n        folderName = %s\n    }\n}\n' "$1" \
        > "$ANALYSIS_SB/main/analysis.config"
}

# What the last analysis invocation printed, refusals included. A refusal happens while the
# DAG is built, so no task runs and no report is written - only this has it.
analysis_output() {
    cat "$ANALYSIS_SB/run.out" 2>/dev/null
}

# ---------------------------------------------------------------------------------------
# Separation. These need no tools and are the ones that keep the layer optional.

# THE DEPENDENCY RUNS ONE WAY. analysis.nf includes scripts/variants.nf so that a results
# directory is looked up through the pipeline's own partition rather than guessed at; nothing
# in the pipeline may include, name or write anything of the analysis layer's. If it did, a
# user who never installs the analysis environment would be running code that expects it.
test_the_pipeline_does_not_read_the_analysis_layer() {
    local hits
    hits=$(cd "$REPO_ROOT" && grep -rn --exclude-dir=__pycache__ -e "analysis/" -e "Analysis" \
        poolseqflow.nf dryrun.nf nextflow.config scripts bin parameters.config.template 2>/dev/null)
    assert_eq "" "$hits" "the pipeline must not mention the analysis layer, but it does:"$'\n'"$hits"
}

# The analysis layer reads the pipeline, which is the direction that is allowed.
test_the_analysis_layer_reads_the_pipeline_partition() {
    local lib; lib=$(cat "$REPO_ROOT/analysis/lib/plan.nf")
    assert_contains "$lib" "from '../../scripts/variants.nf'" \
        "the results directory of a run comes from the pipeline's own plan"
    assert_contains "$lib" "from '../../scripts/resolve_parameters.nf'" \
        "and so do the run definitions"
}

# The frame and a module ask one function where the results are, so a module can never be
# reading a directory the verification did not clear.
test_the_frame_and_a_module_share_one_answer() {
    assert_contains "$(cat "$REPO_ROOT/analysis.nf")" "analysisPlan(module, moduleNeeds(module))" \
        "the entry point takes its targets from the library"
    local hits
    hits=$(cd "$REPO_ROOT" && grep -rln "def analysisPlan" . --exclude-dir=.git --exclude-dir=test \
        --exclude-dir=docs --exclude-dir=site --exclude-dir=.claude 2>/dev/null | sort)
    assert_eq "./analysis/lib/plan.nf" "$hits" "and there is one definition of it"
}

test_the_analysis_layer_ships_with_the_release() {
    local f
    for f in analysis.nf analysis/modules.nf analysis/0_verify_analysis.nf \
             analysis/defaults.config analysis/analysis.config.template \
             analysis/lib/paths.nf analysis/lib/plan.nf; do
        assert_file "$REPO_ROOT/$f" "$f must ship"
    done
    assert_contains "$(cat "$REPO_ROOT/PoolSeqFlow")" "lib analysis install" \
        "the payload must carry the analysis directory"
}

# Being on PATH is not being installed, and the install has to say so: the wrapper is
# symlinked with everything else while the environment it needs is never created here.
test_install_says_the_analysis_wrapper_is_not_the_analysis_layer() {
    local wrapper; wrapper=$(cat "$REPO_ROOT/PoolSeqFlow")
    assert_contains "$wrapper" "THAT DOES NOT MEAN THE ANALYSIS LAYER IS INSTALLED" \
        "install must say the symlink is not an installation"
    assert_contains "$wrapper" "PoolSeqFlow-analysis install" \
        "and say how to install it"
}

# One list of modules, in the layer that refuses. A second copy in the wrapper would be the
# one that goes stale.
test_the_module_roster_lives_in_one_place() {
    local hits
    hits=$(cd "$REPO_ROOT" && grep -rln "moduleRoster" . --exclude-dir=.git --exclude-dir=test \
        --exclude-dir=docs --exclude-dir=site --exclude-dir=.claude 2>/dev/null | sort)
    assert_eq "./analysis/modules.nf" "$hits" "the roster must exist in exactly one file"
    assert_contains "$(cat "$REPO_ROOT/PoolSeqFlow-analysis")" '--module "$COMMAND"' \
        "the wrapper passes the word through rather than judging it"
}

# The three layers, in order. Losing one silently drops either the defaults or the user's
# settings, and both look like the module simply ignoring the config.
test_the_wrapper_layers_three_configurations() {
    local wrapper; wrapper=$(cat "$REPO_ROOT/PoolSeqFlow-analysis")
    assert_contains "$wrapper" 'analysis/defaults.config' "the installation's defaults"
    assert_contains "$wrapper" '-f analysis.config' "then the project's"
    assert_contains "$wrapper" '-f "${COMMAND}.config"' "then the module's"
    # analysis/defaults.config reads this back. It is the run's only way to the installation,
    # a module having become the entry script.
    assert_contains "$wrapper" 'export POOLSEQFLOW_HOME="$INSTALL"' \
        "and the installation goes into the environment"
}

# An analysis run must not overwrite the pipeline's dag, trace, timeline and report, which
# are the record of the run that produced the results being read.
test_the_defaults_keep_the_session_files_out_of_the_pipeline_reports() {
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/defaults.config")
    local key
    for key in trace report timeline dag; do
        assert_contains "$cfg" "PoolSeqFlow_analysis_${key}" "the ${key} must be redirected"
    done
    assert_contains "$cfg" 'Analysis/Session' "into Analysis/Session"
    assert_contains "$cfg" 'workDir = "${params.mainDir}/Analysis/work"' \
        "and the work directory into Analysis/work"
}

# A module is launched as its own entry script, so Nextflow reads a nextflow.config beside the
# module and in the project - never the installation's. Anything the pipeline gets from
# nextflow.config a module gets from here or not at all, and the ones below are silent when
# absent: no conda for a task that asks for it, no bin/ on PATH, and a null `cores` scope that
# fails inside pipeline code with nothing pointing back here.
test_the_defaults_carry_what_a_module_run_has_no_other_source_for() {
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/defaults.config")
    assert_contains "$cfg" 'params.cores = params.containsKey' "the cores scope"
    assert_contains "$cfg" 'params.dir.bin = "${params.analysis.installDir}/bin"' \
        "bin/ in the installation rather than beside the module"
    assert_contains "$cfg" 'PATH="${params.dir.bin}:\$PATH"' "and on the task PATH"
    assert_contains "$cfg" 'conda.enabled = true' "conda, which every analysis module needs"
    assert_contains "$cfg" 'resourceLimits' "and the ceiling on what a task may ask for"
}

# The installation is what the environment variable says, and a run that cannot find it stops
# with that sentence rather than with a helper missing from a path nobody recognises.
test_a_run_that_cannot_find_its_installation_refuses() {
    analysis_ready single || return
    local status
    export SANDBOX_INSTALL_OVERRIDE=""
    status=$(run_analysis "$ANALYSIS_SB" verify)
    unset SANDBOX_INSTALL_OVERRIDE
    assert_status 1 "$status" "an installation that is not there must stop the run"
    assert_contains "$(analysis_output)" "POOLSEQFLOW_HOME is not set" \
        "naming what was missing"
    assert_contains "$(analysis_output)" "PoolSeqFlow-analysis <module>" \
        "and how a run is started"
}

test_the_template_documents_the_run_selection() {
    local tpl; tpl=$(cat "$REPO_ROOT/analysis/analysis.config.template")
    assert_contains "$tpl" "runs = 'all'" "the default"
    assert_contains "$tpl" "['reference_a'" "and that a list names runs"
}

# A module name reaches the shell as a file name, so its shape is checked before anything
# else happens.
test_a_module_name_must_be_a_bare_word() {
    run_analysis_launcher_with_envs "base" "../etc/passwd"
    assert_status 1 "$LAUNCHER_STATUS" "a path must not be taken for a module"
    assert_contains "$LAUNCHER_OUTPUT" "is not a module name" "and must say so"
}

# ---------------------------------------------------------------------------------------
# The module roster.

test_an_unknown_module_refuses_before_any_task() {
    analysis_ready single || return
    local status; status=$(run_analysis "$ANALYSIS_SB" mds)
    assert_status 1 "$status" "a module that does not exist must stop the run"
    assert_contains "$(analysis_output)" "'mds' is not installed" \
        "should name what was asked for"
    assert_contains "$(analysis_output)" "Available here: verify" \
        "and list what there is"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/mds/0_verify_analysis.txt" \
        "nothing should have run"
}

# A RELEASE SHIPS AN EMPTY STORE. Modules are published on their own timetable, so what is
# available is whatever has been installed into this release's installation - not a list frozen
# into the source.
test_a_module_installed_into_the_store_joins_the_roster() {
    analysis_ready single || return
    analysis_install_module mds \
        '{"name":"mds","version":"1.4.2","contract":"freq-1","summary":"scaling over frequencies"}'
    local status; status=$(run_analysis "$ANALYSIS_SB" mds)
    assert_status 0 "$status" "an installed module should be found"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "mds v1.4.2 - scaling over frequencies" \
        "the report carries the module's OWN version, not the release's"
    assert_contains "$report" "speaks table contract freq-1" "and the contract it reads"
}

# The module's version is its own. A module fixed and republished must not need a release of the
# pipeline, which is the whole reason the two are separate.
test_a_module_version_is_not_the_release_version() {
    analysis_ready single || return
    analysis_install_module mds \
        '{"name":"mds","version":"9.9.9","contract":"freq-1","summary":"scaling over frequencies"}'
    run_analysis "$ANALYSIS_SB" mds > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "mds v9.9.9" "the module reports its own version"
    assert_contains "$report" "PoolSeqFlow ${EXPECTED_VERSION:-2.2.0}" \
        "while the results still carry the pipeline release"
}

test_a_manifest_missing_a_field_refuses() {
    analysis_ready single || return
    analysis_install_module mds '{"name":"mds","version":"1.0.0"}'
    local status; status=$(run_analysis "$ANALYSIS_SB" mds)
    assert_status 1 "$status" "an incomplete manifest must stop the run"
    assert_contains "$(analysis_output)" "has no 'contract'" "naming the field that is missing"
}

# The directory is how a module is found and the name is how it is asked for, so the two
# disagreeing means one of them would never be reachable.
test_a_manifest_that_disagrees_with_its_directory_refuses() {
    analysis_ready single || return
    analysis_install_module mds \
        '{"name":"pca","version":"1.0.0","contract":"freq-1","summary":"wrong name"}'
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a mismatched manifest must stop even an unrelated module"
    assert_contains "$(analysis_output)" "installed in a directory named 'mds'" \
        "naming both sides of the disagreement"
}

# Half-finished installs and stray directories are ordinary; only a manifest that exists and
# cannot be used is an error.
test_a_directory_without_a_manifest_is_ignored() {
    analysis_ready single || return
    mkdir -p "$ANALYSIS_SB/install/analysis/modules/half-installed"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a directory holding no manifest should be passed over"
    assert_not_contains "$(analysis_report "$ANALYSIS_SB")" "half-installed" \
        "and must not appear as a module"
}

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
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "analysis/defaults.config" "the installation's defaults"
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

# ---------------------------------------------------------------------------------------
# Where an analysis is written.

test_results_go_to_a_folder_named_after_the_module() {
    analysis_ready single || return
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the default folder name should verify"
    assert_file "$ANALYSIS_SB/main/Analysis/Results/verify/0_verify_analysis.txt" \
        "the verification record goes in the folder it cleared"
    assert_dir "$ANALYSIS_SB/main/Analysis/Main" \
        "and the shared intermediates root exists beside Results"
}

# A folder name may be a path, so two settings of one module sit side by side under a name of
# their own rather than being told apart by a timestamp.
test_a_folder_name_may_be_a_path() {
    analysis_ready single || return
    analysis_folder_name "'MDS/SummerPops'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a path should be accepted"
    assert_file "$ANALYSIS_SB/main/Analysis/Results/MDS/SummerPops/0_verify_analysis.txt" \
        "the results folder is the path that was named"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "analysis.folderName = 'MDS/SummerPops'" \
        "and the report says where it came from"
}

# It names a folder under Results, so anything that would climb out of it is refused before
# a task starts rather than resolved into somewhere unexpected.
test_a_folder_name_may_not_leave_the_results_tree() {
    analysis_ready single || return
    analysis_folder_name "'../escape'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "climbing out of Results must stop the run"
    assert_contains "$(analysis_output)" "contains a '..' segment" "naming what is wrong"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/escape/0_verify_analysis.txt" \
        "and nothing is written"
}

# NAMING THE FOLDER IS THE STALENESS MECHANISM. Two settings of one module are told apart by
# the folder each was written to, so one that already holds an analysis is a collision.
test_a_populated_results_folder_is_refused() {
    analysis_ready single || return
    mkdir -p "$ANALYSIS_SB/main/Analysis/Results/verify"
    printf 'an earlier analysis\n' > "$ANALYSIS_SB/main/Analysis/Results/verify/mds_plot.pdf"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "writing over an analysis must stop the run"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "HOLDS AN ANALYSIS ALREADY - 1 entry" "counting what is there"
    assert_contains "$report" "mds_plot.pdf" "and naming it"
    assert_contains "$report" "analysis.folderName" "with the way out"
}

# The record the verification itself leaves is not an analysis. A module that failed after the
# check leaves the folder holding nothing else, and that retry has to be allowed - otherwise
# the first failure makes the folder name unusable for good.
test_the_verification_record_does_not_count_as_an_analysis() {
    analysis_ready single || return
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    assert_file "$ANALYSIS_SB/main/Analysis/Results/verify/0_verify_analysis.txt" \
        "the first run leaves its record"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a second run into the same folder should be allowed"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "holds no analysis" "and say the folder is free"
}

# One folder per results directory, inside the one the user named - the same rule the pipeline
# uses for Output, where only divergence gets a name.
test_each_results_directory_gets_its_own_folder_under_a_multi_run() {
    analysis_ready multi || return
    analysis_folder_name "'sweep'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a multi-run project should verify"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "Results/sweep/Shared_1" "the shared directory gets its own folder"
    assert_contains "$report" "Results/sweep/strict" "and so does the one that shares nothing"
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

# ---------------------------------------------------------------------------------------
# The library a module imports.
#
# A module is its own pipeline, launched directly, and analysis/lib is what it reads the
# project through. These cases run a module for real - the second of the two invocations -
# against a store the case populates itself.

# The probe module: it computes what it would read and where it would write, and prints both.
# Nothing statistical, so the case measures the library and not an analysis.
ANALYSIS_PROBE_MAIN='nextflow.enable.dsl=2

include { analysisPlan } from '"'"'../../lib/plan.nf'"'"'

workflow {
    analysisPlan('"'"'probe'"'"', ['"'"'frequencies'"'"']).targets.each { target ->
        println "PROBE reads ${target.classes.frequencies.dir}"
        println "PROBE writes ${target.results}"
    }
}'

ANALYSIS_PROBE_MANIFEST='{ "name": "probe", "version": "0.1.0", "contract": "freq-1",
  "summary": "print what the library says this project holds", "needs": ["frequencies"] }'

# THE ARCHITECTURE, IN ONE CASE. The module is the entry script and the library sits at a
# fixed place relative to it, so it resolves the same in a checkout and in an installation.
test_a_module_reads_the_library_from_its_own_directory() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_PROBE_MAIN"
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "a module importing the library should run"
    local out; out=$(analysis_output)
    assert_contains "$out" "PROBE reads $ANALYSIS_SB/store/Output/Frequencies" \
        "the module is told where the published tables are"
    assert_contains "$out" "PROBE writes $ANALYSIS_SB/main/Analysis/Results/probe" \
        "and where its own results go"
}

# The verification and the module compute the same partition from the same function, so a
# module can never write into a folder the verification did not clear.
test_a_module_covers_exactly_what_the_verification_cleared() {
    analysis_ready multi || return
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_PROBE_MAIN"
    run_analysis "$ANALYSIS_SB" probe > /dev/null
    local report; report=$(analysis_report "$ANALYSIS_SB")
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "the module should run over both directories"

    local out written
    out=$(analysis_output)
    assert_count 2 "$(printf '%s\n' "$out" | grep -c '^PROBE writes ')" \
        "two results directories, two analyses"
    written=$(printf '%s\n' "$out" | sed -n 's|^PROBE writes ||p' | sort)
    local expected
    expected=$(printf '%s\n' "$ANALYSIS_SB/main/Analysis/Results/probe/Shared_1" \
                              "$ANALYSIS_SB/main/Analysis/Results/probe/strict" | sort)
    assert_eq "$expected" "$written" "one folder per results directory, named as the pipeline named it"
    assert_contains "$report" "3 of 3 runs, in 2 results directories" \
        "and the verification cleared the same two"
}

# The frame never includes a module. If it did, an absent module would be a compile error in
# every other one, which is what the store exists to avoid.
test_the_library_does_not_reach_into_the_module_store() {
    local hits
    hits=$(cd "$REPO_ROOT" && grep -rn "modules/" analysis/lib 2>/dev/null)
    assert_eq "" "$hits" "analysis/lib must not name the store:"$'\n'"$hits"
    hits=$(cd "$REPO_ROOT" && grep -rn "from '\./lib/\|from '\.\./lib/" analysis/modules.nf 2>/dev/null)
    assert_contains "$hits" "lib/paths.nf" "the frame reads the library, which is the allowed direction"
}
