#!/bin/bash
# Unit coverage for the bin/ helpers, called directly rather than through a pipeline run.
#
# These need no conda environment and no fixture, so they run even under --fast. Until now
# the helpers were exercised only end to end, which meant their edge cases - the ones that
# decide whether a skip check is right - had no coverage at all.

HELPERS_DIR=""
FA_OUT=""
FA_ERR=""
FA_STATUS=0

helpers_sandbox() {
    HELPERS_DIR=$(guard_path "$TEST_TMPDIR/helpers")
    rm -rf "$HELPERS_DIR"
    mkdir -p "$HELPERS_DIR"
}

# Run find_artifact.sh and capture stdout, stderr and status separately.
#
# Assigned in the caller rather than echoed back, because a function called inside $(...)
# runs in a subshell and everything it sets is lost when that subshell exits.
fa() {
    local errfile="$HELPERS_DIR/stderr"
    FA_OUT=$("$REPO_ROOT/bin/find_artifact.sh" "$@" 2>"$errfile")
    FA_STATUS=$?
    FA_ERR=$(cat "$errfile")
}

CM_OUT=""
CM_STATUS=0

# Classify two manifests written inline. Every case below costs a millisecond; checking the
# same thing through a pipeline run costs a JVM start, which is why this logic was pulled out
# of the process script in the first place.
cm() {
    local stored="$1" current="$2"
    printf '%s' "$stored"  > "$HELPERS_DIR/stored.txt"
    printf '%s' "$current" > "$HELPERS_DIR/current.txt"
    CM_OUT=$("$REPO_ROOT/bin/classify_manifest.sh" "$HELPERS_DIR/stored.txt" "$HELPERS_DIR/current.txt" 2>"$HELPERS_DIR/stderr")
    CM_STATUS=$?
}

cm_counts() {   # added changed removed malformed
    printf '%s' "$CM_OUT" | awk -F'\t' '$1 == "COUNTS" { print $2, $3, $4, $5 }'
}

test_classify_manifest_reports_no_difference() {
    helpers_sandbox
    cm 'a=1
b=2
' 'a=1
b=2
'
    assert_status 0 "$CM_STATUS" "classifying is not a verdict and should always succeed"
    assert_eq "0 0 0 0" "$(cm_counts)" "identical manifests should differ in nothing"
}

test_classify_manifest_separates_the_three_kinds() {
    helpers_sandbox
    cm 'gone=9
same=1
moved=old
' 'same=1
moved=new
fresh=7
'
    assert_eq "1 1 1 0" "$(cm_counts)" "one added, one changed, one removed"
    assert_contains "$CM_OUT" "CHANGED	moved	old	new" "should carry both values for a change"
    assert_contains "$CM_OUT" "ADDED	fresh		7" "an added key has no previous value"
    assert_contains "$CM_OUT" "REMOVED	gone	9" "a removed key has no new value"
}

# Option strings contain '='. Splitting anywhere but the first one corrupts the value, and a
# corrupted value compares unequal to itself - which would report a change that never
# happened, on every run, for a parameter nobody touched.
test_classify_manifest_splits_on_the_first_equals_only() {
    helpers_sandbox
    cm 'opts=-a X=1 -b Y=2
' 'opts=-a X=1 -b Y=3
'
    assert_eq "0 1 0 0" "$(cm_counts)" "a value containing '=' is one changed parameter"
    assert_contains "$CM_OUT" "CHANGED	opts	-a X=1 -b Y=2	-a X=1 -b Y=3" "the whole value should survive"
}

test_classify_manifest_handles_an_empty_value() {
    helpers_sandbox
    cm 'adapter1=ACGT
' 'adapter1=
'
    assert_eq "0 1 0 0" "$(cm_counts)" "clearing a value is a change"
    assert_contains "$CM_OUT" "CHANGED	adapter1	ACGT	" "should show the value going empty"
}

# analysisParams() sorts and joins, so a manifest written by an older release may lack the
# final newline. Losing the last line would hide a parameter from the comparison entirely.
test_classify_manifest_reads_a_file_with_no_trailing_newline() {
    helpers_sandbox
    cm 'a=1
b=2' 'a=1
b=3'
    assert_eq "0 1 0 0" "$(cm_counts)" "the last line must still be compared"
    assert_contains "$CM_OUT" "CHANGED	b	2	3" "should catch the change on the final line"
}

test_classify_manifest_ignores_blank_lines() {
    helpers_sandbox
    cm 'a=1

b=2
' 'a=1
b=2

'
    assert_eq "0 0 0 0" "$(cm_counts)" "padding is not a difference"
}

# A manifest is machine-written, so a line that does not parse means something upstream is
# wrong. Dropping it silently would hide a key and make a real change look like none.
test_classify_manifest_reports_an_unparseable_line() {
    helpers_sandbox
    cm 'a=1
this line has no equals sign
' 'a=1
'
    assert_eq "0 0 0 1" "$(cm_counts)" "the bad line should be counted, not skipped"
    assert_contains "$CM_OUT" "MALFORMED	this line has no equals sign	stored" "should quote it and say which file"
}

test_classify_manifest_rejects_a_missing_file() {
    helpers_sandbox
    : > "$HELPERS_DIR/only.txt"
    local err
    err=$("$REPO_ROOT/bin/classify_manifest.sh" "$HELPERS_DIR/only.txt" "$HELPERS_DIR/nope.txt" 2>&1)
    assert_status 2 "$?" "a missing manifest is a usage error"
    assert_contains "$err" "not a file" "should say which file is missing"
}

test_find_artifact_returns_the_first_root_that_has_it() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold/Trimmed/S1" "$HELPERS_DIR/hot/Trimmed/S1"
    : > "$HELPERS_DIR/cold/Trimmed/S1/reads.fq.gz"
    fa "Trimmed/S1/reads.fq.gz" "$HELPERS_DIR/cold" "$HELPERS_DIR/hot"
    assert_status 0 "$FA_STATUS" "an artifact that exists should be found"
    assert_eq "$HELPERS_DIR/cold/Trimmed/S1/reads.fq.gz" "$FA_OUT" "should print the permanent copy"
}

# The ordinary mid-run case: written to the working volume, not promoted yet.
test_find_artifact_falls_through_to_a_later_root() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold" "$HELPERS_DIR/hot/Aligned"
    : > "$HELPERS_DIR/hot/Aligned/S1_aligned.bam"
    fa "Aligned/S1_aligned.bam" "$HELPERS_DIR/cold" "$HELPERS_DIR/hot"
    assert_status 0 "$FA_STATUS" "a not-yet-promoted artifact should still be found"
    assert_eq "$HELPERS_DIR/hot/Aligned/S1_aligned.bam" "$FA_OUT" "should print the working copy"
}

# Absent is the normal answer on a first run, so it must be quiet and distinguishable from
# a usage mistake.
test_find_artifact_is_silent_when_nothing_has_it() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold" "$HELPERS_DIR/hot"
    fa "VCF/Test.vcf" "$HELPERS_DIR/cold" "$HELPERS_DIR/hot"
    assert_status 1 "$FA_STATUS" "a missing artifact should exit 1"
    assert_eq "" "$FA_OUT" "nothing should be printed"
    assert_eq "" "$FA_ERR" "absence is not an error and should not be reported as one"
}

# A duplicate means a promotion did not finish. The first root still wins, but silently
# preferring it would let a stale copy win on every later run too.
test_find_artifact_reports_an_artifact_in_two_places() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold/VCF" "$HELPERS_DIR/hot/VCF"
    : > "$HELPERS_DIR/cold/VCF/Test.vcf"
    : > "$HELPERS_DIR/hot/VCF/Test.vcf"
    fa "VCF/Test.vcf" "$HELPERS_DIR/cold" "$HELPERS_DIR/hot"
    assert_status 0 "$FA_STATUS" "a duplicate is still a hit"
    assert_eq "$HELPERS_DIR/cold/VCF/Test.vcf" "$FA_OUT" "the first root should win"
    assert_contains "$FA_ERR" "exists in more than one place" "should say the artifact is duplicated"
    assert_contains "$FA_ERR" "$HELPERS_DIR/hot/VCF/Test.vcf" "should name the other copy"
}

# An unset parameter interpolated by a caller arrives as an empty argument. Treating that as
# "/" would search the filesystem root and match almost anything.
test_find_artifact_skips_an_empty_root() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/hot/Ready"
    : > "$HELPERS_DIR/hot/Ready/S1_ready.bam"
    fa "Ready/S1_ready.bam" "" "$HELPERS_DIR/hot"
    assert_status 0 "$FA_STATUS" "an empty root should be skipped, not searched"
    assert_eq "$HELPERS_DIR/hot/Ready/S1_ready.bam" "$FA_OUT" "the real root should still answer"
}

