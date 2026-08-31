#!/bin/bash
# The ./PoolSeqFlow wrapper's environment handling, against a stub conda.
#
# These run entirely against the fake conda in lib/sandbox.sh. Nothing here creates,
# activates or removes a real environment: a test suite that could delete an operator's
# install is not worth having.

VERSIONED_ENV="PoolSeqFlow-$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)"

# The whole point of naming environments after the release: an older shared environment
# must not be silently borrowed, because the pinned tools are part of what made a result.
test_run_refuses_to_fall_back_to_the_legacy_environment() {
    run_launcher_with_envs "base PoolSeqFlow" check
    assert_status 1 "$LAUNCHER_STATUS" "check should fail when this version's env is absent"
    assert_contains "$LAUNCHER_OUTPUT" "$VERSIONED_ENV" "should name the environment it wanted"
    assert_contains "$LAUNCHER_OUTPUT" "kept every version in one environment" \
        "should explain what the legacy env is"
    assert_contains "$LAUNCHER_OUTPUT" "does not use it" "should be explicit that it is not borrowed"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate PoolSeqFlow" \
        "must not activate anything when the versioned env is missing"
}

test_run_lists_other_versions_without_using_them() {
    run_launcher_with_envs "base PoolSeqFlow-0.1.0 PoolSeqFlow-9.9.9" check
    assert_status 1 "$LAUNCHER_STATUS" "check should fail"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list other installed versions"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-9.9.9" "should list other installed versions"
    assert_contains "$LAUNCHER_OUTPUT" "install" "should say how to fix it"
}

test_check_activates_when_the_matching_environment_exists() {
    run_launcher_with_envs "base $VERSIONED_ENV" check
    assert_status 0 "$LAUNCHER_STATUS" "check should succeed"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate $VERSIONED_ENV" \
        "should activate this version's environment"
    assert_contains "$LAUNCHER_OUTPUT" "STUB check_install ran" "should go on to verify the install"
}

# `conda env create` takes its name from environment.yml unless -n overrides it. Without the
# override every release lands in one environment again, which is the bug being fixed.
test_install_creates_the_versioned_name_explicitly() {
    run_launcher_with_envs "base" install
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env create -n $VERSIONED_ENV" \
        "install must pass -n to override the name: key in environment.yml"
}

PSF_VERSION="${VERSIONED_ENV#PoolSeqFlow-}"

# `install` deploys the code as well as the environment. The two are versioned together
# because the pinned tools are part of what produced a result, so a payload without its
# matching environment reproduces nothing.
test_install_deploys_the_pipeline_and_wrappers() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "install should succeed"
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_file "$dest/poolseqflow.nf"   "the pipeline should be deployed"
    assert_file "$dest/PoolSeqFlow"      "the wrapper should be deployed beside it"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" "a versioned wrapper should go on PATH"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow"              "so should the plain one"
    # The message is the whole point of the PATH note: a prefix nobody has on PATH gives
    # commands that cannot be found by name, with nothing to say why.
    assert_contains "$LAUNCHER_OUTPUT" "$LAUNCHER_PREFIX/bin" "should name the wrapper directory"
    assert_contains "$LAUNCHER_OUTPUT" "PATH" "should say something about PATH"
}

# The deployed copy is reached through a symlink, so it carries its own location rather than
# resolving one. The copy in a clone must stay unstamped, or a checkout would point at an
# installation instead of itself.
test_the_deployed_wrapper_is_stamped_and_the_source_is_not() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_contains "$(grep '^POOLSEQFLOW_INSTALLED_HOME=' "$dest/PoolSeqFlow")" "$dest" \
        "the installed wrapper should know its own payload"
    assert_eq 'POOLSEQFLOW_INSTALLED_HOME=""' \
        "$(grep '^POOLSEQFLOW_INSTALLED_HOME=' "$REPO_ROOT/PoolSeqFlow")" \
        "the source wrapper must stay unstamped"
}

# By version order, not install order: reinstalling an older release must not capture the
# plain name and quietly become what `PoolSeqFlow run` means.
test_the_plain_wrapper_points_at_the_newest_version() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "the first install should succeed"
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    mkdir -p "$LAUNCHER_PREFIX/opt/PoolSeqFlow-99.9.9"
    : > "$LAUNCHER_PREFIX/opt/PoolSeqFlow-99.9.9/PoolSeqFlow"
    ( cd "$sb" && PATH="$sb/stub/bin:$PATH" POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
      ./PoolSeqFlow install ) >/dev/null 2>&1
    assert_contains "$(readlink "$LAUNCHER_PREFIX/bin/PoolSeqFlow")" "PoolSeqFlow-99.9.9" \
        "the plain wrapper should follow the highest version, not the last installed"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" \
        "this version's own wrapper should still be there"
}

# Both halves go, and nothing is left on PATH pointing at a directory that no longer exists.
test_uninstall_removes_the_pipeline_as_well_as_the_environment() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" ./PoolSeqFlow uninstall 2>&1 <<< y )
    assert_contains "$out" "Removed" "should say the pipeline was removed"
    assert_count 0 "$(find "$LAUNCHER_PREFIX/opt" -maxdepth 1 -name 'PoolSeqFlow-*' | wc -l)" \
        "the payload should be gone"
    assert_count 0 "$(find "$LAUNCHER_PREFIX/bin" -maxdepth 1 -name 'PoolSeqFlow*' | wc -l)" \
        "and so should every symlink to it, rather than dangling"
}

