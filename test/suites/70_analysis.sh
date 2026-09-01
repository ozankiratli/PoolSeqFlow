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
    # Required of every module, so a fixture that omits it fails on that rather than on what
    # the case is about. A case testing its absence removes it again.
    printf '{}\n' > "$dir/citations.json"
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
    assert_contains "$(cat "$REPO_ROOT/analysis.nf")" "analysisPlan(module)" \
        "the entry point takes its targets from the library"
    local hits
    hits=$(cd "$REPO_ROOT" && grep -rln "def analysisPlan" . --exclude-dir=.git --exclude-dir=test \
        --exclude-dir=docs --exclude-dir=site --exclude-dir=.claude 2>/dev/null | sort)
    assert_eq "./analysis/lib/plan.nf" "$hits" "and there is one definition of it"
}

test_the_analysis_layer_ships_with_the_release() {
    local f
    for f in analysis.nf analysis/modules.nf analysis/0_verify_analysis.nf \
             analysis/frame.config analysis/analysis.config.template \
             analysis/lib/paths.nf analysis/lib/plan.nf analysis/lib/modules.nf \
             analysis/lib/results.nf analysis/lib/store.nf; do
        assert_file "$REPO_ROOT/$f" "$f must ship"
    done
    assert_contains "$(cat "$REPO_ROOT/PoolSeqFlow")" "lib analysis install" \
        "the payload must carry the analysis directory"
}

# Answering to `PoolSeqFlow analysis` is not being installed, and the install has to say so:
# the layer is copied with everything else while the environment it needs is never created.
test_install_says_the_analysis_command_is_not_the_analysis_layer() {
    local wrapper; wrapper=$(cat "$REPO_ROOT/PoolSeqFlow")
    assert_contains "$wrapper" "THAT DOES NOT MEAN THE ANALYSIS LAYER IS INSTALLED" \
        "install must say that answering is not an installation"
    assert_contains "$wrapper" 'analysis install' \
        "and say how to install it"
}

# One list of modules, in the layer that refuses. A second copy in the wrapper would be the
# one that goes stale.
test_the_module_roster_lives_in_one_place() {
    local hits
    hits=$(cd "$REPO_ROOT" && grep -rln "moduleRoster" . --exclude-dir=.git --exclude-dir=test \
        --exclude-dir=docs --exclude-dir=site --exclude-dir=.claude 2>/dev/null | sort)
    assert_eq "./analysis/lib/modules.nf" "$hits" "the roster must exist in exactly one file"
    assert_contains "$(cat "$REPO_ROOT/PoolSeqFlow")" '--module "$ANALYSIS_COMMAND"' \
        "the wrapper passes the word through rather than judging it"
}

# The three layers, in order. Losing one silently drops either the defaults or the user's
# settings, and both look like the module simply ignoring the config.
test_the_wrapper_layers_three_configurations() {
    local wrapper; wrapper=$(cat "$REPO_ROOT/PoolSeqFlow")
    assert_contains "$wrapper" 'analysis/frame.config' "the installation's frame"
    assert_contains "$wrapper" '-f analysis.config' "then the project's"
    assert_contains "$wrapper" '-f "${ANALYSIS_COMMAND}.config"' "then the module's"
    # analysis/frame.config reads this back. It is the run's only way to the installation,
    # a module having become the entry script.
    assert_contains "$wrapper" 'export POOLSEQFLOW_HOME="$INSTALL"' \
        "and the installation goes into the environment"
}

# An analysis run must not overwrite the pipeline's dag, trace, timeline and report, which
# are the record of the run that produced the results being read.
test_the_defaults_keep_the_session_files_out_of_the_pipeline_reports() {
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/frame.config")
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
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/frame.config")
    assert_contains "$cfg" 'params.cores = params.containsKey' "the cores scope"
    assert_contains "$cfg" 'PATH="${System.getenv(' "bin/ on the task PATH"
    assert_contains "$cfg" 'conda.enabled = true' "conda, which every analysis module needs"
    assert_contains "$cfg" 'resourceLimits' "and the ceiling on what a task may ask for"
}

