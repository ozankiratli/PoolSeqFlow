#!/bin/bash
# mds, against the analytic corpus its own tools build.
# cost: jvm
# covers: modules/mds/ modules/lib/
# covers: test/tools/freq_corpus.py
# covers: analysis.nf modules/mds/main.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.
#
# Every expectation is `test/tools/freq_corpus.py`'s, computed by plain Python loops that share
# nothing with the R under test - a second implementation of Nei's minimum distance and of the
# unbiased correction, written from the definition rather than from the R. Two implementations
# of one statistic agreeing is the point; one agreeing with itself would not be.

# The corpus, into a sandbox of this case's own. Sets CORPUS_DIR, which corpus_expects reads.
mds_corpus() {
    rm -rf "$1"
    CORPUS_DIR="$1/corpus"
    mkdir -p "$CORPUS_DIR"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$CORPUS_DIR" "$CORPUS_DIR"
}

# Run the module's R directly over the corpus, under one set of options, into $1.
#
# Every library's .R rather than the list the manifest names: they are standalone function
# definitions, so a superset is harmless, and the case then cannot go stale when that list
# changes. The Nextflow case is what proves main.nf assembles the same thing, and 00_static is
# what proves the manifest declares exactly what the module calls.
mds_direct() {
    local dest="$1" options="$2" design="${3:-}"
    mkdir -p "$dest"
    [ -n "$design" ] || design="$CORPUS_DIR/design.json"
    cat "$REPO_ROOT"/modules/lib/*/*.R "$REPO_ROOT/modules/mds/mds.R" > "$dest/mds.R"
    printf '%s' "$options" > "$dest/options.json"
    ( cd "$CORPUS_DIR/Frequencies" && Rscript --vanilla "$dest/mds.R" \
        --design "$design" --pools "$CORPUS_DIR/pools.json" \
        --options "$dest/options.json" \
        --cpp-frequencies "$REPO_ROOT/modules/lib/allele_frequencies/allele_frequencies.cpp" \
        --cpp-distance "$REPO_ROOT/modules/lib/nei_distance/nei_distance.cpp" \
        --depths 'Test_snp_depth.tsv' --out "$dest" ) > "$dest/out.txt" 2>&1
}

# The worst relative difference between two published tables, or the word `shape` or `text` when
# they differ in something a number cannot express.
#
# TWO IMPLEMENTATIONS OF ONE SUM AGREE MATHEMATICALLY AND NOT BITWISE. Floating-point addition
# is not associative, so the compiled path accumulating a site at a time and the R accumulating
# a column at a time reach the same total by different roundings, and so do two bin sizes. The
# `correction` column is a difference of two nearly equal sums and shows it first. Comparing the
# files byte for byte would fail on every change to either that did not change the arithmetic.
table_gap() {
    Rscript --vanilla -e '
        args <- commandArgs(trailingOnly = TRUE)
        left <- read.delim(args[1], check.names = FALSE)
        right <- read.delim(args[2], check.names = FALSE)
        if (!identical(dim(left), dim(right)) || !identical(names(left), names(right))) {
            cat("shape"); quit()
        }
        worst <- 0
        for (j in seq_along(left)) {
            if (is.numeric(left[[j]]) && is.numeric(right[[j]])) {
                worst <- max(worst, max(abs(left[[j]] - right[[j]]) /
                                        pmax(1e-12, abs(left[[j]]))))
            } else if (!identical(as.character(left[[j]]), as.character(right[[j]]))) {
                cat("text"); quit()
            }
        }
        cat(format(worst, scientific = TRUE))' "$1" "$2" 2>&1
}

# $1 and $2 agree to within rounding; $3 names what was being compared.
assert_tables_agree() {
    local gap; gap=$(table_gap "$1" "$2")
    if ! awk -v g="$gap" 'BEGIN { exit !(g + 0 < 1e-9 && g != "") }' 2>/dev/null; then
        fail_case "$3: the tables differ by $gap"
    fi
}

# A COHORT OF $2 POOLS INTO $1, the corpus's six plus copies of the sixth, with an `exp_cage`
# variable carrying one level per pool. Three uses, none of them reachable with six pools:
#
#   - two pools that are bit-identical, whose raw distance is exactly zero and whose corrected
#     distance is therefore exactly minus the correction - the only fixture where the sign of a
#     corrected distance is known in advance rather than measured;
#   - more levels than ggplot2 would give shapes on its own, which is seven;
#   - more levels than R has plotting symbols at all, which is twenty-seven.
#
# A variable takes at most one level per pool, so the level count IS the pool count.
mds_wide_cohort() {
    mkdir -p "$1/Frequencies"
    python3 - "$CORPUS_DIR" "$1" "$2" <<'PY'
import json, os, sys

corpus, dest, wanted = sys.argv[1], sys.argv[2], int(sys.argv[3])

rows = open(os.path.join(corpus, "Frequencies", "Test_snp_depth.tsv")).read().splitlines()
header = rows[0].split("\t")
last = header.index("TestSample6")
extra = ["TestSample%d" % n for n in range(7, wanted + 1)]
out = ["\t".join(header + extra)]
for row in rows[1:]:
    cells = row.split("\t")
    out.append("\t".join(cells + [cells[last]] * len(extra)))
open(os.path.join(dest, "Frequencies", "Test_snp_depth.tsv"), "w").write("\n".join(out) + "\n")

pools = json.load(open(os.path.join(corpus, "pools.json")))
json.dump(pools + [dict(pools[-1], pool=name) for name in extra],
          open(os.path.join(dest, "pools.json"), "w"))

design = json.load(open(os.path.join(corpus, "design.json")))
design["variables"].append(
    {"name": "exp_cage", "levels": ["C%d" % i for i in range(1, wanted + 1)]})
for name in extra:
    design["pools"].append(json.loads(json.dumps(design["pools"][5])))
    design["pools"][-1]["pool"] = name
    design["pools"][-1]["libraries"] = [name]
    design["units"].append({"label": name, "pools": [name]})
for index, entry in enumerate(design["pools"]):
    entry["values"]["exp_cage"] = "C%d" % (index + 1)
json.dump(design, open(os.path.join(dest, "design.json"), "w"))
PY
}

# The module's R over a cohort built by mds_wide_cohort in $1, options $2, output into $3.
mds_on_cohort() {
    mkdir -p "$3"
    cat "$REPO_ROOT"/modules/lib/*/*.R "$REPO_ROOT/modules/mds/mds.R" > "$3/mds.R"
    printf '%s' "$2" > "$3/options.json"
    ( cd "$1/Frequencies" && Rscript --vanilla "$3/mds.R" \
        --design "$1/design.json" --pools "$1/pools.json" --options "$3/options.json" \
        --cpp-frequencies "$REPO_ROOT/modules/lib/allele_frequencies/allele_frequencies.cpp" \
        --cpp-distance "$REPO_ROOT/modules/lib/nei_distance/nei_distance.cpp" \
        --depths 'Test_snp_depth.tsv' --out "$3" ) > "$3/out.txt" 2>&1
}