# Removing one version must leave the others alone, and must leave the plain wrapper pointing
# at a version that still exists rather than at the hole it just made. An older version is
# uninstalled by calling its OWN wrapper - each copy knows only the version it belongs to.
test_uninstall_leaves_the_other_installed_versions_alone() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    # An OLDER version alongside, wrappers and all, as its own `install` would have left it.
    # Older rather than newer on purpose: removing the newest is the case where the plain
    # wrapper has to be repointed, and a newer sibling would leave it correct by accident.
    mkdir -p "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0"
    : > "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0/PoolSeqFlow"
    ln -sfn "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0/PoolSeqFlow" \
            "$LAUNCHER_PREFIX/bin/PoolSeqFlow-0.1.0"

    assert_contains "$(readlink "$LAUNCHER_PREFIX/bin/PoolSeqFlow")" "PoolSeqFlow-$PSF_VERSION" \
        "before uninstalling, the plain wrapper should point at the newest"
    # Called by its versioned name, which names the version and so needs no prompt.
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
        "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" uninstall 2>&1 <<< y )
    assert_contains "$out" "Removed" "should remove the version its wrapper belongs to"
    assert_no_file "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION/PoolSeqFlow" \
        "its own payload should be gone"
    assert_no_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" \
        "and its own wrapper with it"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0" "the other version must stay installed"
    assert_file "$LAUNCHER_PREFIX/bin/PoolSeqFlow-0.1.0" "and keep its own wrapper"
    assert_contains "$(readlink "$LAUNCHER_PREFIX/bin/PoolSeqFlow")" "PoolSeqFlow-0.1.0" \
        "the plain wrapper must fall back to the version that is left, not dangle"
}

# With several installed and nothing attached to ask, picking one would be guessing at which
# installation to delete. It refuses and names the command that is exact instead.
test_uninstall_refuses_to_choose_a_version_without_a_terminal() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    mkdir -p "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0"
    : > "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0/PoolSeqFlow"

    local out status
    out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
           ./PoolSeqFlow uninstall 2>&1 ) && status=0 || status=$?
    assert_status 1 "$status" "should refuse rather than pick one"
    assert_contains "$out" "PoolSeqFlow-0.1.0" "should list what is installed"
    assert_contains "$out" "PoolSeqFlow-<version> uninstall" "should name the exact command"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION" "and must remove nothing"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-0.1.0" "and must remove nothing"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "and attempt no removal"
}

test_install_reports_environments_left_from_other_versions() {
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0" install
    assert_contains "$LAUNCHER_OUTPUT" "Other PoolSeqFlow environments" "should report what else is installed"
    assert_contains "$LAUNCHER_OUTPUT" "unversioned" "the legacy env should be labelled, not called a version"
    assert_contains "$LAUNCHER_OUTPUT" "uninstall_all" "should offer the bulk removal command"
}

test_list_marks_the_current_version() {
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0 $VERSIONED_ENV" list
    assert_status 0 "$LAUNCHER_STATUS" "list should succeed"
    assert_contains "$LAUNCHER_OUTPUT" "* $VERSIONED_ENV" "should mark this copy's environment"
    assert_contains "$LAUNCHER_OUTPUT" "unversioned" "should annotate the legacy environment"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list other versions"
}

test_list_says_so_when_nothing_is_installed() {
    run_launcher_with_envs "base" list
    assert_status 0 "$LAUNCHER_STATUS" "list should succeed with no environments"
    assert_contains "$LAUNCHER_OUTPUT" "No PoolSeqFlow conda environments" "should say none are installed"
}

# `conda env remove` on an absent environment exits non-zero, and under set -e that used to
# surface as a raw conda error with no hint about what was actually installed.
test_uninstall_explains_itself_when_the_environment_is_absent() {
    run_launcher_with_envs "base PoolSeqFlow-0.1.0" uninstall
    assert_status 1 "$LAUNCHER_STATUS" "uninstall should fail"
    assert_contains "$LAUNCHER_OUTPUT" "is not installed" "should say the environment is not there"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list what is installed instead"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "must not attempt a removal"
}

test_uninstall_all_removes_every_poolseqflow_environment() {
    local log
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0 $VERSIONED_ENV" uninstall_all <<< "y"
    log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env remove -n PoolSeqFlow " "should remove the legacy environment"
    assert_contains "$log" "env remove -n PoolSeqFlow-0.1.0" "should remove other versions"
    assert_contains "$log" "env remove -n $VERSIONED_ENV" "should remove this version too"
}

test_uninstall_all_aborts_on_a_negative_answer() {
    run_launcher_with_envs "base PoolSeqFlow PoolSeqFlow-0.1.0" uninstall_all <<< "n"
    assert_status 1 "$LAUNCHER_STATUS" "declining should exit non-zero"
    assert_contains "$LAUNCHER_OUTPUT" "Aborted" "should say it aborted"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "must remove nothing"
}