# Usage mistakes exit 2 so a caller can tell them from "not there".
test_find_artifact_rejects_an_absolute_path() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/hot"
    fa "/etc/passwd" "$HELPERS_DIR/hot"
    assert_status 2 "$FA_STATUS" "an absolute path should be a usage error, not a miss"
    assert_contains "$FA_ERR" "expected a relative path" "should say what is wrong"
}

test_find_artifact_rejects_too_few_arguments() {
    helpers_sandbox
    fa "Trimmed/S1/reads.fq.gz"
    assert_status 2 "$FA_STATUS" "a missing root should be a usage error"
    assert_contains "$FA_ERR" "Usage:" "should print usage"
}

test_find_artifact_rejects_an_empty_relative_path() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/hot"
    fa "" "$HELPERS_DIR/hot"
    assert_status 2 "$FA_STATUS" "an empty relative path should be a usage error"
    assert_contains "$FA_ERR" "empty relative path" "should say what is wrong"
}

# Sample directories come from FASTQ filenames, which the pipeline does not control.
test_find_artifact_handles_spaces_in_paths() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold dir/Trimmed/Sample One"
    : > "$HELPERS_DIR/cold dir/Trimmed/Sample One/reads.fq.gz"
    fa "Trimmed/Sample One/reads.fq.gz" "$HELPERS_DIR/cold dir"
    assert_status 0 "$FA_STATUS" "a path with spaces should be found"
    assert_eq "$HELPERS_DIR/cold dir/Trimmed/Sample One/reads.fq.gz" "$FA_OUT" "should survive the spaces"
}

# Some skip checks ask about a directory rather than a file - the snpEff database, for one.
test_find_artifact_finds_a_directory() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold/Reference/snpEff/data/genome.gff"
    fa "Reference/snpEff/data/genome.gff" "$HELPERS_DIR/cold"
    assert_status 0 "$FA_STATUS" "a directory should count as present"
    assert_eq "$HELPERS_DIR/cold/Reference/snpEff/data/genome.gff" "$FA_OUT" "should print the directory"
}

# Artifacts in the working tree are reached through symlinks in places. A broken one is not
# a usable artifact, and treating it as present would mark a step done that never finished.
test_find_artifact_does_not_count_a_broken_symlink() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/cold/VCF" "$HELPERS_DIR/hot/VCF"
    ln -s "$HELPERS_DIR/nowhere/Test.vcf" "$HELPERS_DIR/cold/VCF/Test.vcf"
    : > "$HELPERS_DIR/hot/VCF/Test.vcf"
    fa "VCF/Test.vcf" "$HELPERS_DIR/cold" "$HELPERS_DIR/hot"
    assert_status 0 "$FA_STATUS" "the real copy should still be found"
    assert_eq "$HELPERS_DIR/hot/VCF/Test.vcf" "$FA_OUT" "a dangling symlink must not win"
}

MR_OUT=""
MR_ERR=""
MR_STATUS=0

# Parse a multi-run table written inline. Every case here is a millisecond; the same coverage
# through step 0 would be a JVM start each, which is the whole reason the parsing is a script.
mr() {
    helpers_sandbox
    printf '%s' "$1" > "$HELPERS_DIR/runs.csv"
    MR_OUT=$(python3 "$REPO_ROOT/bin/parse_multirun.py" "$HELPERS_DIR/runs.csv" 2>"$HELPERS_DIR/stderr")
    MR_STATUS=$?
    MR_ERR=$(cat "$HELPERS_DIR/stderr")
}

test_multirun_reads_a_plain_table() {
    mr 'RunID,referenceFile
refA,a.fasta.gz
refB,b.fasta.gz
'
    assert_status 0 "$MR_STATUS" "a valid table should be accepted"
    assert_contains "$MR_OUT" '"RunID": "refA"' "the first run should be there"
    assert_contains "$MR_OUT" '"referenceFile": "b.fasta.gz"' "so should the second's value"
}

# The reason this is Python and not awk. readPattern's default is *_R{1,2}.fq.gz, so the
# single most likely thing to vary between runs contains a comma. Splitting on commas would
# cut it in half and report the row as having too many fields - a different mistake entirely.
test_multirun_keeps_a_quoted_value_containing_a_comma() {
    mr 'RunID,readPattern
r1,"*_R{1,2}.fq.gz"
'
    assert_status 0 "$MR_STATUS" "a quoted value with a comma is legal CSV"
    assert_contains "$MR_OUT" '*_R{1,2}.fq.gz' "the pattern should survive intact"
}

# A row carries only what differs, so a blank cell means "take it from parameters.config".
# The key must be absent from the run rather than present and empty, because those mean
# opposite things to the resolver.
test_multirun_treats_a_blank_cell_as_inherit() {
    mr 'RunID,trim_galore.quality,poolSize
r1,,50
'
    assert_status 0 "$MR_STATUS" "blank cells are ordinary"
    assert_not_contains "$MR_OUT" 'trim_galore.quality' "a blank cell must not become an override"
    assert_contains "$MR_OUT" '"poolSize": "50"' "a filled cell still counts"
}

test_multirun_ignores_comments_and_blank_lines() {
    mr '# two references

RunID,referenceFile

refA,a.fasta.gz
# refB is disabled for now
'
    assert_status 0 "$MR_STATUS" "comments and blank lines should be skipped"
    assert_contains "$MR_OUT" 'refA' "the real row should still be read"
    assert_not_contains "$MR_OUT" 'refB' "a commented-out row is not a run"
}

test_multirun_rejects_a_duplicate_run_id() {
    mr 'RunID,poolSize
r1,10
r1,20
'
    assert_status 1 "$MR_STATUS" "two runs cannot share a name"
    assert_contains "$MR_ERR" "each run needs its own name" "and should say why"
}

test_multirun_rejects_a_missing_run_id_column() {
    mr 'referenceFile
a.fasta.gz
'
    assert_status 1 "$MR_STATUS" "a table without RunID is unusable"
    assert_contains "$MR_ERR" "RunID" "the message should name the missing column"
}

# The header is parameter names as parameters.config spells them. Writing params.poolSize is
# the obvious mistake to make, so it gets its own message rather than "not a parameter name".
test_multirun_rejects_the_params_prefix_by_name() {
    mr 'RunID,params.poolSize
r1,10
'
    assert_status 1 "$MR_STATUS" "the params. prefix does not belong here"
    assert_contains "$MR_ERR" "write 'poolSize'" "and should say what to write instead"
}

test_multirun_rejects_a_ragged_row() {
    mr 'RunID,poolSize,diploidy
r1,10
'
    assert_status 1 "$MR_STATUS" "a short row is a mistake, not an inherit"
    assert_contains "$MR_ERR" "must be quoted" "and should point at the likely cause"
}

# A RunID becomes a directory name, so it has to be usable as one.
test_multirun_rejects_a_run_id_that_is_not_a_directory_name() {
    mr 'RunID,poolSize
../escape,10
'
    assert_status 1 "$MR_STATUS" "a RunID with a path separator should be refused"
    assert_contains "$MR_ERR" "directory name" "and should say why"
}

# A run's directory sits beside the ones named for shared work, so those names are taken.
# Refused rather than quietly renamed: a run called All_Runs would write into a directory
# whose whole purpose is to say "everything in here belongs to every run".
test_multirun_rejects_a_reserved_run_id() {
    mr 'RunID,poolSize
All_Runs,10
Shared_3,20
'
    assert_status 1 "$MR_STATUS" "a reserved directory name should be refused"
    assert_contains "$MR_ERR" "All_Runs" "and should name the offending id"
    assert_contains "$MR_ERR" "Shared_3" "including the numbered form"
    assert_contains "$MR_ERR" "a name the pipeline uses itself" "and say why it is taken"
}

# ...but only the exact spellings. A run whose name merely resembles one is fine.
test_multirun_accepts_a_run_id_that_only_looks_reserved() {
    mr 'RunID,poolSize
All_Runs_2,10
Shared_x,20
'
    assert_status 0 "$MR_STATUS" "these are not the reserved names"
}

# One fix-and-rerun cycle, not four. Each message carries the line it is about.
test_multirun_reports_every_problem_at_once() {
    mr 'RunID,poolSize,poolSize
r1,10,20
,30,40
'
    assert_status 1 "$MR_STATUS" "the table is unusable"
    assert_contains "$MR_ERR" "appears 2 times" "the duplicate column should be reported"
    assert_contains "$MR_ERR" "RunID is empty"  "and the empty RunID in the same pass"
}

