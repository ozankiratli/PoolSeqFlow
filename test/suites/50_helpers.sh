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