# The frame's version reaches a module or nothing does: Nextflow reads a nextflow.config beside
# the ENTRY SCRIPT, and for a module that is the module. Without this block every intermediate's
# provenance recorded an unknown release, on both the write and the comparison, so the staleness
# check passed on everything.
test_the_frame_carries_a_version_of_its_own() {
    local version
    version=$(grep -vE '^\s*(#|$)' "$REPO_ROOT/analysis/frame.version" 2>/dev/null | head -1 | tr -d ' ')
    case "$version" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9]) ;;
        *) fail_case "analysis/frame.version must hold one YYYYMMDD.NNN line, got '$version'"; return ;;
    esac
}

# `manifest.version` IS the pipeline release: 0_verify_analysis.nf:42 reads it and compares it
# against the .poolseqflow_version the results carry. A manifest block in frame.config overrides
# it for every analysis run, and the identity check then refuses every project - measured, and it
# failed 17 runtime cases before the version moved to a file of its own.
test_the_frame_version_does_not_hijack_the_release() {
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/frame.config")
    assert_not_contains "$cfg" "manifest {" "frame.config must not declare a manifest"
    # Comments stripped: the reason this must not read the release is written there in full.
    local code; code=$(grep -vE '^\s*//' "$REPO_ROOT/analysis/lib/paths.nf")
    assert_not_contains "$code" "workflow.manifest" \
        "and frameVersion() must not read the release"
    assert_contains "$code" 'frame.version' "it reads its own file instead"
    # A params key would be settable from a project's analysis.config, and a provenance record
    # the analysed project can rewrite records nothing.
    assert_not_contains "$cfg" "frameVersion" "and it is not a parameter either"
}

# bump-version.sh moves the RELEASE. The frame version moves when the frame changes, which is a
# different event, so a release bump must leave it alone - otherwise every intermediate derived
# before the release reads as stale for no reason.
test_bump_version_does_not_touch_the_frame() {
    local bump; bump=$(cat "$REPO_ROOT/dev/scripts/bump-version.sh")
    assert_not_contains "$bump" "frame.version" "bump-version.sh must not name the frame version"
    assert_not_contains "$bump" "frame.config" "nor the frame config"
    assert_contains "$bump" 'NFCONFIG="nextflow.config"' \
        "and the file it rewrites is named explicitly"
}

# A missing frame version REFUSES rather than falling back. Both the write and the comparison
# would read the same placeholder, so a fallback is a check that passes on everything.
test_a_run_without_a_frame_version_refuses() {
    local paths; paths=$(cat "$REPO_ROOT/analysis/lib/paths.nf")
    assert_contains "$paths" "does not know its own version" "the refusal exists"
    assert_not_contains "$(cat "$REPO_ROOT/analysis/lib/store.nf")" "'unknown'" \
        "and store.nf no longer has a placeholder to compare against itself"
    assert_not_contains "$(cat "$REPO_ROOT/analysis/lib/modules.nf")" "?: 'unknown'" \
        "nor does the builtin roster"
}

# env is a config scope and config is read before the entry script, so PATH cannot be built
# from the params.dir.bin that analysisPlan() sets - it has to compute the installation itself.
# The two would disagree silently: the task would run with a PATH pointing at the module.
test_the_task_path_does_not_wait_for_params_dir_bin() {
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/frame.config")
    assert_not_contains "$cfg" 'PATH="${params.dir.bin}' \
        "PATH must not be interpolated from a params value set later"
    local plan; plan=$(cat "$REPO_ROOT/analysis/lib/plan.nf")
    assert_contains "$plan" 'params.dir.bin = "${installDir()}/bin"' \
        "and analysisPlan sets it for the Groovy that reads it"
}