test_multirun_rejects_a_header_with_no_rows() {
    mr 'RunID,poolSize
'
    assert_status 1 "$MR_STATUS" "a table with no runs is not a table"
    assert_contains "$MR_ERR" "no runs" "and should say so"
}

test_multirun_reports_a_missing_file_rather_than_crashing() {
    helpers_sandbox
    MR_STATUS=0
    python3 "$REPO_ROOT/bin/parse_multirun.py" "$HELPERS_DIR/absent.csv" >/dev/null 2>"$HELPERS_DIR/stderr" || MR_STATUS=$?
    assert_status 1 "$MR_STATUS" "a missing table is an error, not a traceback"
    assert_contains "$(cat "$HELPERS_DIR/stderr")" "no such file" "and should say what is missing"
}

# Usage mistakes exit 2, so a caller can tell "your file is wrong" from "you called me wrong".
test_multirun_separates_a_usage_mistake_from_a_bad_table() {
    MR_STATUS=0
    python3 "$REPO_ROOT/bin/parse_multirun.py" >/dev/null 2>&1 || MR_STATUS=$?
    assert_status 2 "$MR_STATUS" "no argument is a usage error"
}

# ---------------------------------------------------------------------------------------
# bin/filterFalsePositives.sh
#
# Worth this much coverage for two reasons. It is the only place in the pipeline where a
# per-sample number decides which variants survive, so a mistake here is a wrong RESULT rather
# than a failed run - nothing downstream looks odd, the frequency tables are simply computed
# over the wrong set of sites. And until E3b its sample-count clause lived inside a
# `bcftools view -i` expression, where it could not be reached without a JVM start and a full
# analysis; moving the arithmetic into awk is what makes every case below cost milliseconds.
#
# Every one runs against test/data/vcf/called.vcf - REAL bcftools output, six samples, 135
# records. See that directory's README for why a hand-written VCF proves nothing here.

FFP_ERR=""
FFP_STATUS=0
FFP_VCF=""
BCFTOOLS_BIN=""

# All six pools at the default poolSize, which is what parameters.config's 0.0025 sensitivity
# already means - so this and a bare -s must agree.
FFP_ALL100="TestSample1=100,TestSample2=100,TestSample3=100,TestSample4=100,TestSample5=100,TestSample6=100"
# The first three as sequenced pools, the last three as single individuals. s = 1/(2*2*1) =
# 0.25 for those, far above the 0.012048 smallest fraction in the file, so they start failing.
FFP_MIXED="TestSample1=100,TestSample2=100,TestSample3=100,TestSample4=1,TestSample5=1,TestSample6=1"

# The filter needs bcftools; the rest of this suite needs nothing. Skipped rather than failed
# when there is no environment, the same way the pipeline suites skip.
ffp_ready() {
    helpers_sandbox
    FFP_VCF="$REPO_ROOT/test/data/vcf/called.vcf"
    BCFTOOLS_BIN="${TEST_CONDA_ENV:-}/bin/bcftools"
    if [ -z "${TEST_CONDA_ENV:-}" ] || [ ! -x "$BCFTOOLS_BIN" ]; then
        skip_case "no bcftools"
        return 1
    fi
    return 0
}

# Run the filter over $FFP_VCF. Extra arguments are appended, so a case adds only what it is
# about. Output lands in the sandbox rather than a variable: these are VCFs, and the assertions
# want records, header lines and sort order separately.
ffp() {
    FFP_STATUS=0
    bash "$REPO_ROOT/bin/filterFalsePositives.sh" -v "$FFP_VCF" -b "$BCFTOOLS_BIN" "$@" \
        > "$HELPERS_DIR/out.vcf" 2>"$HELPERS_DIR/ffp.err" || FFP_STATUS=$?
    FFP_ERR=$(cat "$HELPERS_DIR/ffp.err")
}

ffp_records() { grep -vc '^#' "$HELPERS_DIR/out.vcf" 2>/dev/null || true; }
ffp_sites()   { grep -v '^#' "$HELPERS_DIR/out.vcf" 2>/dev/null | cut -f1,2,4,5 | sort; }
ffp_save()    { cp "$HELPERS_DIR/out.vcf" "$HELPERS_DIR/$1.vcf"; }

# THE INERTNESS PROOF, and the only test that ties the two copies of the sensitivity equation
# together. resolve_parameters.nf computes 1/(2*diploidy*poolSize) in Groovy for the flat -s;
# the script computes it in awk for each -p pool. Give every pool the global size and the two
# must select the same records, or one of them is wrong.
test_filter_fp_per_pool_sizes_match_the_flat_sensitivity() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025
    assert_status 0 "$FFP_STATUS" "the flat path should succeed"
    assert_eq 126 "$(ffp_records)" "the pre-E3b filter kept 126 of 135"
    ffp_save flat

    ffp -t 0.2 -s 0.0025 -p "$FFP_ALL100" -d 2
    assert_status 0 "$FFP_STATUS" "the per-pool path should succeed"
    assert_eq "$(grep -v '^#' "$HELPERS_DIR/flat.vcf" | md5sum)" \
              "$(grep -v '^#' "$HELPERS_DIR/out.vcf" | md5sum)" \
              "every pool at poolSize 100 must select exactly what a flat 0.0025 selects"
}

# The point of the whole stage: a pool of one individual cannot produce an allele fraction
# below 0.25, so calling one at 0.0025 accepted noise as signal.
test_filter_fp_applies_each_pools_own_threshold() {
    ffp_ready || return 0
    ffp -t 0.8 -s 0.0025
    assert_eq 118 "$(ffp_records)" "one threshold for every pool"

    ffp -t 0.8 -s 0.0025 -p "$FFP_MIXED" -d 2
    assert_eq 102 "$(ffp_records)" "three single-individual pools must reject more"
}

# WHY THE THRESHOLDS ARE KEYED BY NAME. The metadata file's row ORDER is a separate identity
# from its values precisely because order decides the VCF's columns; a positional binding would
# be one permutation away from filtering a pool at another pool's threshold, silently.
test_filter_fp_keys_thresholds_by_sample_name_not_column_order() {
    ffp_ready || return 0
    ffp -t 0.8 -s 0.0025 -p "$FFP_MIXED" -d 2
    ffp_save forward

    local reversed="TestSample6=1,TestSample5=1,TestSample4=1,TestSample3=100,TestSample2=100,TestSample1=100"
    ffp -t 0.8 -s 0.0025 -p "$reversed" -d 2
    assert_eq "$(grep -v '^#' "$HELPERS_DIR/forward.vcf" | md5sum)" \
              "$(grep -v '^#' "$HELPERS_DIR/out.vcf" | md5sum)" \
              "reversing the -p list must change nothing"
}

# The comparison is >=, not >. Constructed from the file rather than asserted about it:
# TestSample2 at chr1:8105 has AD=1, DP=72, so its fraction is exactly 1/72 - which is exactly
# the sensitivity of a pool of 18, since 1/(2*2*18) is the same division. With the sample
# threshold at 1.0 every pool must pass, so this one sample decides the record.
test_filter_fp_keeps_a_pool_sitting_exactly_on_its_threshold() {
    ffp_ready || return 0
    local at_18="TestSample1=100,TestSample2=18,TestSample3=100,TestSample4=100,TestSample5=100,TestSample6=100"
    local at_17="TestSample1=100,TestSample2=17,TestSample3=100,TestSample4=100,TestSample5=100,TestSample6=100"

    ffp -t 1.0 -s 0.0025 -p "$at_18" -d 2
    assert_contains "$(ffp_sites)" "chr1	8105" "a fraction equal to the threshold passes it"

    # Non-vacuous: one individual fewer in the pool raises s above 1/72 and the record goes.
    ffp -t 1.0 -s 0.0025 -p "$at_17" -d 2
    assert_not_contains "$(ffp_sites)" "chr1	8105" "and a fraction below it does not"
}

# The refusal that a positional mechanism could not have made at all.
test_filter_fp_refuses_a_sample_column_it_has_no_pool_size_for() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025 -p "TestSample1=100" -d 2
    [ "$FFP_STATUS" -eq 0 ] && fail_case "a VCF column with no pool size should not be filtered"
    assert_contains "$FFP_ERR" "TestSample2" "should name the column it has no size for"
    assert_eq 0 "$(ffp_records)" "and should emit no records"
}

