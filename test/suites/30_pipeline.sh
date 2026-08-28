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
    for p in CompleteAfterClip:PromoteArtifacts CompleteAfterAlign:PromoteArtifacts \
             CompleteAfterClean:PromoteArtifacts CompleteAfterUse:PromoteArtifacts; do
        assert_count "$samples" "$(task_count "$PIPELINE_SB" "$p")" "$p should run once per sample"
    done

    # The cohort side of the boundary. VariantCall gathers every BAM through toSortedList,
    # so more than one task here would mean samples were called separately.
    for p in BuildDictionaries:UngzipReference BuildDictionaries:CreateBwaIndex \
             BuildDictionaries:CreateSamtoolsFaiIndex VariantCalling:VariantCall \
             VCF2Frequencies:SplitSNPsAndINDELs CompleteAfterVcf:PromoteArtifacts; do
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

# The first stage where an artifact actually moves. Step 2's clipped reads are step 3's only
# input and nothing after step 3 reads them, so a sample's alignment succeeding is what
# releases that sample's reads to permanent storage.
#
# Both halves are asserted, because only the pair is the property that matters. Present in
# Output/ says the move happened; ABSENT from Utilized/ says it was a move and not a copy -
# and that second half is the one with teeth. find_artifact.sh reports the first root that
# has an artifact and searches the working volume second, so a copy left behind is invisible
# until the promoted one is replaced or reset, at which point it wins every skip check.
test_trimmed_reads_are_promoted_after_alignment() {
    needs_run || return
    local s stored left
    for s in $(cut -d, -f1 "$PIPELINE_SB/main/RGTags.csv" | tail -n +2); do
        stored="$PIPELINE_SB/store/Output/Trimmed/$s"
        assert_file "$stored/${s}_R1_clipped.fq.gz" "$s R1 should reach permanent storage"
        assert_file "$stored/${s}_R2_clipped.fq.gz" "$s R2 should reach permanent storage"
    done
    left=$(find "$PIPELINE_SB/main/Utilized" -name '*_clipped.fq.gz' 2>/dev/null | wc -l)
    assert_count 0 "$left" "clipped reads left on the working volume after promotion"

    # The *_val_* reads are the other half of what step 2 writes. They are never promoted -
    # ClipReads deletes them - so finding one here would mean that deletion stopped working
    # and the working volume is now growing by the size of the raw data every run.
    left=$(find "$PIPELINE_SB/main/Utilized" -name '*_val_[12].fq.gz' 2>/dev/null | wc -l)
    assert_count 0 "$left" "intermediate trimmed reads left behind"
}

# The skip check has to consult BOTH roots, because a promoted artifact and an unpromoted
# one are equally valid answers to "has this already been done". Asking one directory would
# re-trim every sample whose reads an earlier run had already moved to storage - silently,
# and at full cost.
#
# One run covers both roots by splitting the samples between them: half seeded where
# promotion would have left them, half where the writing step would have. A second run would
# have cost another minute and told us less, since it could only ever exercise one root at a
# time.
#
# Step 2 alone, and the seeded files are the fixture's own reads under a clipped name: the
# skip branches only test for existence and symlink what they find, so nothing reads them.
test_step_2_finds_its_clipped_reads_in_either_root() {
    if ! have_tools; then skip_case "no conda environment"; return; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return; fi
    local sb status s dest n log
    sb=$(make_pipeline_sandbox "either-root")
    : > "$sb/store/.step0_token"
    write_sandbox_config "$sb"

    for n in 1 2 3 4 5 6; do
        s="TestSample$n"
        if [ "$n" -le 3 ]; then
            dest="$sb/store/Output/Trimmed/$s"      # promoted by an earlier run
        else
            dest="$sb/main/Utilized/Trimmed/$s"     # written but not yet promoted
        fi
        mkdir -p "$dest"
        cp "$sb/main/Data/${s}_R1.fq.gz" "$dest/${s}_R1_clipped.fq.gz"
        cp "$sb/main/Data/${s}_R2.fq.gz" "$dest/${s}_R2_clipped.fq.gz"
    done

    status=$(run_trim_only "$sb")
    assert_status 0 "$status" "step 2 should complete; see $sb/run.out"

    # Process output goes to the per-process log, never to Nextflow's stdout.
    for n in 1 2 3 4 5 6; do
        s="TestSample$n"
        log="$sb/store/Logs/2_trim_reads/s1_TrimReads/$s/2_TrimQcClip_s1_TrimReads_${s}_nextflow.log"
        if [ -f "$log" ]; then
            assert_contains "$(cat "$log")" "Found existing clipped files" \
                "$s should have been skipped, not re-trimmed"
        else
            fail_case "no TrimReads log for $s at $log"
        fi
    done

    # What trimming actually produces, none of which may appear if every sample was skipped.
    assert_no_file "$sb/store/Output/Reports/Trimming" "no trim report should be written"
    assert_no_file "$sb/store/Output/Unpaired"         "no unpaired reads should be written"
    assert_count 0 "$(find "$sb/main/Utilized" -name '*_val_[12].fq.gz' 2>/dev/null | wc -l)" \
        "no reads should have been trimmed"

    # And nothing was moved between the roots: promotion is step 3's business, and step 3
    # did not run here.
    assert_file "$sb/store/Output/Trimmed/TestSample1/TestSample1_R1_clipped.fq.gz" \
        "a promoted sample should stay promoted"
    assert_file "$sb/main/Utilized/Trimmed/TestSample6/TestSample6_R1_clipped.fq.gz" \
        "an unpromoted sample should stay where it was"
}

