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

# The fixture's metadata carries exp_time, and a project with a time column has to say how to
# read it or every analysis refuses. So the baseline carries the analysis.config a real project of
# this shape would have, and EVERY helper that writes that file carries this block too - the file
# is written whole, so a helper that omitted it would leave the project unreadable. A case testing
# what happens without an analysis.config removes the time column as well.
ANALYSIS_TIME_BLOCK="        timeVar {
            kind  = 'categorical'
            order = ['T1', 'T2']
        }"

analysis_write_time_config() {
    printf 'params {\n    analysis {\n%s\n    }\n}\n' "$ANALYSIS_TIME_BLOCK" \
        > "$1/main/analysis.config"
}

# A single-run project whose identity the pipeline has recorded. Step 0 alone writes
# .poolseqflow_version and .poolseqflow_params, which is everything the identity check reads,
# and costs about a fifth of a full run.
analysis_baseline_single() {
    [ -n "$ANALYSIS_BASELINE_SINGLE" ] && return 0
    local sb status
    sb=$(make_pipeline_sandbox "analysis-single")
    write_sandbox_config "$sb"
    analysis_write_time_config "$sb"
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
    analysis_write_time_config "$sb"
    status=$(run_verify_only "$sb")
    [ "$status" = "0" ] || return 1
    ANALYSIS_BASELINE_MULTI="$sb"
    return 0
}

# What a completed run would have left in a results directory. The analysis layer counts these
# files and never opens them, so empty ones answer exactly the question the count asks.
analysis_plant_results() {
    local out="$1" name
    mkdir -p "$out/Frequencies" "$out/VCF" "$out/Ready" "$out/Reports" "$out/Reports/Depth"
    for name in Test_snp Test_indel; do
        : > "$out/Frequencies/${name}_freq.tsv"
        : > "$out/Frequencies/${name}_depth.tsv"
    done
    : > "$out/VCF/Test.vcf"
    for name in 1 2 3 4 5 6; do
        : > "$out/Ready/TestSample${name}_ready.bam"
        : > "$out/Ready/TestSample${name}_ready.bam.bai"
        : > "$out/Reports/Depth/TestSample${name}_depth_histogram.tsv"
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
    printf 'params {\n    analysis {\n        runs = %s\n%s\n    }\n}\n' "$1" "$ANALYSIS_TIME_BLOCK" \
        > "$ANALYSIS_SB/main/analysis.config"
}

# The same for the results folder name.
analysis_folder_name() {
    printf 'params {\n    analysis {\n        folderName = %s\n%s\n    }\n}\n' "$1" "$ANALYSIS_TIME_BLOCK" \
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
    local lib; lib=$(cat "$REPO_ROOT/analysis/lib/nf/plan.nf")
    assert_contains "$lib" "from '../../../scripts/variants.nf'" \
        "the results directory of a run comes from the pipeline's own plan"
    assert_contains "$lib" "from '../../../scripts/resolve_parameters.nf'" \
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
    assert_eq "./analysis/lib/nf/plan.nf" "$hits" "and there is one definition of it"
}

test_the_analysis_layer_ships_with_the_release() {
    local f
    for f in analysis.nf analysis/modules.nf analysis/0_verify_analysis.nf analysis/complete.nf \
             analysis/frame.config analysis/frame.version analysis/citations.json \
             analysis/analysis.config.template \
             analysis/lib/nf/paths.nf analysis/lib/nf/plan.nf analysis/lib/nf/modules.nf \
             analysis/lib/nf/results.nf analysis/lib/nf/store.nf analysis/lib/nf/citations.nf \
             analysis/lib/nf/design.nf analysis/lib/nf/outputs.nf analysis/lib/nf/time.nf \
             analysis/lib/nf/pools.nf; do
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
    assert_eq "./analysis/lib/nf/modules.nf" "$hits" "the roster must exist in exactly one file"
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
    # The wrapper exports it into the launching shell, which is the task's environment only
    # under the local executor.
    assert_contains "$cfg" 'POOLSEQFLOW_HOME="${System.getenv(' \
        "and the installation, for a task that does not inherit the launching shell"
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
    local code; code=$(grep -vE '^\s*//' "$REPO_ROOT/analysis/lib/nf/paths.nf")
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
    local paths; paths=$(cat "$REPO_ROOT/analysis/lib/nf/paths.nf")
    assert_contains "$paths" "does not know its own version" "the refusal exists"
    assert_not_contains "$(cat "$REPO_ROOT/analysis/lib/nf/store.nf")" "'unknown'" \
        "and store.nf no longer has a placeholder to compare against itself"
    assert_not_contains "$(cat "$REPO_ROOT/analysis/lib/nf/modules.nf")" "?: 'unknown'" \
        "nor does the builtin roster"
}

