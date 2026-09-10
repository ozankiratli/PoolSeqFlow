#!/bin/bash
# The ./PoolSeqFlow wrapper's environment handling, against a stub conda.
# cost: static
# covers: PoolSeqFlow lib/wrapper_lib.sh lib/tool_version.sh bin/check_install.sh
# covers: bin/check_analysis_install.sh bin/check_project.sh
#
# These run entirely against the fake conda in lib/sandbox.sh. Nothing here creates,
# activates or removes a real environment: a test suite that could delete an operator's
# install is not worth having.

VERSIONED_ENV="PoolSeqFlow-$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/PoolSeqFlow" | head -1)"

# The whole point of naming environments after the release: an older shared environment
# must not be silently borrowed, because the pinned tools are part of what made a result.
test_run_refuses_to_fall_back_to_the_legacy_environment() {
    run_launcher_with_envs "base PoolSeqFlow" check install
    assert_status 1 "$LAUNCHER_STATUS" "check should fail when this version's env is absent"
    assert_contains "$LAUNCHER_OUTPUT" "$VERSIONED_ENV" "should name the environment it wanted"
    assert_contains "$LAUNCHER_OUTPUT" "kept every version in one environment" \
        "should explain what the legacy env is"
    assert_contains "$LAUNCHER_OUTPUT" "does not use it" "should be explicit that it is not borrowed"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate PoolSeqFlow" \
        "must not activate anything when the versioned env is missing"
}

test_run_lists_other_versions_without_using_them() {
    run_launcher_with_envs "base PoolSeqFlow-0.1.0 PoolSeqFlow-9.9.9" check install
    assert_status 1 "$LAUNCHER_STATUS" "check should fail"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-0.1.0" "should list other installed versions"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow-9.9.9" "should list other installed versions"
    assert_contains "$LAUNCHER_OUTPUT" "install" "should say how to fix it"
}

test_check_activates_when_the_matching_environment_exists() {
    run_launcher_with_envs "base $VERSIONED_ENV" check install
    assert_status 0 "$LAUNCHER_STATUS" "check should succeed"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate $VERSIONED_ENV" \
        "should activate this version's environment"
    assert_contains "$LAUNCHER_OUTPUT" "STUB check_install ran" "should go on to verify the install"
}

# A TOOL FROM OUTSIDE THE ENVIRONMENT IS A FAULT, AND IT IS THE SILENT ONE. Every tool the
# installation check looks for is pinned in install/environment.yml, so one resolving elsewhere
# means the environment is missing a package and the machine's own copy is standing in - at
# some other version, and nowhere but here. The run works and reproduces nowhere.
#
# The real script, not the stub every other case in this suite uses: what is being checked is
# the script's own logic, and a stub that echoes a line proves nothing about it. No conda and
# no JVM - a directory named after the environment and CONDA_PREFIX pointing at it is the whole
# fixture, because that is all the script reads.
#
# THE ENVIRONMENT DIRECTORY MUST BE NAMED FOR THE ENVIRONMENT. The script only compares paths
# when CONDA_PREFIX's basename matches ENV_NAME - otherwise it cannot say which environment it
# is in, and checks nothing. A fixture that gets that wrong disables the very comparison under
# test and passes, which is what the first version of these cases did.
CHECK_ENV_NAME="fixture-env"

check_install_fixture() {
    local sb; sb=$(guard_path "$TEST_TMPDIR/check-install-env")
    rm -rf "$sb"; mkdir -p "$sb/$CHECK_ENV_NAME/bin" "$sb/system"
    # The canonical list out of the script itself, so this cannot drift from what it checks.
    local tools; tools=$(sed -n 's/^CANONICAL="\(.*\)"$/\1/p' "$REPO_ROOT/bin/check_install.sh")
    [ -n "$tools" ] || { skip_case "could not read CANONICAL out of check_install.sh"; return 1; }
    local t
    for t in $tools nextflow python3 awk; do
        printf '#!/bin/bash\necho "%s 1.0"\n' "$t" > "$sb/$CHECK_ENV_NAME/bin/$t"
        chmod +x "$sb/$CHECK_ENV_NAME/bin/$t"
    done
    printf '%s' "$sb"
}

test_the_install_check_wants_the_environments_own_tools() {
    local sb; sb=$(check_install_fixture) || return
    local out
    out=$(cd "$REPO_ROOT" && ENV_NAME="$CHECK_ENV_NAME" CONDA_PREFIX="$sb/$CHECK_ENV_NAME" \
          PATH="$sb/$CHECK_ENV_NAME/bin:/usr/bin:/bin" bash bin/check_install.sh 2>&1)
    # This assertion is what stops the case passing over a disabled comparison: the header
    # names the prefix only when the script decided it knows which environment it is in.
    assert_contains "$out" "from $sb/$CHECK_ENV_NAME" \
        "the check must say it is reading the environment:"$'\n'"$out"
    assert_contains "$out" "checks passed" "and every tool comes from it here"
    assert_not_contains "$out" "OUTSIDE THE ENVIRONMENT" "so none is outside it"
}

test_the_install_check_catches_a_tool_from_outside_the_environment() {
    local sb; sb=$(check_install_fixture) || return
    # samtools leaves the environment and only the system has it - the exact shape of a
    # package missing from environment.yml's solve with a system copy standing in.
    mv "$sb/$CHECK_ENV_NAME/bin/samtools" "$sb/system/samtools"
    local out
    out=$(cd "$REPO_ROOT" && ENV_NAME="$CHECK_ENV_NAME" CONDA_PREFIX="$sb/$CHECK_ENV_NAME" \
          PATH="$sb/$CHECK_ENV_NAME/bin:$sb/system:/usr/bin:/bin" bash bin/check_install.sh 2>&1)
    assert_contains "$out" "OUTSIDE THE ENVIRONMENT" \
        "a tool resolving outside the environment must be reported:"$'\n'"$out"
    assert_contains "$out" "$sb/system/samtools" "naming where it actually came from"
    assert_contains "$out" "checks failed" "and it must fail the check, not warn"
}