# One cell of distance.tsv, found by the pair rather than by row number.
pair_cell() {
    awk -F'\t' -v a="$2" -v b="$3" -v col="$4" '
        NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
        $(h["pool_a"]) == a && $(h["pool_b"]) == b { print $(h[col]); exit }' "$1"
}

# The options a case uses unless it is testing one of them. Every key main.nf sends, because the
# module refuses one that is missing and a fixture that quietly omits half the contract is not
# testing the thing that ships.
MDS_OPTIONS='{"dimensions":2,"colorBy":"","shapeBy":"","includeIndels":false,"chromosomes":[],"binSize":100000,"workers":1,"usecpp":false}'

# ---------------------------------------------------------------------------------------

# EVERY DISTANCE THE CORPUS HOLDS, all fifteen pairs and all four columns.
test_mds_computes_the_distances_the_corpus_says() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-corpus")
    mds_corpus "$sb"
    mds_direct "$sb/run" "$MDS_OPTIONS"

    local table="$sb/run/distance.tsv"
    if [ ! -s "$table" ]; then
        fail_case "nothing published"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi

    local a b column
    for a in TestSample1 TestSample2 TestSample3 TestSample4 TestSample5; do
        for b in TestSample1 TestSample2 TestSample3 TestSample4 TestSample5 TestSample6; do
            [ "$a" \< "$b" ] || continue
            for column in sites distance raw correction; do
                assert_close "$(pair_cell "$table" "$a" "$b" "$column")" \
                             "$(corpus_expects "mds.$a.$b.$column")" \
                             "$a-$b: $column"
            done
        done
    done
}