# Piped into a script or run from CI there is no one to answer, and silence must not be
# taken for consent.
test_uninstall_all_aborts_without_a_terminal() {
    run_launcher_with_envs "base PoolSeqFlow" uninstall_all < /dev/null
    assert_status 1 "$LAUNCHER_STATUS" "no confirmation should exit non-zero"
    assert_contains "$LAUNCHER_OUTPUT" "no confirmation received" "should say why it stopped"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "must remove nothing"
}

# The wrapper takes exactly one subcommand; parameters.config.template documents that.
test_wrapper_rejects_extra_arguments() {
    run_launcher_with_envs "base" uninstall all
    assert_status 1 "$LAUNCHER_STATUS" "two arguments should be refused"
    run_launcher_with_envs "base"
    assert_status 1 "$LAUNCHER_STATUS" "no argument should be refused"
    run_launcher_with_envs "base" nonsense_command
    assert_status 1 "$LAUNCHER_STATUS" "an unknown subcommand should be refused"
}

# Everything `init` writes is something you then edit, so a second run must leave it alone.
test_init_populates_a_project_without_overwriting() {
    local proj out
    proj=$(guard_path "$TEST_TMPDIR/init-project")
    rm -rf "$proj"; mkdir -p "$proj"

    out=$(cd "$proj" && POOLSEQFLOW_HOME="$REPO_ROOT" bash "$REPO_ROOT/PoolSeqFlow" init 2>&1)
    assert_contains "$out" "created  parameters.config" "should create the config"
    assert_contains "$out" "created  metadata.csv.example" "should copy the metadata example"
    [ -d "$proj/Data" ] || fail_case "init should create Data/"
    [ -d "$proj/Reference" ] || fail_case "init should create Reference/"
    # metadata.csv is a table describing the experiment, so the user writes it.
    if [ -e "$proj/metadata.csv" ]; then
        fail_case "init must not write metadata.csv"
    fi

    echo "# edited by the user" >> "$proj/parameters.config"
    out=$(cd "$proj" && POOLSEQFLOW_HOME="$REPO_ROOT" bash "$REPO_ROOT/PoolSeqFlow" init 2>&1)
    assert_contains "$out" "0 created, 4 already present" "a second init should change nothing"
    assert_contains "$(cat "$proj/parameters.config")" "edited by the user" \
        "a second init must not overwrite a file you have edited"
}

# multi-run.csv.example is documentation, not a template: the runs and the parameters that
# differ between them are the whole content of a table, so only the user can write one.
test_init_multi_switches_multirun_on_without_inventing_a_table() {
    local proj out
    proj=$(guard_path "$TEST_TMPDIR/init-multi-project")
    rm -rf "$proj"; mkdir -p "$proj"

    out=$(cd "$proj" && POOLSEQFLOW_HOME="$REPO_ROOT" bash "$REPO_ROOT/PoolSeqFlow" init_multi 2>&1)
    assert_contains "$(grep -E '^[[:space:]]*multiRun[[:space:]]*=' "$proj/parameters.config")" \
        "true" "init_multi should switch multiRun on"
    assert_contains "$out" "multi-run.csv.example" "should point at the rules for writing a table"
    [ -f "$proj/multi-run.csv.example" ] || fail_case "init_multi should leave the example beside you"
    if [ -e "$proj/runs.csv" ]; then
        fail_case "init_multi must not invent a run table"
    fi
}

# A project inside the installation does not survive an upgrade, and the installation may be
# read-only or shared between users. Refused outright rather than left to fail later.
test_init_refuses_to_populate_inside_the_installation() {
    local inst out status
    inst=$(guard_path "$TEST_TMPDIR/init-install")
    rm -rf "$inst"; mkdir -p "$inst"
    cp "$REPO_ROOT/PoolSeqFlow" "$REPO_ROOT/parameters.config.template" \
       "$REPO_ROOT/metadata.csv.template" "$inst/"
    : > "$inst/poolseqflow.nf"
    # The wrapper sources lib/wrapper_lib.sh before it does anything else, so even a fake
    # installation needs it - without it the run fails on an incomplete copy rather than
    # reaching the check this case is about.
    mkdir -p "$inst/lib"
    cp "$REPO_ROOT/lib/wrapper_lib.sh" "$inst/lib/"

    out=$(cd "$inst" && POOLSEQFLOW_HOME="$inst" bash "$inst/PoolSeqFlow" init 2>&1) && status=0 || status=$?
    assert_status 1 "$status" "init inside the installation should be refused"
    assert_contains "$out" "not a project" "should say what is wrong"
    if [ -d "$inst/Data" ]; then
        fail_case "it must not have populated the installation"
    fi
}