# The scope is not declared in any config file, so the defaults live in the code that reads
# them. A block in the frame would be a second copy of every default, in a file that ships.
test_the_analysis_settings_default_without_a_config_block() {
    local cfg paths
    cfg=$(cat "$REPO_ROOT/analysis/frame.config")
    paths=$(cat "$REPO_ROOT/analysis/lib/paths.nf")
    assert_not_contains "$cfg" 'runs = ' "the frame declares no run selection"
    assert_not_contains "$cfg" 'folderName' "and no folder name"
    assert_contains "$paths" "runs      : 'all'" "the default for runs is in the accessor"
    assert_contains "$paths" 'scope.containsKey(key) ? scope[key] : defaults[key]' \
        "and a key the project did not set falls back to it"
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
    assert_contains "$(analysis_output)" "PoolSeqFlow analysis <module>" \
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

# OPTION (C), Z's call: a module names itself and nothing else, and analysisPlan() reads what it
# needs from that module's own manifest. Before this there were two lists to keep equal - the
# manifest's, which the verification ran against, and the literal in main.nf, which the module
# ran against - and a disagreement between them was silent.
#
# The module below asks for NOTHING, so a required class in what it gets back can only have come
# from the manifest.
test_a_module_states_what_it_reads_only_in_its_manifest() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local main='nextflow.enable.dsl=2

include { analysisPlan } from '"'"'../../lib/plan.nf'"'"'

workflow {
    analysisPlan('"'"'probe'"'"').targets.each { target ->
        println "PROBE requires " + target.classes.findAll { k, v -> v.required }.keySet().sort().join(",")
    }
}'
    analysis_install_module probe \
        '{"name":"probe","version":"0.1.0","contract":"freq-1","summary":"reads depths","needs":["depths"]}' \
        "$main"
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "a module naming only itself should run"
    assert_contains "$(analysis_output)" "PROBE requires depths" \
        "the required classes come from the module's manifest, which main.nf never repeats"
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

# A module is a pipeline of its own, so a manifest with no pipeline behind it is a broken
# install. Caught while the DAG is built, which is before the verification clears the results
# folder - the wrapper's own check happens after, when the folder is already gone.
test_a_module_with_a_manifest_but_no_pipeline_refuses() {
    analysis_ready single || return
    analysis_install_module mds \
        '{"name":"mds","version":"1.4.2","contract":"freq-1","summary":"scaling over frequencies"}'
    rm "$ANALYSIS_SB/install/analysis/modules/mds/main.nf"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a module with no main.nf must stop even an unrelated module"
    assert_contains "$(analysis_output)" "has a manifest but no main.nf" \
        "naming what is missing"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/verify" \
        "and refusing before anything is cleared or written"
}

# A module says what it should be cited with, and it is not optional: a result whose method
# nobody can credit is the same class of gap as one nobody can regenerate. Refused where
# main.nf is, at DAG-build time, before the verification clears a results folder.
test_a_module_without_citations_refuses() {
    analysis_ready single || return
    analysis_install_module mds \
        '{"name":"mds","version":"1.4.2","contract":"freq-1","summary":"scaling over frequencies"}'
    rm "$ANALYSIS_SB/install/analysis/modules/mds/citations.json"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "a module with no citations.json must stop even an unrelated module"
    assert_contains "$(analysis_output)" "has no citations.json" "naming what is missing"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/verify" \
        "and refusing before anything is cleared or written"
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
    analysisPlan('"'"'probe'"'"').targets.each { target ->
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

# ---------------------------------------------------------------------------------------
# What a module writes: its results, and the intermediates it derives on the way.

# A module that does the whole shape once - restore what is shared, derive it if it is not
# there, produce an analysis, publish it. Nothing statistical again; these cases measure the
# moves.
ANALYSIS_WRITER_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/plan.nf'
include { intermediateFile; publishIntermediate; RestoreIntermediates } from '../../lib/store.nf'
include { PublishResults } from '../../lib/results.nf'

process Derive {
    debug true

    input:
    val target

    output:
    tuple val(target), path('result.*')

    script:
    matrix = intermediateFile(target, 'matrix.tsv')
    publish = publishIntermediate(target, 'matrix.tsv', 'staged.tsv')
    """
    if [ -f '${matrix}' ]; then
        echo "WRITER reused ${matrix}"
    else
        printf 'derived from %s\\n' '${target.label}' > staged.tsv
        ${publish}
        echo "WRITER derived ${matrix}"
    fi

    printf 'analysis of %s\\n' '${target.label}' > result.tsv
    printf 'the script that produced it\\n' > result.R
    """
}

workflow {
    def targets = channel.fromList(analysisPlan('writer').targets)
    RestoreIntermediates(targets.map { target -> tuple(target, ['matrix.tsv']) })
    PublishResults(Derive(RestoreIntermediates.out))
}
MODULE
)

ANALYSIS_WRITER_MANIFEST='{ "name": "writer", "version": "0.1.0", "contract": "freq-1",
  "summary": "derive one intermediate and publish one analysis", "needs": ["frequencies"] }'

# The same, minus everything shared: it produces its results and then fails, which is the state
# refuse-if-populated has to survive.
ANALYSIS_BREAKER_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/plan.nf'
include { PublishResults } from '../../lib/results.nf'

process Derive {
    input:
    val target

    output:
    tuple val(target), path('result.*')

    script:
    """
    printf 'analysis of %s\\n' '${target.label}' > result.tsv
    echo "BREAKER has its results and is about to fail" >&2
    exit 3
    """
}

workflow {
    PublishResults(Derive(channel.fromList(analysisPlan('breaker').targets)))
}
MODULE
)