# Run without the environment active there is nothing to compare a path against, so the check
# says so instead of comparing against nothing and calling every tool fine.
test_the_install_check_says_when_it_cannot_tell_where_a_tool_came_from() {
    local sb; sb=$(check_install_fixture) || return
    local out
    out=$(cd "$REPO_ROOT" && ENV_NAME="$CHECK_ENV_NAME" CONDA_PREFIX="" \
          PATH="$sb/$CHECK_ENV_NAME/bin:/usr/bin:/bin" bash bin/check_install.sh 2>&1)
    assert_contains "$out" "is not active" "must say the environment is not active:"$'\n'"$out"
    assert_not_contains "$out" "OUTSIDE THE ENVIRONMENT" "and claim nothing about where tools came from"
}

# TWO CHECKS THAT ANSWER DIFFERENT QUESTIONS, and a bare `check` must not pick one. Whichever
# it picked would leave the other unchecked while reporting success, which is the failure the
# word exists to prevent.
test_check_refuses_without_a_word() {
    run_launcher_with_envs "base $VERSIONED_ENV" check
    assert_status 1 "$LAUNCHER_STATUS" "a bare check must refuse"
    assert_contains "$LAUNCHER_OUTPUT" "check {install|project}" "naming both"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check_install ran" "and running neither"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check_project ran" "and running neither"
}

test_check_refuses_a_word_it_does_not_know() {
    run_launcher_with_envs "base $VERSIONED_ENV" check everything
    assert_status 1 "$LAUNCHER_STATUS" "an unknown check must refuse"
    assert_contains "$LAUNCHER_OUTPUT" "check {install|project}" "naming the two that exist"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check" "and running neither"
}

# `project` reads the directory you are standing in, so it refuses where there is no project
# rather than checking the installation and calling that an answer.
test_check_project_refuses_outside_a_project() {
    run_launcher_with_envs "base $VERSIONED_ENV" check project
    assert_status 1 "$LAUNCHER_STATUS" "check project must refuse without a parameters.config"
    assert_contains "$LAUNCHER_OUTPUT" "no parameters.config" "saying what is missing"
    assert_contains "$LAUNCHER_OUTPUT" "check project" "and naming the command to run again"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check_project ran" "having run nothing"
}

# An older config stops `check project` the same way it stops a run, and with the same advice.
# Checking a project against a config this release cannot read would report on a file the
# pipeline would refuse.
test_check_project_refuses_a_config_from_an_older_release() {
    local sb; sb=$(guard_path "$TEST_TMPDIR/launcher")
    LAUNCHER_PROJECT_CONFIG='projectDir = "/tmp/x"'
    run_launcher_with_envs "base $VERSIONED_ENV" check project
    unset LAUNCHER_PROJECT_CONFIG
    assert_status 1 "$LAUNCHER_STATUS" "an older config must stop the project check"
    assert_contains "$LAUNCHER_OUTPUT" "older release" "saying what is wrong"
    assert_contains "$LAUNCHER_OUTPUT" "migrate_config" "and how to fix it"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check_project ran" "having run nothing"
}

test_check_project_runs_in_the_project_with_the_environment_active() {
    LAUNCHER_PROJECT_CONFIG='storageDir = "/tmp/x"'
    run_launcher_with_envs "base $VERSIONED_ENV" check project
    unset LAUNCHER_PROJECT_CONFIG
    assert_status 0 "$LAUNCHER_STATUS" "check project should succeed: $LAUNCHER_OUTPUT"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate $VERSIONED_ENV" \
        "the project check needs the environment: it runs nextflow and asks tools their versions"
    assert_contains "$LAUNCHER_OUTPUT" "STUB check_project ran" "and it is the project script"
    assert_not_contains "$LAUNCHER_OUTPUT" "STUB check_install ran" "not the installation one"
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

# The frame config is wiring, not settings. Read-only stops the slip where a user edits an
# installation file and silently changes every project on the machine; it is not a lock, and
# the manual does not call it one.
test_install_deploys_the_frame_config_read_only() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "install should succeed: $LAUNCHER_OUTPUT"
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_file "$dest/analysis/frame.config" "the frame config should be deployed"
    assert_eq "444" "$(stat -c '%a' "$dest/analysis/frame.config" 2>/dev/null)" \
        "and it should be read-only"
    # The checkout it was installed FROM stays writable, or development would need a chmod
    # after every install.
    assert_eq "644" "$(stat -c '%a' "$REPO_ROOT/analysis/frame.config" 2>/dev/null)" \
        "while the source in the checkout stays writable"
}

# Installing over an installation has to work, and a 0444 file inside a writable directory is
# removable - but only because `rm -rf` takes the directory's permission, not the file's. If
# that ever stops being true, every upgrade fails on the second install rather than the first.
test_install_over_a_sealed_installation_succeeds() {
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "the first install should succeed"
    run_launcher_with_envs "base $VERSIONED_ENV" install
    assert_status 0 "$LAUNCHER_STATUS" "and so should a second over it: $LAUNCHER_OUTPUT"
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    assert_eq "444" "$(stat -c '%a' "$dest/analysis/frame.config" 2>/dev/null)" \
        "with the frame config still sealed afterwards"
}

