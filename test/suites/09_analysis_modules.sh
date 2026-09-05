#!/bin/bash
# The module store, and what a module gets from the frame.
# cost: jvm
# covers: analysis/modules.nf analysis/lib/nf/modules.nf analysis/lib/nf/store.nf
# covers: analysis/lib/nf/paths.nf
# covers: analysis.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# ---------------------------------------------------------------------------------------
# The module roster.
test_an_unknown_module_refuses_before_any_task() {
    analysis_ready single || return
    local status; status=$(run_analysis "$ANALYSIS_SB" mds)
    assert_status 1 "$status" "a module that does not exist must stop the run"
    assert_contains "$(analysis_output)" "'mds' is not installed" \
        "should name what was asked for"
    # Both kinds of module, sorted: one the release ships into the store, and the frame's own
    # built-in, which is in no directory at all.
    assert_contains "$(analysis_output)" "Available here: basicstats, verify" \
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