ANALYSIS_BREAKER_MANIFEST='{ "name": "breaker", "version": "0.1.0", "contract": "freq-1",
  "summary": "fail after producing results", "needs": ["frequencies"] }'

# Produces a result and no script - the thing README rule 15 forbids and nothing used to catch.
ANALYSIS_MUTE_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/plan.nf'
include { PublishResults } from '../../lib/results.nf'

process Derive {
    input:
    val target

    output:
    tuple val(target), path('result.*')

    script:
    """
    printf 'analysis of %s\\n' '${target.label}' > result.tsv
    """
}

workflow {
    PublishResults(Derive(channel.fromList(analysisPlan('mute').targets)))
}
MODULE
)

ANALYSIS_MUTE_MANIFEST='{ "name": "mute", "version": "20260901.001", "contract": "freq-1",
  "summary": "produce a result and no script", "needs": ["frequencies"] }'

# Set up a single-run project with results planted and one module installed.
analysis_writer_ready() {
    analysis_ready single || return 1
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_WRITER_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    return 0
}

# What Analysis/Main holds for the one results directory a single-run project has.
analysis_main_dir() {
    printf '%s\n' "$ANALYSIS_SB/main/Analysis/Main/Output"
}

# What `PoolSeqFlow analysis complete` will do: Analysis/Main moves to permanent storage. The
# command is not built yet and these cases must not wait for it - the move back is the half
# that carries the risk.
analysis_archive_main() {
    mkdir -p "$ANALYSIS_SB/store/Analysis"
    mv "$ANALYSIS_SB/main/Analysis/Main" "$ANALYSIS_SB/store/Analysis/Main"
}

# One analysis, start to finish: verify, then the module itself.
analysis_run_module() {
    local module="$1" status
    status=$(run_analysis "$ANALYSIS_SB" "$module")
    [ "$status" = "0" ] || { printf 'verify:%s\n' "$status"; return 0; }
    run_module "$ANALYSIS_SB" "$module"
}

# A module writes everything it produced into the folder the verification cleared, and the
# record that cleared it is still there beside the analysis.
test_a_module_publishes_what_it_produced() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder; folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/result.tsv" "the analysis is published"
    assert_file "$folder/result.R" "and so is the script beside it"
    assert_file "$folder/0_verify_analysis.txt" \
        "the record that cleared the folder travels with the analysis it let run"
    assert_eq "analysis of Output" "$(cat "$folder/result.tsv" 2>/dev/null)" \
        "the file's contents, not a link into a work directory cleanup has removed"
}

# THE HALF THAT WILL REGRESS. A module that fails must leave the folder as the verification
# left it, or its own name is unusable for good: refuse-if-populated cannot tell a crash from
# a collision.
test_a_module_that_fails_publishes_nothing() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module breaker "$ANALYSIS_BREAKER_MANIFEST" "$ANALYSIS_BREAKER_MAIN"

    local status; status=$(analysis_run_module breaker)
    assert_status 1 "$status" "the breaker module should fail"

    local folder held
    folder="$ANALYSIS_SB/main/Analysis/Results/breaker"
    held=$(ls -A "$folder" 2>/dev/null | sort | tr '\n' ' ')
    assert_eq "0_verify_analysis.txt " "$held" \
        "a failed module leaves the folder holding nothing but the verification record"

    status=$(run_analysis "$ANALYSIS_SB" breaker)
    assert_status 0 "$status" "so the retry is not refused"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "holds no analysis" \
        "and the folder still reads as ready to be written"
}

