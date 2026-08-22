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
    local o="$PIPELINE_SB/proj/Output"
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
    header=$(head -1 "$PIPELINE_SB/proj/Output/Frequencies/Test_snp_freq.tsv" | cut -f6-)
    expected=$(tail -n +2 "$PIPELINE_SB/proj/RGTags.csv" | cut -d, -f1 | tr '\n' '\t' | sed 's/\t$//')
    assert_eq "$expected" "$header" "sample columns should match RGTags row order"
}

# Every frequency must be a proportion. A value outside [0,1] means the allele counts and
# the depth disagree somewhere upstream.
test_all_frequencies_are_proportions() {
    needs_run || return
    local bad
    bad=$(awk -F'\t' 'NR>1 { for (i=5;i<=NF;i++) if ($i+0 < 0 || $i+0 > 1) c++ } END { print c+0 }' \
          "$PIPELINE_SB/proj/Output/Frequencies/Test_snp_freq.tsv")
    assert_count 0 "$bad" "frequencies outside [0,1]"
}

# The fixture plants indels deliberately. They vanished entirely once before, when every
# fragment had the same length and bwa's proper-pair window was consequently degenerate -
# so an empty indel table is a real regression signal, not an empty edge case.
test_indels_survive_to_the_frequency_table() {
    needs_run || return
    local rows
    rows=$(( $(wc -l < "$PIPELINE_SB/proj/Output/Frequencies/Test_indel_freq.tsv") - 1 ))
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
    ' "$PIPELINE_SB/proj/planted.tsv" "$PIPELINE_SB/proj/Output/Frequencies/Test_snp_freq.tsv")

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
    before=$(cd "$PIPELINE_SB/proj/Output/VCF" && ls | sort)
    local sums_before sums_after
    sums_before=$(md5sum "$PIPELINE_SB"/proj/Output/Frequencies/*.tsv | awk '{print $1}')
    status=$(run_pipeline "$PIPELINE_SB")
    assert_status 0 "$status" "the rerun should succeed"
    after=$(cd "$PIPELINE_SB/proj/Output/VCF" && ls | sort)
    sums_after=$(md5sum "$PIPELINE_SB"/proj/Output/Frequencies/*.tsv | awk '{print $1}')
    assert_eq "$before" "$after" "Output/VCF should be unchanged by a rerun"
    assert_eq "$sums_before" "$sums_after" "frequency tables should be unchanged by a rerun"
    local split_log
    split_log=$(cat "$PIPELINE_SB"/proj/Logs/7_vcf2freq/s4_SplitSNPsAndINDELs/*.log 2>/dev/null)
    local reruns
    reruns=$(printf '%s' "$split_log" | grep -c "Processing SNPs")
    assert_count 1 "$reruns" "SplitSNPsAndINDELs should do its work once, not again on the rerun"
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
    rm -f "$sb"/proj/Data/TestSample[3-9]_R*.fq.gz
    grep -v -E '^TestSample[3-9],' "$sb/proj/RGTags.csv" > "$sb/proj/rg" && mv "$sb/proj/rg" "$sb/proj/RGTags.csv"
    write_sandbox_config "$sb" 's|^        options        = ""|        options        = "-m 200"|'
    status=$(run_pipeline "$sb")
    out=$(cat "$sb/run.out")
    assert_status 1 "$status" "the run should fail rather than clip everything away"
    assert_contains "$out" "would discard every read" "should say what is wrong"
    assert_contains "$out" "minimum length of 200" "should quote the configured minimum"
    assert_count 0 "$(find "$sb/proj/Output" -name '*_clipped.fq.gz' 2>/dev/null | wc -l)" \
        "no clipped output should be published"
}

test_a_legitimate_min_length_still_runs() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status
    sb=$(make_pipeline_sandbox "minlen-ok")
    rm -f "$sb"/proj/Data/TestSample[3-9]_R*.fq.gz
    grep -v -E '^TestSample[3-9],' "$sb/proj/RGTags.csv" > "$sb/proj/rg" && mv "$sb/proj/rg" "$sb/proj/RGTags.csv"
    write_sandbox_config "$sb" 's|^        options        = ""|        options        = "-m 50"|'
    status=$(run_pipeline "$sb")
    assert_status 0 "$status" "a minimum below the computed limit should run normally"
    assert_count 4 "$(find "$sb/proj/Output" -name '*_clipped.fq.gz' 2>/dev/null | wc -l)" \
        "both samples should produce clipped reads"
}