# A sealed item is checked for existence like any other payload item. Deploying an
# installation without it would leave every analysis run without conda, bin/ or a ceiling.
test_install_refuses_when_a_sealed_item_is_missing() {
    local names; names=$(sealed_items)
    assert_contains "$(cat "$REPO_ROOT/PoolSeqFlow")" 'for item in $PAYLOAD_ITEMS $SEALED_ITEMS' \
        "the existence check must cover the sealed items too"
    assert_contains "$names" "analysis/frame.config" "which is where the frame config is named"
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
    assert_contains "$LAUNCHER_OUTPUT" "unversioned" "the legacy env should be labeled, not called a version"
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

# `nocpp` reaches the MODULE run and not the verifier. recordedManifest() keeps every
# top-level parameter, so a verifier run carrying one would read the project as having gained a
# setting since its results were produced and refuse every analysis in it.
test_the_module_flag_reaches_the_module_and_not_the_verifier() {
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" probe nocpp
    unset LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "a module should take the flag: $LAUNCHER_OUTPUT"
    assert_not_contains "$(sed -n 1p "$LAUNCHER_NEXTFLOW_LOG")" "--nocpp" \
        "the verifier must not be given it"
    assert_contains "$(sed -n 2p "$LAUNCHER_NEXTFLOW_LOG")" "--nocpp" \
        "and the module must be"
}

# A word the wrapper does not know used to be dropped in silence, so a typo ran the module
# with its defaults and said nothing.
test_a_word_a_module_run_does_not_know_is_refused() {
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" probe nocpu
    assert_status 1 "$LAUNCHER_STATUS" "a misspelled flag should stop the run"
    assert_contains "$LAUNCHER_OUTPUT" "nocpu" "naming the word it did not know"
    assert_eq "" "$(cat "$LAUNCHER_NEXTFLOW_LOG" 2>/dev/null)" "and nothing should have run"

    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" probe nocpp extra
    unset LAUNCHER_STORE_MODULE
    assert_status 1 "$LAUNCHER_STATUS" "two words after a module should be refused"
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
        "frame.config, analysis.config and probe.config"
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

# `modules list` reads the store and nothing else - no conda, no project - because it is the
# thing you run when an analysis run is refusing and you need to know what is installed.
test_modules_list_reports_the_store() {
    run_analysis_launcher_with_envs "base" modules list
    assert_status 0 "$LAUNCHER_STATUS" "listing should work without any environment"
    assert_contains "$LAUNCHER_OUTPUT" "none" "an empty store should say so"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "activate" "and activate nothing"

    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base" modules list
    unset LAUNCHER_STORE_MODULE
    assert_contains "$LAUNCHER_OUTPUT" "probe" "an installed module should be listed"
    assert_contains "$LAUNCHER_OUTPUT" "installed" "as installed"
}

# An incomplete module stops every analysis run, not only its own, so the listing is where a
# user finds out which one is at fault.
test_modules_list_names_an_incomplete_module() {
    LAUNCHER_STORE_MODULE=probe
    LAUNCHER_STORE_MODULE_INCOMPLETE=1
    run_analysis_launcher_with_envs "base" modules list
    unset LAUNCHER_STORE_MODULE LAUNCHER_STORE_MODULE_INCOMPLETE
    assert_status 0 "$LAUNCHER_STATUS" "listing a broken store should still work"
    assert_contains "$LAUNCHER_OUTPUT" "INCOMPLETE" "the module should be marked"
    assert_contains "$LAUNCHER_OUTPUT" "stops EVERY analysis run" "and the consequence stated"
}

# Removal confirms, as every uninstall in this wrapper does, and takes only the directory it
# names.
test_modules_uninstall_confirms_and_can_be_refused() {
    local store="$TEST_TMPDIR/analysis-launcher/analysis/modules"
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base" modules uninstall probe <<< n
    assert_status 1 "$LAUNCHER_STATUS" "a refused removal should fail"
    assert_dir "$store/probe" "and leave the module in place"

    run_analysis_launcher_with_envs "base" modules uninstall probe <<< y
    unset LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "a confirmed removal should succeed"
    assert_no_file "$store/probe" "and the module should be gone"
}

# The catalogue is the one thing a release does NOT carry, so everything below reads a local
# one through POOLSEQFLOW_MODULE_INDEX. That override is a shipped feature - a lab mirror, an
# air-gapped machine - and not only a test hook.
modules_catalogue() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue")
    rm -rf "$dir"; mkdir -p "$dir"
    make_module_release "$dir" probe 0.1.0 > /dev/null
    make_module_release "$dir" probe 0.2.0 > /dev/null
    make_module_release "$dir" future 9.0.0 freq-2
}

test_modules_available_reads_the_catalogue() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    run_analysis_launcher_with_envs "base" modules available
    unset LAUNCHER_MODULE_INDEX
    assert_status 0 "$LAUNCHER_STATUS" "listing what is published should work"
    assert_contains "$LAUNCHER_OUTPUT" "probe" "a published module should be listed"
    assert_contains "$LAUNCHER_OUTPUT" "0.2.0" "with its version"
    # ONE LINE PER MODULE, NOT PER PUBLISHED VERSION. The fixture publishes probe twice, and a
    # listing that walks rows prints a module's whole history - which grows with every publish
    # and tells a reader nothing they can act on. What is listed is the version `install` would
    # take, so the two commands cannot say different things.
    assert_not_contains "$LAUNCHER_OUTPUT" "0.1.0" "and not the version install would pass over"
    assert_eq "1" "$(printf '%s\n' "$LAUNCHER_OUTPUT" | grep -c '^    probe ')" \
              "probe must appear on exactly one line"
    # A module reading a contract this release does not speak is shown and marked, not hidden:
    # a user who was told to install it needs to know why they cannot.
    assert_contains "$LAUNCHER_OUTPUT" "future" "a module for another contract should still appear"
    assert_contains "$LAUNCHER_OUTPUT" "not this release" "marked as unreadable here"
}

# THE OLDER VERSION IS WHAT AN OLDER RELEASE MUST SEE, not a blank and not the newest one it
# cannot run. `available` and `install` answer the same question through one helper, so this is
# the listing half of `modules install takes the newest version this release can run`.
test_modules_available_lists_the_version_this_release_can_run() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-listcompat")
    rm -rf "$dir"; mkdir -p "$dir"
    MODULE_RELEASE_ENV="1.0.0"  make_module_release "$dir" probe 1.0.0 > /dev/null
    MODULE_RELEASE_ENV="99.0.0" make_module_release "$dir" probe 2.0.0 > /dev/null
    LAUNCHER_MODULE_INDEX="$dir/index.tsv"
    run_analysis_launcher_with_envs "base" modules available
    unset LAUNCHER_MODULE_INDEX MODULE_RELEASE_ENV
    assert_status 0 "$LAUNCHER_STATUS" "listing should work: $LAUNCHER_OUTPUT"
    assert_contains "$LAUNCHER_OUTPUT" "1.0.0" \
        "the newest version this release can run is what is listed"
    assert_not_contains "$LAUNCHER_OUTPUT" "2.0.0" \
        "and the one needing a newer release is not offered"
}

# Puts the two `#!` headers on a fixture catalogue. A catalogue without them is layout 1 by
# definition, which is what the other cases here exercise.
modules_catalogue_stamped() {
    local index="$1" format="$2" version="$3" tmp
    tmp="${index}.stamped"
    { printf '#!index-format: %s\n#!index-version: %s\n' "$format" "$version"; cat "$index"; } > "$tmp"
    mv "$tmp" "$index"
    printf '%s' "$index"
}