# A published analysis is self-describing: the result, the script that made it, the record
# that cleared the folder, and what it was all produced with. Written into the STAGE, so the
# citations arrive in the same rename and a folder is never half-described.
test_a_published_analysis_carries_its_citations() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder; folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/CITATIONS.md" "the citation list is published with the analysis"
    assert_file "$folder/references.bib" "and the BibTeX beside it"

    local md; md=$(cat "$folder/CITATIONS.md" 2>/dev/null)
    assert_contains "$md" "PoolSeqFlow" "citing the pipeline itself"
    assert_contains "$md" "Nextflow" "and Nextflow"
    assert_contains "$md" "R" "and R, which every module runs on"
    # The pipeline's own tools are in install/citations.json and an analysis invokes none of
    # them. Citing BWA for a run that never aligned anything would be a false claim.
    assert_not_contains "$md" "BWA" "but not a tool the analysis never ran"
    assert_not_contains "$md" "SnpEff" "nor another"
}

# A module is published separately, so the frame cannot hold a list of citations for modules
# that do not exist yet. Each carries its own, and they are merged for the run that used it.
test_a_module_adds_its_own_citations() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_WRITER_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    cat > "$ANALYSIS_SB/install/analysis/modules/writer/citations.json" <<'JSON'
{
  "vegan": {
    "name": "vegan",
    "type": "misc",
    "key": "oksanen2024vegan",
    "authors": "Oksanen, Jari and others",
    "title": "vegan: Community Ecology Package",
    "url": "https://CRAN.R-project.org/package=vegan",
    "r_package": "vegan"
  }
}
JSON

    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should still run"
    local md; md=$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/CITATIONS.md" 2>/dev/null)
    assert_contains "$md" "vegan" "the module's own citation is in the list"
    assert_contains "$md" "PoolSeqFlow" "beside the frame's"
    assert_contains "$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/references.bib" 2>/dev/null)" \
        "oksanen2024vegan" "and its BibTeX key is in references.bib"
}

# THE REPRODUCIBILITY GUARANTEE, enforced rather than documented. README rule 15 has always
# said a result ships the script that made it; nothing checked, so a module could simply not
# and no one would know until someone tried to regenerate the result.
test_a_module_that_emits_no_script_publishes_nothing() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module mute "$ANALYSIS_MUTE_MANIFEST" "$ANALYSIS_MUTE_MAIN"

    local status; status=$(analysis_run_module mute)
    assert_status 1 "$status" "publishing without a script must fail the run"

    local out; out=$(analysis_output)
    assert_contains "$out" "carries no script" "saying what is missing"
    assert_contains "$out" "result.tsv" "and listing what it did produce"
    assert_contains "$out" "*.R" "and which extensions count"

    # The same guarantee the breaker case makes: a refusal here must not consume the folder
    # name, or the module could never be published under it again.
    local folder held
    folder="$ANALYSIS_SB/main/Analysis/Results/mute"
    held=$(ls -A "$folder" 2>/dev/null | sort | tr '\n' ' ')
    assert_eq "0_verify_analysis.txt " "$held" \
        "and the folder still holds nothing but the verification record"
    assert_no_file "$folder/result.tsv" "the result itself is not published"
}

# Every intermediate says which results it came from. Analysis/Main outlives any one analysis,
# so nothing else in the layout would notice a pipeline re-run underneath it.
test_an_intermediate_records_the_results_it_came_from() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local main; main=$(analysis_main_dir)
    assert_file "$main/matrix.tsv" "the intermediate is on the working volume"
    assert_file "$main/matrix.tsv.provenance" "with its provenance record beside it"

    local record; record=$(cat "$main/matrix.tsv.provenance" 2>/dev/null)
    assert_contains "$record" ".poolseqflow_params" "the record names the parameter manifest"
    assert_contains "$record" ".poolseqflow_version" "and the version record"
    assert_contains "$record" ".multirun.csv" "and the run table, absent or not"
}

