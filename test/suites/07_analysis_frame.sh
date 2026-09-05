#!/bin/bash
# The analysis frame: what it is, what it reads, what keeps it optional.
# cost: jvm
# covers: analysis.nf analysis/frame.config analysis/frame.version analysis/lib/nf/paths.nf
# covers: analysis/analysis.config.template
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

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
             analysis/lib/nf/pools.nf \
             analysis/modules/basicstats/manifest.json analysis/modules/basicstats/main.nf \
             analysis/modules/basicstats/basicstats.R \
             analysis/modules/basicstats/citations.json; do
        assert_file "$REPO_ROOT/$f" "$f must ship"
    done

    # A shipped module ships only what is TRACKED: `git archive` builds the tarball from the
    # index, so a file left unadded is one that works here and is absent from every download -
    # and a module missing one file stops every analysis run, not only its own.
    #
    # Only modules that are PARTLY tracked are checked. One with nothing tracked is a module
    # being written, which is the ordinary state of the working tree and not a mistake.
    local dir name tracked untracked partial=""
    for dir in "$REPO_ROOT"/analysis/modules/*/; do
        [ -f "$dir/manifest.json" ] || continue
        name=$(basename "$dir")
        tracked=$(cd "$REPO_ROOT" && git ls-files -- "analysis/modules/$name/")
        [ -n "$tracked" ] || continue
        untracked=$(cd "$REPO_ROOT" && git ls-files --others --exclude-standard -- "analysis/modules/$name/")
        [ -z "$untracked" ] || partial="$partial$untracked"$'\n'
    done
    assert_eq "" "$partial" "these files of a shipped module would not be in the tarball:"$'\n'"$partial"
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