# THE CORRECTION IS THE WHOLE REASON THIS STATISTIC WAS CHOSEN, so it is asserted as a quantity
# and not only as a column that exists: raw minus distance is what was subtracted, and it must
# be positive at every pair. A correction that came out zero would mean the unbiased form was
# never applied and the table would still look ordinary.
test_the_sampling_correction_is_applied_and_positive() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-correction")
    mds_corpus "$sb"
    mds_direct "$sb/run" "$MDS_OPTIONS"

    local a b raw distance correction
    while IFS=$'\t' read -r a b _ distance raw correction; do
        # %.17g, because assert_close's tolerance is absolute and awk's default six significant
        # figures lands outside it on a number this small.
        assert_close "$correction" \
                     "$(awk -v r="$raw" -v d="$distance" 'BEGIN{printf "%.17g", r - d}')" \
                     "$a-$b: correction must be raw minus distance"
        if awk -v c="$correction" 'BEGIN{exit !(c <= 0)}'; then
            fail_case "$a-$b: the correction is $correction, so nothing was subtracted"
        fi
    done < <(awk -F'\t' 'NR > 1' "$sb/run/distance.tsv")
}

# A BIN BOUNDARY MUST NOT MOVE A NUMBER. The distances are sums over sites, so a bin falls
# between two of them and the totals are identical whatever the bin size - which is what makes
# binSize a memory knob rather than a setting that changes a result.
test_the_bin_size_changes_no_number() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-bins")
    mds_corpus "$sb"
    mds_direct "$sb/whole" "$MDS_OPTIONS"
    mds_direct "$sb/split" "${MDS_OPTIONS/\"binSize\":100000/\"binSize\":3}"

    assert_tables_agree "$sb/whole/distance.tsv" "$sb/split/distance.tsv" \
                        "a bin size of 3 changed the distances"
    assert_tables_agree "$sb/whole/mds.tsv" "$sb/split/mds.tsv" \
                        "a bin size of 3 changed the coordinates"
    assert_eq "$(awk -F'\t' 'NR > 1 { print $3 }' "$sb/whole/distance.tsv" | sort -u)" \
              "$(awk -F'\t' 'NR > 1 { print $3 }' "$sb/split/distance.tsv" | sort -u)" \
              "and it must not change which sites were counted"
}

# THE COMBINATION THAT FOUND F1's WORKER BUG: compiled and parallel together. Neither alone
# reached it, and a compiled function cannot cross a process boundary, so a worker that does not
# source it for itself fails only here.
test_every_path_through_the_distance_agrees() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    if ! Rscript --vanilla -e 'quit(status = !requireNamespace("Rcpp", quietly = TRUE))' \
         > /dev/null 2>&1; then
        skip_case "no Rcpp"
        return
    fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-paths")
    mds_corpus "$sb"
    mds_direct "$sb/r" "$MDS_OPTIONS"
    mds_direct "$sb/cpp" "${MDS_OPTIONS/\"usecpp\":false/\"usecpp\":true}"

    assert_tables_agree "$sb/r/distance.tsv" "$sb/cpp/distance.tsv" \
                        "the compiled path disagrees with the R"

    if Rscript --vanilla -e 'quit(status = !requireNamespace("doFuture", quietly = TRUE))' \
       > /dev/null 2>&1; then
        local both="${MDS_OPTIONS/\"usecpp\":false/\"usecpp\":true}"
        mds_direct "$sb/both" "${both/\"workers\":1,/\"workers\":2,}"
        if [ ! -s "$sb/both/distance.tsv" ]; then
            fail_case "compiled and parallel published nothing"$'\n'"$(cat "$sb/both/out.txt")"
            return
        fi
        assert_tables_agree "$sb/r/distance.tsv" "$sb/both/distance.tsv" \
                            "compiled and parallel together disagree with the R"
    fi
}