# The other direction is NOT an error: a metadata table kept ahead of the data has rows whose
# reads have not arrived, which step 0 reports as a note rather than refusing.
test_filter_fp_ignores_a_pool_size_for_a_sample_not_in_the_vcf() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025 -p "$FFP_ALL100,GhostPool=50" -d 2
    assert_status 0 "$FFP_STATUS" "a pool with no column is not an error"
    assert_eq 126 "$(ffp_records)" "and changes nothing"
}

# -p carries sizes, so without ploidy it cannot become a threshold. Defaulting to 2 would
# silently halve or double every threshold on a non-diploid organism.
test_filter_fp_requires_diploidy_alongside_pool_sizes() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025 -p "$FFP_ALL100"
    [ "$FFP_STATUS" -eq 0 ] && fail_case "pool sizes without ploidy should be refused"
    assert_contains "$FFP_ERR" "-d" "should say what is missing"
}

test_filter_fp_refuses_a_malformed_pool_size_entry() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025 -p "TestSample1" -d 2
    [ "$FFP_STATUS" -eq 0 ] && fail_case "an entry with no = is not a pool size"
    assert_contains "$FFP_ERR" "Name=count" "should say what the entry should look like"
}

# Zero would divide by zero and produce an infinite threshold, which rejects everything and
# looks exactly like a real result.
test_filter_fp_refuses_a_pool_of_no_individuals() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025 -p "${FFP_ALL100/TestSample1=100/TestSample1=0}" -d 2
    [ "$FFP_STATUS" -eq 0 ] && fail_case "a pool size of zero should be refused"
    assert_contains "$FFP_ERR" "TestSample1" "should name the pool"
}

# WHAT WAS APPLIED, BESIDE WHAT IT WAS APPLIED TO. The pool sizes are in the metadata file and
# in .poolseqflow_metadata, but the VCF is what gets shared and cited, so it carries its own
# record of the thresholds that shaped it.
test_filter_fp_records_the_thresholds_it_applied_in_the_vcf_header() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025 -p "$FFP_MIXED" -d 2
    assert_status 0 "$FFP_STATUS" "should succeed"
    assert_eq 6 "$(grep -c '^##PoolSeqFlowPool' "$HELPERS_DIR/out.vcf")" "one line per pool"
    assert_contains "$(cat "$HELPERS_DIR/out.vcf")" \
        "##PoolSeqFlowPool=<ID=TestSample4,PoolSize=1,Sensitivity=0.25>" \
        "carrying both the size the user wrote and the threshold derived from it"
    # They are written mid-pipeline, so they have to survive the norm -m+ rejoin and the two
    # gsub passes after it. Counted through bcftools rather than grep, which is what proves they
    # are being parsed as header lines rather than merely sitting in the file.
    assert_eq 6 "$("$BCFTOOLS_BIN" view -h "$HELPERS_DIR/out.vcf" | grep -c '^##PoolSeqFlowPool')" \
        "and are still valid header lines after the rejoin"
}

# The flat path is what anyone running the script by hand gets, and it must not start demanding
# the new flags.
test_filter_fp_still_works_with_only_a_flat_sensitivity() {
    ffp_ready || return 0
    ffp -t 0.2 -s 0.0025
    assert_status 0 "$FFP_STATUS" "-s alone is still a complete invocation"
    assert_eq 0 "$(grep -c '^##PoolSeqFlowPool' "$HELPERS_DIR/out.vcf")" \
        "and claims no per-pool provenance it does not have"
}

test_filter_fp_needs_a_vcf_a_threshold_and_a_sensitivity() {
    ffp_ready || return 0
    FFP_STATUS=0
    bash "$REPO_ROOT/bin/filterFalsePositives.sh" -v "$FFP_VCF" -t 0.2 -b "$BCFTOOLS_BIN" \
        >/dev/null 2>"$HELPERS_DIR/ffp.err" || FFP_STATUS=$?
    [ "$FFP_STATUS" -eq 0 ] && fail_case "a missing sensitivity should be refused"
    assert_contains "$(cat "$HELPERS_DIR/ffp.err")" "required" "should say which flags are required"
}

# Derived VCFs. Each is a mechanical transform of the real file - field order permuted, one
# depth zeroed, genotypes dropped - never a record written by hand, so the record STRUCTURE
# stays the structure bcftools actually emits.
ffp_derive() {   # <name> <awk-program>
    awk "$2" "$FFP_VCF" > "$HELPERS_DIR/$1.vcf"
    FFP_VCF="$HELPERS_DIR/$1.vcf"
}

# AD and DP are found by name in each record's FORMAT column, not at a fixed offset. bcftools
# writes FORMAT in the order the fields were produced, so an offset that happens to be right
# for this pipeline's mpileup options would read the wrong numbers under someone else's.
test_filter_fp_finds_ad_and_dp_wherever_format_puts_them() {
    ffp_ready || return 0
    ffp -t 0.8 -s 0.0025 -p "$FFP_MIXED" -d 2
    ffp_save normal

    ffp_derive reversed '
        BEGIN { FS = OFS = "\t" }
        /^#/ { print; next }
        {
            n = split($9, k, ":"); s = ""
            for (i = n; i >= 1; i--) s = s (s == "" ? "" : ":") k[i]
            $9 = s
            for (c = 10; c <= NF; c++) {
                m = split($c, v, ":"); t = ""
                for (i = m; i >= 1; i--) t = t (t == "" ? "" : ":") v[i]
                $c = t
            }
            print
        }'
    ffp -t 0.8 -s 0.0025 -p "$FFP_MIXED" -d 2
    assert_status 0 "$FFP_STATUS" "a different FORMAT order is still a valid VCF"
    assert_eq "$(grep -vc '^#' "$HELPERS_DIR/normal.vcf")" "$(ffp_records)" \
        "and must select exactly the same records"
}

# A sample with no coverage at a site divides by zero. awk would emit a fatal error, and the
# task would fail with a message about arithmetic rather than about data.
test_filter_fp_survives_a_sample_with_no_depth() {
    ffp_ready || return 0
    ffp_derive zerodepth '
        BEGIN { FS = OFS = "\t" }
        /^#/ { print; next }
        {
            n = split($9, k, ":"); dpi = 0
            for (i = 1; i <= n; i++) if (k[i] == "DP") dpi = i
            m = split($10, v, ":"); v[dpi] = 0
            t = v[1]; for (i = 2; i <= m; i++) t = t ":" v[i]
            $10 = t; print
        }'
    ffp -t 0.2 -s 0.0025 -p "$FFP_ALL100" -d 2
    assert_status 0 "$FFP_STATUS" "zero depth is data, not an error"
    # Not "stderr is empty": bcftools norm always reports its line counts there.
    assert_not_contains "$FFP_ERR" "division by zero" "the depth must be checked before dividing"
    [ "$(ffp_records)" -gt 0 ] || fail_case "the other five samples should still carry records"
}

# MINSAMPLES is the right-hand side of the count, so zero samples silently sets it to zero and
# disables the cross-sample filter entirely while the rest of the expression still runs.
test_filter_fp_refuses_a_vcf_with_no_samples() {
    ffp_ready || return 0
    "$BCFTOOLS_BIN" view -G "$FFP_VCF" -o "$HELPERS_DIR/sitesonly.vcf" 2>/dev/null
    FFP_VCF="$HELPERS_DIR/sitesonly.vcf"
    ffp -t 0.2 -s 0.0025
    [ "$FFP_STATUS" -eq 0 ] && fail_case "a VCF with no samples should be refused"
    assert_contains "$FFP_ERR" "no samples" "should say so rather than filtering nothing"
}

# ---------------------------------------------------------------------------------------
# bin/parse_metadata.py - the param_ columns
#
# Only E3b's own refusals. The prefix rule is what makes them worth unit tests: a column the
# parser lets through is a setting the user believes is live, and the failure is silent.

PM_ERR=""
PM_STATUS=0

pm() {
    helpers_sandbox
    printf '%s' "$1" > "$HELPERS_DIR/metadata.csv"
    PM_STATUS=0
    python3 "$REPO_ROOT/bin/parse_metadata.py" "$HELPERS_DIR/metadata.csv" \
        > "$HELPERS_DIR/metadata.json" 2>"$HELPERS_DIR/pm.err" || PM_STATUS=$?
    PM_ERR=$(cat "$HELPERS_DIR/pm.err")
}

