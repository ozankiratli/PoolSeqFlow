#!/bin/bash
# The shared R library, called directly. No Nextflow, no conda, no fixture.
# cost: static
# covers: analysis/lib/R/ test/tools/r_lib_tests.R
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# BASE R, AND NOTHING ELSE. These functions are unit-tested against whatever R is on the
# machine: the pipeline environment carries none, and the analysis environment is not built on
# a development machine. A library() call here would make them testable only where the analysis
# environment already exists, which is the one place nobody develops.
test_the_shared_r_library_needs_no_package() {
    local hits
    hits=$(grep -rnE '^\s*(library|require|requireNamespace)\(' "$REPO_ROOT/analysis/lib/R" || true)
    assert_eq "" "$hits" "the shared R library must load no package, but does:"$'\n'"$hits"
}

# The two n_eff forms in circulation differ only by the -1, and they agree closely at high
# depth - so the cases that separate them are at low depth and at the limits, where a wrong
# form is a wrong diversity rather than a rounding difference.
test_the_shared_r_library_computes_effective_sample_size() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section n_eff)
    assert_status 0 "$status" "n_eff: $R_LIB_OUTPUT"
}

# 1/n_eff is linear in 1/depth, which is what lets a pool collapse to two numbers instead of
# one per site. The case asserts the collapse is exact rather than close.
test_the_shared_r_library_collapses_a_pool_to_two_numbers() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section pool_n_eff)
    assert_status 0 "$status" "pool_n_eff: $R_LIB_OUTPUT"
}

# A depth histogram is one row per depth and a count of positions, so the weighted harmonic
# mean must equal what expanding it back to one entry per position would give.
test_the_shared_r_library_takes_a_histogram_as_weights() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section harmonic_mean)
    assert_status 0 "$status" "harmonic_mean: $R_LIB_OUTPUT"
}

# The same thresholds bin/filterFalsePositives.sh computed in awk when it filtered these
# tables, and the same table the manual prints.
test_the_shared_r_library_agrees_with_the_filters_thresholds() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section pool_sensitivity)
    assert_status 0 "$status" "pool_sensitivity: $R_LIB_OUTPUT"
}

# The whole column at once, which is what a genome-scale run needs and what the per-site
# function is the reference for. The trap it exists to fall into is summing p^2 over SITES
# instead of over the ALLELES of a site: one number where there should be one per site.
test_the_shared_r_library_vectorises_over_a_whole_column() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section site_diversity)
    assert_status 0 "$status" "site_diversity: $R_LIB_OUTPUT"
}

# What a parallel loop iterates over. A gap between two bins drops sites from a sum and an
# overlap counts them twice, and both are silent.
test_the_shared_r_library_splits_work_into_bins() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section chunk_ranges)
    assert_status 0 "$status" "chunk_ranges: $R_LIB_OUTPUT"
}

test_the_shared_r_library_reads_a_depth_cell() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local status; status=$(r_lib_section split_counts)
    assert_status 0 "$status" "split_counts: $R_LIB_OUTPUT"
}