# Every advertised subcommand must exist, and every implemented one must be advertised.
test_usage_and_implementation_agree() {
    local usage_line advertised implemented
    usage_line=$(sed -n 's/.*Usage: \$0 {\(.*\)}.*/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)
    # `analysis <command>` is advertised with the word it carries; the arm is `analysis`.
    advertised=$(printf '%s' "$usage_line" | tr '|' '\n' | sed 's/ .*$//' | sort)
    implemented=$(sed -n 's/^    \([a-z_|]*\))$/\1/p' "$REPO_ROOT/PoolSeqFlow" \
                  | tr '|' '\n' | grep -v '^\*$' | sort)
    local cmd
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        printf '%s\n' "$implemented" | grep -qx "$cmd" \
            || fail_case "usage advertises '$cmd' but no case arm implements it"
    done < <(printf '%s\n' "$advertised")
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        # `resume` is an accepted deprecated alias, deliberately not advertised.
        [ "$cmd" = "resume" ] && continue
        printf '%s\n' "$advertised" | grep -qx "$cmd" \
            || fail_case "'$cmd' is implemented but not advertised in usage"
    done < <(printf '%s\n' "$implemented")
}

# A VERSION'S ANALYSIS ENVIRONMENT GOES WITH IT.
#
# The analysis layer installs `PoolSeqFlow-<version>-analysis` beside the pipeline environment
# of the same version. Uninstalling the version has to take both, or it strands an environment
# whose pipeline no longer exists - and one that `list` will keep reporting, because
# poolseqflow_envs() matches the whole family.
test_uninstall_takes_the_analysis_environment_of_that_version() {
    run_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis PoolSeqFlow-0.1.0" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
        "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" uninstall 2>&1 <<< y )

    assert_contains "$out" "$VERSIONED_ENV'" "the pipeline environment should be named"
    assert_contains "$out" "${VERSIONED_ENV}-analysis'" "and the analysis one beside it"

    local removed; removed=$(grep -c "env remove -n ${VERSIONED_ENV}-analysis" "$LAUNCHER_CONDA_LOG" || true)
    assert_eq "1" "$removed" "conda should have been asked to remove the analysis environment"

    # Another version's environment is not this version's business.
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove -n PoolSeqFlow-0.1.0" \
        "a different version's environment must survive"
}

# The absence of an analysis environment is the ordinary case and must stay silent - most
# projects never install the analysis layer at all.
test_uninstall_says_nothing_about_an_analysis_environment_that_is_absent() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
        "$LAUNCHER_PREFIX/bin/PoolSeqFlow-$PSF_VERSION" uninstall 2>&1 <<< y )
    # The wrapper's own symlink is reported going, which is a different thing from the
    # environment and says nothing about whether one was installed.
    assert_not_contains "$out" "conda environment '${VERSIONED_ENV}-analysis'" \
        "with no analysis environment installed, uninstall should not mention one"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove -n ${VERSIONED_ENV}-analysis" \
        "and conda should not be asked to remove one"
}

# ONE COMMAND, NOT TWO.
#
# The analysis layer hangs off `PoolSeqFlow analysis` and ships in the same payload. A second
# executable would be a second thing to version, symlink, stamp and remove.
test_install_puts_one_command_on_the_path() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "install should succeed"
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_file "$dest/analysis.nf" "the analysis entry point belongs in the payload"
    assert_dir "$dest/analysis" "and the analysis directory with it"
    local extra
    extra=$(find "$LAUNCHER_PREFIX/bin" -name 'PoolSeqFlow-analysis*' 2>/dev/null)
    assert_eq "" "$extra" "no second command should be linked:"$'\n'"$extra"
}

# Shipped is not enabled. Installing the pipeline must not build the R environment, which
# is large and which most projects never want.
test_install_does_not_create_the_analysis_environment() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env create -n ${VERSIONED_ENV}-analysis" \
        "installing the pipeline must not build the analysis environment"
    assert_contains "$LAUNCHER_OUTPUT" "analysis install" \
        "but it should say how to add it"
}

test_analysis_install_creates_only_the_analysis_environment() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "install should succeed"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env create -n ${VERSIONED_ENV}-analysis" \
        "should create this version's analysis environment"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env create -n $VERSIONED_ENV " \
        "and must not touch the pipeline environment"
}

test_analysis_install_is_a_no_op_when_the_environment_is_there() {
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" install
    assert_status 0 "$LAUNCHER_STATUS" "a second install should succeed"
    assert_contains "$LAUNCHER_OUTPUT" "already exists" "should say it is already there"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env create" \
        "and must not rebuild it"
}

# The layer is opt-in on a machine that may never run the pipeline, so a missing pipeline
# environment is a note rather than a refusal.
test_analysis_install_notes_a_missing_pipeline_environment_without_refusing() {
    run_analysis_launcher_with_envs "base" install
    assert_status 0 "$LAUNCHER_STATUS" "install should not need the pipeline environment"
    assert_contains "$LAUNCHER_OUTPUT" "$VERSIONED_ENV" "should name the pipeline environment"
    assert_contains "$LAUNCHER_OUTPUT" "cannot produce them" "and say what is missing without it"
}

test_analysis_uninstall_leaves_the_pipeline_environment_alone() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" uninstall <<< y
    assert_status 0 "$LAUNCHER_STATUS" "uninstall should succeed"
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env remove -n ${VERSIONED_ENV}-analysis" \
        "should remove the analysis environment"
    assert_not_contains "$log" "env remove -n $VERSIONED_ENV " \
        "and nothing else"
}