# THE REASON THE LAYOUT NUMBER EXISTS. The catalogue is fetched from the default branch at run
# time, so a release meets whatever is there years later, and its rows are read BY POSITION. A
# layout this release does not know must stop it, or it takes the wrong field out of each row -
# including the sha256 it verifies the tarball against.
test_modules_available_refuses_a_catalogue_layout_it_cannot_read() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue_stamped "$(modules_catalogue)" 99 20991231.001)
    run_analysis_launcher_with_envs "base" modules available
    unset LAUNCHER_MODULE_INDEX
    assert_status 1 "$LAUNCHER_STATUS" "an unreadable layout must stop the command"
    assert_contains "$LAUNCHER_OUTPUT" "layout 99" "naming the layout it found"
    assert_contains "$LAUNCHER_OUTPUT" "reads layout 1" "and the one it reads"
    assert_not_contains "$LAUNCHER_OUTPUT" "probe" "and listing nothing out of it"
    # An installation that already has modules keeps working; only the catalogue is unreadable.
    assert_contains "$LAUNCHER_OUTPUT" "still runs" "saying installed modules are unaffected"
}

# `install` goes through the same gate: refusing to LIST a catalogue but agreeing to install
# from it would be the worse half of the two.
test_modules_install_refuses_a_catalogue_layout_it_cannot_read() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue_stamped "$(modules_catalogue)" 99 20991231.001)
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 1 "$LAUNCHER_STATUS" "an unreadable layout must stop the install"
    assert_no_file "$LAUNCHER_STORE/probe" "and nothing may be installed from it"
}

# Which catalogue a module came from is answerable only if it was recorded when it was read.
test_the_catalogue_version_is_reported_and_recorded() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue_stamped "$(modules_catalogue)" 1 20260901.007)
    run_analysis_launcher_with_envs "base" modules available
    assert_status 0 "$LAUNCHER_STATUS" "a known layout should still list"
    assert_contains "$LAUNCHER_OUTPUT" "20260901.007" "available should name the catalogue it read"

    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "and installing from it should work"
    assert_contains "$(cat "$LAUNCHER_STORE/probe/.source" 2>/dev/null)" "20260901.007" \
        "the .source file should record which catalogue it came from"
}

test_modules_install_takes_the_newest_version_it_can_read() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "installing a published module should work"
    assert_contains "$LAUNCHER_OUTPUT" "probe v0.2.0" "the newest version, not the first row"
    assert_file "$LAUNCHER_STORE/probe/main.nf" "the module's pipeline should be in the store"
    assert_file "$LAUNCHER_STORE/probe/manifest.json" "and its manifest"
    # Where it came from, beside the module, so an installation can account for itself.
    assert_contains "$(cat "$LAUNCHER_STORE/probe/.source")" "0.2.0" "a source record should be written"
}

test_modules_install_pins_a_named_version() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe 0.1.0
    unset LAUNCHER_MODULE_INDEX
    assert_status 0 "$LAUNCHER_STATUS" "naming a version should install that one"
    assert_contains "$LAUNCHER_OUTPUT" "probe v0.1.0" "the version asked for, not the newest"
}

# The archive becomes code that runs on this machine, so it is verified before it is unpacked.
test_modules_install_refuses_a_tampered_download() {
    local index; index=$(modules_catalogue)
    # The checksum column is found BY NAME, as the wrapper finds it. Edited by position this
    # silently corrupted a different column when the layout gained two, and the case then
    # passed a download it was meant to refuse.
    awk -F'\t' 'BEGIN { OFS = "\t" }
        !hdr { hdr = 1; for (i = 1; i <= NF; i++) if ($i == "sha256") sha = i; print; next }
        $1 == "probe" && $2 == "0.2.0" { $sha = "0000000000000000000000000000000000000000000000000000000000000000" }
        { print }' "$index" > "$index.tampered"
    LAUNCHER_MODULE_INDEX="$index.tampered"
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX
    assert_status 1 "$LAUNCHER_STATUS" "a checksum mismatch must stop the install"
    assert_contains "$LAUNCHER_OUTPUT" "does not match the checksum" "saying what failed"
    assert_no_file "$LAUNCHER_STORE/probe" "and nothing should reach the store"
}

test_modules_install_refuses_a_module_for_another_contract() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install future
    unset LAUNCHER_MODULE_INDEX
    assert_status 1 "$LAUNCHER_STATUS" "a module for another contract should be refused"
    assert_no_file "$LAUNCHER_STORE/future" "and not installed"
}

# Replacing in place would leave a half-old module if the download failed partway.
test_modules_install_will_not_replace_an_installed_module() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "it is not an error, only a no-op"
    assert_contains "$LAUNCHER_OUTPUT" "already installed" "saying so"
    assert_contains "$LAUNCHER_OUTPUT" "modules uninstall probe" "and how to replace it"
}

# ---------------------------------------------------------------------------------------
# ONE CATALOGUE SERVES SEVERAL RELEASES. A row says the oldest frame and release it needs, so
# an installation that is behind takes an earlier version of a module rather than the newest
# one and a failure the first time it is used.

test_modules_install_takes_the_newest_version_this_release_can_run() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-compat")
    rm -rf "$dir"; mkdir -p "$dir"
    MODULE_RELEASE_ENV="1.0.0" make_module_release "$dir" probe 1.0.0 > /dev/null
    MODULE_RELEASE_ENV="99.0.0" make_module_release "$dir" probe 2.0.0 > /dev/null
    LAUNCHER_MODULE_INDEX="$dir/index.tsv"
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE MODULE_RELEASE_ENV
    assert_status 0 "$LAUNCHER_STATUS" "the older compatible version should install: $LAUNCHER_OUTPUT"
    assert_contains "$LAUNCHER_OUTPUT" "probe v1.0.0" "and it should be the one this release can run"
    assert_contains "$LAUNCHER_OUTPUT" "published up to v2.0.0" "saying what it passed over"
    assert_contains "$(cat "$LAUNCHER_STORE/probe/.source" 2>/dev/null)" "1.0.0" \
        "with the source record naming what was actually taken"
}

test_modules_install_refuses_when_no_published_version_fits() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-nofit")
    rm -rf "$dir"; mkdir -p "$dir"
    MODULE_RELEASE_ENV="99.0.0" make_module_release "$dir" probe 2.0.0 > /dev/null
    LAUNCHER_MODULE_INDEX="$dir/index.tsv"
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE MODULE_RELEASE_ENV
    assert_status 1 "$LAUNCHER_STATUS" "nothing installable should stop the install"
    assert_contains "$LAUNCHER_OUTPUT" "PoolSeqFlow 99.0.0" "naming the release it wants"
    assert_no_file "$LAUNCHER_STORE/probe/main.nf" "and nothing should reach the store"
}