# The aligned BAMs, released when cleaning has succeeded for that sample. Same pair of claims
# as the trimmed reads: present in permanent storage, and gone from the working volume.
#
# This directory is flat rather than per-sample, so all six promotions move files out of one
# shared folder concurrently. That is the case where a promotion aimed at the wrong sample
# would be invisible - it would still leave the folder looking right.
test_aligned_bams_are_promoted_after_cleaning() {
    needs_run || return
    local s left
    for s in $(cut -d, -f1 "$PIPELINE_SB/main/RGTags.csv" | tail -n +2); do
        assert_file "$PIPELINE_SB/store/Output/Aligned/${s}_aligned.bam" \
            "$s should reach permanent storage"
    done
    left=$(find "$PIPELINE_SB/main/Utilized" -name '*_aligned.bam' 2>/dev/null | wc -l)
    assert_count 0 "$left" "aligned BAMs left on the working volume after promotion"
}

# The FastQC zips are the small case: ~250KB against gigabyte read files, and kept on the
# working volume anyway because ClipReads reads them. Rule 2 has no size exception, so this
# case exists to keep it that way.
#
# The htmls FastQC writes beside them are the control. Nothing reads those, so they go
# straight to permanent storage and must never appear under Utilized at all - the two halves
# of one FastQC run taking different routes to the same directory.
test_fastqc_zips_are_promoted_but_htmls_go_straight_to_storage() {
    needs_run || return
    local s d left
    for s in $(cut -d, -f1 "$PIPELINE_SB/main/RGTags.csv" | tail -n +2); do
        d="$PIPELINE_SB/store/Output/Reports/Fastqc/$s"
        assert_file "$d/${s}_val_1_fastqc.zip"  "$s R1 zip should reach permanent storage"
        assert_file "$d/${s}_val_2_fastqc.zip"  "$s R2 zip should reach permanent storage"
        assert_file "$d/${s}_val_1_fastqc.html" "$s R1 html should be written straight to storage"
    done
    left=$(find "$PIPELINE_SB/main/Utilized" -name '*_fastqc.zip' 2>/dev/null | wc -l)
    assert_count 0 "$left" "FastQC zips left on the working volume after promotion"
    left=$(find "$PIPELINE_SB/main/Utilized" -name '*_fastqc.html' 2>/dev/null | wc -l)
    assert_count 0 "$left" "FastQC htmls should never enter the working volume"
}

# A BAM whose index is missing is not a finished step.
#
# The skip test used to check the BAM alone while the skip branch symlinked both it and the
# index, and `ln -s` does not check that its target exists. So a missing index produced a
# dangling link that still satisfied the `*_ready.bam.bai` output glob, and the run carried
# on as though the index were there. Reachable whenever indexing was interrupted, and from
# E1q reachable a second way, when the pair is promoted between the volumes.
#
# Runs against a copy of the finished project, so the cost is a run of skips rather than a
# fresh analysis. Copying is safe for the same reason 40_guards relies on it: the stored
# manifest excludes mainDir, storageDir and every dir.* entry, so it still matches after the
# move. This also exercises the other half of E1p - the rebuilt sample's aligned BAM has been
# promoted, so Align has to find it in permanent storage rather than where it wrote it.
test_a_missing_index_is_not_treated_as_a_finished_bam() {
    needs_run || return
    local sb sample status log
    sb=$(guard_path "$TEST_TMPDIR/missing-bai")
    rm -rf "$sb"
    cp -r "$PIPELINE_SB" "$sb"
    rm -f "$sb/run.out"
    write_sandbox_config "$sb"

    sample=$(cut -d, -f1 "$sb/main/RGTags.csv" | tail -n +2 | head -1)
    rm -f "$sb/store/Output/Ready/${sample}_ready.bam.bai"
    assert_file "$sb/store/Output/Ready/${sample}_ready.bam" "the BAM itself should still be there"

    status=$(run_pipeline "$sb")
    assert_status 0 "$status" "the run should recover; see $sb/run.out"

    assert_file "$sb/store/Output/Ready/${sample}_ready.bam.bai" "the index should be rebuilt"

    log="$sb/store/Logs/4_clean/$sample/4_SortCleanBam_${sample}_nextflow.log"
    if [ -f "$log" ]; then
        assert_contains "$(cat "$log")" "Processing BAM file" \
            "$sample should have been reprocessed, not skipped"
    else
        fail_case "no SortCleanBam log for $sample at $log"
    fi

    # Every other sample was complete, so nothing else may have been redone.
    local others
    others=$(cut -d, -f1 "$sb/main/RGTags.csv" | tail -n +2 | grep -vx "$sample" | head -1)
    log="$sb/store/Logs/4_clean/$others/4_SortCleanBam_${others}_nextflow.log"
    assert_contains "$(tail -30 "$log")" "Found existing BAM file and index" \
        "$others was complete and should have been skipped"
}

