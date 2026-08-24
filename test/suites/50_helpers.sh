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