# Derived once, reused by every module after it. That is what Analysis/Main is for, and the
# reuse is skip-by-existence across separate Nextflow runs.
test_an_intermediate_is_derived_once() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive it"
    assert_contains "$(analysis_output)" "WRITER derived" "the first run derives the intermediate"

    analysis_folder_name "'second'"
    status=$(analysis_run_module writer)
    assert_status 0 "$status" "the second run should reuse it"
    local out; out=$(analysis_output)
    assert_contains "$out" "WRITER reused" "the second run reuses it"
    assert_contains "$out" "on the working volume" "and finds it without touching storage"
}

# THE ONE THE VERIFICATION CANNOT CATCH. Re-running the pipeline under the settings it already
# recorded leaves the identity check passing, and every intermediate derived from the results
# it replaced is stale. The record beside the intermediate is the only thing that sees it.
test_an_intermediate_derived_from_other_results_refuses() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive the intermediate"

    # Field 2 is the date the results were recorded, which the identity check prints and does
    # not compare - so this is a re-run the verification has no quarrel with.
    local version release
    version="$ANALYSIS_SB/store/Output/.poolseqflow_version"
    release=$(cut -f1 < "$version")
    printf '%s\t%s\n' "$release" "1999-01-01" > "$version"

    analysis_folder_name "'after_rerun'"
    status=$(run_analysis "$ANALYSIS_SB" writer)
    assert_status 0 "$status" "the verification still passes, which is the point"

    status=$(run_module "$ANALYSIS_SB" writer)
    assert_status 1 "$status" "the module refuses on the stale intermediate"
    local out; out=$(analysis_output)
    assert_contains "$out" "matrix.tsv is STALE" "and names the file"
    assert_contains "$out" ".poolseqflow_version" "and the record that moved"
}

# What is IN the record is the contract: a later run compares against it byte for byte. The
# frame version is the half the results digests cannot see - .poolseqflow_version records the
# PIPELINE release that produced the results, not the code that derived from them.
test_an_intermediate_records_the_frame_that_derived_it() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should derive the intermediate"

    local record declared
    record=$(cat "$(analysis_main_dir)/matrix.tsv.provenance" 2>/dev/null)
    declared=$(grep -vE '^\s*(#|$)' "$REPO_ROOT/analysis/frame.version" | head -1 | tr -d ' ')
    assert_contains "$record" "frame " "the record names the frame that derived it"
    assert_contains "$record" "$declared" "with the version frame.config declares"
    assert_not_contains "$record" "unknown" "and never a placeholder"
    assert_contains "$record" ".poolseqflow_version" "beside the pipeline's own records"
}

# THE RISKY TRANSFER. Named files, one at a time, out of a directory that holds other things -
# a wholesale copy is how a neighbour comes back with them.
#
# It COPIES: permanent storage keeps its copy, so a cycle costs one transfer instead of two and
# the next `complete` has something to discard rather than something to send again.
test_an_intermediate_comes_back_from_permanent_storage() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive the intermediate"

    analysis_archive_main
    local archived; archived="$ANALYSIS_SB/store/Analysis/Main/Output"
    printf 'somebody else put this here\n' > "$archived/bystander.txt"
    assert_file "$archived/matrix.tsv" "the intermediate is in permanent storage to start with"

    analysis_folder_name "'from_storage'"
    status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should run against the archived intermediate"

    local main out
    main=$(analysis_main_dir)
    out=$(analysis_output)
    assert_contains "$out" "copied back from permanent storage" "the copy back is reported"
    assert_contains "$out" "WRITER reused" "and the intermediate is reused, not derived again"
    assert_file "$main/matrix.tsv" "it is on the working volume now"
    assert_file "$main/matrix.tsv.provenance" "and its record came with it"
    assert_file "$archived/matrix.tsv" "and permanent storage still has it - this is a copy"
    assert_file "$archived/matrix.tsv.provenance" "record included"
    assert_file "$archived/bystander.txt" \
        "and nothing else in permanent storage was carried off with them"
}