test_metadata_accepts_a_pool_whose_rows_agree_on_size() {
    pm 'SampleID,RG_Sample,param_poolSize
A1,PoolA,50
A2,PoolA,50
B1,PoolB,100
'
    assert_status 0 "$PM_STATUS" "two lanes of one pool with one size is the ordinary case"
    assert_contains "$(cat "$HELPERS_DIR/metadata.json")" '"param_poolSize": "50"' \
        "and the value should reach the pipeline"
}

# One pool is one VCF column and gets one sensitivity, so two sizes cannot both be honoured.
test_metadata_rejects_one_pool_with_two_sizes() {
    pm 'SampleID,RG_Sample,param_poolSize
A1,PoolA,50
A2,PoolA,80
'
    assert_status 1 "$PM_STATUS" "a pool cannot have two sizes"
    assert_contains "$PM_ERR" "PoolA" "should name the pool"
    assert_contains "$PM_ERR" "50" "and both sizes it was given"
    assert_contains "$PM_ERR" "80" "and both sizes it was given"
}

# A blank cell means "the global poolSize", which is a third answer rather than agreement.
test_metadata_rejects_a_pool_where_only_some_rows_set_a_size() {
    pm 'SampleID,RG_Sample,param_poolSize
A1,PoolA,50
A2,PoolA,
'
    assert_status 1 "$PM_STATUS" "blank is not agreement with 50"
    assert_contains "$PM_ERR" "blank" "and should say that is what it means"
}

test_metadata_rejects_a_pool_size_that_is_not_a_count() {
    pm 'SampleID,param_poolSize
A1,50.5
A2,-3
A3,lots
'
    assert_status 1 "$PM_STATUS" "individuals come in whole numbers"
    assert_contains "$PM_ERR" "line 2" "should report the fractional one"
    assert_contains "$PM_ERR" "line 3" "and the negative one"
    assert_contains "$PM_ERR" "line 4" "and the word, all in one pass"
}

# Same closed-list rule as RG_: the prefix promises the pipeline acts on the column.
test_metadata_rejects_an_unknown_param_column() {
    pm 'SampleID,param_poolsize
A1,50
'
    assert_status 1 "$PM_STATUS" "param_poolsize is not param_poolSize"
    assert_contains "$PM_ERR" "not a per-sample parameter" "should say what the prefix means"
    assert_contains "$PM_ERR" "param_poolSize" "and list the ones that exist"
}

# The prefix missing rather than misspelled. Without this the column is accepted as design
# metadata and silently ignored - the user reads their own header back and believes it is live.
test_metadata_rejects_a_parameter_column_missing_its_prefix() {
    pm 'SampleID,poolSize,adapter1,adapter2
A1,50,ACGT,TGCA
'
    assert_status 1 "$PM_STATUS" "a bare parameter name should not become design metadata"
    assert_contains "$PM_ERR" "param_poolSize" "should say what to write instead"
    assert_contains "$PM_ERR" "param_adapter1" "for each of them"
    assert_contains "$PM_ERR" "param_adapter2" "for each of them"
}

# The rule is exact-match, not substring: a design column is free to mention a parameter.
test_metadata_leaves_a_design_column_that_merely_resembles_a_parameter_alone() {
    pm 'SampleID,poolsize_notes,population
A1,counted twice,Pop1
'
    assert_status 0 "$PM_STATUS" "this is the user's own column"
}

# ---------------------------------------------------------------- citations --

# Writes both citation files into a scratch directory and echoes it. Runs against the real
# install/citations.json, so a malformed entry fails here rather than at the end of a run.
write_citations() {
    local annotate="$1"; shift
    local out
    out=$(guard_path "$TEST_TMPDIR/citations-$annotate")
    rm -rf "$out"; mkdir -p "$out"
    python3 "$REPO_ROOT/bin/write_citations.py" \
        --data "$REPO_ROOT/install/citations.json" \
        --out-dir "$out" --pipeline-version 3.0.0 --annotate "$annotate" \
        "$@" >/dev/null 2>&1
    CITE_STATUS=$?
    printf '%s' "$out"
}

# Citing a tool the run never invoked is claiming a step that did not happen. `annotate` is
# the case that exists today; the analysis layer will add more conditional tools, and this is
# the rule they will follow.
test_citations_omit_a_tool_the_run_did_not_invoke() {
    local on off
    on=$(write_citations true  bwa=0.7.19 snpEff=5.4.0c)
    off=$(write_citations false bwa=0.7.19 snpEff=5.4.0c)

    assert_contains "$(cat "$on/CITATIONS.md")" "SnpEff" \
        "a run that annotates has invoked SnpEff"
    assert_not_contains "$(cat "$off/CITATIONS.md")" "SnpEff" \
        "a run with annotate = false has not, and must not cite it"
    assert_not_contains "$(cat "$off/references.bib")" "cingolani" \
        "and it must not reach the bibliography either"

    # The rest of the list is unaffected - this removes one entry, not the section.
    assert_contains "$(cat "$off/CITATIONS.md")" "BWA" "everything else is still cited"
}

# The version is the reason these are generated per run rather than shipped as a static list.
test_citations_record_the_version_that_ran() {
    local out; out=$(write_citations true bwa=0.7.19 trim_galore=0.6.10 snpEff=5.4.0c)
    assert_contains "$(cat "$out/CITATIONS.md")" "BWA 0.7.19" "the readable list carries it"
    # trim_galore and snpEff are the two whose display name does not lowercase into their key,
    # so they are the ones a name-based lookup loses.
    assert_contains "$(cat "$out/CITATIONS.md")" "Trim Galore 0.6.10" "including the awkward names"
    assert_contains "$(cat "$out/references.bib")" "Version 0.6.10 used" "and so does the BibTeX"
    assert_contains "$(cat "$out/references.bib")" "Version 5.4.0c used" "for every entry"
}

# SAMtools and BCFtools are one paper. Both tools are named for the reader; the bibliography
# carries the reference once, because a duplicate key is a BibTeX error.
test_citations_deduplicate_a_shared_reference() {
    local out; out=$(write_citations false samtools=1.24 bcftools=1.24)
    local md; md=$(cat "$out/CITATIONS.md")
    assert_contains "$md" "SAMtools"  "both tools are named"
    assert_contains "$md" "BCFtools"  "both tools are named"
    assert_count 1 "$(grep -c '@article{danecek2021samtools,' "$out/references.bib")" \
        "the shared reference should appear once"
}

DC_CORPUS=""

# Build the corpus once and reuse it: twenty analytic histograms, a few milliseconds each.
depth_corpus() {
    [ -n "$DC_CORPUS" ] && return 0
    DC_CORPUS=$(guard_path "$TEST_TMPDIR/depth-corpus")
    rm -rf "$DC_CORPUS"
    python3 "$REPO_ROOT/test/tools/depth_corpus.py" "$DC_CORPUS" >/dev/null 2>&1
}

# One histogram's chosen cutoff.
depth_cut() {
    python3 "$REPO_ROOT/bin/depth_cutoff.py" "$DC_CORPUS/$1.tsv" 2>/dev/null | sed -n 1p
}

# THE WHOLE DETECTOR, AGAINST TWENTY DISTRIBUTIONS, FOR THE COST OF NONE.
#
# The bounds in expected.tsv come from how each case was BUILT - `lo` is the 99.9th percentile
# of its real coverage, `hi` is where the planted pile-up begins - so this measures the
# detector against the intent of the corpus rather than against its own last output. A cutoff
# below `lo` truncates legitimate reads; one above `hi` truncates nothing worth truncating.
test_the_depth_detector_agrees_with_the_whole_corpus() {
    depth_corpus
    local name verdict lo hi desc cut
    while IFS=$'\t' read -r name verdict lo hi desc; do
        [ "$name" = "name" ] && continue
        cut=$(depth_cut "$name")
        if [ "$verdict" = "none" ]; then
            assert_eq "0" "$cut" "$name ($desc) must be left uncapped"
        else
            if [ "$cut" -le "$lo" ] || [ "$cut" -ge "$hi" ]; then
                fail_case "$name ($desc): cut at $cut, which is outside $lo..$hi"
            fi
        fi
    done < "$DC_CORPUS/expected.tsv"
}

# A CLEAN LIBRARY MUST NEVER BE CAPPED, whatever depth it runs at. This is the failure that
# would go unnoticed: capping a sample that needed no capping silently truncates real coverage,
# and the frequency tables that come out of it look perfectly ordinary.
test_a_clean_library_is_never_capped_at_any_depth() {
    depth_corpus
    local name
    for name in clean-8x clean-40x clean-200x clean-800x clean-4000x; do
        assert_eq "0" "$(depth_cut "$name")" "$name spans one lobe and has nothing to cut"
    done
}