# THE ORDINATION IS OF SQUARED DISTANCES AND cmdscale SQUARES WHAT IT IS GIVEN, so handing it
# the matrix directly would ordinate a quartic. This is the case that would fail if the double
# centering were ever replaced by a cmdscale call on the distances themselves.
test_the_coordinates_reproduce_the_distance_matrix() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-coords")
    mds_corpus "$sb"
    mds_direct "$sb/run" "${MDS_OPTIONS/\"dimensions\":2/\"dimensions\":5}"

    # Six pools span five dimensions exactly, so on all five axes the coordinates must
    # reproduce every distance the matrix holds.
    local worst
    worst=$(Rscript --vanilla -e '
        args <- commandArgs(trailingOnly = TRUE)
        coords <- read.delim(file.path(args[1], "mds.tsv"), check.names = FALSE)
        pairs <- read.delim(file.path(args[1], "distance.tsv"), check.names = FALSE)
        axes <- as.matrix(coords[, grep("^dim", names(coords))])
        rownames(axes) <- coords$pool
        gap <- 0
        for (i in seq_len(nrow(pairs))) {
            placed <- sum((axes[pairs$pool_a[i], ] - axes[pairs$pool_b[i], ])^2)
            gap <- max(gap, abs(placed - pairs$distance[i]))
        }
        cat(format(gap, scientific = TRUE))' "$sb/run" 2>&1)

    if ! awk -v g="$worst" 'BEGIN{exit !(g < 1e-9)}' 2>/dev/null; then
        fail_case "the coordinates do not reproduce the distances: worst gap $worst"
    fi
}

# EIGENVALUES ARE PUBLISHED WITH THEIR SIGNS AND UNDER BOTH DENOMINATORS. With nothing negative
# the two agree, which is what makes a disagreement elsewhere readable as "not flat".
test_the_eigenvalues_are_published_whole() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-eigen")
    mds_corpus "$sb"
    mds_direct "$sb/run" "$MDS_OPTIONS"

    local rows
    rows=$(awk -F'\t' 'NR > 1' "$sb/run/eigenvalues.tsv" | wc -l)
    assert_eq "6" "$rows" "one row per pool, the trivial axis included"
    assert_eq "2" "$(awk -F'\t' 'NR > 1 && $7 == 1' "$sb/run/eigenvalues.tsv" | wc -l)" \
              "two axes plotted at the default dimensions"
    assert_close "1" "$(awk -F'\t' 'NR > 1 { s += $3 } END { print s }' \
                        "$sb/run/eigenvalues.tsv")" "the signed shares sum to one"
}

# THE POINTS ARE POOLS AND CARRY THE UNIT THEY BELONG TO, so a reader can see which of them
# should have coincided. Collapsing to units first would remove exactly that.
test_every_pool_is_placed_and_carries_its_unit() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-pools")
    mds_corpus "$sb"
    mds_direct "$sb/run" "$MDS_OPTIONS"

    assert_eq "6" "$(awk -F'\t' 'NR > 1' "$sb/run/mds.tsv" | wc -l)" "one row per pool"
    assert_contains "$(head -1 "$sb/run/mds.tsv")" "unit" "the unit travels with the point"
    assert_contains "$(head -1 "$sb/run/mds.tsv")" "exp_population" \
                    "and so do the experimental variables"
    assert_eq "0" "$(awk -F'\t' 'NR > 1 && $2 == ""' "$sb/run/mds.tsv" | wc -l)" \
              "no pool may be placed without a unit"
    assert_file "$sb/run/mds.png" "the plot is always drawn"
}