# env is a config scope and config is read before the entry script, so PATH cannot be built
# from the params.dir.bin that analysisPlan() sets - it has to compute the installation itself.
# The two would disagree silently: the task would run with a PATH pointing at the module.
test_the_task_path_does_not_wait_for_params_dir_bin() {
    local cfg; cfg=$(cat "$REPO_ROOT/analysis/frame.config")
    assert_not_contains "$cfg" 'PATH="${params.dir.bin}' \
        "PATH must not be interpolated from a params value set later"
    local plan; plan=$(cat "$REPO_ROOT/analysis/lib/nf/plan.nf")
    assert_contains "$plan" 'params.dir.bin = "${installDir()}/bin"' \
        "and analysisPlan sets it for the Groovy that reads it"
}

# The scope is not declared in any config file, so the defaults live in the code that reads
# them. A block in the frame would be a second copy of every default, in a file that ships.
test_the_analysis_settings_default_without_a_config_block() {
    local cfg paths
    cfg=$(cat "$REPO_ROOT/analysis/frame.config")
    paths=$(cat "$REPO_ROOT/analysis/lib/nf/paths.nf")
    assert_not_contains "$cfg" 'runs = ' "the frame declares no run selection"
    assert_not_contains "$cfg" 'folderName' "and no folder name"
    assert_contains "$paths" "runs      : 'all'" "the default for runs is in the accessor"
    assert_contains "$paths" 'if (!scope.containsKey(key)) return defaults[key]' \
        "and a key the project did not set falls back to it"
    # Nextflow REPLACES a nested map rather than merging into it, so a project writing one
    # sub-key would otherwise lose every other default in that scope.
    assert_contains "$paths" 'return defaults[key] + written' \
        "while a scope the project set only part of keeps the rest of its defaults"
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

include { analysisPlan } from '"'"'../../lib/nf/plan.nf'"'"'

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

# resultsTargets() marks a class required by asking whether the manifest's `needs` contains its
# name, so a name no class answers to used to pass verification with that check silently absent -
# the module then started with the files it said it could not run without unaccounted for.
test_a_module_needing_an_unknown_artifact_class_refuses() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module probe \
        '{"name":"probe","version":"0.1.0","contract":"freq-1","summary":"reads nothing that exists","needs":["frequencies","pileups"]}'
    local status; status=$(run_analysis "$ANALYSIS_SB" probe)
    assert_status 1 "$status" "a manifest naming a class the frame has no answer for must stop the run"
    local out; out=$(analysis_output)
    assert_contains "$out" "pileups" "the refusal names the class that does not exist"
    assert_contains "$out" "bams, depths, frequencies, histograms, vcf" \
        "and lists every class a module can name"
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
# The experimental design, and the one thing the frame refuses about it.

# Writes a metadata file into a sandbox's project directory, replacing the fixture's.
analysis_write_metadata() {
    printf '%s\n' "$2" > "$1/main/metadata.csv"
}

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
# off its target: poolSizes() and diploidy live in the pipeline's scripts, which a module does
# not import.
#
# The detection limits below are hand-computed from 1/(2*diploidy*poolSize), which is a third
# copy of the equation - the Groovy one in resolve_parameters.nf and the awk one in
# bin/filterFalsePositives.sh are tied together by 50_helpers, and these numbers tie this one
# to both.

test_the_verification_report_states_the_pool_sizes() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the fixture's pools are consistent"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "POOL SIZES:                diploidy 2, 6 pools of 100 individuals" \
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
    assert_contains "$report" "diploidy 2, 2 pools" "the sizes are no longer one number"
    assert_contains "$report" "PoolA: 100 individuals, 200 chromosomes, frequencies above 0.0025" \
        "the pool with a blank cell takes the run's own poolSize"
    assert_contains "$report" "PoolB: 25 individuals, 50 chromosomes, frequencies above 0.01" \
        "and the one that sets param_poolSize is measured and reported on its own"
}

# ---------------------------------------------------------------------------------------
# The time axis. Every failure here is silent when it is not caught: the plot renders, the
# slope has a sign, and nothing says the order was wrong.