# The first artifact with two consumers: step 5 reads the ready BAMs for its reports, step 6
# for calling. Releasing on either one alone would delete a file the other still needs, so the
# gate is both - and because calling is a cohort step, no sample's BAM can go until every
# sample has been called.
#
# The index is asserted alongside its BAM. Nothing in step 5 names the index; both processes
# just expect it beside the file, so a BAM promoted without one would look complete and fail
# only later, somewhere else.
test_ready_bams_are_promoted_after_both_consumers() {
    needs_run || return
    local s left
    for s in $(cut -d, -f1 "$PIPELINE_SB/main/RGTags.csv" | tail -n +2); do
        assert_file "$PIPELINE_SB/store/Output/Ready/${s}_ready.bam" \
            "$s BAM should reach permanent storage"
        assert_file "$PIPELINE_SB/store/Output/Ready/${s}_ready.bam.bai" \
            "$s index should travel with its BAM"
    done
    left=$(find "$PIPELINE_SB/main/Utilized" -name '*_ready.bam*' 2>/dev/null | wc -l)
    assert_count 0 "$left" "ready BAMs left on the working volume after promotion"
}

# The called VCF is the parameter-dependent gate: step 7 always reads it, step 8 only when
# annotate is on. The shared run has annotate on, so this is the both-consumers path.
#
# The rest of the case is about what must NOT be in Output/VCF. Every intermediate in step 7
# is consumed and deleted by the next process, so a finished project should hold exactly the
# called VCF and the annotated one. _sort_fp_dq.vcf used to be the exception - the only step 7
# process that reads its input twice was also the only one that never deleted it, so a
# filtered intermediate was published beside the real results on every run since 1.0.
test_only_real_vcfs_reach_storage() {
    needs_run || return
    local o="$PIPELINE_SB/store/Output/VCF" listed expected
    assert_file "$o/Test.vcf"           "the called VCF should be promoted"
    assert_file "$o/Test_annotated.vcf" "the annotated VCF is a result and stays"

    assert_no_file "$o/Test_sort.vcf"           "the sorted intermediate should not be published"
    assert_no_file "$o/Test_sort_fp.vcf"        "the FP-filtered intermediate should not be published"
    assert_no_file "$o/Test_sort_fp_dq.vcf"     "the DQ-filtered intermediate should not be published"
    assert_no_file "$o/Test_sort_fp_dq_snp.vcf" "the split SNP VCF should not be published"
    assert_no_file "$o/Test_sort_fp_dq_indel.vcf" "the split INDEL VCF should not be published"

    # Stated as a whole set as well, so a future intermediate that nobody thought to list
    # above still fails here. LC_ALL=C because the default collation orders "_" before ".",
    # which would make this assertion depend on the machine's locale rather than on the
    # pipeline.
    listed=$(cd "$o" && ls | LC_ALL=C sort | tr '\n' ' ')
    expected="Test.vcf Test_annotated.vcf "
    assert_eq "$expected" "$listed" "Output/VCF should hold only the two real VCFs"

    assert_count 0 "$(find "$PIPELINE_SB/main/Utilized" -name '*.vcf' 2>/dev/null | wc -l)" \
        "no VCF should be left on the working volume"
}

# One installation serves any number of projects, so a run that wrote inside it would corrupt
# every other project on the machine - and would do it silently, since nothing about a
# successful run would look wrong. The fingerprint is taken when the sandbox is built and
# compared after a full run, so this covers every step rather than any one of them.
test_a_run_never_writes_inside_the_installation() {
    needs_run || return
    local diff_out
    diff_out=$(diff "$PIPELINE_SB/install.before" <(install_fingerprint "$PIPELINE_SB") 2>&1)
    if [ -n "$diff_out" ]; then
        fail_case "the installation changed during a run:"
        fail_case "$diff_out"
    fi
}

