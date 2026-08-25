#!/bin/bash
# End-to-end runs against the committed fixture. The slow suite; --fast skips it.
#
# One full run is shared by the cases that only inspect its results, because a run costs
# about a minute and there is no reason to pay for it more than once. Cases that need a
# different configuration build their own sandbox.

PIPELINE_SB=""
PIPELINE_STATUS=""

# Run the fixture once, on demand, and reuse it. Returns 1 if the run could not happen.
shared_run() {
    if [ -n "$PIPELINE_STATUS" ]; then
        [ "$PIPELINE_STATUS" = "0" ]
        return
    fi
    have_tools || return 1
    PIPELINE_SB=$(make_pipeline_sandbox "e2e")
    write_sandbox_config "$PIPELINE_SB"
    PIPELINE_STATUS=$(run_pipeline "$PIPELINE_SB")
    [ "$PIPELINE_STATUS" = "0" ]
}

needs_run() {
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi
    if ! shared_run; then
        fail_case "the pipeline run failed (status $PIPELINE_STATUS); see $PIPELINE_SB/run.out"
        return 1
    fi
    return 0
}

test_full_run_completes() {
    needs_run || return
    local out; out=$(cat "$PIPELINE_SB/run.out")
    assert_contains "$out" "failed=0" "no task should fail"
    assert_contains "$out" "SUCCESS" "the run should report success"
}

test_every_step_produces_its_outputs() {
    needs_run || return
    local o="$PIPELINE_SB/store/Output"
    assert_file "$o/Reports/0_verify_environment.txt" "step 0 should publish its report"
    assert_file "$o/VCF/Test.vcf"                     "step 6 should produce the raw VCF"
    assert_file "$o/Frequencies/Test_snp_freq.tsv"    "step 7 should produce the SNP table"
    assert_file "$o/Frequencies/Test_indel_freq.tsv"  "step 7 should produce the INDEL table"
    assert_file "$o/VCF/Test_annotated.vcf"           "step 8 should produce the annotated VCF"
    [ -d "$o/Ready" ] || fail_case "step 4 should leave ready BAMs"
    [ -d "$o/Reports/Coverage" ] || fail_case "step 5 should leave coverage reports"
}

# One column per sample, in the order RGTags.csv lists them. `.collect()` alone emits in
# task-completion order, which would vary between runs.
test_frequency_table_columns_follow_the_rgtags_order() {
    needs_run || return
    local header expected
    header=$(head -1 "$PIPELINE_SB/store/Output/Frequencies/Test_snp_freq.tsv" | cut -f6-)
    expected=$(tail -n +2 "$PIPELINE_SB/main/RGTags.csv" | cut -d, -f1 | tr '\n' '\t' | sed 's/\t$//')
    assert_eq "$expected" "$header" "sample columns should match RGTags row order"
}

# Every frequency must be a proportion. A value outside [0,1] means the allele counts and
# the depth disagree somewhere upstream.
test_all_frequencies_are_proportions() {
    needs_run || return
    local bad
    bad=$(awk -F'\t' 'NR>1 { for (i=5;i<=NF;i++) if ($i+0 < 0 || $i+0 > 1) c++ } END { print c+0 }' \
          "$PIPELINE_SB/store/Output/Frequencies/Test_snp_freq.tsv")
    assert_count 0 "$bad" "frequencies outside [0,1]"
}

# The fixture plants indels deliberately. They vanished entirely once before, when every
# fragment had the same length and bwa's proper-pair window was consequently degenerate -
# so an empty indel table is a real regression signal, not an empty edge case.
test_indels_survive_to_the_frequency_table() {
    needs_run || return
    local rows
    rows=$(( $(wc -l < "$PIPELINE_SB/store/Output/Frequencies/Test_indel_freq.tsv") - 1 ))
    [ "$rows" -gt 0 ] || fail_case "the INDEL frequency table is empty; planted indels are being lost"
}