# THE ANCHOR IS THE DEEPER OF TWO MEDIANS, and each half of that is load-bearing.
#
# bad-reference is two thirds junk at depth 1-5: its median POSITION is depth 3, so an anchor
# there searches upward from below the real coverage and cuts into it. Its median BASE is 63,
# in the lobe, because junk holds no reads. hill-dominant is the other way round - the pile-up
# holds most of the reads, so the base median lands inside the anomaly while the position
# median stays in the coverage. Taking the deeper of the two is what survives both.
test_the_anchor_survives_a_poor_reference_and_a_dominant_pileup() {
    depth_corpus
    assert_eq "0" "$(depth_cut "bad-reference")" \
        "junk at depth 1-5 is not coverage and must not drag the anchor below the lobe"
    local cut; cut=$(depth_cut "bad-reference-hill")
    [ "$cut" -gt 142 ] && [ "$cut" -lt 2500 ] \
        || fail_case "the same poor reference with a real hill should still cap; cut at $cut"
    assert_eq "0" "$(depth_cut "hill-dominant")" \
        "a pile-up holding most of the genome is not distinguishable from a deep library"
}

# The cap goes where coverage RAN OUT, not where it came back. Both of these have a wide empty
# trough, so taking the far side of it would truncate a 30000x organelle to 15849 and a 50000x
# spike to 35482 - arithmetically a cap, and useless.
test_the_cap_lands_at_the_bottom_of_the_trough() {
    depth_corpus
    local mito spike
    mito=$(depth_cut "mito")
    spike=$(depth_cut "spike-far")
    [ "$mito" -lt 1000 ] || fail_case "the organelle cap should sit just above coverage, not at $mito"
    [ "$spike" -lt 1000 ] || fail_case "the spike cap should sit just above coverage, not at $spike"
}

# Malformed input is a failure, not a silent zero: a cutoff of 0 means "do not cap", so
# returning it for an unreadable histogram would disable capping and report success.
test_the_depth_detector_refuses_a_histogram_it_cannot_read() {
    helpers_sandbox
    printf 'not a histogram\n' > "$HELPERS_DIR/bad.tsv"
    python3 "$REPO_ROOT/bin/depth_cutoff.py" "$HELPERS_DIR/bad.tsv" >/dev/null 2>&1
    assert_status 1 "$?" "a line that is not depth TAB positions should fail"

    printf '10\t5\n-3\t2\n' > "$HELPERS_DIR/negative.tsv"
    python3 "$REPO_ROOT/bin/depth_cutoff.py" "$HELPERS_DIR/negative.tsv" >/dev/null 2>&1
    assert_status 1 "$?" "a negative depth should fail"

    python3 "$REPO_ROOT/bin/depth_cutoff.py" >/dev/null 2>&1
    assert_status 2 "$?" "no argument is a usage mistake, not a bad file"
}

# An empty histogram is a real state - a sample whose BAM holds no aligned reads - and the
# answer is "nothing to cap", not a crash.
test_an_empty_histogram_caps_nothing() {
    helpers_sandbox
    : > "$HELPERS_DIR/empty.tsv"
    local out; out=$(python3 "$REPO_ROOT/bin/depth_cutoff.py" "$HELPERS_DIR/empty.tsv")
    assert_status 0 "$?" "an empty histogram is not an error"
    assert_eq "0" "$(printf '%s' "$out" | sed -n 1p)" "and caps nothing"
    assert_contains "$out" "no covered positions" "saying why"
}

# Every decision is published, so every decision needs a sentence. A cutoff on its own tells a
# reader what happened and never whether it should have.
test_every_depth_decision_explains_itself() {
    depth_corpus
    local reason
    reason=$(python3 "$REPO_ROOT/bin/depth_cutoff.py" "$DC_CORPUS/clean-200x.tsv" | sed -n 2p)
    assert_contains "$reason" "without rising again" "an uncapped sample says why it was left alone"
    reason=$(python3 "$REPO_ROOT/bin/depth_cutoff.py" "$DC_CORPUS/hill-small.tsv" | sed -n 2p)
    assert_contains "$reason" "rises again" "a capped one says what it found"
}

# ---------------------------------------------------------------------------------------
# atomic_mv.sh

# THE BUG THIS GUARDS, measured 2026-08-31: atomic_mv.sh staged every caller through one
# ${DEST}.part, derived from the destination alone. Each caller's EXIT trap then removed the
# file the others were still writing, so six to eight of eight callers failed, and - worse - a
# PARTIAL file appeared under the destination's own name, which skip-by-existence reads as a
# finished derivation. The analysis layer shares intermediates across separate Nextflow
# invocations, so nothing arbitrates between two callers there.
#
# Eight callers is enough: the old code failed at least five of eight in every run, at any
# file size, because the race is on the trap rather than on the copy.
test_atomic_mv_survives_callers_racing_for_one_destination() {
    helpers_sandbox
    local i workers=8 fails=0 letters=ABCDEFGH
    local -a pids=()
    mkdir -p "$HELPERS_DIR/src" "$HELPERS_DIR/dst"
    for ((i = 0; i < workers; i++)); do
        head -c 1048576 /dev/zero | tr '\0' "${letters:$i:1}" > "$HELPERS_DIR/src/w$i"
    done
    for ((i = 0; i < workers; i++)); do
        bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/w$i" "$HELPERS_DIR/dst/shared" \
            > /dev/null 2>&1 &
        pids+=($!)
    done
    for i in "${pids[@]}"; do
        wait "$i" || fails=$((fails + 1))
    done

    assert_count 0 "$fails" "every caller should succeed, not just the one that won the race"
    assert_file "$HELPERS_DIR/dst/shared" "the destination should exist"
    assert_count 1048576 "$(wc -c < "$HELPERS_DIR/dst/shared")" "and be whole, not truncated"
    # One caller's bytes, all the way through: two callers writing one file would leave both.
    local first rest
    first=$(head -c1 "$HELPERS_DIR/dst/shared")
    rest=$(LC_ALL=C tr -d "$first" < "$HELPERS_DIR/dst/shared" | wc -c)
    assert_count 0 "$rest" "the destination should hold exactly one caller's content"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" \
        "and no staging directory should be left behind"
}

# Step 1 moves a whole snpEff database directory with this, so a source that is a directory is
# not a corner case. A staging TEMP FILE instead of a temp directory passes every file-based
# test here and fails the pipeline at step 1.
test_atomic_mv_moves_a_directory() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src/db/nested" "$HELPERS_DIR/dst"
    printf 'x' > "$HELPERS_DIR/src/db/nested/file"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/db" "$HELPERS_DIR/dst/db"
    assert_status 0 "$?" "moving a directory should work"
    assert_file "$HELPERS_DIR/dst/db/nested/file" "with its contents"
    assert_no_file "$HELPERS_DIR/src/db" "and the source should be gone"
}

# THE BUG THIS GUARDS, measured 2026-09-01: the staged copy was made by MOVING the source into
# it, so between that move and the rename into place the staged copy was the only copy - and
# the EXIT trap deleted it. A failed rename destroyed the artifact outright, with no signal and
# no race: source gone, destination absent, exit 1. Killing a move mid-way lost a 400 MB file
# in two runs of five, and left a directory source 59% deleted with nothing at the destination.
#
# This case is the deterministic half of that. `atomic_mv.sh src dst/` used to resolve the
# destination to dst/src WITHOUT re-testing it, so an existing directory of that name took the
# source INSIDE itself: exit 0, source gone, artifact under a name no skip check looks for.
test_atomic_mv_refuses_a_destination_that_is_already_a_directory() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src/payload" "$HELPERS_DIR/dst/payload/already_here"
    printf 'the only copy\n' > "$HELPERS_DIR/src/payload/real.txt"
    local status
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/payload" "$HELPERS_DIR/dst/" \
        > /dev/null 2>&1 && status=0 || status=$?

    assert_status 1 "$status" "moving onto an existing directory should be refused"
    assert_file "$HELPERS_DIR/src/payload/real.txt" \
        "and the source must survive a refusal - it may be the only copy there is"
    assert_no_file "$HELPERS_DIR/dst/payload/payload" "nothing may be nested inside it"
    assert_dir "$HELPERS_DIR/dst/payload/already_here" "and what was there is untouched"
}