# `clean` throws away scratch. `reset` throws away results. The difference is the whole reason
# there are two commands, and from 3.0 it is sharper than it used to be: Utilized/ sits beside
# work/ under mainDir and holds real outputs a run produced but has not yet moved to permanent
# storage. Deleting it as though it were scratch would silently discard finished work.
#
# Runs the real wrapper against a copy of the finished project. The conda side is stubbed, so
# nothing here can touch an operator's environments; everything else - the project's config,
# the payload, and the `nextflow config` call the wrapper uses to learn what it is about to
# delete - is real, which is the part that matters.
test_clean_removes_scratch_and_keeps_everything_else() {
    needs_run || return
    local sb
    sb=$(guard_path "$TEST_TMPDIR/clean-scope")
    rm -rf "$sb"; cp -r "$PIPELINE_SB" "$sb"; rm -f "$sb/run.out"
    write_sandbox_config "$sb"

    # A finished run leaves Utilized empty - everything has been promoted - so an interrupted
    # one is staged by hand. This file is the case.
    mkdir -p "$sb/main/Utilized/Trimmed/TestSample1"
    echo "not yet promoted" > "$sb/main/Utilized/Trimmed/TestSample1/TestSample1_R1_clipped.fq.gz"
    [ -d "$sb/main/work" ] || fail_case "the copied project should still have a work directory"

    run_project_wrapper "$sb" clean
    assert_status 0 "$WRAPPER_STATUS" "clean should succeed: $WRAPPER_OUTPUT"

    # Named, not merely deleted. `.nextflow*` used to be removed below the branch that
    # reports on workDir, so it was deleted without ever being mentioned.
    assert_contains "$WRAPPER_OUTPUT" ".nextflow" "clean should name Nextflow's own files"
    assert_contains "$WRAPPER_OUTPUT" "Not removed" "clean should say what it leaves alone"

    assert_no_file "$sb/main/work"        "the work directory should be gone"
    assert_no_file "$sb/main/.nextflow"   "Nextflow's cache directory should be gone"

    assert_file "$sb/main/Utilized/Trimmed/TestSample1/TestSample1_R1_clipped.fq.gz" \
        "clean must not touch outputs waiting to be promoted"
    assert_file "$sb/store/Output/Frequencies/Test_snp_freq.tsv" "results should survive clean"
    assert_file "$sb/main/Reference/Dictionaries/reference.fasta" "dictionaries should survive clean"
    assert_file "$sb/main/Data/TestSample1_R1.fq.gz"             "your reads should survive clean"
    assert_file "$sb/main/parameters.config"                     "your config should survive clean"
}

# reset is the destructive one, so what it does NOT delete is the assertion that matters. A
# reset that took the reads, the reference or the configuration with it would leave a project
# that cannot be re-run at all - and the reads are the one thing here that cannot be recreated.
test_reset_removes_results_but_keeps_what_you_provided() {
    needs_run || return
    local sb
    sb=$(guard_path "$TEST_TMPDIR/reset-scope")
    rm -rf "$sb"; cp -r "$PIPELINE_SB" "$sb"; rm -f "$sb/run.out"
    write_sandbox_config "$sb"
    mkdir -p "$sb/main/Utilized/VCF"
    echo "not yet promoted" > "$sb/main/Utilized/VCF/Test.vcf"

    run_project_wrapper "$sb" reset <<< "DELETE_MY_ANALYSIS"
    assert_status 0 "$WRAPPER_STATUS" "reset should succeed: $WRAPPER_OUTPUT"

    # Gone: everything the pipeline produced or derived.
    assert_no_file "$sb/store/Output"                        "results should be removed"
    assert_no_file "$sb/store/Logs"                          "logs should be removed"
    assert_no_file "$sb/store/Output/.poolseqflow_params"           "the parameter manifest should be removed"
    assert_no_file "$sb/store/Output/.poolseqflow_rgtags"           "the rgtags baseline should be removed"
    assert_no_file "$sb/main/Utilized"                       "unpromoted outputs should be removed"
    assert_no_file "$sb/main/Reference/Dictionaries"         "derived dictionaries should be removed"
    assert_no_file "$sb/main/work"                           "the work directory should be removed"

    # Kept: everything you put there yourself.
    assert_file "$sb/main/Data/TestSample1_R1.fq.gz"   "your reads must survive reset"
    assert_file "$sb/main/Reference/reference.fasta.gz" "your reference must survive reset"
    assert_file "$sb/main/Reference/reference.gff.gz"   "your annotation must survive reset"
    assert_file "$sb/main/parameters.config"            "your config must survive reset"
    assert_file "$sb/main/RGTags.csv"                   "your RGTags file must survive reset"
}