# A row demanding a frame newer than the installation carries is refused the same way, and this
# is the axis `contract` does not cover: the module imports the library by name.
test_modules_install_refuses_a_row_needing_a_newer_frame() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-frame")
    rm -rf "$dir"; mkdir -p "$dir"
    MODULE_RELEASE_FRAME="20990101.001" make_module_release "$dir" probe 2.0.0 > /dev/null
    LAUNCHER_MODULE_INDEX="$dir/index.tsv"
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE MODULE_RELEASE_FRAME
    assert_status 1 "$LAUNCHER_STATUS" "a frame this installation does not have should stop it"
    assert_contains "$LAUNCHER_OUTPUT" "20990101.001" "naming the frame it wants"
}

# THE PROPERTY THAT KEEPS A NEW COLUMN FROM FORCING A NEW MAJOR RELEASE. Columns are matched by
# name out of the header row, so a catalogue carrying one this release has never heard of is
# read correctly and the extra ignored - and one written before a column existed leaves that
# field empty rather than shifting every field after it.
test_a_catalogue_column_this_release_does_not_know_is_ignored() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-extra")
    rm -rf "$dir"; mkdir -p "$dir"
    make_module_release "$dir" probe 1.0.0 > /dev/null

    # Rewrite the catalogue with the columns shuffled, one this release cannot know appended,
    # and `summary` moved ahead of `url` - all of which a positional reader would get wrong.
    local idx="$dir/index.tsv" row
    row=$(tail -1 "$idx")
    local f_url f_sha
    f_url=$(printf '%s' "$row" | cut -f6); f_sha=$(printf '%s' "$row" | cut -f7)
    printf 'summary\tname\tsignature\tversion\tcontract\turl\tsha256\n' > "$idx"
    printf 'planted probe\tprobe\tnot-a-column-this-release-knows\t1.0.0\tfreq-1\t%s\t%s\n' \
        "$f_url" "$f_sha" >> "$idx"

    LAUNCHER_MODULE_INDEX="$idx"
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "a reordered catalogue with an extra column should install: $LAUNCHER_OUTPUT"
    assert_file "$LAUNCHER_STORE/probe/main.nf" "taking the url from the column named url"
}

# ---------------------------------------------------------------------------------------
# One analysis environment, shared by every module in it. What these prove is which conda
# command lines are issued and in what order; whether a solve succeeds is not a question a
# stub can answer, and dev/scripts/check-module-packages.sh is where that is asked.

# Installing a module now installs what it runs on, so an environment to install it into is
# no longer optional.
test_modules_install_needs_the_analysis_environment() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 1 "$LAUNCHER_STATUS" "installing without the analysis environment should fail"
    assert_contains "$LAUNCHER_OUTPUT" "${VERSIONED_ENV}-analysis" "naming the environment it wanted"
    assert_no_file "$LAUNCHER_STORE/probe/main.nf" "and nothing should reach the store"
}

# --freeze-installed is the whole guarantee: the solver may add these and what they need, and
# may not move anything another module is already running on.
test_modules_install_puts_a_modules_packages_in_the_environment() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-pkgs")
    rm -rf "$dir"; mkdir -p "$dir"
    LAUNCHER_MODULE_INDEX=$(make_module_release "$dir" probe 0.1.0 freq-1 "r-poolfstat=3.0.0")
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "installing a module with a dependency should work: $LAUNCHER_OUTPUT"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" \
        "install -n ${VERSIONED_ENV}-analysis --freeze-installed -y r-poolfstat=3.0.0" \
        "the pin should be installed into the analysis environment, frozen"
    assert_contains "$LAUNCHER_OUTPUT" "r-poolfstat=3.0.0" "and the user should be told what was added"
}

# Every module shipped in this release declares nothing, so the common case must issue no
# conda command at all rather than an empty install.
test_modules_install_asks_conda_for_nothing_when_a_module_declares_none() {
    LAUNCHER_MODULE_INDEX=$(modules_catalogue)
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "installing a module with no packages should work"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "--freeze-installed" \
        "a module declaring nothing should reach conda with nothing"
}

# Refused from the manifest, before the archive is moved and before conda is asked: a spec
# conda would reject anyway is refused here so the message names the module, not the solver.
test_modules_install_refuses_a_spec_that_is_not_pinned() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-loose")
    rm -rf "$dir"; mkdir -p "$dir"
    LAUNCHER_MODULE_INDEX=$(make_module_release "$dir" probe 0.1.0 freq-1 "r-poolfstat")
    LAUNCHER_STORE_MODULE=""
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    assert_status 1 "$LAUNCHER_STATUS" "an unpinned package should stop the install"
    assert_contains "$LAUNCHER_OUTPUT" "'r-poolfstat'" "quoting the spec that is wrong"
    assert_contains "$LAUNCHER_OUTPUT" "no build string" "and saying what a spec may not carry"
    assert_no_file "$LAUNCHER_STORE/probe/main.nf" "with nothing left in the store"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "--freeze-installed" \
        "and conda never asked"

    rm -rf "$dir"; mkdir -p "$dir"
    LAUNCHER_MODULE_INDEX=$(make_module_release "$dir" probe 0.1.0 freq-1 "r-poolfstat=3.0.0=r44h1")
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE
    assert_status 1 "$LAUNCHER_STATUS" "a build string should stop the install"
    assert_contains "$LAUNCHER_OUTPUT" "r44h1" "quoting the spec that is wrong"
}

# --freeze-installed covers what the SOLVE reaches on its own and not what the command line
# names: conda installs a named pin at the version asked for, downgrading what is there. Found
# by dev/scripts/check-module-packages.sh against real conda, which watched a fixture take the
# baseline's r-glue from 1.8.1 to 1.8.0 and call the solve a success.
test_modules_install_refuses_a_pin_over_a_version_already_installed() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-clash")
    rm -rf "$dir"; mkdir -p "$dir"
    LAUNCHER_MODULE_INDEX=$(make_module_release "$dir" probe 0.1.0 freq-1 "r-poolfstat=3.0.0")
    LAUNCHER_STORE_MODULE=""
    STUB_CONDA_INSTALLED='r-poolfstat=2.0.0=r44h1'
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE STUB_CONDA_INSTALLED
    assert_status 1 "$LAUNCHER_STATUS" "a pin over a different installed version should fail"
    assert_contains "$LAUNCHER_OUTPUT" "already holds" "saying the environment disagrees"
    assert_contains "$LAUNCHER_OUTPUT" "installed 2.0.0" "and naming the version that is there"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "--freeze-installed" \
        "with conda never asked to install it"
    assert_no_file "$LAUNCHER_STORE/probe/main.nf" "and the module rolled back out of the store"
}