test_analysis_uninstall_is_quiet_when_there_is_nothing_to_remove() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV" uninstall
    assert_status 0 "$LAUNCHER_STATUS" "removing an absent environment is not an error"
    assert_contains "$LAUNCHER_OUTPUT" "already absent" "should say so"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" \
        "and ask conda for nothing"
}

# The same rule as the pipeline wrapper's: a versioned environment is never substituted.
# Borrowing the pipeline's would run R that is not there and pin nothing.
test_a_module_refuses_to_borrow_the_pipeline_environment() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV" mds
    assert_status 1 "$LAUNCHER_STATUS" "a module should refuse without its own environment"
    assert_contains "$LAUNCHER_OUTPUT" "${VERSIONED_ENV}-analysis" "should name the environment it wanted"
    assert_contains "$LAUNCHER_OUTPUT" "analysis install" "and say how to get it"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate" \
        "and activate nothing at all"
}

# Running a module is two Nextflow runs: analysis.nf checks the project and clears the results
# folder, then the module's own main.nf produces the results. Nothing else in the wrapper
# launches twice, so the order is asserted rather than the count alone.
test_a_module_runs_the_verifier_then_its_own_pipeline() {
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" probe
    unset LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "a module with a main.nf should run"
    assert_count 2 "$(grep -c '^run ' "$LAUNCHER_NEXTFLOW_LOG")" "two runs, not one"
    local verifier module_run
    verifier=$(sed -n 1p "$LAUNCHER_NEXTFLOW_LOG")
    module_run=$(sed -n 2p "$LAUNCHER_NEXTFLOW_LOG")
    assert_contains "$verifier" "analysis.nf" "the verifier goes first"
    assert_contains "$verifier" "--module probe" "and it is the one told which module"
    assert_contains "$module_run" "analysis/modules/probe/main.nf" \
        "the module's own pipeline goes second"
    assert_not_contains "$module_run" "--module" \
        "which names itself, so it is not told again"
}

# A module the frame provides has no directory in the store and nothing to run after the
# checks. `verify` is that module, and it is how a project is asked whether it is ready.
test_a_builtin_module_runs_the_verifier_alone() {
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" verify
    assert_status 0 "$LAUNCHER_STATUS" "verify should run"
    assert_count 1 "$(grep -c '^run ' "$LAUNCHER_NEXTFLOW_LOG")" "one run, and no second"
    assert_contains "$(cat "$LAUNCHER_NEXTFLOW_LOG")" "--module verify" \
        "the verifier is the whole of it"
}

# Both invocations are assembled from one array, so they cannot drift apart - but a second
# `nextflow run` written by hand is exactly where they would.
test_both_invocations_read_the_same_configuration() {
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" probe
    unset LAUNCHER_STORE_MODULE
    local first second
    first=$(sed -n 1p "$LAUNCHER_NEXTFLOW_LOG" | grep -o -- '-c [^ ]*')
    second=$(sed -n 2p "$LAUNCHER_NEXTFLOW_LOG" | grep -o -- '-c [^ ]*')
    assert_eq "$first" "$second" "both runs must read the same config layers, in the same order"
    assert_count 3 "$(printf '%s\n' "$first" | grep -c .)" \
        "defaults.config, analysis.config and probe.config"
}

# The store directory is how a module is found, so a directory without the pipeline in it is a
# broken install rather than a module that does nothing. Silence here would look like success.
test_an_installed_module_without_a_main_nf_fails_loudly() {
    LAUNCHER_STORE_MODULE=probe
    LAUNCHER_STORE_MODULE_INCOMPLETE=1
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" probe
    unset LAUNCHER_STORE_MODULE LAUNCHER_STORE_MODULE_INCOMPLETE
    assert_status 1 "$LAUNCHER_STATUS" "an installed module with no main.nf should fail"
    assert_contains "$LAUNCHER_OUTPUT" "has no main.nf" "and say what is missing"
    assert_contains "$LAUNCHER_OUTPUT" "analysis/modules/probe" "and where it looked"
    assert_count 1 "$(grep -c '^run ' "$LAUNCHER_NEXTFLOW_LOG")" \
        "the verifier still ran, and nothing ran after it"
}

# Analysis runs where the pipeline ran, and reads what it produced. Built by hand rather
# than through the harness, whose sandbox is a project.
test_a_module_refuses_outside_a_project() {
    local dir stub out status
    dir=$(guard_path "$TEST_TMPDIR/analysis-no-project")
    rm -rf "$dir"; mkdir -p "$dir/lib" "$dir/install"
    cp "$REPO_ROOT/PoolSeqFlow" "$dir/"
    cp "$REPO_ROOT/lib/wrapper_lib.sh" "$dir/lib/"
    : > "$dir/analysis.nf"
    stub="$dir/stub"
    make_stub_conda "$stub" base "${VERSIONED_ENV}-analysis"

    out=$(cd "$dir" && PATH="$stub/bin:$PATH" POOLSEQFLOW_HOME="$dir" \
          bash "$dir/PoolSeqFlow" analysis mds 2>&1) && status=0 || status=$?
    assert_status 1 "$status" "a module outside a project should be refused"
    assert_contains "$out" "parameters.config" "should say what is missing"
    assert_not_contains "$(cat "$stub/conda.log")" "activate" \
        "and should refuse before activating anything"
}