# The branch that fires when the wrapper cannot read the config at all - a real state, since a
# malformed parameters.config is exactly when someone reaches for clean. It used to report
# "leaving it in place" about workDir and then delete .nextflow* anyway, unmentioned. The
# deletion is correct; being told about it is the fix.
test_clean_still_reports_what_it_removes_when_the_config_is_unreadable() {
    needs_run || return
    local sb
    sb=$(guard_path "$TEST_TMPDIR/clean-broken")
    rm -rf "$sb"; cp -r "$PIPELINE_SB" "$sb"; rm -f "$sb/run.out"
    printf 'params {\n    mainDir = "unterminated\n' > "$sb/main/parameters.config"
    mkdir -p "$sb/main/Utilized/Trimmed"
    echo "not yet promoted" > "$sb/main/Utilized/Trimmed/keep_me"

    run_project_wrapper "$sb" clean
    assert_contains "$WRAPPER_OUTPUT" ".nextflow" \
        "clean must still name Nextflow's own files when workDir cannot be resolved"
    assert_contains "$WRAPPER_OUTPUT" "could not resolve workDir" "it should say why"
    assert_file "$sb/main/Utilized/Trimmed/keep_me" "and still leave unpromoted outputs alone"
}

# ---------------------------------------------------------------------------------------
# Multi-run: N runs from one invocation.
#
# ONE PIPELINE RUN, MANY SCENARIOS. A three-row table costs three analyses - several minutes -
# so the table is built to make every divergence shape the design has to get right visible in
# the same run rather than paying for one run per question:
#
#   inherit    every cell blank. The run that changes nothing must still work, and must get
#              the values parameters.config holds.
#   filter     a late divergence. Nothing before variant calling differs, so it also proves
#              two runs that agree for six steps still keep their results apart.
#   plain      annotate off AND poolSize changed. `annotate` is the branchiest parameter in
#              the pipeline - it decides a step-0 stage, a step-1 process, a step-8 process
#              and the shape of the VCF promotion gate - and poolSize is the re-derivation
#              case, because sensitivity is computed from it.
#
# WHY THESE VALUES. The fixture's reads are uniformly Q40, so a trimming-quality column would
# produce three identical answers and prove nothing; and after false-positive filtering the
# QUAL range is 468-1487, so minQUAL has to be inside that to bite at all. Both were measured,
# not guessed.
MULTIRUN_SB=""
MULTIRUN_STATUS=""

multirun_run() {
    if [ -n "$MULTIRUN_STATUS" ]; then
        [ "$MULTIRUN_STATUS" = "0" ]
        return
    fi
    have_tools || return 1
    MULTIRUN_SB=$(make_pipeline_sandbox "multirun")
    # multiRun is itself an analysis parameter, so flipping it legitimately trips the change
    # guard. Its own sandbox, never a copy of the shared one.
    write_sandbox_config "$MULTIRUN_SB" "s|^    multiRun .*|    multiRun        = true|"
    cat > "$MULTIRUN_SB/main/runs.csv" <<'CSV'
RunID,vcffilter.minQUAL,poolSize,annotate
inherit,,,
filter,1000,,
plain,,25,false
CSV
    MULTIRUN_STATUS=$(run_pipeline "$MULTIRUN_SB")
    [ "$MULTIRUN_STATUS" = "0" ]
}

needs_multirun() {
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi
    if ! multirun_run; then
        fail_case "the multi-run failed (status $MULTIRUN_STATUS); see $MULTIRUN_SB/run.out"
        return 1
    fi
    return 0
}

test_every_run_produces_its_own_complete_results() {
    needs_multirun || return
    local o="$MULTIRUN_SB/store/Output"

    # A RUN'S RESULTS ARE NO LONGER ALL IN ONE DIRECTORY, and that is the feature. The three
    # runs here differ only from step 7 on, so everything before it was done once and lives
    # under All_Runs; each run's own directory holds only the part nothing else shares. What
    # must still be true is that every run's complete set EXISTS somewhere reachable.
    assert_file "$o/All_Runs/VCF/Test.vcf"  "the VCF all three share should be filed under All_Runs"
    [ -d "$o/All_Runs/Ready" ] || fail_case "the ready BAMs are shared, so they belong to All_Runs"
    [ -d "$o/All_Runs/Trimmed" ] || fail_case "and so do the trimmed reads"

    local run
    for run in inherit filter plain; do
        assert_file "$o/$run/Reports/0_verify_environment.txt" "$run should publish its own step 0 report"
        assert_file "$o/$run/Frequencies/Test_snp_freq.tsv"    "$run should produce its own SNP table"
        assert_file "$o/$run/Frequencies/Test_indel_freq.tsv"  "$run should produce its own INDEL table"
        # ...and NOT a private copy of the work it shares.
        assert_no_file "$o/$run/VCF/Test.vcf" \
            "$run shares the raw VCF, so it must not have called one of its own"
    done

    # Every shared directory says who it belongs to, so the grouping can be recovered from the
    # results rather than only from the report that announced it.
    assert_contains "$(cat "$o/All_Runs/members.txt")" "inherit" "All_Runs should list its members"
    assert_file "$o/Shared_1/members.txt" "and a partial group should carry one too"
}

