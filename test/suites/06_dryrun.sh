#!/bin/bash
# The dry run: where the work would go, shown before any of it is done.
# cost: jvm
# covers: dryrun.nf scripts/variants.nf scripts/resolve_parameters.nf
#
# What these are about is the promise the subcommand makes. A preview verifies the project and
# builds the directory tree it would fill, and it leaves the project able to say "this has never
# run" afterwards - so nothing it writes may become the baseline a later real run is compared
# against, and none of the user's own files may change. That is a property of five separate
# writers in step 0, not of one, which is why it is asserted by absence rather than by reading a
# report.

DRYRUN_SB=""
DRYRUN_WRAPPER_SB=""

# ONE PREVIEW, BUILT ONCE. A dry run is a Nextflow invocation and costs about 21 seconds flat,
# so the fixture carries everything the read-only cases need at the same time:
#
#   a and b share steps 2-6 and 8 and diverge at step 7  - so there is a Shared_<N>
#   c has a storageDir of its own                        - so there are TWO storage roots,
#                                                          which is the case dryrun exists for
#   metadata.csv has Windows line endings                - so nothing anywhere may rewrite a
#                                                          file the user wrote
#
# No group contains all three runs, so `All_Runs` is nobody's variant - which is exactly the
# table that catches a preview leaving out the invocation's own directories.
dryrun_baseline() {
    [ -n "$DRYRUN_SB" ] && return 0
    local sb
    sb=$(make_pipeline_sandbox "dryrun-baseline")
    guard_path "$sb/store2" > /dev/null
    printf 'RunID,storageDir,vcffilter.minQUAL\na,,30\nb,,1000\nc,%s,30\n' "$sb/store2" \
        > "$sb/main/runs.csv"
    write_sandbox_config "$sb" 's|^    multiRun .*|    multiRun        = true|'
    sed -i 's/$/\r/' "$sb/main/metadata.csv"
    run_project_wrapper "$sb" dryrun
    [ "$WRAPPER_STATUS" = "0" ] || return 1
    DRYRUN_SB="$sb"
    return 0
}

dryrun_ready() {
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi
    if ! dryrun_baseline; then
        fail_case "the dry run itself failed:
$WRAPPER_OUTPUT"
        return 1
    fi
    return 0
}

# A storage root's directory inside the preview, found by the same flattening the pipeline
# applies rather than by rebuilding the rule here: a test that reimplemented it would agree with
# itself and with nothing else.
preview_root() {
    local sb="$1" root="$2"
    printf '%s/main/dryrun/%s' "$sb" "$(printf '%s' "${root#/}" | tr '/' '_')"
}

# A sandbox for the wrapper's own handling of the preview directory. No pipeline run: `dryclean`
# and `dryrun`'s refusal both happen before Nextflow is started, so what they need is a project
# with a parameters.config to read params.dryRunDir out of.
dryrun_wrapper_ready() {
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ -z "$DRYRUN_WRAPPER_SB" ]; then
        DRYRUN_WRAPPER_SB=$(make_pipeline_sandbox "dryrun-wrapper")
        write_sandbox_config "$DRYRUN_WRAPPER_SB"
    fi
    # Each case builds the preview it wants, so they do not depend on each other's order.
    rm -rf "$DRYRUN_WRAPPER_SB/main/dryrun"
    return 0
}

# THE WHOLE PROMISE, ASSERTED BY ABSENCE. Every one of these files is written by a different
# branch of step 0, and each of them is what a later run compares against - so a preview that
# left any one behind would have the next real run measuring results that do not exist against
# settings that were never used.
test_a_dry_run_records_nothing() {
    dryrun_ready || return
    local sb="$DRYRUN_SB" store
    store="$sb/store/Output"

    assert_no_file "$store/.poolseqflow_version" "the release must not be stamped by a preview"
    assert_no_file "$store/.poolseqflow_params"  "nor the resolved parameter manifest"
    assert_no_file "$store/.parameters.config"   "nor the copy of the config"
    assert_no_file "$store/.multirun.csv"        "nor the copy of the table"
    assert_no_file "$store/run_parameters.txt"   "nor the readable record beside them"
    assert_no_file "$sb/store2/Output/.poolseqflow_version" "and not under a second storage root"

    # The metadata baseline is written beside the VCF of the variant it describes, so it is
    # looked for anywhere under either root rather than at one path.
    assert_eq "" "$(find "$sb/store" "$sb/store2" -name '.poolseqflow_metadata' 2>/dev/null)" \
        "no metadata baseline may be recorded either"
    # A members file is a record of what a directory holds. The preview holds it instead.
    assert_eq "" "$(find "$sb/store" "$sb/store2" -name 'members.txt' 2>/dev/null)" \
        "and no members file in the real results tree"

    # Said in the report as well as done, because a user reading it should not have to infer
    # from silence that nothing was written.
    assert_contains "$(cat "$sb/store/Output/a/Reports/0_verify_environment.txt")" \
        "DRY RUN - everything is checked, nothing is recorded" \
        "the parameter check should say that this was a dry run"
}

# The other half: the files the user wrote themselves.
#
# Step 0 used to rewrite metadata.csv in place when it had Windows line endings, which made
# "a dry run changes nothing of yours" a thing that had to be arranged. It is now structural -
# bin/parse_metadata.py tolerates CRLF and nothing else reads the file at all - so what this
# asserts is that the structural version holds, for a dry run and by extension for any run.
test_a_dry_run_leaves_the_users_own_files_alone() {
    dryrun_ready || return
    local sb="$DRYRUN_SB"
    assert_eq "still there" \
        "$(grep -q $'\r' "$sb/main/metadata.csv" && echo 'still there' || echo 'rewritten')" \
        "nothing may rewrite the user's metadata file"

    # And the carriage returns must not cascade either: a file that is tolerated has to be
    # tolerated all the way through, not merely left alone and then misread.
    local report
    report=$(cat "$sb/store/Output/a/Reports/0_verify_environment.txt")
    assert_contains "$report" "METADATA VERIFICATION:  STATUS=PASS" \
        "a CRLF metadata file should verify cleanly"
    assert_not_contains "$report" "has reads but no row" \
        "and its sample names must not pick up a stray carriage return"
}