# The same pin twice is not a disagreement: two modules may need one package at one version,
# which is the whole reason the environment is shared.
test_modules_install_accepts_a_pin_the_environment_already_matches() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-match")
    rm -rf "$dir"; mkdir -p "$dir"
    LAUNCHER_MODULE_INDEX=$(make_module_release "$dir" probe 0.1.0 freq-1 "r-poolfstat=3.0.0")
    LAUNCHER_STORE_MODULE=""
    STUB_CONDA_INSTALLED='r-poolfstat=3.0.0=r44h1'
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE STUB_CONDA_INSTALLED
    assert_status 0 "$LAUNCHER_STATUS" "the same version already there should install: $LAUNCHER_OUTPUT"
    assert_file "$LAUNCHER_STORE/probe/main.nf" "and the module should be in the store"
    # AND CONDA IS NOT ASKED. A module declares what it needs whether or not the release already
    # carries it, so this is the ordinary case rather than the rare one: three modules sharing a
    # baseline package used to mean three solves to be told nothing has to happen.
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "--freeze-installed" \
        "a spec already satisfied needs no solve"
    assert_contains "$LAUNCHER_OUTPUT" "already in" "and the message says so rather than listing work"
}

# ONLY THE DIFFERENCE IS INSTALLED. A manifest names everything the module needs, and what the
# environment already holds at the version asked for is not work - it is a round trip and a solve
# to be told nothing has to happen.
test_modules_install_asks_conda_only_for_what_is_missing() {
    local dir; dir=$(guard_path "$TEST_TMPDIR/module-catalogue-diff")
    rm -rf "$dir"; mkdir -p "$dir"
    LAUNCHER_MODULE_INDEX=$(make_module_release "$dir" probe 0.1.0 freq-1 \
        "r-have=1.0.0 r-want=2.0.0")
    LAUNCHER_STORE_MODULE=""
    STUB_CONDA_INSTALLED='r-have=1.0.0=r44h1'
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" modules install probe
    unset LAUNCHER_MODULE_INDEX LAUNCHER_STORE_MODULE STUB_CONDA_INSTALLED
    assert_status 0 "$LAUNCHER_STATUS" "the install should succeed: $LAUNCHER_OUTPUT"
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "r-want=2.0.0" "the missing package is asked for"
    assert_not_contains "$log" "r-have=1.0.0" "the one already there is not"
    # The message and the command line have to agree: a line naming a package that is not then
    # installed is the same defect wearing different clothes.
    assert_not_contains "$LAUNCHER_OUTPUT" "    r-have=1.0.0" \
        "and it is not listed as something being installed"
}

# The environment is shared, so what leaves with a module is its own list minus whatever the
# modules left behind still declare.
test_modules_uninstall_takes_only_what_nothing_else_declares() {
    local store="$TEST_TMPDIR/analysis-launcher/analysis/modules"
    LAUNCHER_STORE_MODULE=probe
    LAUNCHER_STORE_MODULE_PACKAGES='"r-shared=1.0","r-mine=2.0"'
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" \
        modules uninstall probe <<< y
    unset LAUNCHER_STORE_MODULE LAUNCHER_STORE_MODULE_PACKAGES
    assert_status 0 "$LAUNCHER_STATUS" "the removal should succeed: $LAUNCHER_OUTPUT"
    assert_no_file "$store/probe" "and the module should be gone"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" \
        "remove -n ${VERSIONED_ENV}-analysis -y r-mine r-shared" \
        "both of its packages go when it is the only module"
}

test_modules_uninstall_leaves_a_package_another_module_declares() {
    local store="$TEST_TMPDIR/analysis-launcher/analysis/modules"
    LAUNCHER_STORE_MODULE=probe
    LAUNCHER_STORE_MODULE_PACKAGES='"r-shared=1.0","r-mine=2.0"'
    LAUNCHER_STORE_EXTRA_MODULE=keeper
    LAUNCHER_STORE_EXTRA_PACKAGES='"r-shared=1.0"'
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" \
        modules uninstall probe <<< y
    unset LAUNCHER_STORE_MODULE LAUNCHER_STORE_MODULE_PACKAGES
    unset LAUNCHER_STORE_EXTRA_MODULE LAUNCHER_STORE_EXTRA_PACKAGES
    assert_status 0 "$LAUNCHER_STATUS" "the removal should succeed: $LAUNCHER_OUTPUT"
    assert_no_file "$store/probe" "and the module should be gone"
    assert_dir "$store/keeper" "while the other module stays"
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "remove -n ${VERSIONED_ENV}-analysis -y r-mine" "only its own package goes"
    assert_not_contains "$log" "-y r-shared" "the one the other module declares stays"
}

# THE KEEP-LIST IS BUILT BY CONCATENATING ONE MANIFEST READ PER MODULE, and the case above
# cannot see what that costs: with a single other module there is no join to get wrong. At two
# the last entry of one manifest meets the first entry of the next, and an unterminated read
# hands them over as one token - which drops a real name out of the keep-list silently, so the
# package is removed while a module that declares it is still installed.
#
# Called directly rather than through the launcher. What is being asked is what two functions
# return, and a conda log is a slow and indirect way to ask it.
test_the_keep_list_survives_more_than_one_other_module() {
    local sb; sb=$(guard_path "$TEST_TMPDIR/keep-list")
    rm -rf "$sb"; mkdir -p "$sb/going" "$sb/first" "$sb/second"
    # `going` is being removed; both of the others declare something it also declares, and the
    # shared names sit at the ENDS of their lists, which is where a join lands.
    printf '{"name":"going","packages":["r-edge=1.0"],"libraries":["lib_edge"]}\n' \
        > "$sb/going/manifest.json"
    printf '{"name":"first","packages":["r-a=1.0","r-b=2.0"],"libraries":["lib_a","lib_b"]}\n' \
        > "$sb/first/manifest.json"
    printf '{"name":"second","packages":["r-edge=1.0"],"libraries":["lib_edge"]}\n' \
        > "$sb/second/manifest.json"

    local packages libraries
    packages=$(INSTALL="$REPO_ROOT"; . "$REPO_ROOT/lib/wrapper_lib.sh" >/dev/null 2>&1
               store_packages "$sb" going | cut -d= -f1 | sort -u)
    libraries=$(INSTALL="$REPO_ROOT"; . "$REPO_ROOT/lib/wrapper_lib.sh" >/dev/null 2>&1
                store_libraries "$sb" going | sort -u)

    assert_contains "$packages" "r-edge" \
        "the package the second module also declares must be in the keep-list:"$'\n'"$packages"
    assert_contains "$libraries" "lib_edge" \
        "and so must the library:"$'\n'"$libraries"
    # A joined pair is the symptom, and naming it makes a failure say what happened rather than
    # only that something is missing.
    assert_not_contains "$packages" "r-br-edge" "two specs must not arrive as one token"
    assert_not_contains "$libraries" "lib_blib_edge" "nor two library names"
}