# `analysis` is the one subcommand carrying a word of its own - exactly one, no more and
# not none.
test_the_analysis_subcommand_takes_exactly_one_word() {
    run_analysis_launcher_with_envs "base" install extra
    assert_status 1 "$LAUNCHER_STATUS" "two words after analysis should be refused"
    run_analysis_launcher_with_envs "base"
    assert_status 1 "$LAUNCHER_STATUS" "no word after analysis should be refused"
    run_analysis_launcher_with_envs "base" --nonsense
    assert_status 1 "$LAUNCHER_STATUS" "an unknown option should be refused"
}

# Every subcommand the analysis usage line advertises must have an arm, and every arm must be
# advertised. `<module>` is the one exclusion: it is a placeholder, not a word. Anything else
# excluded here is a command advertised to users that does nothing.
#
# The arms sit in the nested case, indented eight spaces further than the pipeline's own.
test_analysis_usage_and_implementation_agree() {
    local wrapper="$REPO_ROOT/PoolSeqFlow" usage_line advertised implemented cmd
    usage_line=$(sed -n 's/.*Usage: \$0 analysis {\(.*\)}.*/\1/p' "$wrapper" | head -1)
    advertised=$(printf '%s' "$usage_line" | tr '|' '\n' | grep -vx '<module>' | sort)
    implemented=$(sed -n 's/^            \([a-z_|]*\))$/\1/p' "$wrapper" | tr '|' '\n' | sort)
    # Both sides going empty together would pass vacuously, and a changed usage line or a
    # re-indented case is exactly how that happens.
    [ -n "$advertised" ] || fail_case "could not read the usage line out of the wrapper"
    [ -n "$implemented" ] || fail_case "could not read any case arm out of the wrapper"
    assert_eq "$advertised" "$implemented" "the advertised subcommands and the implemented arms"
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        # `y` for `uninstall`, which confirms before it removes anything; the rest ignore it.
        run_analysis_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" "$cmd" <<< y
        assert_status 0 "$LAUNCHER_STATUS" "$cmd should be implemented"
    done < <(printf '%s\n' "$advertised")
}

# `check` is the analysis half of `PoolSeqFlow check`: it activates this version's analysis
# environment and hands off to the checker, never borrowing the pipeline's.
test_analysis_check_activates_the_analysis_environment() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" check
    assert_status 0 "$LAUNCHER_STATUS" "check should succeed"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate ${VERSIONED_ENV}-analysis" \
        "should activate the analysis environment"
    assert_contains "$LAUNCHER_OUTPUT" "STUB check_analysis_install ran" \
        "should go on to verify the install"
}

test_analysis_check_refuses_without_its_environment() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV" check
    assert_status 1 "$LAUNCHER_STATUS" "check should fail when the analysis env is absent"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check_analysis_install ran" \
        "and must not run the checker against no environment"
}

# `install` verifies what it just built, the way `PoolSeqFlow install` does.
test_analysis_install_verifies_what_it_built() {
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" install
    assert_contains "$LAUNCHER_OUTPUT" "STUB check_analysis_install ran" \
        "install should finish by verifying itself"
}

# The DOI and the citation text live in lib/wrapper_lib.sh so the two `cite` arms cannot drift.
# Both must print the same software citation for the same version.
test_both_citations_carry_the_same_software_citation() {
    local pipeline_cite analysis_cite
    pipeline_cite=$(cd "$REPO_ROOT" && POOLSEQFLOW_HOME="$REPO_ROOT" bash ./PoolSeqFlow cite)
    run_analysis_launcher_with_envs "base" cite
    analysis_cite="$LAUNCHER_OUTPUT"
    assert_contains "$analysis_cite" "PoolSeqFlow v$PSF_VERSION" "should name this version"
    assert_contains "$pipeline_cite" "10.5281/zenodo" "the pipeline should print a DOI"
    # Every line of the pipeline's citation must appear in the analysis one, which then adds
    # R and its packages.
    local missing=0 line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$analysis_cite" in *"$line"*) ;; *) missing=$((missing + 1)) ;; esac
    done <<EOF
$pipeline_cite
EOF
    assert_eq "0" "$missing" "the analysis wrapper should print the whole software citation"
}

# Without the environment there is no R to ask, so it says so rather than printing nothing
# or failing.
test_cite_explains_itself_when_r_is_not_installed() {
    run_analysis_launcher_with_envs "base" cite
    assert_status 0 "$LAUNCHER_STATUS" "cite should not need the environment"
    assert_contains "$LAUNCHER_OUTPUT" "is not installed" "should say why R is not reported"
}