# The stage the copy lands in belongs to the transfer, not to Analysis/Main. Left behind it
# would be read as an intermediate by the next `find` that walks Main.
test_a_copy_back_leaves_no_staging_directory() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive the intermediate"

    analysis_archive_main
    analysis_folder_name "'from_storage'"
    status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should run against the archived intermediate"

    local leftovers
    leftovers=$(find "$(analysis_main_dir)" -maxdepth 1 -name '.restore.*' 2>/dev/null | wc -l)
    assert_eq "0" "$leftovers" "no staging directory survives the copy"
}

# ---------------------------------------------------------------------------------------
# `PoolSeqFlow analysis complete` - the move to permanent storage.

# Where an archived analysis lands. The same relative path under either volume, which is what
# lets a module find an intermediate again after this has run.
analysis_archived() {
    printf '%s\n' "$ANALYSIS_SB/store/Analysis"
}

# One analysis and one intermediate on the working volume, ready to be moved.
analysis_completable() {
    analysis_writer_ready || return 1
    local status; status=$(analysis_run_module writer)
    [ "$status" = "0" ] || { fail_case "the writer module should have run first"; return 1; }
    return 0
}

test_complete_moves_the_analyses_and_the_intermediates() {
    analysis_completable || return
    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "complete should move what the writer produced"

    local store; store=$(analysis_archived)
    assert_file "$store/Results/writer/result.tsv" "the analysis is in permanent storage"
    assert_file "$store/Results/writer/0_verify_analysis.txt" "with the record that cleared it"
    assert_file "$store/Main/Output/matrix.tsv" "and so is the intermediate"
    assert_file "$store/Main/Output/matrix.tsv.provenance" "with its provenance record"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/writer" "the working copies are gone"
    assert_no_file "$(analysis_main_dir)/matrix.tsv" ""
}

# THE RISK, IN THE OTHER DIRECTION. RestoreIntermediates already proves a move back does not
# carry off a neighbour; this is the same guarantee on the way out.
test_complete_leaves_permanent_storage_alone() {
    analysis_completable || return
    local store; store=$(analysis_archived)
    mkdir -p "$store/Main/Output" "$store/Results/somebody_else"
    printf 'not mine\n' > "$store/Main/Output/bystander.txt"
    printf 'not mine\n' > "$store/Results/somebody_else/report.tsv"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "complete should run with other things already in storage"
    assert_eq "not mine" "$(cat "$store/Main/Output/bystander.txt" 2>/dev/null)" \
        "a file already beside the intermediates is untouched"
    assert_eq "not mine" "$(cat "$store/Results/somebody_else/report.tsv" 2>/dev/null)" \
        "and so is somebody else's results folder"
    assert_file "$store/Main/Output/matrix.tsv" "while what was asked for did move"
}

# Logs and Session describe invocations rather than results - Session is overwritten by the
# next one and Logs is appended to by every one - so neither belongs in permanent storage.
test_complete_leaves_the_working_records_behind() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null
    local out; out=$(analysis_output)
    assert_dir "$ANALYSIS_SB/main/Analysis/Logs" "Logs stays on the working volume"
    assert_no_file "$(analysis_archived)/Logs" "and does not appear in permanent storage"
    assert_contains "$out" "Logs, Session and work stay" "and the run says so"
}

# Two different analyses under one name is what folderName exists to prevent, so a name
# already taken stops the whole command - not just that one item.
test_complete_refuses_a_name_already_in_permanent_storage() {
    analysis_completable || return
    local store; store=$(analysis_archived)
    mkdir -p "$store/Results/writer"
    printf 'an older analysis\n' > "$store/Results/writer/result.tsv"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 1 "$status" "a collision should stop the command"
    local out; out=$(analysis_output)
    assert_contains "$out" "already in permanent storage" "naming what collided"
    assert_contains "$out" "Results/writer" "and which one"
    assert_eq "an older analysis" "$(cat "$store/Results/writer/result.tsv" 2>/dev/null)" \
        "the copy in storage is untouched"
    assert_file "$ANALYSIS_SB/main/Analysis/Results/writer/result.tsv" \
        "and NOTHING moved - not the colliding folder"
    assert_file "$(analysis_main_dir)/matrix.tsv" "and not the intermediate either"
}