# `conda remove` takes everything depending on what it is given, so the plan is read before
# it runs and a name beyond the ones asked for stops the removal.
test_modules_uninstall_stops_when_the_removal_would_cascade() {
    local store="$TEST_TMPDIR/analysis-launcher/analysis/modules"
    LAUNCHER_STORE_MODULE=probe
    LAUNCHER_STORE_MODULE_PACKAGES='"r-mine=2.0"'
    STUB_CONDA_COLLATERAL=r-bystander
    run_analysis_launcher_with_envs "base ${VERSIONED_ENV}-analysis" \
        modules uninstall probe <<< y
    unset LAUNCHER_STORE_MODULE LAUNCHER_STORE_MODULE_PACKAGES STUB_CONDA_COLLATERAL
    assert_status 1 "$LAUNCHER_STATUS" "a cascade should stop the removal"
    assert_contains "$LAUNCHER_OUTPUT" "r-bystander" "naming what would have gone with it"
    assert_contains "$LAUNCHER_OUTPUT" "still installed" "and saying the module stayed"
    assert_dir "$store/probe" "which it did"
}

# The store lives inside the payload and dies with it, so its packages come out while the
# manifests declaring them still exist. After this both are back to what the release ships.
test_installing_over_a_store_takes_its_packages_out_first() {
    run_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" install
    assert_status 0 "$LAUNCHER_STATUS" "the first install should succeed"
    local dest="$LAUNCHER_PREFIX/opt/PoolSeqFlow-$PSF_VERSION"
    mkdir -p "$dest/analysis/modules/planted"
    printf '{"name":"planted","version":"1.0","contract":"freq-1","packages":["r-planted=1.0"]}\n' \
        > "$dest/analysis/modules/planted/manifest.json"
    # The second install runs against the sandbox as it stands: run_launcher_with_envs rebuilds
    # it from scratch, which would take the planted module with it.
    local sb out status=0
    sb=$(dirname "$LAUNCHER_PREFIX")
    out=$(cd "$sb" && PATH="$sb/stub/bin:$PATH" POOLSEQFLOW_PREFIX="$LAUNCHER_PREFIX" \
          ./PoolSeqFlow install 2>&1) || status=$?
    assert_status 0 "$status" "installing over it should succeed: $out"
    assert_contains "$(cat "$LAUNCHER_CONDA_LOG")" \
        "remove -n ${VERSIONED_ENV}-analysis -y r-planted" \
        "the wiped store's packages should be removed before the wipe"
    assert_contains "$out" "r-planted" "and the user should be told what came out"
    assert_no_file "$dest/analysis/modules/planted" "with the store back to what the release ships"
}

# The store outlives the environment - `analysis uninstall` takes one and leaves the other -
# so creating the environment has to give the modules already there what they run on, or the
# pair leaves every one of them installed and unable to start.
test_analysis_install_gives_the_store_its_packages_back() {
    LAUNCHER_STORE_MODULE=probe
    LAUNCHER_STORE_MODULE_PACKAGES='"r-poolfstat=3.0.0"'
    run_analysis_launcher_with_envs "base" install
    unset LAUNCHER_STORE_MODULE LAUNCHER_STORE_MODULE_PACKAGES
    assert_status 0 "$LAUNCHER_STATUS" "creating the analysis environment should work: $LAUNCHER_OUTPUT"
    local log; log=$(cat "$LAUNCHER_CONDA_LOG")
    assert_contains "$log" "env create -n ${VERSIONED_ENV}-analysis" "the environment is created"
    assert_contains "$log" \
        "install -n ${VERSIONED_ENV}-analysis --freeze-installed -y r-poolfstat=3.0.0" \
        "and the installed modules' packages go back into it"
    assert_contains "$LAUNCHER_OUTPUT" "r-poolfstat=3.0.0" "with the user told what was added"
}

test_analysis_install_asks_conda_for_nothing_when_the_store_declares_none() {
    LAUNCHER_STORE_MODULE=probe
    run_analysis_launcher_with_envs "base" install
    unset LAUNCHER_STORE_MODULE
    assert_status 0 "$LAUNCHER_STATUS" "creating the analysis environment should work"
    assert_not_contains "$(cat "$LAUNCHER_CONDA_LOG")" "--freeze-installed" \
        "a store whose modules declare nothing reaches conda with nothing"
}

test_modules_explains_an_unreachable_catalogue() {
    LAUNCHER_MODULE_INDEX="$TEST_TMPDIR/module-catalogue/absent.tsv"
    run_analysis_launcher_with_envs "base" modules available
    unset LAUNCHER_MODULE_INDEX
    assert_status 1 "$LAUNCHER_STATUS" "an unreachable catalogue should fail"
    assert_contains "$LAUNCHER_OUTPUT" "could not read the module catalogue" "saying what failed"
    assert_contains "$LAUNCHER_OUTPUT" "POOLSEQFLOW_MODULE_INDEX" "and how to point it elsewhere"
}