# AN ANALYSIS ENVIRONMENT IS NOT A VERSION.
#
# installed_versions() reads versions out of environment names, and `PoolSeqFlow-2.2.0-analysis`
# parses as a version called "2.2.0-analysis". That made ONE installed version look like two:
# the single-version fast path was skipped, so `uninstall` refused outright with nothing
# attached to ask, and interactively offered a version that does not exist.
test_an_analysis_environment_is_not_counted_as_a_version() {
    run_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" uninstall <<< y
    assert_status 0 "$LAUNCHER_STATUS" \
        "one version plus its analysis environment should not be asked WHICH to remove"
    assert_not_contains "$LAUNCHER_OUTPUT" "installations are present" \
        "it must not report two installations when only one is installed"
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env remove -n $VERSIONED_ENV" "the pipeline environment should go"
    assert_contains "$log" "env remove -n ${VERSIONED_ENV}-analysis" "and the analysis one with it"
}

# The chooser must still engage for genuinely different versions.
test_a_second_real_version_still_forces_a_choice() {
    run_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis PoolSeqFlow-0.1.0" \
        uninstall < /dev/null
    assert_status 1 "$LAUNCHER_STATUS" "two real versions with nothing to ask should refuse"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list the other real version"
    assert_not_contains "$LAUNCHER_OUTPUT" "${VERSIONED_ENV}-analysis" \
        "but must not offer an analysis environment as a version to remove"
}

# WHAT BARE WORDS COST, pinned so it is a decision and not a surprise.
#
# Under flags, `--uninstal` hit the `-*)` arm and was refused instantly. As a bare word it is
# indistinguishable from a module name, so it goes the module route: analysis.nf owns the list
# and is the only thing that can say the word is not on it. A leading dash is still refused
# outright, which is what keeps a mistyped FLAG cheap.
test_a_mistyped_subcommand_is_treated_as_a_module_name() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV" uninstal
    assert_status 1 "$LAUNCHER_STATUS" "an unknown bare word should not succeed"
    # It got as far as needing the analysis environment, which is the module route: the
    # machinery arms never ask for one.
    assert_contains "$LAUNCHER_OUTPUT" "${VERSIONED_ENV}-analysis" \
        "an unknown bare word should be routed to analysis.nf, not to usage"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" \
        "and a near-miss of uninstall must never remove anything"
}

# The machinery verbs are reserved out of the module namespace by the case arms preceding
# `*)`. A module may not be called any of them, and this is what says so.
test_the_machinery_verbs_are_reserved_from_the_module_namespace() {
    local wrapper="$REPO_ROOT/PoolSeqFlow" reserved word
    reserved=$(sed -n 's/^            \([a-z_|]*\))$/\1/p' "$wrapper" | tr '|' '\n')
    [ -n "$reserved" ] || fail_case "could not read the reserved words out of the wrapper"
    for word in $reserved; do
        # Each reserved word must be handled without ever reaching the analysis environment.
        run_analysis_launcher_with_envs "base" "$word"
        assert_not_contains "$LAUNCHER_OUTPUT" "analysis.nf" \
            "'$word' is reserved and must not be dispatched as a module"
    done
}

# WHAT `uninstall` OFFERS, and what removing one takes with it (Z, 2026-08-30):
# the legacy unversioned environment is listed beside the versioned ones, each version says
# whether its analysis layer is installed, and choosing one removes that installation whole.
test_uninstall_lists_the_legacy_environment_beside_the_versions() {
    run_launcher_with_envs "base PoolSeqFlow $VERSIONED_ENV PoolSeqFlow-0.1.0" uninstall < /dev/null
    assert_status 1 "$LAUNCHER_STATUS" "several installations with nothing to ask should refuse"
    assert_contains "$LAUNCHER_OUTPUT" "unversioned - predates per-version environments" \
        "the legacy environment should be offered, and labelled for what it is"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "beside the other versions"
    assert_contains "$LAUNCHER_OUTPUT" "3 PoolSeqFlow installations" \
        "and counted with them"
}

test_uninstall_says_which_installations_have_an_analysis_layer() {
    run_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis PoolSeqFlow-0.1.0" \
        uninstall < /dev/null
    assert_contains "$LAUNCHER_OUTPUT" "analysis installed" \
        "a version whose analysis layer is installed should say so"
    # The one without it must not be annotated, or the marker means nothing.
    local plain
    plain=$(printf '%s\n' "$LAUNCHER_OUTPUT" | grep 'PoolSeqFlow-0.1.0')
    assert_not_contains "$plain" "analysis installed" \
        "a version without an analysis layer should not claim one"
}

# The whole point of the marker: picking that entry takes both environments.
test_choosing_an_installation_removes_its_analysis_environment_with_it() {
    have_a_pty_runner || { skip_case "no python3 for a pty"; return; }
    run_launcher_with_envs "base PoolSeqFlow $VERSIONED_ENV ${VERSIONED_ENV}-analysis" version
    : > "$LAUNCHER_CONDA_LOG"
    # 1 is the legacy environment, 2 is this version - the list is sorted by version.
    run_launcher_on_a_tty $'2\ny' uninstall
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env remove -n $VERSIONED_ENV" "the chosen version's environment"
    assert_contains "$log" "env remove -n ${VERSIONED_ENV}-analysis" "and its analysis layer"
    assert_not_contains "$log" "env remove -n PoolSeqFlow " \
        "but not the legacy environment, which was not chosen"
}