# Replaces the baseline's analysis.config with an `analysis` scope of the case's own.
analysis_write_analysis_config() {
    cat > "$1/main/analysis.config" <<CFG
params {
    analysis {
$2
    }
}
CFG
}

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

# ---------------------------------------------------------------------------------------
# Biological and technical replicates. The two have OPPOSITE statistical standing - biological
# ones are independent and carry degrees of freedom, technical ones are the same material
# measured twice and carry none - so treating one as the other is pseudo-replication.

# Two conditions, two biological replicates each, and two technical dimensions crossed over
# them: 2 lanes x 2 sequencing runs = 4 series per unit, 16 series, 8 independent units.
ANALYSIS_REPLICATE_METADATA='SampleID,RG_Sample,exp_treatment,exp_rep,exp_lane,exp_seqrun,exp_time
S1,P1,control,1,L1,R1,T1
S2,P2,control,1,L1,R1,T2
S3,P3,control,1,L2,R1,T1
S4,P4,control,1,L2,R1,T2
S5,P5,control,1,L1,R2,T1
S6,P6,control,1,L1,R2,T2
S7,P7,control,1,L2,R2,T1
S8,P8,control,1,L2,R2,T2
S9,P9,control,2,L1,R1,T1
S10,P10,control,2,L1,R1,T2
S11,P11,control,2,L2,R1,T1
S12,P12,control,2,L2,R1,T2
S13,P13,control,2,L1,R2,T1
S14,P14,control,2,L1,R2,T2
S15,P15,control,2,L2,R2,T1
S16,P16,control,2,L2,R2,T2'

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

# ---------------------------------------------------------------------------------------
# The library a module imports.
#
# A module is its own pipeline, launched directly, and analysis/lib is what it reads the
# project through. These cases run a module for real - the second of the two invocations -
# against a store the case populates itself.

# The probe module: it computes what it would read and where it would write, and prints both.
# Nothing statistical, so the case measures the library and not an analysis.
ANALYSIS_PROBE_MAIN='nextflow.enable.dsl=2

include { analysisPlan } from '"'"'../../lib/nf/plan.nf'"'"'

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

# The histograms class is the only one that does not sit at a top-level dir.output key: it is
# reached through dir.output.report.depth.
ANALYSIS_HISTOGRAM_MAIN='nextflow.enable.dsl=2

include { analysisPlan } from '"'"'../../lib/nf/plan.nf'"'"'

workflow {
    analysisPlan('"'"'probe'"'"').targets.each { target ->
        println "PROBE histograms ${target.classes.histograms.dir}"
        println "PROBE frequencies ${target.classes.frequencies.dir}"
        println "PROBE required " + target.classes.findAll { k, v -> v.required }.keySet().sort().join(",")
    }
}'

test_the_depth_histograms_resolve_through_a_nested_key() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_HISTOGRAM_MAIN"
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "a module asking for the histograms should run"
    local out; out=$(analysis_output)
    assert_contains "$out" "PROBE histograms $ANALYSIS_SB/store/Output/Reports/Depth" \
        "the step 5 histograms sit under Reports, not beside the tables"
    assert_contains "$out" "PROBE required frequencies" \
        "and a class the manifest does not name is present without being required"
}

# A histogram belongs to the step 5 variant, and vcffilter.minDP and annotate branch the plan at
# steps 7 and 8 - so all three runs share one step 5 ancestor and the two results directories are
# told about the same histograms.
test_targets_that_branch_after_step_5_share_one_histogram_directory() {
    analysis_ready multi || return
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_HISTOGRAM_MAIN"
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "the module should run over both directories"
    local out histograms frequencies
    out=$(analysis_output)
    histograms=$(printf '%s\n' "$out" | sed -n 's|^PROBE histograms ||p' | sort -u)
    frequencies=$(printf '%s\n' "$out" | sed -n 's|^PROBE frequencies ||p' | sort -u)
    assert_count 1 "$(printf '%s\n' "$histograms" | wc -l)" \
        "both targets read the histograms of the one step 5 variant they share"
    assert_count 2 "$(printf '%s\n' "$frequencies" | wc -l)" \
        "while their step 7 tables are two different directories"
    assert_contains "$histograms" "/Reports/Depth" "and the shared directory is the depth report's"
}