# A name that is not a plain word never reaches `rm -rf`.
test_modules_uninstall_refuses_a_name_that_is_not_one() {
    run_analysis_launcher_with_envs "base" modules uninstall ../../etc
    assert_status 1 "$LAUNCHER_STATUS" "a path should be refused"
    assert_contains "$LAUNCHER_OUTPUT" "is not a module name" "saying why"
    run_analysis_launcher_with_envs "base" modules uninstall absent
    assert_status 0 "$LAUNCHER_STATUS" "a module that is not installed is not an error"
    assert_contains "$LAUNCHER_OUTPUT" "No module 'absent' is installed" "and says so"
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

# A CONFIG FROM AN OLDER RELEASE IS REFUSED, AND THE COMMAND THAT FIXES IT IS NOT.
#
# Nothing failed on this path before 3.0. Nextflow reads whatever parameters.config gives it,
# the parameters this release wants are simply absent, and step 0 interpolates one into a path:
# `dir_log = "${params.dir.allLogs}/0_verify_environment"` became `null/0_verify_environment`,
# so the run started and wrote into a directory named "null". Measured against a real v2.2.0
# config, not imagined - `nextflow config` resolved it without an error of any kind.
#
# The real v2.2.0 template is the fixture, so this cannot pass against a hand-written file that
# happens to omit storageDir while being nothing a user ever had.
test_a_config_from_an_older_release_is_refused_with_the_fix() {
    local dir out status
    dir=$(guard_path "$TEST_TMPDIR/unmigrated-config")
    rm -rf "$dir"; mkdir -p "$dir"
    (cd "$REPO_ROOT" && git show v2.2.0:parameters.config.template) > "$dir/parameters.config" \
        2>/dev/null || { skip_case "no v2.2.0 template to migrate from"; return; }

    # The checkout's own wrapper, run FROM the project directory, which is how a user meets
    # this. A copy into the sandbox is an incomplete installation and would be refused by
    # require_install several checks earlier, testing nothing this case is about.
    out=$(cd "$dir" && bash "$REPO_ROOT/PoolSeqFlow" run 2>&1) && status=0 || status=$?
    assert_status 1 "$status" "an unmigrated config should be refused"
    assert_contains "$out" "older release" "should say why it refused"
    assert_contains "$out" "migrate_config" "should name the command that fixes it"
    assert_contains "$out" "projectDir" "should name the old parameters it recognized"

    # The refusal has to come before anything is run, or it is just a different late failure.
    assert_not_contains "$out" "Running pipeline" "should refuse before launching anything"

    # migrate_config is the fix and must never be refused by the guard against it.
    out=$(cd "$dir" && bash "$REPO_ROOT/PoolSeqFlow" migrate_config 2>&1) \
        && status=0 || status=$?
    assert_status 0 "$status" "migrate_config must not be refused by the guard it fixes:"$'\n'"$out"
    assert_contains "$(cat "$dir/parameters.config")" "storageDir" \
        "and must write a config this release recognizes"
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

# Arity is each arm's own, which is what lets `modules uninstall <name>` take a second word
# while everything beside it still takes none.
test_the_modules_arm_takes_a_word_the_others_refuse() {
    run_analysis_launcher_with_envs "base" modules
    assert_status 1 "$LAUNCHER_STATUS" "modules with no verb should be refused"
    assert_contains "$LAUNCHER_OUTPUT" "modules {list|available|install" "with its own usage"
    run_analysis_launcher_with_envs "base" modules list
    assert_status 0 "$LAUNCHER_STATUS" "modules list should be accepted as two words"
    run_analysis_launcher_with_envs "base" modules list extra
    assert_status 1 "$LAUNCHER_STATUS" "but not as three"
    run_analysis_launcher_with_envs "base" modules uninstall
    assert_status 1 "$LAUNCHER_STATUS" "uninstall needs the module to remove"
}

# Every subcommand the analysis usage line advertises must have an arm, and every arm must be
# advertised. `<module>` is the one exclusion: it is a placeholder, not a word. Anything else
# excluded here is a command advertised to users that does nothing.
#
# The arms sit in the nested case, indented eight spaces further than the pipeline's own.
test_analysis_usage_and_implementation_agree() {
    local wrapper="$REPO_ROOT/PoolSeqFlow" usage_line advertised implemented cmd
    usage_line=$(sed -n 's/.*Usage: \$0 analysis {\(.*\)}.*/\1/p' "$wrapper" | head -1)
    # The arm is the first word of each entry; `modules <command>` is an arm that carries a
    # word, `<module>` is a placeholder with no arm at all.
    advertised=$(printf '%s' "$usage_line" | tr '|' '\n' | awk '{print $1}' | grep -vx '<module>' | sort)
    implemented=$(sed -n 's/^            \([a-z_|]*\))$/\1/p' "$wrapper" | tr '|' '\n' | sort)
    # Both sides going empty together would pass vacuously, and a changed usage line or a
    # re-indented case is exactly how that happens.
    [ -n "$advertised" ] || fail_case "could not read the usage line out of the wrapper"
    [ -n "$implemented" ] || fail_case "could not read any case arm out of the wrapper"
    assert_eq "$advertised" "$implemented" "the advertised subcommands and the implemented arms"
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        # Only the entries that carry no word of their own can be run bare.
        case $cmd in *' '*|*'<'*) continue ;; esac
        # `y` for `uninstall`, which confirms before it removes anything; the rest ignore it.
        run_analysis_launcher_with_envs "base $VERSIONED_ENV ${VERSIONED_ENV}-analysis" "$cmd" <<< y
        assert_status 0 "$LAUNCHER_STATUS" "$cmd should be implemented"
    done < <(printf '%s' "$usage_line" | tr '|' '\n')
}

# The same agreement one level down: every verb `modules` advertises must have an arm.
test_modules_usage_and_implementation_agree() {
    local wrapper="$REPO_ROOT/PoolSeqFlow" usage_line advertised implemented
    usage_line=$(sed -n 's/.*Usage: \$0 analysis modules {\(.*\)}.*/\1/p' "$wrapper" | head -1)
    advertised=$(printf '%s' "$usage_line" | tr '|' '\n' | awk '{print $1}' | sort)
    implemented=$(sed -n 's/^                    \([a-z_|]*\))$/\1/p' "$wrapper" | tr '|' '\n' | sort)
    [ -n "$advertised" ] || fail_case "could not read the modules usage line out of the wrapper"
    [ -n "$implemented" ] || fail_case "could not read any modules arm out of the wrapper"
    assert_eq "$advertised" "$implemented" "the advertised module verbs and the implemented arms"
}

# `analysis check` is the analysis layer's counterpart to `check install`: it activates this
# version's analysis environment and hands off to the checker, never borrowing the pipeline's.
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
        "the legacy environment should be offered, and labeled for what it is"
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