# The cardinality assertion, which is what a status check cannot see. A run that quietly did
# one run's work instead of three would still report SUCCESS.
#
# The two counts that are NOT N x runs are the point of the design: step 1 writes to mainDir,
# which every run shares, so it is deduplicated by its output paths; and the two step-0 stages
# that describe the machine rather than a run happen once.
test_multi_run_fans_out_per_run_and_not_per_invocation() {
    needs_multirun || return
    local samples p
    samples=$(find "$MULTIRUN_SB/main/Data" -name '*_R1.fq.gz' | wc -l)

    # SHARED WORK IS DONE ONCE. These three runs agree up to step 6, so every per-sample step
    # before the divergence runs `samples` times for the invocation - not `samples * runs`.
    # This is the whole point of the feature and the assertion that would catch losing it.
    for p in TrimQcClip:TrimReads TrimQcClip:ClipReads AlignReads:Align \
             SortCleanBams:SortCleanBam GenerateReports:AlignmentReport \
             GenerateReports:CoverageReport CompleteAfterClip:PromoteArtifacts \
             CompleteAfterAlign:PromoteArtifacts CompleteAfterClean:PromoteArtifacts \
             CompleteAfterUse:PromoteArtifacts; do
        assert_count "$samples" "$(task_count "$MULTIRUN_SB" "$p")" \
            "$p is shared up to step 6, so it should run once per sample for the invocation"
    done
    assert_count 1 "$(task_count "$MULTIRUN_SB" VariantCalling:VariantCall)" \
        "one cohort is called, not three"
    assert_count 1 "$(task_count "$MULTIRUN_SB" CompleteAfterVcf:PromoteArtifacts)" \
        "and the VCF they share is promoted once"

    # ...and the diverging tail is NOT. minQUAL and poolSize both bite at step 7, so all three
    # runs part company there and each filters for itself.
    for p in VCF2Frequencies:SortRefAltByFrequency VCF2Frequencies:FilterPotentialFalsePositives \
             VCF2Frequencies:DepthAndQualityFilter VCF2Frequencies:SplitSNPsAndINDELs; do
        assert_count 3 "$(task_count "$MULTIRUN_SB" "$p")" \
            "$p is step 7, where all three runs diverge"
    done
    assert_count $(( samples )) "$(task_count "$MULTIRUN_SB" VCF2Frequencies:CalculateFrequencies)" \
        "two tables per run, three runs"

    # STEP 0 FOLLOWS THE PIPELINE'S SHAPE, not the run list. A check runs once per distinct
    # value of what it reads, so three runs against one reference ask about that reference once
    # - and the answer is handed to all three. The three that would otherwise be identical N
    # times over are the point of the stage.
    for p in VerifyEnvironment:CheckReference VerifyEnvironment:CheckData \
             VerifyEnvironment:CheckTrimParameters VerifyEnvironment:CheckDirectories; do
        assert_count 1 "$(task_count "$MULTIRUN_SB" "$p")" \
            "$p reads the same values for all three runs, so it should run once"
    done
    # The RGTags change guard is keyed to the step-6 variant, because its answer depends on
    # which BAMs and which VCF are on disk. All three runs share step 6 and diverge at step 7.
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:CheckRGTagsFile)" \
        "all three share the called VCF, so one guard answers for them"

    # The reproducibility guard is ONE task for the whole project: it compares the two files the
    # user wrote - parameters.config and the table - not anything a run resolved for itself.
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:CheckRunParameters)" \
        "the configuration is one thing, so it is checked once"

    # VerifyAll is the one stage that really is per run: it assembles that run's own report and
    # is the gate its own work waits on.
    assert_count 3 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:VerifyAll)" \
        "VerifyAll should run once per run"
    local run
    for run in inherit filter plain; do
        assert_count 1 "$(run_task_count "$MULTIRUN_SB" VerifyEnvironment:VerifyAll "$run")" \
            "$run should have verified its own environment"
    done

    # Shared by construction since before multi-run existed, and still shared.
    for p in BuildDictionaries:UngzipReference BuildDictionaries:CreateBwaIndex \
             BuildDictionaries:CreateSamtoolsFaiIndex BuildDictionaries:BuildSnpEffDb; do
        assert_count 1 "$(task_count "$MULTIRUN_SB" "$p")" \
            "$p should be built once for the reference all three runs share"
    done

    # About the invocation, not about a run.
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:CheckInstalledSoftware)" \
        "the software check describes the machine, so it runs once"
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:CheckMultiRun)" \
        "the multi-run check describes the fan-out, so it runs once"
    # It WRITES to a file every run shares; N concurrent repairs would be a race.
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:RepairRGTagsLineEndings)" \
        "one RGTags table means one line-ending repair"
}