# A site planted at 0.0 in a sample has no read carrying that allele, and nothing downstream
# can invent one, so the reported frequency must be exactly zero. This is the one thing the
# planted data genuinely predicts: an intermediate frequency depends on trimming, clipping
# and the proper-pair filter, so it is deliberately not asserted anywhere.
#
# Rows are matched on the allele BASE, not on "the row where REF differs from ALLELE".
# MajorAlleleToRef.py re-polarises every site to the cohort major allele, so a planted ALT
# routinely becomes the REF and the latter test would compare against the wrong row.
test_sites_planted_absent_stay_absent() {
    needs_run || return
    local report checked bad
    # Checked across every sample, not just the first. Sites that are absent in sample 1 but
    # present elsewhere are not among the planted patterns, whereas zeros in samples 2..N are
    # common - so looking only at column 6 found nothing to test.
    #
    # Both files carry the samples in the same column order (5 fixed columns, then one per
    # sample); the rgtags-order case above is what holds the frequency table to it.
    report=$(awk -F'\t' '
        FNR == NR {
            if (FNR > 1 && $3 == "snp") {
                alt[$1] = $5
                for (i = 6; i <= NF; i++) if ($i + 0 == 0) zero[$1 SUBSEP i] = 1
            }
            next
        }
        FNR > 1 && ($2 in alt) && $4 == alt[$2] {
            for (i = 6; i <= NF; i++) {
                if (($2 SUBSEP i) in zero) {
                    checked++
                    if ($i + 0 != 0)
                        printf "pos %s allele %s sample %d planted 0.0 but reported %s\n", \
                               $2, $4, i - 5, $i
                }
            }
        }
        END { printf "CHECKED %d\n", checked + 0 }
    ' "$PIPELINE_SB/main/planted.tsv" "$PIPELINE_SB/store/Output/Frequencies/Test_snp_freq.tsv")

    checked=$(printf '%s' "$report" | sed -n 's/^CHECKED //p')
    bad=$(printf '%s' "$report" | grep -c "planted 0.0 but reported")
    while read -r line; do
        [ -n "$line" ] && fail_case "$line"
    done < <(printf '%s' "$report" | grep "planted 0.0 but reported")
    [ "${checked:-0}" -gt 0 ] || skip_case "no zero-frequency SNP reached the table"
}

# Rerunning a finished project must be a no-op. The step 7 guards once resolved to filenames
# nothing ever wrote, so a rerun re-ran both vcftools passes and left the split VCFs behind
# in Output/VCF after CalculateFrequencies had already consumed them.
test_rerunning_a_finished_project_changes_nothing() {
    needs_run || return
    local before after status
    before=$(cd "$PIPELINE_SB/store/Output/VCF" && ls | sort)
    local sums_before sums_after
    sums_before=$(md5sum "$PIPELINE_SB"/store/Output/Frequencies/*.tsv | awk '{print $1}')
    status=$(run_pipeline "$PIPELINE_SB")
    assert_status 0 "$status" "the rerun should succeed"
    after=$(cd "$PIPELINE_SB/store/Output/VCF" && ls | sort)
    sums_after=$(md5sum "$PIPELINE_SB"/store/Output/Frequencies/*.tsv | awk '{print $1}')
    assert_eq "$before" "$after" "Output/VCF should be unchanged by a rerun"
    assert_eq "$sums_before" "$sums_after" "frequency tables should be unchanged by a rerun"
    local split_log
    split_log=$(cat "$PIPELINE_SB"/store/Logs/7_vcf2freq/s4_SplitSNPsAndINDELs/*.log 2>/dev/null)
    local reruns
    reruns=$(printf '%s' "$split_log" | grep -c "Processing SNPs")
    assert_count 1 "$reruns" "SplitSNPsAndINDELs should do its work once, not again on the rerun"
}

# Per-sample steps must run once per sample, and cohort steps exactly once.
#
# A status check cannot see this. Every singleton artifact here - the verify token, the
# reference, both indexes, the snpEff marker - rides a value channel, which is what lets one
# index broadcast against N samples. An operator inserted into such a path turns it into a
# queue channel, and the run then still reports SUCCESS while aligning one sample instead of
# six. The counts come from the Nextflow trace, so this holds for any rewiring.
test_each_step_runs_once_per_sample() {
    needs_run || return
    local samples
    samples=$(find "$PIPELINE_SB/main/Data" -name '*_R1.fq.gz' | wc -l)
    [ "$samples" -gt 1 ] || { skip_case "fixture has $samples samples; nothing to fan out"; return; }

    local p
    for p in TrimQcClip:TrimReads TrimQcClip:ClipReads AlignReads:Align \
             SortCleanBams:SortCleanBam GenerateReports:AlignmentReport \
             GenerateReports:CoverageReport; do
        assert_count "$samples" "$(task_count "$PIPELINE_SB" "$p")" "$p should run once per sample"
    done

    # The promotion attachment points, which hang off those same per-sample channels as
    # additional consumers. Asserted for their own sake and as a canary: they are the newest
    # things attached to this graph, so if an inserted operator ever turns one of these paths
    # from a value channel into a queue channel, the count that moves is likely to be one of
    # theirs - and a wrong count here is visible where a wrong result would not be.
    for p in CompleteAfterAlign:RecordCompletion CompleteAfterClean:RecordCompletion; do
        assert_count "$samples" "$(task_count "$PIPELINE_SB" "$p")" "$p should run once per sample"
    done

    # The cohort side of the boundary. VariantCall gathers every BAM through toSortedList,
    # so more than one task here would mean samples were called separately.
    for p in BuildDictionaries:UngzipReference BuildDictionaries:CreateBwaIndex \
             BuildDictionaries:CreateSamtoolsFaiIndex VariantCalling:VariantCall \
             VCF2Frequencies:SplitSNPsAndINDELs; do
        assert_count 1 "$(task_count "$PIPELINE_SB" "$p")" "$p should run exactly once"
    done

    # SNPs and INDELs, from one .mix().
    assert_count 2 "$(task_count "$PIPELINE_SB" VCF2Frequencies:CalculateFrequencies)" \
        "CalculateFrequencies should run twice"
}

# One snpEff folder serves every reference a project has built, so the build marker has to
# name the genome it belongs to. It used to be a single .build_complete at the top of that
# folder, which answered "has anything been built here?" - so a second reference found it,
# skipped its own build, and inherited the first genome's database. That did not surface
# until step 8, as snpEff falling through to -download and dying with "Genome download
# failed!" after alignment and calling had already run.
#
# Uses the step-1-only entry script: this is entirely a reference-handling question, and a
# full run per genome would cost a minute each for nothing.
# What the reference tier is for: everything derived from your genome is built once, on the
# working volume, and stays there. It is never promoted to permanent storage and never
# rebuilt while it is still valid, so a second run against a genome already built here starts
# at step 2.
#
# Two runs rather than one, because "it was built in the right place" and "it was not built
# again" are different claims and only the second one is about reuse. Modification times are
# the evidence: a rebuild that happened to produce identical bytes would still be a rebuild,
# and comparing content would call it a pass.
#
# This is also the one step where the two-root problem does not arise. Its artifacts never
# move, so its skip checks have exactly one place to look - unlike every promoted artifact
# from E1o onwards, which can legitimately be in either root.
test_dictionaries_are_built_on_maindir_and_reused() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status dict before after
    sb=$(make_pipeline_sandbox "dict-reuse")
    : > "$sb/store/.step0_token"
    write_sandbox_config "$sb"
    dict="$sb/main/Reference/Dictionaries"

    status=$(run_dictionaries_only "$sb")
    assert_status 0 "$status" "the first build should succeed; see $sb/run.out"

    # Yours at the top of Reference/, the pipeline's one level down. That split is what makes
    # it plain which files reset may clear and which it must never touch.
    assert_file "$sb/main/Reference/reference.fasta.gz" "your reference should stay where you put it"
    assert_file "$dict/reference.fasta"                 "the decompressed FASTA belongs under Dictionaries"
    assert_file "$dict/reference.fasta.fai"             "and so does the fai"
    assert_file "$dict/reference.fasta.bwt"             "and the bwa index"
    assert_count 0 "$(find "$sb/store" -maxdepth 1 -name 'Reference' | wc -l)" \
        "nothing derived from the reference should reach permanent storage"

    before=$(find "$dict" -type f -printf '%p %T@\n' | sort)
    status=$(run_dictionaries_only "$sb")
    assert_status 0 "$status" "the second run should succeed"
    after=$(find "$dict" -type f -printf '%p %T@\n' | sort)

    assert_eq "$before" "$after" "a second run must not rebuild anything under Dictionaries"

    # From the per-process log, not run.out: a process's own echo output goes to its task's
    # .command.log and from there to Logs/, while run.out holds only what Nextflow itself
    # prints. The log accumulates across runs, so a plain search is enough - this message
    # exists only on a run that found an index already built.
    assert_contains "$(cat "$sb/store/Logs/1_build_dictionaries/s2_1_CreateBwaIndex/"*.log)" \
        "Found a complete existing index" \
        "the second run should say it reused the index rather than rebuilding it"
}

test_a_second_reference_builds_its_own_snpeff_database() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status db
    sb=$(make_pipeline_sandbox "twogenome")
    # Same sequence and annotation under a second name - what differs is the database name
    # snpEff derives from gffFile, which is exactly what the marker has to distinguish.
    cp "$sb/main/Reference/reference.fasta.gz" "$sb/main/Reference/genomeB.fasta.gz"
    cp "$sb/main/Reference/reference.gff.gz"   "$sb/main/Reference/genomeB.gff.gz"
    : > "$sb/store/.step0_token"
    write_sandbox_config "$sb"

    status=$(run_dictionaries_only "$sb")
    assert_status 0 "$status" "the first genome's dictionaries should build"

    write_sandbox_config "$sb" \
        "s|^    referenceFile .*|    referenceFile   = 'genomeB.fasta.gz'|" \
        "s|^    gffFile .*|    gffFile         = 'genomeB.gff.gz'|"
    status=$(run_dictionaries_only "$sb")
    assert_status 0 "$status" "the second genome's dictionaries should build"

    # Derived artifacts live beside the reference they came from, under Dictionaries/ - which
    # is what keeps them clearly the pipeline's to delete and rebuild, and the user's two
    # files clearly theirs.
    db="$sb/main/Reference/Dictionaries/snpEff/data"
    assert_file "$db/reference.gff/.build_complete"  "the first genome should keep its marker"
    assert_file "$db/genomeB.gff/.build_complete"    "the second genome should get its own marker"
    assert_file "$db/genomeB.gff/snpEffectPredictor.bin" \
        "the second genome should have a real database, not the first genome's"

    # snpEff reads every entry in the config, so it has to name both genomes. A plain
    # overwrite left only the most recent one, which made the earlier genome unannotatable
    # while its database sat on disk intact.
    local cfg; cfg=$(cat "$sb/main/Reference/Dictionaries/snpEff/snpEff.config")
    assert_contains "$cfg" "reference.gff.genome" "the config should still name the first genome"
    assert_contains "$cfg" "genomeB.gff.genome"   "the config should also name the second genome"

    # Both references' indexes coexist too - already true, and worth holding to.
    assert_file "$sb/main/Reference/Dictionaries/reference.fasta.fai" "the first genome's fai should survive"
    assert_file "$sb/main/Reference/Dictionaries/genomeB.fasta.fai"   "the second genome should get its own fai"
}

# cutadapt applies -m after -l, so a minimum length above the computed read length limit
# discards every pair while still exiting 0. Without the guard that leaves empty clipped
# FASTQs which the existence checks would treat as a finished step for good.
test_min_length_above_the_computed_limit_fails_loudly() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status out
    sb=$(make_pipeline_sandbox "minlen")
    # Two samples are enough, and the run stops at step 2 anyway.
    rm -f "$sb"/main/Data/TestSample[3-9]_R*.fq.gz
    grep -v -E '^TestSample[3-9],' "$sb/main/RGTags.csv" > "$sb/main/rg" && mv "$sb/main/rg" "$sb/main/RGTags.csv"
    write_sandbox_config "$sb" 's|^        options        = ""|        options        = "-m 200"|'
    status=$(run_pipeline "$sb")
    out=$(cat "$sb/run.out")
    assert_status 1 "$status" "the run should fail rather than clip everything away"
    assert_contains "$out" "would discard every read" "should say what is wrong"
    assert_contains "$out" "minimum length of 200" "should quote the configured minimum"
    assert_count 0 "$(find "$sb/store/Output" -name '*_clipped.fq.gz' 2>/dev/null | wc -l)" \
        "no clipped output should be published"
}

test_a_legitimate_min_length_still_runs() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status
    sb=$(make_pipeline_sandbox "minlen-ok")
    rm -f "$sb"/main/Data/TestSample[3-9]_R*.fq.gz
    grep -v -E '^TestSample[3-9],' "$sb/main/RGTags.csv" > "$sb/main/rg" && mv "$sb/main/rg" "$sb/main/RGTags.csv"
    write_sandbox_config "$sb" 's|^        options        = ""|        options        = "-m 50"|'
    status=$(run_pipeline "$sb")
    assert_status 0 "$status" "a minimum below the computed limit should run normally"
    assert_count 4 "$(find "$sb/store/Output" -name '*_clipped.fq.gz' 2>/dev/null | wc -l)" \
        "both samples should produce clipped reads"
}