# A POOL OF ONE CHROMOSOME IS REFUSED BY NAME. n_eff is 1 there at every depth, so the
# correction divides by zero at every site and the whole matrix would come back empty.
test_a_single_haploid_genome_is_refused() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-haploid")
    mds_corpus "$sb"
    sed 's/"nChrom": *[0-9]*/"nChrom": 1/; s/"ploidy": *[0-9]*/"ploidy": 1/; s/"size": *[0-9]*/"size": 1/' \
        "$CORPUS_DIR/pools.json" > "$sb/one.json"
    mkdir -p "$sb/run"
    cat "$REPO_ROOT"/modules/lib/*/*.R "$REPO_ROOT/modules/mds/mds.R" > "$sb/run/mds.R"
    printf '%s' "$MDS_OPTIONS" > "$sb/run/options.json"
    ( cd "$CORPUS_DIR/Frequencies" && Rscript --vanilla "$sb/run/mds.R" \
        --design "$CORPUS_DIR/design.json" --pools "$sb/one.json" \
        --options "$sb/run/options.json" \
        --cpp-frequencies "$REPO_ROOT/modules/lib/allele_frequencies/allele_frequencies.cpp" \
        --cpp-distance "$REPO_ROOT/modules/lib/nei_distance/nei_distance.cpp" \
        --depths 'Test_snp_depth.tsv' --out "$sb/run" ) > "$sb/run/out.txt" 2>&1

    assert_contains "$(cat "$sb/run/out.txt")" "one chromosome" "should say what is wrong"
    assert_contains "$(cat "$sb/run/out.txt")" "single haploid genome" \
                    "and say it in the reader's terms"
    assert_no_file "$sb/run/distance.tsv" "and publish nothing"
}

# AN UNKNOWN colorBy OR shapeBy IS REFUSED BEFORE ANY WORK, naming what the project does have.
# A plot silently drawn without the key would look like the setting had been honoured.
test_an_unknown_plot_column_is_refused() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-color")
    mds_corpus "$sb"

    local setting
    for setting in colorBy shapeBy; do
        mds_direct "$sb/$setting" \
            "${MDS_OPTIONS/\"$setting\":\"\"/\"$setting\":\"exp_nonesuch\"}"
        assert_contains "$(cat "$sb/$setting/out.txt")" "exp_nonesuch" \
                        "$setting: should name what was asked for"
        assert_contains "$(cat "$sb/$setting/out.txt")" "exp_population" \
                        "$setting: and what there is"
        assert_no_file "$sb/$setting/distance.tsv" "$setting: and publish nothing"
    done
}

# THE TWO KEYS COMPOSE, which is the question a six-pool ordination is usually asked: do the
# pools group by what was set up, or by when they were sampled.
test_the_points_can_carry_a_color_and_a_shape() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-keys")
    mds_corpus "$sb"
    local options="${MDS_OPTIONS/\"colorBy\":\"\"/\"colorBy\":\"exp_population\"}"
    mds_direct "$sb/run" "${options/\"shapeBy\":\"\"/\"shapeBy\":\"exp_time\"}"

    if [ ! -s "$sb/run/mds.png" ]; then
        fail_case "no plot was drawn"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    # A ggplot2 warning about an unknown label or a dropped shape is written to stderr, which
    # a Nextflow task swallows; out.txt is where a case can still see it.
    assert_not_contains "$(cat "$sb/run/out.txt")" "Warning" "and it must draw without warning"
    assert_tables_agree "$sb/run/distance.tsv" "$sb/run/distance.tsv" "self-comparison sanity"
}

# SIX SHAPES AND NO MORE. ggplot2 assigns none to a seventh level and leaves those pools off the
# plot with a warning a task swallows, so a picture would be missing samples and not say so.
#
# A SEVENTH LEVEL IS DRAWN, NOT REFUSED, AND NOT DROPPED. ggplot2's own shape scale stops at
# six and assigns NA beyond it, so this is the case that fails if the explicit symbol list is
# ever removed - the plot would still be written, one pool short and one warning quieter.
test_a_seventh_shape_level_is_drawn() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-shapes")
    mds_corpus "$sb"
    mds_wide_cohort "$sb/wide" 7
    mds_on_cohort "$sb/wide" "${MDS_OPTIONS/\"shapeBy\":\"\"/\"shapeBy\":\"exp_cage\"}" "$sb/run"

    if [ ! -s "$sb/run/mds.png" ]; then
        fail_case "seven levels drew no plot"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    assert_eq "8" "$(awk 'END { print NR }' "$sb/run/mds.tsv" 2>/dev/null)" \
              "a header and seven pools"
    # ggplot2's own scale warns and drops here; naming the symbols is what stops it.
    assert_not_contains "$(cat "$sb/run/out.txt")" "shape palette" \
                        "ggplot2 must not be left to run out of shapes"
    assert_not_contains "$(cat "$sb/run/out.txt")" "Removed" \
                        "and no pool may be dropped from the plot"
}

# PAST R'S OWN SYMBOLS THERE IS NOTHING LEFT TO GIVE, so the refusal names the count rather than
# letting scale_shape_manual stop with "insufficient values in manual scale".
test_more_levels_than_r_has_symbols_is_refused() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-symbols")
    mds_corpus "$sb"
    mds_wide_cohort "$sb/wide" 27
    mds_on_cohort "$sb/wide" "${MDS_OPTIONS/\"shapeBy\":\"\"/\"shapeBy\":\"exp_cage\"}" "$sb/run"

    assert_contains "$(cat "$sb/run/out.txt")" "exp_cage" "should name the variable"
    assert_contains "$(cat "$sb/run/out.txt")" "27 levels" "and how many it has"
    assert_contains "$(cat "$sb/run/out.txt")" "26 plotting symbols" "against how many there are"
    assert_contains "$(cat "$sb/run/out.txt")" "colorBy" "and what to use instead"
    assert_no_file "$sb/run/mds.png" "and draw nothing"

    # AND THE SAME 27-POOL COHORT MUST WORK once the shape key is dropped, or the refusal above
    # would pass on a cohort the module simply cannot read.
    mds_on_cohort "$sb/wide" "$MDS_OPTIONS" "$sb/plain"
    assert_eq "28" "$(awk 'END { print NR }' "$sb/plain/mds.tsv" 2>/dev/null)" \
              "a header and twenty-seven pools"$'\n'"$(cat "$sb/plain/out.txt")"
}

# DISTANCES ARE NOT FLOORED AT ZERO, and this is the case that says so. It is the module's
# loudest published caveat: an unbiased estimator of a true zero lands either side of zero, so
# two pools drawn from one population produce a small negative number about as often as a small
# positive one, and flooring would bias every distance upward at exactly the pairs where the
# answer should be "no difference".
#
# TWO IDENTICAL POOLS ARE THE ONLY FIXTURE WHERE THE SIGN IS KNOWN IN ADVANCE. Their raw
# distance is exactly zero, so the corrected one is exactly minus the correction and must be
# negative. Every other pair in the corpus is positive, which is why the corpus alone cannot
# catch a max(0, ...) slipped into the accumulation.
test_two_identical_pools_come_out_negative() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/mds-identical")
    mds_corpus "$sb"
    mds_wide_cohort "$sb/wide" 7
    mds_on_cohort "$sb/wide" "$MDS_OPTIONS" "$sb/run"

    local table="$sb/run/distance.tsv"
    if [ ! -s "$table" ]; then
        fail_case "nothing published"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi

    local raw distance correction
    raw=$(pair_cell "$table" TestSample6 TestSample7 raw)
    distance=$(pair_cell "$table" TestSample6 TestSample7 distance)
    correction=$(pair_cell "$table" TestSample6 TestSample7 correction)

    assert_close "$raw" "0" "two identical pools have no uncorrected distance"
    if ! awk -v d="$distance" 'BEGIN { exit !(d < 0) }'; then
        fail_case "a pool against its own copy came out $distance, so the distance is floored"
    fi
    assert_close "$distance" \
                 "$(awk -v c="$correction" 'BEGIN { printf "%.17g", -c }')" \
                 "and it is exactly minus the correction"
}

# AND ONCE THROUGH NEXTFLOW, which is what proves main.nf assembles what the direct cases check.
test_mds_runs_through_the_frame() {
    analysis_ready single || return
    if ! have_r; then skip_case "no Rscript"; return; fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"

    local status; status=$(analysis_run_module mds)
    assert_status 0 "$status" "mds should run; see $ANALYSIS_SB/run.out"

    local dir="$ANALYSIS_SB/main/Analysis/Results/mds"
    assert_file "$dir/distance.tsv" "the distances"
    assert_file "$dir/eigenvalues.tsv" "the eigenvalues"
    assert_file "$dir/mds.tsv" "the coordinates"
    assert_file "$dir/mds.R" "the script that produced them"
    assert_file "$dir/allele_frequencies.cpp" "the compiled parse, shipped either way"
    assert_file "$dir/nei_distance.cpp" "and the compiled distance"
    assert_contains "$(cat "$dir/mds.R")" "nei_distance <- function" \
        "the shared library must be folded into the published script"
    assert_contains "$(cat "$dir/mds.R")" "not floored at zero" \
        "and the header must say what a negative distance means"
}