# WHAT THE PROJECT RECORDS ABOUT ITS OWN CONFIGURATION: the two files the user wrote, kept
# beside the results, plus the base parameters as the pipeline resolved them.
#
# Between them they pin every run's effective settings - the base from the config, each run's
# overrides from the table - which is what lets the guard be one task instead of one per run.
test_the_project_records_the_configuration_it_ran_under() {
    needs_multirun || return
    local o="$MULTIRUN_SB/store/Output"

    # The files as written, verbatim.
    assert_eq "$(cat "$MULTIRUN_SB/main/parameters.config")" "$(cat "$o/.parameters.config")" \
        "parameters.config should be kept beside the results, unaltered"
    assert_contains "$(cat "$o/.multirun.csv")" "filter,1000,," "and the table with every row it had"
    assert_contains "$(cat "$o/.multirun.csv")" "plain,,25,false" "including the last one"

    # And the base configuration as resolved, which is what the comparison is made against.
    local base="$o/.poolseqflow_params"
    assert_contains "$(cat "$base")" "vcffilter.minQUAL=30" "the base value, not a run's override"
    assert_contains "$(cat "$base")" "poolSize=100"         "likewise"
    assert_contains "$(cat "$base")" "filterFalsePositives.sensitivity=0.0025" \
        "with the values computed from it"

    # Where files live and how much of the machine to use are absent on purpose: they cannot
    # change a number, so changing them must not invalidate finished results.
    assert_not_contains "$(cat "$base")" "threads="    "resources are excluded"
    assert_not_contains "$(cat "$base")" "storageDir=" "and so are paths"
}