# The refusal comes from rename(2), which reports ENOTDIR itself, so the wording is the
# kernel's rather than this script's.
test_atomic_mv_refuses_a_directory_onto_a_file() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src/tree" "$HELPERS_DIR/dst"
    printf 'inside' > "$HELPERS_DIR/src/tree/f"
    printf 'in the way' > "$HELPERS_DIR/dst/tree"
    local status err
    err=$(bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/tree" "$HELPERS_DIR/dst/tree" 2>&1) \
        && status=0 || status=$?

    assert_status 1 "$status" "a directory must not replace a file"
    assert_contains "$err" "Not a directory" "and the refusal says which way round it is"
    assert_contains "$err" "$HELPERS_DIR/src/tree" "naming the source"
    assert_file "$HELPERS_DIR/src/tree/f" "the source survives"
    assert_eq "in the way" "$(cat "$HELPERS_DIR/dst/tree" 2>/dev/null)" "the destination is untouched"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" "and nothing was staged"
}

# Within one filesystem there is nothing to stage: a rename is already atomic. Asserted by
# inode, because a copy would answer every other question here identically while doubling the
# I/O on every promoted BAM.
test_atomic_mv_within_one_filesystem_is_a_rename() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src" "$HELPERS_DIR/dst"
    printf 'payload\n' > "$HELPERS_DIR/src/f"
    local before after
    before=$(stat -c %i "$HELPERS_DIR/src/f")
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/f" "$HELPERS_DIR/dst/f"
    after=$(stat -c %i "$HELPERS_DIR/dst/f")

    assert_eq "$before" "$after" "the file should be renamed, not copied"
    assert_no_file "$HELPERS_DIR/src/f" "and the source name is gone"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" \
        "with nothing staged at all"
}

# A working area on the OTHER filesystem, beside the usual one. Moving between two volumes is a
# different code path - copy, hash both sides, rename, then remove the source - and it is the one
# both data-loss defects lived in. run_tests.sh finds a second filesystem if the machine has one.
XDEV_DIR=""
xdev_sandbox() {
    if [ -z "${TEST_XDEV_TMPDIR:-}" ]; then
        skip_case "no second filesystem to move across"
        return 1
    fi
    helpers_sandbox
    XDEV_DIR=$(guard_path "$TEST_XDEV_TMPDIR/helpers")
    rm -rf "$XDEV_DIR"
    mkdir -p "$XDEV_DIR"
    return 0
}

# Across filesystems there is no rename to be had, so the artifact is copied and the source is
# removed only afterwards. A different inode is the proof that it was copied rather than moved.
test_atomic_mv_across_filesystems_copies_and_verifies() {
    xdev_sandbox || return
    mkdir -p "$HELPERS_DIR/dst"
    printf 'across\n' > "$XDEV_DIR/f"
    local before after
    before=$(stat -c %i "$XDEV_DIR/f")
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/f" "$HELPERS_DIR/dst/f"
    assert_status 0 "$?" "a move between filesystems should succeed"
    after=$(stat -c %i "$HELPERS_DIR/dst/f")

    assert_eq "across" "$(cat "$HELPERS_DIR/dst/f" 2>/dev/null)" "with the content intact"
    [ "$before" != "$after" ] || fail_case "expected a copy across filesystems, not a rename"
    assert_no_file "$XDEV_DIR/f" "and the source removed once the copy was in place"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" \
        "with no staging directory left behind"
}

# The digest stands for the whole tree, so what it compares has to be the whole tree: an empty
# directory and a symlink carry no file contents and would both survive a check that only hashed
# regular files.
test_atomic_mv_across_filesystems_carries_a_whole_directory() {
    xdev_sandbox || return
    mkdir -p "$HELPERS_DIR/dst" "$XDEV_DIR/tree/sub" "$XDEV_DIR/tree/empty"
    printf 'data' > "$XDEV_DIR/tree/sub/real"
    ln -s sub/real "$XDEV_DIR/tree/link"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/tree" "$HELPERS_DIR/dst/tree"
    assert_status 0 "$?" "a directory should move across filesystems"

    assert_eq "data" "$(cat "$HELPERS_DIR/dst/tree/sub/real" 2>/dev/null)" "the file arrives"
    assert_dir "$HELPERS_DIR/dst/tree/empty" "the empty directory arrives"
    [ -L "$HELPERS_DIR/dst/tree/link" ] || fail_case "the symlink should arrive as a symlink"
    assert_no_file "$XDEV_DIR/tree" "and the source is gone"
}

# THE HALF THAT MAKES IT SAFE. A copy that fails must leave the source untouched: the September
# defect was that the source had already been moved away by the time anything could fail, so a
# failure took the only copy with it.
test_atomic_mv_keeps_the_source_when_the_copy_fails() {
    xdev_sandbox || return
    mkdir -p "$HELPERS_DIR/dst" "$XDEV_DIR/tree"
    printf 'readable' > "$XDEV_DIR/tree/open"
    printf 'secret' > "$XDEV_DIR/tree/closed"
    chmod 000 "$XDEV_DIR/tree/closed"
    local status
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/tree" "$HELPERS_DIR/dst/tree" \
        > /dev/null 2>&1 && status=0 || status=$?
    chmod 600 "$XDEV_DIR/tree/closed" 2>/dev/null

    assert_status 1 "$status" "an unreadable member should fail the move"
    assert_file "$XDEV_DIR/tree/open" "and the source must survive it"
    assert_no_file "$HELPERS_DIR/dst/tree" "with nothing written at the destination"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" "and nothing staged"
}

# The hash is checked BEFORE the copy is renamed into place, so a copy that does not match its
# source never appears under the destination's name at all.
#
# Driven by a writer that keeps appending for longer than the move can take, rather than by a
# sleep: the source is then guaranteed to have changed by the time the two digests are compared,
# on a fast machine and a slow one alike.
test_atomic_mv_refuses_a_copy_that_does_not_match_its_source() {
    xdev_sandbox || return
    mkdir -p "$HELPERS_DIR/dst"
    head -c 67108864 /dev/urandom > "$XDEV_DIR/moving.bin"

    local writer status
    ( for _ in $(seq 1 400); do printf 'more' >> "$XDEV_DIR/moving.bin"; sleep 0.01; done ) &
    writer=$!
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/moving.bin" "$HELPERS_DIR/dst/moving.bin" \
        > "$HELPERS_DIR/mismatch.err" 2>&1 && status=0 || status=$?
    kill "$writer" 2>/dev/null
    wait "$writer" 2>/dev/null

    assert_status 1 "$status" "a copy that does not match its source should fail"
    assert_contains "$(cat "$HELPERS_DIR/mismatch.err" 2>/dev/null)" "does not match" \
        "and say so"
    assert_no_file "$HELPERS_DIR/dst/moving.bin" \
        "nothing may appear under the destination name - every skip check would read it as done"
    assert_file "$XDEV_DIR/moving.bin" "and the source is untouched"
}

# EVERY REFUSAL IS ONE RULE, NOT THREE CASES. rename(2) reports EISDIR, ENOTDIR and ENOTEMPTY
# itself, and leaves both sides alone when it does; this script tests the destination's type
# nowhere. A table, because the point is that the same mechanism covers every row - if a future
# change re-introduces a hand-written guard, one row will start behaving differently from the
# rest.
test_atomic_mv_refusals_leave_both_sides_alone() {
    helpers_sandbox
    local label skind dkind status src dst
    src="$HELPERS_DIR/s"
    dst="$HELPERS_DIR/d"
    while IFS='|' read -r label skind dkind; do
        [ -n "$label" ] || continue
        rm -rf "$src" "$dst"
        case "$skind" in
            file) printf 'the source' > "$src" ;;
            dir)  mkdir -p "$src/inner"; printf 'the source' > "$src/inner/f" ;;
        esac
        case "$dkind" in
            file)     printf 'the destination' > "$dst" ;;
            fulldir)  mkdir -p "$dst/keep"; printf 'the destination' > "$dst/keep/f" ;;
        esac

        bash "$REPO_ROOT/bin/atomic_mv.sh" "$src" "$dst" > /dev/null 2>&1 && status=0 || status=$?
        assert_status 1 "$status" "$label: should be refused"
        [ -e "$src" ] || fail_case "$label: the source must survive a refusal"
        if [ "$dkind" = "file" ]; then
            assert_eq "the destination" "$(cat "$dst" 2>/dev/null)" "$label: destination untouched"
        else
            assert_file "$dst/keep/f" "$label: destination untouched"
        fi
        assert_count 0 "$(find "$HELPERS_DIR" -name '.atomic_mv.*' | wc -l)" "$label: nothing staged"
    done <<'CASES'
a file onto a directory|file|fulldir
a directory onto a file|dir|file
a directory onto a directory with something in it|dir|fulldir
CASES
}