# A failed verification leaves a folder holding its record and nothing else, and the manual
# promises that retry is allowed. Archiving it would take the name into storage and the
# two-root refusal would then block the retry for good.
test_complete_leaves_a_folder_holding_only_a_failed_record() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_WRITER_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    run_analysis "$ANALYSIS_SB" writer > /dev/null

    local folder; folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/0_verify_analysis.txt" "the verification record is there to start with"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "complete should run"
    assert_contains "$(analysis_output)" "left behind" "and say it passed the folder over"
    assert_file "$folder/0_verify_analysis.txt" "the record stays on the working volume"
    assert_no_file "$(analysis_archived)/Results/writer" \
        "and the name is not consumed in permanent storage"
}

# Interrupted, it has to be safe to run again; and with nothing left to move it must not
# invent an error.
test_complete_run_twice_moves_nothing_the_second_time() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null
    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "a second run should succeed"
    local out; out=$(analysis_output)
    assert_contains "$out" "0 item(s) moved" "having found nothing to move"
    assert_file "$(analysis_archived)/Main/Output/matrix.tsv" "and disturbed nothing"
}

# END TO END, and the reason the relative path is the same under both volumes: a module run
# after `complete` finds its intermediate in storage and brings it back.
test_a_module_reaches_an_intermediate_that_complete_archived() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should run against the archived intermediate"
    local out; out=$(analysis_output)
    assert_contains "$out" "copied back from permanent storage" "restoring it"
    assert_contains "$out" "WRITER reused" "rather than deriving it again"
}

# THE LOOP THAT WAS NEVER TESTED, and the one that failed: complete -> run -> complete. The
# second complete used to refuse, because every intermediate the run copied back collided with
# the copy that was still in storage and every collision was a refusal.
test_complete_after_a_resume_discards_the_working_intermediate() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module runs against the archived intermediate"
    assert_file "$(analysis_main_dir)/matrix.tsv" "which puts a working copy back"

    status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "the second complete should succeed, not refuse"

    local out store
    out=$(analysis_output)
    store=$(analysis_archived)
    assert_contains "$out" "discarded - permanent storage has it" "saying what it discarded"
    assert_contains "$out" "Main/Output/matrix.tsv" "and naming it"
    assert_no_file "$(analysis_main_dir)/matrix.tsv" "the working copy is gone"
    assert_no_file "$(analysis_main_dir)/matrix.tsv.provenance" "and so is its record"
    assert_file "$store/Main/Output/matrix.tsv" "the archived copy is untouched"
    assert_file "$store/Results/after_complete/result.tsv" "and the new analysis did move"
}

# The discard is licensed by the provenance records agreeing. When they do not, the two copies
# came from different results and only the user can say which one to keep.
test_complete_refuses_an_intermediate_whose_records_disagree() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    analysis_run_module writer > /dev/null

    local main store
    main=$(analysis_main_dir)
    store=$(analysis_archived)
    printf 'derived from something else\n' > "$main/matrix.tsv.provenance"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 1 "$status" "a disagreement should stop the command"
    local out; out=$(analysis_output)
    assert_contains "$out" "do not agree" "naming the disagreement"
    assert_contains "$out" "Main/Output/matrix.tsv" "and which intermediate"
    assert_contains "$out" "Nothing was moved and nothing was discarded" "and doing nothing"
    assert_file "$main/matrix.tsv" "the working copy is left for the user to judge"
    assert_file "$store/Main/Output/matrix.tsv" "and so is the archived one"
    assert_no_file "$store/Results/after_complete" "and the analysis did not move either"
}

# A working copy with no record beside it cannot license its own discard. publishIntermediate
# writes the record first, so this state means something removed it by hand.
test_complete_refuses_an_intermediate_with_no_record_beside_it() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    analysis_run_module writer > /dev/null
    rm -f "$(analysis_main_dir)/matrix.tsv.provenance"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 1 "$status" "a missing record should stop the command"
    local out; out=$(analysis_output)
    assert_contains "$out" "no provenance record" "saying which side is missing one"
    assert_file "$(analysis_main_dir)/matrix.tsv" "and nothing is discarded"
}