# A module declares its whole scope's defaults in ONE call and gets the whole scope back. A
# per-call fallback could refuse nothing: `chromosome` for `chromosomes` would take the default,
# and the module would plot nothing with nothing said about it.
ANALYSIS_SETTINGS_MAIN='nextflow.enable.dsl=2

include { moduleSettings } from '"'"'../../lib/nf/paths.nf'"'"'

workflow {
    def settings = moduleSettings('"'"'probe'"'"', [chromosomes: [], minReads: 2])
    println "PROBE chromosomes ${settings.chromosomes}"
    println "PROBE minReads ${settings.minReads}"
}'

test_a_module_setting_defaults_when_the_project_sets_none() {
    analysis_ready single || return
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_SETTINGS_MAIN"
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "a module with no settings file should run"
    local out; out=$(analysis_output)
    assert_contains "$out" "PROBE chromosomes []" "an unset key is the module's own default"
    assert_contains "$out" "PROBE minReads 2" "for every key in the scope"
}

test_a_module_setting_is_taken_from_the_module_config() {
    analysis_ready single || return
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_SETTINGS_MAIN"
    cat > "$ANALYSIS_SB/main/probe.config" <<'CFG'
params {
    analysis {
        probe {
            chromosomes = ['chr2L', 'chr3R']
        }
    }
}
CFG
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 0 "$status" "a module reading its own config should run"
    local out; out=$(analysis_output)
    assert_contains "$out" "PROBE chromosomes [chr2L, chr3R]" "the project's value wins"
    assert_contains "$out" "PROBE minReads 2" "and the keys it did not set keep the default"
}

test_an_unknown_module_setting_refuses() {
    analysis_ready single || return
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_SETTINGS_MAIN"
    cat > "$ANALYSIS_SB/main/probe.config" <<'CFG'
params {
    analysis {
        probe {
            chromosome = ['chr2L']
        }
    }
}
CFG
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 1 "$status" "a misspelled key must not be answered with the default"
    local out; out=$(analysis_output)
    assert_contains "$out" "does not have: chromosome" "the refusal names the key"
    assert_contains "$out" "It has: chromosomes, minReads" "and lists the ones it has"
}

# A top-level scope reaches the recorded manifest, and the identity check reads it as a setting
# added since the results were produced - so every analysis refuses, and the message is about a
# changed project rather than about the file the user just wrote.
test_a_module_scope_written_at_the_top_level_says_so() {
    analysis_ready single || return
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_SETTINGS_MAIN"
    cat > "$ANALYSIS_SB/main/probe.config" <<'CFG'
params {
    probe {
        chromosomes = ['chr2L']
    }
}
CFG
    local status; status=$(run_module "$ANALYSIS_SB" probe)
    assert_status 1 "$status" "a top-level module scope must be refused where it is written"
    local out; out=$(analysis_output)
    assert_contains "$out" "params.probe is set at the top level" "the refusal names what is wrong"
    assert_contains "$out" "belong inside the analysis scope" "and where the scope belongs"
}

test_the_report_echoes_the_module_settings_the_project_set() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module probe "$ANALYSIS_PROBE_MANIFEST" "$ANALYSIS_SETTINGS_MAIN"
    run_analysis "$ANALYSIS_SB" probe > /dev/null
    assert_contains "$(analysis_report "$ANALYSIS_SB")" \
        "MODULE SETTINGS:       none set - probe runs on its own defaults" \
        "a module with nothing set says so"

    cat > "$ANALYSIS_SB/main/probe.config" <<'CFG'
params {
    analysis {
        probe {
            chromosomes = ['chr2L']
        }
    }
}
CFG
    rm -rf "$ANALYSIS_SB/main/Analysis/Results"
    run_analysis "$ANALYSIS_SB" probe > /dev/null
    assert_contains "$(analysis_report "$ANALYSIS_SB")" \
        "MODULE SETTINGS:       analysis.probe.chromosomes = ['chr2L']" \
        "and one with a setting has it echoed as it was written"
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
    # CODE only. Documentation under analysis/lib is free to name a path - the library's own
    # README points module authors at the one in the store - and the rule being enforced is
    # about what the library READS, not what it mentions. Both extensions, so the R library is
    # held to the same rule as the Nextflow one.
    hits=$(cd "$REPO_ROOT" && grep -rn --include='*.nf' --include='*.R' "modules/" analysis/lib 2>/dev/null)
    assert_eq "" "$hits" "analysis/lib must not name the store:"$'\n'"$hits"
    hits=$(cd "$REPO_ROOT" && grep -rn "from '\./lib/\|from '\.\./lib/" analysis/modules.nf 2>/dev/null)
    assert_contains "$hits" "lib/nf/paths.nf" "the frame reads the library, which is the allowed direction"
}