# The one cell where behaviour changed when the guards went: rename(2) replaces an EMPTY
# directory rather than refusing it. Nothing is lost - an empty directory holds nothing - and
# no caller reaches it, but it is a change and it is asserted rather than discovered.
test_atomic_mv_replaces_an_empty_directory() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src/tree/inner" "$HELPERS_DIR/dst/tree"
    printf 'moved' > "$HELPERS_DIR/src/tree/inner/f"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/tree" "$HELPERS_DIR/dst/tree"
    assert_status 0 "$?" "an empty directory should be replaced, not refused"
    assert_eq "moved" "$(cat "$HELPERS_DIR/dst/tree/inner/f" 2>/dev/null)" "by the source"
    assert_no_file "$HELPERS_DIR/src/tree" "and the source is gone"
}

# A file landing on an existing file is the one overwrite the pipeline wants: two callers
# deriving the same artifact. It must NOT be caught by anything that refuses the other cells.
test_atomic_mv_replaces_an_existing_file() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src" "$HELPERS_DIR/dst"
    printf 'new' > "$HELPERS_DIR/src/f"
    printf 'old' > "$HELPERS_DIR/dst/f"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/f" "$HELPERS_DIR/dst/f"
    assert_status 0 "$?" "a file should replace a file"
    assert_eq "new" "$(cat "$HELPERS_DIR/dst/f" 2>/dev/null)" "with the source's content"
}

# THE SHAPE THAT USED TO GENERATE GUARDS. `dst/` resolves to `dst/<name>` and then travels the
# identical path an explicit destination does - there is no check downstream of the resolution
# that could treat the two differently. Asserted by running both and comparing the outcome.
test_atomic_mv_both_destination_spellings_agree() {
    helpers_sandbox
    local explicit resolved
    mkdir -p "$HELPERS_DIR/a" "$HELPERS_DIR/dst_a" "$HELPERS_DIR/b" "$HELPERS_DIR/dst_b"
    printf 'payload' > "$HELPERS_DIR/a/f"
    printf 'payload' > "$HELPERS_DIR/b/f"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/a/f" "$HELPERS_DIR/dst_a/f"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/b/f" "$HELPERS_DIR/dst_b/"
    explicit=$(cd "$HELPERS_DIR/dst_a" && find . | sort)
    resolved=$(cd "$HELPERS_DIR/dst_b" && find . | sort)
    assert_eq "$explicit" "$resolved" "both spellings must land the same way"
    assert_no_file "$HELPERS_DIR/a/f" "and both must consume the source"
    assert_no_file "$HELPERS_DIR/b/f" ""
}

# The destination's parent is created on the way. Every caller writes into a results directory
# that may not exist on a first run.
test_atomic_mv_creates_the_destination_parent() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/src"
    printf 'x' > "$HELPERS_DIR/src/f"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/src/f" "$HELPERS_DIR/made/up/path/f"
    assert_status 0 "$?" "a missing destination parent should be created"
    assert_file "$HELPERS_DIR/made/up/path/f" "and the artifact lands in it"
}

test_atomic_mv_refuses_the_wrong_number_of_arguments() {
    helpers_sandbox
    local status
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/only-one" > /dev/null 2>&1 && status=0 || status=$?
    assert_status 1 "$status" "one argument should be refused"
    bash "$REPO_ROOT/bin/atomic_mv.sh" a b c > /dev/null 2>&1 && status=0 || status=$?
    assert_status 1 "$status" "three arguments should be refused"
}

# Across filesystems the refusals come AFTER the copy, because the kernel reports EXDEV before
# it would report EISDIR and no trial rename can tell you sooner. The outcome has to be the
# same as it is on one filesystem; only the wasted work differs.
test_atomic_mv_refusals_reach_the_same_outcome_across_filesystems() {
    xdev_sandbox || return
    mkdir -p "$XDEV_DIR/tree/inner" "$HELPERS_DIR/dst"
    printf 'the source' > "$XDEV_DIR/tree/inner/f"
    printf 'in the way' > "$HELPERS_DIR/dst/tree"
    local status
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/tree" "$HELPERS_DIR/dst/tree" \
        > /dev/null 2>&1 && status=0 || status=$?

    assert_status 1 "$status" "a directory onto a file is refused across filesystems too"
    assert_file "$XDEV_DIR/tree/inner/f" "the source survives"
    assert_eq "in the way" "$(cat "$HELPERS_DIR/dst/tree" 2>/dev/null)" "the destination is untouched"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" "and the stage is cleaned up"
}

# The race, on the path that actually stages. The same-filesystem race never reaches the
# staging directory at all now, so without this the concurrency guarantee is untested where it
# is hardest - eight callers copying into eight staging directories beside one destination.
test_atomic_mv_survives_callers_racing_across_filesystems() {
    xdev_sandbox || return
    local i workers=8 fails=0 letters=ABCDEFGH
    local -a pids=()
    mkdir -p "$HELPERS_DIR/dst"
    for ((i = 0; i < workers; i++)); do
        head -c 1048576 /dev/zero | tr '\0' "${letters:$i:1}" > "$XDEV_DIR/w$i"
    done
    for ((i = 0; i < workers; i++)); do
        bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/w$i" "$HELPERS_DIR/dst/shared" \
            > /dev/null 2>&1 &
        pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i" || fails=$((fails + 1)); done

    assert_count 0 "$fails" "every caller should succeed"
    assert_count 1048576 "$(wc -c < "$HELPERS_DIR/dst/shared")" "the destination should be whole"
    local first rest
    first=$(head -c1 "$HELPERS_DIR/dst/shared")
    rest=$(LC_ALL=C tr -d "$first" < "$HELPERS_DIR/dst/shared" | wc -c)
    assert_count 0 "$rest" "and hold exactly one caller's content"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" \
        "with no staging directory left behind"
}

# A symlink as the source. Today's digest followed the link and compared the target's contents,
# which failed across filesystems whenever the target did not resolve from the staging
# directory; the copy now carries the link itself.
test_atomic_mv_moves_a_symlink_across_filesystems() {
    xdev_sandbox || return
    mkdir -p "$HELPERS_DIR/dst"
    printf 'target' > "$XDEV_DIR/real"
    ln -s real "$XDEV_DIR/link"
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$XDEV_DIR/link" "$HELPERS_DIR/dst/link"
    assert_status 0 "$?" "a symlink should move across filesystems"
    [ -L "$HELPERS_DIR/dst/link" ] || fail_case "it should arrive as a symlink, not its target"
    assert_eq "real" "$(readlink "$HELPERS_DIR/dst/link")" "pointing where it pointed"
    assert_no_file "$XDEV_DIR/link" "and the source link is gone"
    assert_file "$XDEV_DIR/real" "while what it pointed at is left alone"
}

# THE ONLY SILENT FAILURE THIS HELPER HAD. `diff` opens a FIFO and blocks for a writer that
# never arrives, and nothing here has a timeout - measured at 15 s and still going. The glob
# loops in 2_trim_reads.nf and 9_completion.nf pass whatever the glob matched, so the argument
# is not always something this file chose. Refused up front, loudly, in under a second.
test_atomic_mv_refuses_a_source_that_is_not_a_file_or_a_directory() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/dst"
    mkfifo "$HELPERS_DIR/pipe" 2>/dev/null || { skip_case "mkfifo unavailable"; return; }
    local status err
    err=$(timeout 20 bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/pipe" "$HELPERS_DIR/dst/pipe" 2>&1) \
        && status=0 || status=$?

    assert_status 1 "$status" "a FIFO source should be refused, not block forever"
    assert_contains "$err" "neither a file nor a directory" "saying what it will move"
    assert_no_file "$HELPERS_DIR/dst/pipe" "and nothing should be written"
    rm -f "$HELPERS_DIR/pipe"
}

# The trap has to fire on the caller's OWN staging directory and no one else's, which is the
# half that made the old code delete work in progress.
test_atomic_mv_leaves_nothing_behind_when_it_fails() {
    helpers_sandbox
    mkdir -p "$HELPERS_DIR/dst"
    local status
    bash "$REPO_ROOT/bin/atomic_mv.sh" "$HELPERS_DIR/absent" "$HELPERS_DIR/dst/x" \
        > /dev/null 2>&1 && status=0 || status=$?
    assert_status 1 "$status" "a missing source should fail"
    assert_no_file "$HELPERS_DIR/dst/x" "and write nothing"
    assert_count 0 "$(find "$HELPERS_DIR/dst" -name '.atomic_mv.*' | wc -l)" "and stage nothing"
}