# WHY THIS EXISTS AT ALL (Z, 2026-08-27): a run that points its own storageDir somewhere else
# used to get a warning in a log. A warning describes a layout; a directory tree is one.
test_each_storage_root_is_one_directory_in_the_preview() {
    dryrun_ready || return
    local sb="$DRYRUN_SB" main store store2
    main=$(preview_root "$sb" "$sb/main")
    store=$(preview_root "$sb" "$sb/store")
    store2=$(preview_root "$sb" "$sb/store2")

    assert_file "$sb/main/dryrun/README.txt" "the preview should explain itself"
    # Three roots, each flattened whole, each holding the tree it would really hold.
    assert_eq "3" "$(find "$sb/main/dryrun" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
        "one directory per storage root and no more"
    assert_dir "$main/work" "mainDir's working directory belongs to mainDir"
    assert_dir "$store/Output/Shared_1/VCF" "what a and b share goes to the shared root"
    assert_dir "$store2/Output/c/VCF" "and c's results to the root c asked for"
    assert_no_file "$store/Output/c" "c writes nothing to the root it left"

    # The invocation's own directories. No group here contains every run, so nothing in the
    # plan produces All_Runs - and step 0, step 1 and Nextflow's trace all write there anyway.
    assert_dir "$store/Logs/All_Runs" "the shared log directory is created whatever the table"
    assert_dir "$store/Output/All_Runs/Reports" "and the one holding the session reports"
}

# Which runs is Shared_1? The preview answers it in the directory that raises the question.
test_the_preview_says_who_each_shared_directory_belongs_to() {
    dryrun_ready || return
    local sb="$DRYRUN_SB" store readme
    store=$(preview_root "$sb" "$sb/store")
    assert_eq "a
b" "$(cat "$store/Output/Shared_1/members.txt" 2>/dev/null)" \
        "the members file goes into the preview, where a real run would put it"

    readme=$(cat "$sb/main/dryrun/README.txt")
    assert_contains "$readme" "Shared_1 is a shared directory for a, b" \
        "and the divergence analysis is reported in full"
    assert_contains "$readme" "This project has not been run yet" \
        "a fresh project should be named as one"
    # a and b diverge AT step 7, so the frequency tables are each run's own and the shared
    # directory stops at what step 6 produced. The listing has to say that, folder by folder.
    assert_contains "$readme" "Output/Shared_1/Ready" "every directory should be listed"
    assert_contains "$readme" "Output/a/Frequencies" "including the ones a run has to itself"
    assert_not_contains "$readme" "Output/Shared_1/Frequencies" \
        "and not one the runs diverged before reaching"
}

test_dryclean_removes_the_preview() {
    dryrun_wrapper_ready || return
    local sb="$DRYRUN_WRAPPER_SB"
    mkdir -p "$sb/main/dryrun/somewhere/Output/Shared_1"
    : > "$sb/main/dryrun/README.txt"
    printf 'a\nb\n' > "$sb/main/dryrun/somewhere/Output/Shared_1/members.txt"

    run_project_wrapper "$sb" dryclean
    assert_status 0 "$WRAPPER_STATUS" "removing a preview should succeed: $WRAPPER_OUTPUT"
    assert_no_file "$sb/main/dryrun" "and the preview should be gone"

    # Nothing to remove is not a failure - it is the ordinary state of a project.
    run_project_wrapper "$sb" dryclean
    assert_status 0 "$WRAPPER_STATUS" "a second dryclean should be a no-op"
    assert_contains "$WRAPPER_OUTPUT" "nothing to remove" "and should say so"
}

# The preview is the one directory of the four that sits in the project rather than in a storage
# root, which is where someone is most likely to have put something of their own. Both commands
# `rm -rf` it, so both ask first.
test_a_preview_directory_holding_anything_else_is_refused() {
    dryrun_wrapper_ready || return
    local sb="$DRYRUN_WRAPPER_SB"
    mkdir -p "$sb/main/dryrun/notes"
    echo "results I meant to keep" > "$sb/main/dryrun/notes/keep.txt"

    run_project_wrapper "$sb" dryclean
    assert_status 1 "$WRAPPER_STATUS" "dryclean should refuse a directory it did not make"
    assert_contains "$WRAPPER_OUTPUT" "is not a dry run preview" "saying so"
    assert_contains "$WRAPPER_OUTPUT" "keep.txt" "and naming what it found"

    run_project_wrapper "$sb" dryrun
    assert_status 1 "$WRAPPER_STATUS" "and dryrun should refuse to replace it"
    assert_file "$sb/main/dryrun/notes/keep.txt" "leaving it exactly where it was"
}

# The entry point and the flag do different halves of the job, so the entry point alone is not a
# dry run: every check would run in its recording mode and stamp a baseline for results that are
# never going to exist.
test_the_entry_point_refuses_to_run_without_the_flag() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status
    sb=$(make_pipeline_sandbox "dryrun-noflag")
    write_sandbox_config "$sb"
    status=$(_run_entry "$sb" dryrun.nf)
    assert_status 1 "$status" "dryrun.nf without --dryRun should not run"
    assert_contains "$(cat "$sb/run.out")" "was run without --dryRun" "and should say why"
    assert_no_file "$sb/store/Output/.poolseqflow_version" "having recorded nothing"
}