# ---------------------------------------------------------------------------------------
# What a module writes: its results, and the intermediates it derives on the way.

# A module that does the whole shape once - restore what is shared, derive it if it is not
# there, produce an analysis, publish it. Nothing statistical again; these cases measure the
# moves.
ANALYSIS_WRITER_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { intermediateFile; publishIntermediate; RestoreIntermediates } from '../../lib/nf/store.nf'
include { PublishResults } from '../../lib/nf/results.nf'

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

include { analysisPlan } from '../../lib/nf/plan.nf'
include { PublishResults } from '../../lib/nf/results.nf'

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

include { analysisPlan } from '../../lib/nf/plan.nf'
include { PublishResults } from '../../lib/nf/results.nf'

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

# ---------------------------------------------------------------------------------------
# What a published folder says about how to read itself.

ANALYSIS_LINKED_MANIFEST='{ "name": "writer", "version": "0.1.0", "contract": "freq-1",
  "summary": "publish one analysis and say where it is explained", "needs": ["frequencies"],
  "outputs": [ { "file": "result.tsv", "summary": "the analysis",
                 "anchor": "output-layout" } ] }'

# A published number is not always a measurement, and a table cell cannot say which it is. The
# README is one mechanism for every module, so no module invents its own way of saying it.
test_a_published_folder_carries_a_readme_linking_every_file_to_the_manual() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local readme; readme=$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/README.md" 2>/dev/null)
    assert_contains "$readme" '`result.tsv`' "the module's own output is listed"
    assert_contains "$readme" "PoolSeqFlow-manual.md#output-layout" \
        "linked to the section its manifest named"
    assert_contains "$readme" '`0_verify_analysis.txt`' "and so is what every analysis carries"
    assert_contains "$readme" "PoolSeqFlow-manual.md#citing-the-tools-it-runs" \
        "with the frame's own anchors rendered by the same mechanism"
}

# The anchor is checked against the manual this release ships, while the DAG is built, so a
# manifest promising a section that does not exist stops before any compute.
test_a_module_naming_an_anchor_the_manual_lacks_refuses() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        '{"name":"writer","version":"0.1.0","contract":"freq-1","summary":"points nowhere",
          "needs":["frequencies"],
          "outputs":[{"file":"result.tsv","anchor":"how-to-read-a-thing-that-is-not-written"}]}' \
        "$ANALYSIS_WRITER_MAIN"
    local status; status=$(run_analysis "$ANALYSIS_SB" writer)
    assert_status 1 "$status" "a link nobody can follow must stop the run"
    local out; out=$(analysis_output)
    assert_contains "$out" "how-to-read-a-thing-that-is-not-written" "the refusal names the anchor"
    assert_contains "$out" "PoolSeqFlow-manual.md" "and the file it was looked for in"
}

# A module published separately has no section in this manual to point at, so it gives a full
# url instead - which is the half of F0c that a first-party-only design would have missed.
test_a_module_may_link_out_of_the_manual_entirely() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        '{"name":"writer","version":"0.1.0","contract":"freq-1","summary":"published elsewhere",
          "needs":["frequencies"],
          "outputs":[{"file":"result.tsv","summary":"the analysis",
                      "url":"https://example.org/writer/#results"}]}' \
        "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "a url needs no heading in this manual"
    assert_contains "$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/README.md" 2>/dev/null)" \
        "https://example.org/writer/#results" "and is rendered as given"
}

# Declaring an output is a promise about what the folder will hold. Checked in the STAGE, like
# the script check beside it, so a module that breaks it publishes nothing.
test_a_module_that_does_not_publish_what_it_declared_publishes_nothing() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        '{"name":"writer","version":"0.1.0","contract":"freq-1","summary":"promises a table",
          "needs":["frequencies"],
          "outputs":[{"file":"frequencies.tsv","summary":"never produced","anchor":"output-layout"}]}' \
        "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 1 "$status" "an undelivered output must fail the publish"
    assert_contains "$(analysis_output)" "declares it publishes 'frequencies.tsv'" \
        "naming what was promised"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/writer/result.tsv" \
        "and nothing is published, so the folder stays as the verification left it"
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
