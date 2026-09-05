#!/bin/bash
# What a module writes: where it lands, what it carries, and completion.
# cost: jvm
# covers: analysis/lib/nf/results.nf analysis/lib/nf/outputs.nf analysis/complete.nf
# covers: bin/write_citations.py
# covers: analysis.nf
# covers: analysis/lib/nf/report.nf analysis/lib/rmd/
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

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

# ONE PDF OF THE WHOLE FOLDER, built by the frame from the same declarations the README uses,
# so a module gets one without writing a line for it.
#
# What it must carry is the FILE NAME above each result: a figure that arrives with nothing
# saying which file it came from is the failure this exists to prevent, and it happens on its
# own - a figure sized for looking at pushes the heading onto the page before it.
test_a_published_folder_carries_one_pdf_of_everything_in_it() {
    analysis_ready single || return
    if ! have_report_tools; then skip_case "no pandoc and typst"; return; fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/report.pdf" "the report is published beside the analysis"

    # Read back as text, because a PDF that exists and says nothing is the interesting failure.
    local text; text=$(pdf_text "$folder/report.pdf")
    assert_contains "$text" "result.tsv" "the module's own output is a section of it"
    assert_contains "$text" "writer" "and it names the module that produced the folder"

    # The README accounts for it too, or a reader has a file nothing explains.
    assert_contains "$(cat "$folder/README.md" 2>/dev/null)" '`report.pdf`' \
        "the README lists the report among what the folder holds"
}

# A REPORT THAT CANNOT BE BUILT MUST NOT THROW AWAY THE ANALYSIS. Every number in it is already
# a file in the folder, so the report is a convenience; refusing to publish over it would lose
# work that is complete and correct. It must still say why, which is the half that would
# otherwise rot into silence.
test_a_report_that_cannot_be_built_still_publishes_the_analysis() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"

    # A pandoc that fails, ahead of the real one, which is what a machine without a working
    # PDF toolchain looks like from inside the task. The pipeline environment carries no pandoc
    # of its own, so this stub is the one the run finds.
    local stub; stub=$(guard_path "$TEST_TMPDIR/no-pandoc")
    rm -rf "$stub"; mkdir -p "$stub"
    printf '#!/bin/sh\necho "no pandoc here" >&2\nexit 1\n' > "$stub/pandoc"
    chmod +x "$stub/pandoc"

    local saved="$PATH" status
    export PATH="$stub:$PATH"
    status=$(analysis_run_module writer)
    export PATH="$saved"
    assert_status 0 "$status" "the analysis should publish without its report"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/result.tsv" "the analysis itself is there"
    assert_no_file "$folder/report.pdf" "and the report is not"
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