# The whole point: a per-run parameter has to reach the task that reads it. A manifest saying
# minQUAL=1000 while vcftools was handed 30 would look entirely correct from the outside.
test_a_diverging_parameter_changes_that_runs_numbers() {
    needs_multirun || return
    local inherit_rows filter_rows
    inherit_rows=$(awk 'END{print NR}' "$MULTIRUN_SB/store/Output/inherit/Frequencies/Test_snp_freq.tsv")
    filter_rows=$(awk 'END{print NR}' "$MULTIRUN_SB/store/Output/filter/Frequencies/Test_snp_freq.tsv")
    [ "$filter_rows" -lt "$inherit_rows" ] || fail_case \
        "minQUAL=1000 should keep fewer sites than minQUAL=30 (got $filter_rows vs $inherit_rows)"

    # And it really was the filter doing it. Asserted as "not the inherited value" rather than
    # as the literal 1000: vcftools echoes its own parsed parameter, so the log says
    # `--minQ 1e+03` even though the command line carried 1000.
    local filter_log inherit_log
    filter_log=$(cat "$MULTIRUN_SB/store/Logs/filter/7_vcf2freq/s3_DepthAndQualityFilter"/*.log)
    inherit_log=$(cat "$MULTIRUN_SB/store/Logs/inherit/7_vcf2freq/s3_DepthAndQualityFilter"/*.log)
    assert_contains "$inherit_log" "--minQ 30" "the inheriting run should get the configured value"
    assert_not_contains "$filter_log" "--minQ 30" "and the diverging run must not"
    assert_contains "$filter_log" "Sites" "vcftools should have reported what it kept"
}

# `annotate` decides a step-0 stage, a step-1 process, a step-8 process and the shape of the
# VCF promotion gate. Before E1u all four read the base config, so one run's setting decided
# for every run.
test_annotate_is_decided_per_run() {
    needs_multirun || return
    local o="$MULTIRUN_SB/store/Output"

    # `annotate` is part of step 8's identity, so the two runs that want annotation form a group
    # and the one that does not is simply absent from step 8. The annotated VCF is therefore
    # produced ONCE, in the group's directory, and both runs read it there.
    assert_file "$o/Shared_1/VCF/Test_annotated.vcf" \
        "the two runs that annotate share the work, so it lands in their group's directory"
    assert_contains "$(cat "$o/Shared_1/members.txt")" "filter" "and the group names them"
    assert_contains "$(cat "$o/Shared_1/members.txt")" "inherit" "both of them"
    assert_no_file "$o/plain/VCF/Test_annotated.vcf" \
        "plain sets annotate = false, so it must not produce an annotated VCF"

    assert_count 1 "$(task_count "$MULTIRUN_SB" AnnotateVCF:AnnotateVariants)" \
        "step 8 runs once for the group, not once per member"
    # The runs are filtered by `annotate` before they are grouped, so the two that want a GFF
    # ask about it once between them and the one that does not gets the skip.
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:CheckGFF)" \
        "the two runs that annotate name one GFF, so it is checked once"
    assert_count 1 "$(task_count "$MULTIRUN_SB" VerifyEnvironment:SkipGFFCheck)" \
        "and skipped once for the one that does not annotate"

    assert_contains "$(cat "$o/plain/Reports/0_verify_environment.txt")" \
        "GFF FILE CHECK:        STATUS=SKIPPED" "plain's own report should say so"
    assert_contains "$(cat "$o/inherit/Reports/0_verify_environment.txt")" \
        "GFF FILE CHECK:        STATUS=PASS" "and inherit's should not"
}

# dir.utilized hangs off mainDir and runs share mainDir, so without the RunID suffix every run
# would write Utilized/VCF/Test.vcf to one path - and the second run's skip check would find
# the first run's file and symlink to it, silently, for the whole VCF chain.
# Each run gets its own combined log, and the shared work gets the project's.
#
# The combined log is assembled in a `workflow.onComplete` handler, which is the most dangerous
# place in the pipeline to have untested code: when such a handler throws, Nextflow reports ITS
# failure instead of the error that actually stopped the run. This one did exactly that during
# E1u - it referenced a workflow-body `def` local, which is not visible to the handler when it
# runs, and a careful multi-run configuration error came out as a line about logging. So the
# handler is asserted on directly rather than assumed to work because the run succeeded.
test_each_run_gets_its_own_combined_log() {
    needs_multirun || return
    local run
    for run in inherit filter plain; do
        assert_file "$MULTIRUN_SB/store/Logs/$run/poolseqflow_last_run.log" \
            "$run should have its own combined log"
    done
    # The shared work has no run to belong to, so it goes to the project's own Logs.
    assert_file "$MULTIRUN_SB/store/Logs/poolseqflow_last_run.log" \
        "the dictionaries are shared, so their log belongs to the project"

    # Not merely present - actually holding this run's blocks. An empty file would pass a
    # existence check while telling you nothing about the run.
    local blocks
    blocks=$(awk '/^##########/' "$MULTIRUN_SB/store/Logs/inherit/poolseqflow_last_run.log" | wc -l)
    [ "$blocks" -gt 1 ] || fail_case "inherit's combined log gathered $blocks process log(s)"
}

# reset must clear a multi-run project completely, and say what it is clearing.
#
# `nextflow config -flat` is the wrapper's only path oracle and it reports the BASE
# configuration, so it cannot name storageDir/<RunID> - which means a reset written against it
# alone would delete the base tree, report success, and leave every run's results behind. Those
# would then be REUSED rather than ignored: the pipeline resumes by looking for output files,
# not by asking what produced them. Silent stale results, from a command whose whole purpose is
# to guarantee a clean slate.
#
# Runs against a copy so the shared multi-run sandbox survives for the other cases.
test_reset_clears_every_run_of_a_multi_run_project() {
    needs_multirun || return
    local sb run
    sb=$(guard_path "$TEST_TMPDIR/multirun-reset")
    rm -rf "$sb"; cp -r "$MULTIRUN_SB" "$sb"; rm -f "$sb/run.out"
    # The copy's parameters.config still names the original sandbox; point it at this one, or
    # reset would resolve - and delete - the wrong project.
    sed -i "s|$MULTIRUN_SB|$sb|g" "$sb/main/parameters.config"

    run_project_wrapper "$sb" reset <<< "DELETE_MY_ANALYSIS"
    assert_status 0 "$WRAPPER_STATUS" "reset should succeed; got: $WRAPPER_OUTPUT"

    for run in inherit filter plain; do
        assert_contains "$WRAPPER_OUTPUT" "$sb/store/Output/$run" "reset should name $run's results before deleting them"
        [ -d "$sb/store/Output/$run" ] && fail_case "reset left $run's results behind"
    done
    [ -d "$sb/store/Output" ] && fail_case "reset left the session reports behind"

    # And still keeps everything the user provided.
    assert_file "$sb/main/RGTags.csv"          "reset must keep the RGTags table"
    assert_file "$sb/main/runs.csv"            "reset must keep the multi-run table"
    assert_file "$sb/main/parameters.config"   "reset must keep the configuration"
    [ -d "$sb/main/Data" ] || fail_case "reset must keep the reads"
    assert_file "$sb/main/Reference/reference.fasta.gz" "reset must keep the reference"
    return 0
}

test_each_run_keeps_its_working_files_apart_and_leaves_none_behind() {
    needs_multirun || return
    local run
    for run in inherit filter plain; do
        [ -d "$MULTIRUN_SB/main/Utilized_$run" ] || fail_case \
            "$run should have had its own working directory Utilized_$run"
    done
    assert_no_file "$MULTIRUN_SB/main/Utilized/VCF/Test.vcf" \
        "no run should have written to an unsuffixed Utilized/"

    local left
    left=$(find "$MULTIRUN_SB/main" -maxdepth 1 -name 'Utilized*' -exec find {} -type f \; | wc -l)
    assert_count 0 "$left" "every artifact should have been promoted out of the working volume"
}