# And the legacy entry is removable on its own, without reaching for a payload it never had.
test_choosing_the_legacy_environment_removes_only_that() {
    have_a_pty_runner || { skip_case "no python3 for a pty"; return; }
    run_launcher_with_envs "base PoolSeqFlow $VERSIONED_ENV ${VERSIONED_ENV}-analysis" install
    : > "$LAUNCHER_CONDA_LOG"
    run_launcher_on_a_tty $'1\ny' uninstall
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env remove -n PoolSeqFlow" "the legacy environment should go"
    assert_not_contains "$log" "env remove -n $VERSIONED_ENV" \
        "this version's environment must survive"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION" \
        "and so must its payload"
    # The legacy environment never had a payload, so there is no path to report on.
    assert_not_contains "$LAUNCHER_OUTPUT" "No pipeline installed at" \
        "and it must not report a missing payload it never had"
}

# UNINSTALL ALWAYS CONFIRMS (Z, 2026-08-30), whether the installation was chosen from a list,
# named by a versioned wrapper, or the only one present. Choosing WHICH is not consenting to
# the removal, and the single-installation path never asked anything at all before this.
test_uninstall_aborts_on_a_negative_answer() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    : > "$LAUNCHER_CONDA_LOG"
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" ./PoolSeqFlow uninstall 2>&1 <<< n )
    assert_contains "$out" "Aborted" "should say it aborted"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "and remove no environment"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION" "and leave the pipeline in place"
}

# The same shape as uninstall_all: no terminal means no consent, so nothing goes.
test_uninstall_aborts_without_a_terminal() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    : > "$LAUNCHER_CONDA_LOG"
    local out status
    out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" ./PoolSeqFlow uninstall < /dev/null 2>&1 ) \
        && status=0 || status=$?
    assert_status 1 "$status" "with nothing to confirm with, it should refuse"
    assert_contains "$out" "no confirmation received" "should say why it stopped"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "and remove no environment"
    assert_dir "$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION" "and leave the pipeline in place"
}

# What it is about to remove has to be on screen before the question, or the answer means
# nothing. A version with an analysis layer lists both environments and the pipeline.
test_uninstall_names_everything_it_is_about_to_remove() {
    run_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" install
    local sb; sb=$(dirname "$LAUNCHER_PREFIX")
    local out; out=$( cd "$sb" && PATH="$sb/stub/bin:$PATH" \
        POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" ./PoolSeqFlow uninstall 2>&1 <<< n )
    assert_contains "$out" "This removes:" "should list what goes before asking"
    assert_contains "$out" "$VERSIONED_ENV" "the pipeline environment"
    assert_contains "$out" "${VERSIONED_ENV}-analysis" "the analysis environment"
    assert_contains "$out" "opt/PoolSeqFlow-$PSF_VERSION" "and the pipeline itself"
    assert_contains "$out" "storageDir are untouched" "and say what is NOT removed"
}

# Nothing to remove is not a question worth asking. A versioned wrapper names its version
# without checking anything, so it is the one path that can reach the confirmation with
# nothing of that version actually present - here, a wrapper pointed at an empty prefix.
test_uninstall_does_not_ask_when_there_is_nothing_installed() {
    local dir stub out status
    dir=$(guard_path "$TEST_TMPDIR/uninstall-nothing")
    rm -rf "$dir"; mkdir -p "$dir/lib" "$dir/prefix"
    cp "$REPO_ROOT/PoolSeqFlow" "$dir/PoolSeqFlow-$PSF_VERSION"
    cp "$REPO_ROOT/lib/wrapper_lib.sh" "$dir/lib/"
    : > "$dir/poolseqflow.nf"
    stub="$dir/stub"
    make_stub_conda "$stub" base

    out=$(cd "$dir" && PATH="$stub/bin:$PATH" POOLSEQFLOW_HOME="$dir" \
          POOLSEQFLOW_PREFIX="$dir/prefix" \
          bash "$dir/PoolSeqFlow-$PSF_VERSION" uninstall 2>&1 <<< y) && status=0 || status=$?
    assert_status 0 "$status" "with nothing installed there is nothing to fail at"
    assert_contains "$out" "nothing to remove" "should say so plainly"
    assert_not_contains "$out" "This removes:" "and must not ask about removing nothing"
    assert_not_contains "$(cat "$stub/conda.log")" "env remove" "and ask conda for nothing"
}

# The analysis wrapper confirms too, and says what it is NOT touching.
test_analysis_uninstall_confirms_and_can_be_refused() {
    run_analysis_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" uninstall <<< n
    assert_contains "$LAUNCHER_OUTPUT" "This removes:" "should say what goes"
    assert_contains "$LAUNCHER_OUTPUT" "${VERSIONED_ENV}-analysis" "naming the analysis environment"
    assert_contains "$LAUNCHER_OUTPUT" "Aborted" "and abort on no"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "env remove" "removing nothing"
}

# conda's own prompt is answered by -y. Without it a user who says no to conda leaves the
# wrapper reporting success over an environment that is still there.
test_every_environment_removal_passes_minus_y() {
    local without
    without=$(grep -n 'conda env remove -n "' "$REPO_ROOT/PoolSeqFlow" | grep -v -- '-y' || true)
    assert_eq "" "$without" "every conda env remove should pass -y"
}
