#!/bin/bash
# association, against the analytic corpus its own tools build.
# cost: jvm
# env: analysis
# covers: modules/association/ modules/lib/
# covers: test/tools/freq_corpus.py
# covers: analysis.nf modules/association/main.nf
# covers: analysis/lib/rmd/
# covers: dev/validation/agree.R dev/validation/lib.R modules/mds/mds.R bin/mask_depth.awk
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 04_pipeline's business, and re-proving it here would
# cost minutes a case.
#
# Every expectation is `test/tools/freq_corpus.py`'s, computed by plain Python loops that share
# nothing with the R under test - including a second, independent implementation of the residual
# permutation. Two implementations of one scheme agreeing is the point; one implementation
# agreeing with itself would not be.

# The corpus, into a sandbox of this case's own. Sets CORPUS_DIR, which corpus_expects reads.
association_corpus() {
    rm -rf "$1"
    CORPUS_DIR="$1/corpus"
    mkdir -p "$CORPUS_DIR"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$CORPUS_DIR" "$CORPUS_DIR"
}

# Run the module's R directly over the corpus, under one set of options, into $1. $4 names the
# depth tables, comma-separated, and is the SNP table alone unless given.
#
# Every library's .R rather than the list the manifest names: they are standalone function
# definitions, so a superset is harmless, and the case then cannot go stale when that list
# changes. The Nextflow case is what proves main.nf assembles the same thing, and 00_static is
# what proves the manifest declares exactly what the module calls.
association_direct() {
    local dest="$1" options="$2" design="${3:-}" depths="${4:-Test_snp_depth.tsv}"
    mkdir -p "$dest"
    [ -n "$design" ] || design="$CORPUS_DIR/design.json"
    cat "$REPO_ROOT"/modules/lib/*/*.R \
        "$REPO_ROOT/modules/association/association.R" > "$dest/association.R"
    printf '%s' "$options" > "$dest/options.json"
    ( cd "$CORPUS_DIR/Frequencies" && "$(analysis_rscript)" --vanilla "$dest/association.R" \
        --design "$design" --pools "$CORPUS_DIR/pools.json" \
        --options "$dest/options.json" \
        --cpp "$REPO_ROOT/modules/lib/allele_frequencies/allele_frequencies.cpp" \
        --depths "$depths" --out "$dest" ) > "$dest/out.txt" 2>&1
}

# Empty one pool's cell at one site to the site's own arity, every count of it set to 0: a pool
# with no reads there, as step 7 publishes one. The pool is found by its header.
empty_cell() {
    local table="$1" chrom="$2" pos="$3" pool="$4"
    awk -F'\t' -v OFS='\t' -v c="$chrom" -v p="$pos" -v pool="$pool" '
        NR == 1 {
            for (i = 1; i <= NF; i++) if ($i == pool) col = i
            if (!col) { print "empty_cell: no column " pool > "/dev/stderr"; exit 2 }
            print; next
        }
        $1 == c && $2 == p {
            n = split($col, k, ","); zeros = "0"
            for (i = 2; i <= n; i++) zeros = zeros ",0"
            $col = zeros
        }
        { print }' "$table" > "$table.new" && mv "$table.new" "$table"
}

# The corpus's six pools as units of the sizes given, in pool order, into $2: `2 2 2` is three
# units of two, a design with technical replication. A unit's pools take its first pool's
# phenotype, which the module otherwise refuses as a unit whose pools disagree.
grouped_design() {
    local from="$1" into="$2"; shift 2
    python3 - "$from" "$into" "$@" <<'PY'
import json, sys
design = json.load(open(sys.argv[1]))
sizes = [int(size) for size in sys.argv[3:]]
pools = [entry["pool"] for entry in design["pools"]]
if sum(sizes) != len(pools):
    sys.exit("grouped_design: %d pools and sizes %s" % (len(pools), sizes))
starts = [sum(sizes[:u]) for u in range(len(sizes))]
design["units"] = [
    {"label": "U%d" % (u + 1), "key": {"exp_population": "Pop%d" % (u + 1)},
     "pools": pools[start:start + size], "members": pools[start:start + size]}
    for u, (start, size) in enumerate(zip(starts, sizes))]
first = {i: start for start, size in zip(starts, sizes) for i in range(start, start + size)}
for entry in design["phenotypes"]:
    for i, value in enumerate(entry["values"]):
        value["value"] = entry["values"][first[i]]["value"]
json.dump(design, open(sys.argv[2], "w"))
PY
}

# Three units of two.
paired_design() { grouped_design "$1" "$2" 2 2 2; }

# One cell of the site table, found by position rather than by column number.
site_cell() {
    awk -F'\t' -v c="$2" -v p="$3" -v col="$4" '
        NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
        $(h["chrom"]) == c && $(h["pos"]) == p { print $(h[col]); exit }' "$1"
}

# One key of what freq_corpus.py --association-from wrote into $1.
oracle_value() {
    awk -F'\t' -v k="$2" '$1 == k { print $2 }' "$1"
}

# Every site row of the run in $1 against the oracle in $2, in each column named after them.
agrees_with_oracle() {
    local run="$1" oracle="$2" chrom pos column; shift 2
    while IFS=$'\t' read -r chrom pos; do
        for column in "$@"; do
            assert_close "$(site_cell "$run/association_pt_wingspan.tsv" "$chrom" "$pos" "$column")" \
                         "$(oracle_value "$oracle" "assoc.$chrom.$pos.$column")" \
                         "$chrom:$pos: $column against the oracle"
        done
    done < <(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                         { print $(h["chrom"]) "\t" $(h["pos"]) }' "$run/association_pt_wingspan.tsv")
}

# The options a case uses unless it is testing one of them.
#
# DISPERSION IS PINNED AT ZERO. The corpus is fourteen sites chosen by hand, so a theta estimated
# from it would be noise, and every expectation in expected.tsv is computed at plain n_eff
# weights. What the estimator does is measured in dev/validation, not here.
# Every key main.nf sends, because the module refuses one that is missing and a fixture that
# quietly omits half the contract is not testing the thing that ships.
ASSOCIATION_OPTIONS='{"phenotypes":["pt_wingspan"],"permutations":5000,"dispersion":0,"fdr":"BH","reportBelow":1.0,"reportTop":100000,"chromosomes":[],"binSize":100000,"workers":1,"usecpp":false}'

# ---------------------------------------------------------------------------------------

# EVERY NUMBER THE CORPUS HOLDS, both phenotypes, site rows and the run's own floors.
#
# A site the corpus flagged as zero_variance is checked for the FLAG and not for its numbers. Two
# alleles of one perfectly separated site are algebraically the same test, and whether each lands
# on exactly zero residual or on 1e-32 decides between an infinite t and 1.15e16 - the corpus's
# Python reaches one and the R reaches the other from the same counts.
test_association_computes_what_the_corpus_says() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-corpus")
    association_corpus "$sb"

    local phenotype prefix sites chrom pos flagged
    for phenotype in pt_wingspan:assoc pt_resistant:assocb; do
        prefix="${phenotype##*:}"
        association_direct "$sb/${prefix}" \
            "${ASSOCIATION_OPTIONS/pt_wingspan/${phenotype%%:*}}"
        sites="$sb/${prefix}/association_${phenotype%%:*}.tsv"
        if [ ! -s "$sites" ]; then
            fail_case "$prefix: nothing published"$'\n'"$(cat "$sb/${prefix}/out.txt")"
            return
        fi

        assert_close "$(published_cell "$sb/${prefix}/permutations.tsv" \
                        "${phenotype%%:*}" permutations)" \
                     "$(corpus_expects "${prefix}.permutations")" "$prefix: rearrangement count"
        assert_close "$(published_cell "$sb/${prefix}/permutations.tsv" \
                        "${phenotype%%:*}" floor)" \
                     "$(corpus_expects "${prefix}.floor")" "$prefix: the floor"

        while IFS=$'\t' read -r chrom pos; do
            flagged=$(site_cell "$sites" "$chrom" "$pos" zero_variance)
            assert_eq "$(corpus_expects "${prefix}.${chrom}.${pos}.zero_variance")" "$flagged" \
                      "${prefix}.${chrom}.${pos}.zero_variance in $CORPUS_DIR"
            [ "$flagged" = "1" ] && continue
            assert_close "$(site_cell "$sites" "$chrom" "$pos" S)" \
                         "$(corpus_expects "${prefix}.${chrom}.${pos}.S")" \
                         "$prefix $chrom:$pos: the site statistic"
            assert_close "$(site_cell "$sites" "$chrom" "$pos" perm_p)" \
                         "$(corpus_expects "${prefix}.${chrom}.${pos}.perm_p")" \
                         "$prefix $chrom:$pos: the permutation p"
        done < <(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' \
                 "$CORPUS_DIR/Frequencies/Test_snp_depth.tsv")
    done
}

# THE CASE THAT NOTICES IF THE PERMUTATION GOES BACK TO MOVING LABELS.
#
# chr1:700 carries the signal at depths from 40 to 400, which is where the two schemes part: the
# label scheme reads it at 0.0167 and moving the standardised residuals reads it at 0.0069, on
# identical counts. A design whose depths line up with its phenotype is where label permutation
# was measured at twice its nominal rate, and this site is the corpus's smallest version of it.
test_the_permutation_moves_residuals_and_not_labels() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-scheme")
    association_corpus "$sb"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS"
    assert_close "$(site_cell "$sb/run/association_pt_wingspan.tsv" chr1 700 perm_p)" \
                 "$(corpus_expects "assoc.chr1.700.perm_p")" \
                 "chr1:700 under residual permutation"
}

# THE SET IS ENUMERATED WHILE IT FITS, AND THAT IS CORRECTNESS AND NOT SPEED.
#
# A sampled p is (1 + reached)/(1 + draws) and can land below the smallest value a design can
# support: four units allow 24 rearrangements and a floor of 1/24, and 150 sampled draws can
# report 1/151. Six units allow 720, so a budget above that must be spent enumerating and the
# reported count must be exactly 720.
test_a_rearrangement_set_that_fits_is_enumerated() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-enumerate")
    association_corpus "$sb"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS"
    assert_eq "720" "$(published_cell "$sb/run/permutations.tsv" pt_wingspan permutations)" \
              "six units must enumerate all 720 rearrangements"
    assert_eq "TRUE" "$(published_cell "$sb/run/permutations.tsv" pt_wingspan exhaustive)" \
              "and must say that it did"
}

# The two floors, which part when the set is sampled and are both owed to a reader, and the
# diagnostics beside them.
#
# `floor` is the smallest p this RUN could report; `design_floor` is the smallest the DESIGN can
# reach by rearrangement at all - one over the units factorial, the observed arrangement being
# the only one sure to tie with itself. Enumerated, the two are one number. design_floor was two
# over the units factorial until 2026-10-05, on the argument that reversing the phenotype always
# ties; it ties only where every unit carries the same weight and the phenotype is symmetric about
# its mean, and this corpus reaches 1/720.
test_both_floors_and_the_diagnostics_are_published() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-floors")
    association_corpus "$sb"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS"
    assert_close "$(published_cell "$sb/run/permutations.tsv" pt_wingspan design_floor)" \
                 "0.00138888888888889" "the design floor is 1/720 and not 2/720"
    assert_close "$(published_cell "$sb/run/permutations.tsv" pt_wingspan floor)" \
                 "$(published_cell "$sb/run/permutations.tsv" pt_wingspan design_floor)" \
                 "an enumerated run reaches the design's own floor"
    local column
    for column in dispersion depth_phenotype_cor lambda_gc arity_mean; do
        [ -n "$(published_cell "$sb/run/permutations.tsv" pt_wingspan "$column")" ] \
            || fail_case "permutations.tsv has no $column: a guard that passes tells nobody anything"
    done
}

# FOUR UNITS ARE A TEST AND THREE ARE A RANKING. The smallest p a design can reach is one over its
# units factorial: 1/24 at four, under 0.05, and 1/6 at three, which is not. So three are told
# the table ranks effect sizes and four are not. Under the two-over floor this replaced, four
# units sat at 0.083 and were told the same as three.
test_four_units_are_a_test_and_three_a_ranking() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-floor-units")
    association_corpus "$sb"
    grouped_design "$CORPUS_DIR/design.json" "$sb/four.json" 2 2 1 1
    paired_design "$CORPUS_DIR/design.json" "$sb/three.json"
    association_direct "$sb/four" "$ASSOCIATION_OPTIONS" "$sb/four.json"
    association_direct "$sb/three" "$ASSOCIATION_OPTIONS" "$sb/three.json"
    local units
    for units in four three; do
        if [ ! -s "$sb/$units/permutations.tsv" ]; then
            fail_case "the $units-unit run published nothing"$'\n'"$(cat "$sb/$units/out.txt")"
            return
        fi
    done
    assert_eq "4" "$(published_cell "$sb/four/permutations.tsv" pt_wingspan units)" \
              "the fixture must fit four units"
    assert_close "$(published_cell "$sb/four/permutations.tsv" pt_wingspan design_floor)" \
                 "0.0416666666666667" "four units: the design floor is 1/24"
    grep -q "RANKING" "$sb/four/out.txt" \
        && fail_case "four units can reach 1/24, under 0.05, and were told they are a ranking"
    assert_close "$(published_cell "$sb/three/permutations.tsv" pt_wingspan design_floor)" \
                 "0.166666666666667" "three units: the design floor is 1/6"
    grep -q "RANKING" "$sb/three/out.txt" \
        || fail_case "three units cannot reach 0.05 and must say the table is a ranking"
}

# A UNIT OF SEVERAL POOLS IS COLLAPSED BEFORE THE FIT, NOT AFTER.
#
# Re-reading a pool-level statistic against the unit count controls nothing - measured over-
# conservative when the pools really were independent and still running at twice its nominal rate
# when they were not. The fixture pairs the six pools into three units that agree about the
# phenotype, so the module must fit three units and permute over six rearrangements, not 720.
test_a_unit_of_several_pools_is_collapsed_before_the_fit() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-rollup")
    association_corpus "$sb"
    paired_design "$CORPUS_DIR/design.json" "$sb/paired.json"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS" "$sb/paired.json"
    if [ ! -s "$sb/run/permutations.tsv" ]; then
        fail_case "the roll-up run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    assert_eq "3" "$(published_cell "$sb/run/permutations.tsv" pt_wingspan units)" \
              "three units of two pools must be fitted as three"
    assert_eq "6" "$(published_cell "$sb/run/permutations.tsv" pt_wingspan permutations)" \
              "and permuted over three units, which is 6 rearrangements and not 720"
}

# A SITE IS TESTED OVER THE UNITS IT WAS READ IN, and only if there are three.
#
# The defect this guards, measured before the fix: permutation_p() built its center from the raw
# weights, so one unread unit made every rearranged statistic NaN, the identity was never counted,
# and the site published perm_p 0 - exit 0, nothing said. chr1:250 went from 0.4 to 0, and the BH
# adjustment pulled sites with no unread unit down with it.
#
# The emptied sites are read in 5, 5, 4, 3, 2, 1 and 1 of the six pools; chr1:100 is the
# control, read in all six. The module rearranges a partly read site through the order its read
# units take inside each rearrangement of all six; freq_corpus.py --association-from enumerates
# the read units' own m! directly. Agreement between the two is the point. chr1:250 and chr2:250
# are read in five DIFFERENT units, because the module groups sites by which units read them, and
# grouped by how many it would rearrange one of them over the other's units.
#
# The floor is 1/m!, not 2/m!. Only the identity is sure to tie the observed statistic; the
# reversal ties too only where every unit carries the same weight and the phenotype is symmetric
# about its mean. So chr2:100, read in 3, can never reach 0.05 - 3! is 6 - while chr1:700, read in
# 4, reaches 1/24 here, below it; the run says how many tested sites are like chr2:100.
#
# AN UNREAD UNIT HAS NO WEIGHT, NOT A WEIGHT OF 0. mean_weight and max_leverage are over the
# units read at the site, and depth_phenotype_cor over each unit's own read sites, all three
# against the oracle. The fix's first version let na.rm in roll_up() turn an unread unit into
# weight 0, and mean_weight at chr10:500 then averaged four zeros in. A site read in one unit has
# no slope for a unit to carry, so its max_leverage is NA: chr2:400 is read only in TestSample5,
# where the weighted mean of its own wingspan misses 11.2 by 2e-15 and a test on the sum of
# squares published 2; chr1:400, read only in TestSample6, cancels exactly and could not see it.
#
# fdr_p is BH over the TESTED sites, the oracle's own adjustment over its own p-values.
test_a_site_is_tested_over_the_units_it_was_read_in() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-unread")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv" pool
    empty_cell "$table" chr1 250 TestSample6
    empty_cell "$table" chr2 250 TestSample1
    for pool in TestSample1 TestSample2; do empty_cell "$table" chr1 700 "$pool"; done
    for pool in TestSample1 TestSample2 TestSample3; do empty_cell "$table" chr2 100 "$pool"; done
    for pool in TestSample1 TestSample2 TestSample3 TestSample4; do
        empty_cell "$table" chr10 500 "$pool"
    done
    for pool in TestSample1 TestSample2 TestSample3 TestSample4 TestSample5; do
        empty_cell "$table" chr1 400 "$pool"
    done
    for pool in TestSample1 TestSample2 TestSample3 TestSample4 TestSample6; do
        empty_cell "$table" chr2 400 "$pool"
    done
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" --association-from "$table" > "$sb/oracle.tsv"

    association_direct "$sb/run" "$ASSOCIATION_OPTIONS"
    if [ ! -s "$sb/run/association_pt_wingspan.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi

    local site chrom pos read
    for site in chr1:100:6 chr1:250:5 chr2:250:5 chr1:700:4 chr2:100:3 chr10:500:2 chr1:400:1 \
                chr2:400:1; do
        IFS=: read -r chrom pos read <<< "$site"
        assert_eq "$read" "$(site_cell "$sb/run/association_pt_wingspan.tsv" "$chrom" "$pos" n_observed)" \
                  "$chrom:$pos is read in $read units"
    done
    agrees_with_oracle "$sb/run" "$sb/oracle.tsv" S perm_p fdr_p mean_weight max_leverage
    assert_eq "NA" "$(site_cell "$sb/run/association_pt_wingspan.tsv" chr10 500 fdr_p)" \
              "a site read in 2 units is left out of the adjustment as well as the test"
    assert_close "$(published_cell "$sb/run/permutations.tsv" pt_wingspan depth_phenotype_cor)" \
                 "$(oracle_value "$sb/oracle.tsv" assoc.depth_phenotype_cor)" \
                 "depth_phenotype_cor over each unit's mean at the sites it was read at"
    grep -q "1 tested site(s) of pt_wingspan (snp) were read in too few units to reach 0.05" \
        "$sb/run/out.txt" \
        || fail_case "the run must say that one tested site, chr2:100, cannot reach 0.05"
    grep -qi "warning" "$sb/run/out.txt" \
        && fail_case "the run warned:"$'\n'"$(grep -i -A2 warning "$sb/run/out.txt")"

    # The defect's own signature, over every row: an enumerated p is never 0, because the
    # identity is one of the rearrangements counted.
    assert_eq "" "$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                                $(h["perm_p"]) == "0" { print $(h["chrom"]) ":" $(h["pos"]) }' \
                    "$sb/run/association_pt_wingspan.tsv")" \
              "no site may publish a permutation p of 0"
}

# A UNIT KEEPS THE POOLS OF IT THAT WERE READ. Two pools of one unit are the same material read
# twice, so where one has no reads the unit is the other; roll_up() used to sum the unit's
# weights with no na.rm, which dropped the whole unit wherever either pool was unread.
#
# chr1:700 in the paired design, U1's second pool emptied: U1 must still be read, so the site
# stays read in all three units and is tested. Dropped, it would be read in two and untested.
# chr1:100 loses U3's second pool the same way, and chr2:550 both of U2's, which leaves U2 unread
# there and the site untested. Every site is checked against the oracle collapsing the same pools
# into the same units, so the weighting inside a unit is checked and not only its count.
test_a_unit_keeps_the_pools_of_it_that_were_read() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-rollup-unread")
    association_corpus "$sb"
    paired_design "$CORPUS_DIR/design.json" "$sb/paired.json"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv"
    empty_cell "$table" chr1 700 TestSample2
    empty_cell "$table" chr1 100 TestSample6
    empty_cell "$table" chr2 550 TestSample3
    empty_cell "$table" chr2 550 TestSample4
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" --association-from "$table" --units 2,2,2 \
        > "$sb/oracle.tsv"

    association_direct "$sb/run" "$ASSOCIATION_OPTIONS" "$sb/paired.json"
    if [ ! -s "$sb/run/association_pt_wingspan.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    assert_eq "3" "$(site_cell "$sb/run/association_pt_wingspan.tsv" chr1 700 n_observed)" \
              "U1 is still read at chr1:700 through TestSample1"
    assert_eq "2" "$(site_cell "$sb/run/association_pt_wingspan.tsv" chr2 550 n_observed)" \
              "U2 is not read at chr2:550, where both of its pools were emptied"
    local stat; stat=$(site_cell "$sb/run/association_pt_wingspan.tsv" chr1 700 S)
    case "$stat" in
        ""|NA) fail_case "chr1:700 must be tested over its three units, and S is '$stat'" ;;
    esac
    agrees_with_oracle "$sb/run" "$sb/oracle.tsv" S perm_p fdr_p n_observed mean_weight \
        max_leverage
}

# DISPERSION IS ESTIMATED FROM THE UNITS EACH SITE WAS READ IN. It used to take rowMeans() over
# every unit, so a site with any unread unit dropped out of the estimate, and with none fully read
# theta was NaN, every weight followed it, and the run published nothing tested at exit 0.
#
# TestSample6 emptied at every SNP site, so no site is fully read: a failed library. Dispersion is
# estimated rather than pinned, which every other case here does, and checked against the
# oracle's own estimate over the same units - noise on fourteen sites, but the same noise. A second
# run pins it and checks every site against the oracle, because one pattern of five read units
# covering the whole table is the shape the shortcut for a fully read bin must not take: taken,
# it rearranges the five over all six.
test_dispersion_is_estimated_from_the_units_each_site_was_read_in() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-dispersion-unread")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv" chrom pos
    while IFS=$'\t' read -r chrom pos; do
        empty_cell "$table" "$chrom" "$pos" TestSample6
    done < <(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' "$table")

    association_direct "$sb/run" \
        '{"phenotypes":["pt_wingspan"],"permutations":5000,"dispersion":null,"fdr":"BH","reportBelow":1.0,"reportTop":100000,"chromosomes":[],"binSize":100000,"workers":1,"usecpp":false}'
    if [ ! -s "$sb/run/permutations.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    local theta tested
    theta=$(published_cell "$sb/run/permutations.tsv" pt_wingspan dispersion)
    tested=$(published_cell "$sb/run/permutations.tsv" pt_wingspan tested)
    awk -v v="$theta" 'BEGIN { exit !(v ~ /^[0-9.eE+-]+$/ && v + 0 >= 0) }' \
        || fail_case "theta must be estimated from the read units, and it is '$theta'"
    [ "${tested:-0}" -gt 0 ] 2>/dev/null \
        || fail_case "the run must still test the sites read in five units, and tested is '$tested'"

    # A unit read nowhere has no mean weight and drops out of the correlation, which with that
    # unit carried as NA came out NA itself.
    local cor; cor=$(published_cell "$sb/run/permutations.tsv" pt_wingspan depth_phenotype_cor)
    awk -v v="$cor" 'BEGIN { exit !(v ~ /^-?[0-9][0-9.eE+-]*$/) }' \
        || fail_case "a unit read nowhere must drop out of depth_phenotype_cor, and it is '$cor'"

    python3 "$REPO_ROOT/test/tools/freq_corpus.py" --association-from "$table" > "$sb/oracle.tsv"
    assert_close "$theta" "$(oracle_value "$sb/oracle.tsv" assoc.dispersion)" \
                 "theta, estimated over the units each site was read in"
    association_direct "$sb/pinned" "$ASSOCIATION_OPTIONS"
    agrees_with_oracle "$sb/pinned" "$sb/oracle.tsv" S perm_p fdr_p mean_weight max_leverage
    assert_close "$(published_cell "$sb/pinned/permutations.tsv" pt_wingspan depth_phenotype_cor)" \
                 "$(oracle_value "$sb/oracle.tsv" assoc.depth_phenotype_cor)" \
                 "depth_phenotype_cor over the five units that were read"
}

# A RUN THAT TESTS NOTHING STILL PUBLISHES WHAT IT READ, qq.png included: the frame refuses a
# folder missing a declared output, and a table where no site is read in three units that differ
# in the phenotype is an ordinary outcome of the three-unit rule.
#
# The first run gives TestSample1-3 one wingspan and TestSample4-6 another, and empties 4-6
# everywhere, so every site is read in three units that all carry one value: no slope to test. A
# weighted mean of one repeated value need not return it, so the module used to fit a slope to
# the difference - S near 1e-16, perm_p 1, counted as tested - and publish leverages above 1.
#
# The second empties all but TestSample1 under an estimated dispersion. No site has two units to
# estimate theta from, and the NA theta used to take every weight with it: n_observed published
# 0 where one unit was read, and mean_weight NA. The weights are now left as they are.
test_a_run_that_tests_nothing_still_publishes_what_it_read() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-nothing-tested")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv" chrom pos pool sites
    cp "$table" "$sb/full.tsv"
    python3 - "$CORPUS_DIR/design.json" "$sb/two-values.json" <<'PY'
import json, sys
design = json.load(open(sys.argv[1]))
level = {"TestSample1": 12.4, "TestSample2": 12.4, "TestSample3": 12.4,
         "TestSample4": 15.1, "TestSample5": 15.1, "TestSample6": 15.1}
for entry in design["phenotypes"]:
    if entry["column"] == "pt_wingspan":
        for value in entry["values"]:
            value["value"] = level[value["pool"]]
json.dump(design, open(sys.argv[2], "w"))
PY
    sites=$(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' "$table")
    while IFS=$'\t' read -r chrom pos; do
        for pool in TestSample4 TestSample5 TestSample6; do
            empty_cell "$table" "$chrom" "$pos" "$pool"
        done
    done <<< "$sites"
    association_direct "$sb/flat" "$ASSOCIATION_OPTIONS" "$sb/two-values.json"

    cp "$sb/full.tsv" "$table"
    while IFS=$'\t' read -r chrom pos; do
        for pool in TestSample2 TestSample3 TestSample4 TestSample5 TestSample6; do
            empty_cell "$table" "$chrom" "$pos" "$pool"
        done
    done <<< "$sites"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" --association-from "$table" > "$sb/oracle.tsv"
    association_direct "$sb/alone" \
        '{"phenotypes":["pt_wingspan"],"permutations":5000,"dispersion":null,"fdr":"BH","reportBelow":1.0,"reportTop":100000,"chromosomes":[],"binSize":100000,"workers":1,"usecpp":false}'

    local run column
    for run in flat alone; do
        if [ ! -s "$sb/$run/association_pt_wingspan.tsv" ]; then
            fail_case "the $run run published nothing"$'\n'"$(cat "$sb/$run/out.txt")"
            return
        fi
        assert_file "$sb/$run/qq.png" "the $run run must draw qq.png with nothing tested"
        assert_eq "0" "$(published_cell "$sb/$run/permutations.tsv" pt_wingspan tested)" \
                  "the $run run tests nothing"
        grep -q "no site of pt_wingspan (snp) was tested" "$sb/$run/out.txt" \
            || fail_case "the $run run must say that it tested nothing"
    done
    while IFS=$'\t' read -r chrom pos; do
        assert_eq "3" "$(site_cell "$sb/flat/association_pt_wingspan.tsv" "$chrom" "$pos" n_observed)" \
                  "$chrom:$pos is read in three units that share a wingspan"
        for column in S perm_p fdr_p max_leverage zero_variance; do
            assert_eq "NA" "$(site_cell "$sb/flat/association_pt_wingspan.tsv" "$chrom" "$pos" "$column")" \
                      "$chrom:$pos has no spread in the phenotype, so no $column"
        done
        assert_eq "1" "$(site_cell "$sb/alone/association_pt_wingspan.tsv" "$chrom" "$pos" n_observed)" \
                  "$chrom:$pos is read in TestSample1 alone"
    done <<< "$sites"
    assert_eq "NA" "$(published_cell "$sb/alone/permutations.tsv" pt_wingspan dispersion)" \
              "no site read in two units leaves theta unestimated"
    agrees_with_oracle "$sb/alone" "$sb/oracle.tsv" mean_weight
}

# A DEPTH TABLE OF ONE SITE IS FITTED LIKE ANY OTHER. The weights are built by vapply, which
# returns a bare vector rather than a matrix for one site, and the run stopped on "attempt to set
# 'colnames' on an object with less than two dimensions" - an indel table holding a single indel
# took the whole run with it, SNPs included. Found by a review on 2026-10-05 and left; fixed on
# 2026-10-08, when a cohort built to exercise the report reached it.
test_a_depth_table_of_one_site_is_fitted() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-one-site")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_indel_depth.tsv"
    awk 'NR <= 2' "$table" > "$table.new" && mv "$table.new" "$table"
    local chrom pos
    IFS=$'\t' read -r chrom pos < <(awk -F'\t' 'NR == 2 { print $1 "\t" $2 }' "$table")
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" --association-from "$table" > "$sb/oracle.tsv"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS" "" "Test_snp_depth.tsv,Test_indel_depth.tsv"
    if [ ! -s "$sb/run/association_pt_wingspan.tsv" ]; then
        fail_case "nothing published"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi

    local column
    for column in S perm_p fdr_p n_observed; do
        assert_close "$(site_cell "$sb/run/association_pt_wingspan.tsv" "$chrom" "$pos" "$column")" \
                     "$(oracle_value "$sb/oracle.tsv" "assoc.$chrom.$pos.$column")" \
                     "the one indel, $chrom:$pos: $column against the oracle"
    done
    assert_eq "14" "$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                                  $(h["kind"]) == "snp"' "$sb/run/association_pt_wingspan.tsv" \
                      | wc -l | tr -d ' ')" \
              "and every SNP is published beside it"

    # The indel alone is a phenotype with one tested site, which the report names in the singular.
    association_direct "$sb/alone" "$ASSOCIATION_OPTIONS" "" "Test_indel_depth.tsv"
    analysis_render_report "$sb/alone" "$sb/report" "$REPO_ROOT/modules/association/report.Rmd" md \
        || { fail_case "the report should knit: $(cat "$sb/report/report_knit.log")"; return; }
    local md; md=$(cat "$sb/report/report.md")
    assert_contains "$md" "The one tested site of pt_wingspan (association_pt_wingspan.tsv)" \
        "one tested site is the one, not all 1"
    assert_contains "$md" "It does not reach the smallest p this run could report." \
        "and whether it reaches the floor is said of it alone"
}

# THE STRONGEST SITE STILL COUNTS ITSELF. A rearrangement reaches the observed statistic to within
# rounding, and the rounding grows with it: rebuilt, the identity lands up to 4e-14 of S away
# from S. Counted against an absolute 1e-12 it went uncounted above S of about 100, nothing else
# reached S, and the site published perm_p 0 and fdr_p 0 - the strongest sites in a table,
# reported as impossible ones. Each of these three rows, taken from a scan of 400 near-linear
# sites in which 15 did that, beats every other arrangement, so the answer is 1/720.
test_the_strongest_site_still_counts_itself() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-strongest")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv" pos
    printf '%s\n' \
        $'chr3\t213\tA\tT\t6035,1666\t915,184\t512,235\t1597,51\t291,296\t1720,204\t1000,696' \
        $'chr3\t341\tA\tT\t4564,1545\t452,98\t553,284\t1411,44\t588,697\t1214,151\t346,271' \
        $'chr3\t399\tA\tT\t5359,1647\t981,164\t566,203\t330,12\t873,623\t1689,169\t920,476' \
        >> "$table"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" --association-from "$table" > "$sb/oracle.tsv"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS"
    if [ ! -s "$sb/run/association_pt_wingspan.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    for pos in 213 341 399; do
        assert_close "$(site_cell "$sb/run/association_pt_wingspan.tsv" chr3 "$pos" perm_p)" \
                     "0.00138888888888889" "chr3:$pos beats every rearrangement but its own"
    done
    agrees_with_oracle "$sb/run" "$sb/oracle.tsv" S perm_p fdr_p
}

# A unit takes one phenotype value. Two pools of one unit disagreeing is either metadata that
# contradicts itself or a repeated measure, and the second is a mixed model this release does not
# fit - so it refuses by name rather than averaging the two into something nobody measured.
test_a_phenotype_that_disagrees_within_a_unit_refuses() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-disagree")
    association_corpus "$sb"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS" "$CORPUS_DIR/design_timed.json"
    [ -s "$sb/run/association_pt_wingspan.tsv" ] \
        && fail_case "a unit carrying two phenotype values must refuse, and it published instead"
    grep -q "values of pt_wingspan" "$sb/run/out.txt" \
        || fail_case "the refusal must name the column and the values"$'\n'"$(cat "$sb/run/out.txt")"
}

# The compiled parse and the R one are the same table or one of them is wrong - over the sites
# every pool read, and over two that some pools did not, where both parse a cell of zeros.
test_both_paths_through_the_parse_agree() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-paths")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv" pool
    empty_cell "$table" chr1 250 TestSample6
    for pool in TestSample1 TestSample2 TestSample3 TestSample4; do
        empty_cell "$table" chr10 500 "$pool"
    done
    association_direct "$sb/plain" "$ASSOCIATION_OPTIONS"
    association_direct "$sb/compiled" "${ASSOCIATION_OPTIONS/\"usecpp\":false/\"usecpp\":true}"
    # A FAILURE, NOT A SKIP. The analysis environment pins gcc_linux-64 and gxx_linux-64, so a
    # compiled path that does not build is a broken release rather than a machine without a
    # compiler. As a skip this read as "no compiler" and the run still exited 0.
    if [ ! -s "$sb/compiled/association_pt_wingspan.tsv" ]; then
        fail_case "the compiled path did not build: $(tail -3 "$sb/compiled/out.txt")"
        return
    fi
    diff -q "$sb/plain/association_pt_wingspan.tsv" "$sb/compiled/association_pt_wingspan.tsv" >/dev/null \
        || fail_case "the compiled parse and the R parse published different site tables"
    diff -q "$sb/plain/alleles_pt_wingspan.tsv" "$sb/compiled/alleles_pt_wingspan.tsv" \
        >/dev/null \
        || fail_case "the compiled parse and the R parse published different allele tables"
}

# THE VALIDATION HARNESS DESCRIBES THIS MODULE, OR ITS NUMBERS DESCRIBE NOTHING. The missing_*
# sections of dev/validation/calibrate.R call association.R's own functions, but restate the
# fifteen lines of its main loop that put them in order -- the roll-up, theta, the untestable rule,
# BH over the tested sites -- and restate step 7's mask. dev/validation/agree.R runs the shipped
# association.R and mds.R and bin/mask_depth.awk on tables with unread cells and compares them with
# the harness site by site. It runs here because nothing else would make it run: a change to the
# main loop the harness did not follow would leave every missing_* number describing a computation
# no run makes, and calibrate.R would go on passing. Z agreed to put it in this suite on
# 2026-10-06. Three one-line mutants of the main loop -- untestable below two units instead of
# three, BH over every site, theta never applied -- each made it disagree.
test_the_validation_harness_agrees_with_the_module() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-agree")
    rm -rf "$sb"
    mkdir -p "$sb"
    local status=0
    "$(analysis_rscript)" --vanilla "$REPO_ROOT/dev/validation/agree.R" "$REPO_ROOT/modules" \
        "$sb/work" > "$sb/agree.out" 2>&1 || status=$?
    if [ "$status" != "0" ]; then
        fail_case "agree.R exit $status: the harness and the shipped modules disagree"$'\n'"$(
            grep -E 'DISAGREE|Error|FAILED' "$sb/agree.out" | head -20)"
        return
    fi
    assert_contains "$(cat "$sb/agree.out")" "all agree" "agree.R must end by saying they agree"
}

# The module credits the statistics it computes and not the family they belong to. A reader who
# follows an entry and finds nothing of it in the output is worse served than by no entry.
test_association_cites_the_statistics_it_computes() {
    local citations="$REPO_ROOT/modules/association/citations.json"
    assert_file "$citations" "association ships a citations.json"
    local id
    for id in phipson2010 benjamini1995 long2026; do
        grep -q "\"$id\"" "$citations" || fail_case "association must cite $id"
    done
    # n_eff is library code every module calls, so it is credited once by the layer rather than
    # by each module, and the frame merges that set into every published folder.
    grep -q '"hivert2018"' "$REPO_ROOT/analysis/citations.json" \
        || fail_case "the analysis layer must cite hivert2018 for n_eff"
    grep -q '"hivert2018"' "$citations" \
        && fail_case "association must not redefine hivert2018: a BibTeX key is defined once"
}

# NAMING SEQUENCES RESTRICTS THE FIT TO THEM, and each one named is drawn. Z, 2026-10-08: "User
# should be able to pick chromosomes ... Otherwise with scaffolds etc it is messy." The manual had
# said the setting only chose which sequences got a Manhattan plot. With the dispersion pinned a
# site's statistic does not move; its fdr_p does, adjusted across the named sequences alone.
test_naming_sequences_restricts_the_fit_to_them() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-chromosomes")
    association_corpus "$sb"
    local options
    options=$(printf '%s' "$ASSOCIATION_OPTIONS" | sed 's/"chromosomes":\[\]/"chromosomes":["chr10"]/')
    assert_contains "$options" '"chromosomes":["chr10"]' "the options name chr10"
    association_direct "$sb/all" "$ASSOCIATION_OPTIONS"
    association_direct "$sb/chr10" "$options"
    if [ ! -s "$sb/chr10/association_pt_wingspan.tsv" ]; then
        fail_case "nothing published"$'\n'"$(cat "$sb/chr10/out.txt")"
        return
    fi

    local sites
    sites=$(awk -F'\t' 'NR > 1 && $1 == "chr10"' "$CORPUS_DIR/Frequencies/Test_snp_depth.tsv" | wc -l)
    assert_eq "$((sites + 1))" "$(wc -l < "$sb/chr10/association_pt_wingspan.tsv" | tr -d ' ')" \
              "a header and a row for each of chr10's $sites sites"
    assert_eq "" "$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                                 $(h["chrom"]) != "chr10"' "$sb/chr10/association_pt_wingspan.tsv")" \
              "and no row off chr10"
    assert_eq "manhattan_chr10.png" "$(cd "$sb/chr10" && ls manhattan_*.png 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
              "chr10 is drawn, and nothing else"
    assert_eq "$(site_cell "$sb/all/association_pt_wingspan.tsv" chr10 1700 S)" \
              "$(site_cell "$sb/chr10/association_pt_wingspan.tsv" chr10 1700 S)" \
              "the dispersion pinned, chr10:1700's statistic is the same either way"
    [ "$(site_cell "$sb/all/association_pt_wingspan.tsv" chr10 1700 fdr_p)" \
        != "$(site_cell "$sb/chr10/association_pt_wingspan.tsv" chr10 1700 fdr_p)" ] \
        || fail_case "chr10:1700's fdr_p must be adjusted across chr10 alone"
}

# EACH PHENOTYPE IS PUBLISHED IN FILES OF ITS OWN. Z, 2026-10-08: "Let's do one file per
# phenotype ... Joining files for comparing sounds good." The site table is the phenotype's whole
# table with no phenotype column, and its allele table holds the sites its own selection names: in
# one table for every phenotype the first reportTop slots went to whichever came first, so a second
# phenotype could get none.
#
# THREE UNITS OF TWO put most sites at the floor, 1/6, which is where the tie-break decides the
# selection. For pt_resistant the tied site first in file order is chr2:400 and the one with the
# largest S chr10:500, so reportTop 1 tells the report's order from the file's.
test_each_phenotype_is_published_in_files_of_its_own() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-per-phenotype")
    association_corpus "$sb"
    paired_design "$CORPUS_DIR/design.json" "$sb/three.json"
    association_direct "$sb/run" \
        '{"phenotypes":["pt_wingspan","pt_resistant"],"permutations":5000,"dispersion":0,"fdr":"BH","reportBelow":0,"reportTop":1,"chromosomes":[],"binSize":100000,"workers":1,"usecpp":false}' \
        "$sb/three.json"

    local phenotype header sites
    for phenotype in pt_wingspan pt_resistant; do
        if [ ! -s "$sb/run/association_$phenotype.tsv" ]; then
            fail_case "$phenotype has no site table"$'\n'"$(cat "$sb/run/out.txt")"
            return
        fi
        assert_file "$sb/run/alleles_$phenotype.tsv" "$phenotype has an allele table of its own"
        header=$(head -1 "$sb/run/association_$phenotype.tsv")
        assert_not_contains "$header" "phenotype" "the file names the phenotype, so no column does"
        sites=$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                            !seen[$(h["chrom"]) "\t" $(h["pos"])]++ { print $(h["chrom"]) "\t" $(h["pos"]) }' \
                "$sb/run/alleles_$phenotype.tsv")
        assert_eq "$(report_site_order "$sb/run" "$phenotype" | head -1)" "$sites" \
                  "$phenotype's allele table holds its own first site, in the report's order"
    done
    assert_eq "chr10	500" "$(report_site_order "$sb/run" pt_resistant | head -1)" \
              "the corpus's tie at 1/6 for pt_resistant goes to chr10:500, by S"
    assert_no_file "$sb/run/association.tsv" "and no one table holds every phenotype"
}

# TWO PHENOTYPES THAT WOULD SHARE A FILE NAME ARE REFUSED before any work, naming both. A name's
# characters outside [A-Za-z0-9._-] become _ in its file name, so pt_wing span and pt_wing_span
# would both be association_pt_wing_span.tsv.
test_two_phenotypes_under_one_file_name_refuse() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-file-names")
    association_corpus "$sb"
    python3 - "$CORPUS_DIR/design.json" "$sb/clash.json" <<'PY'
import copy, json, sys
design = json.load(open(sys.argv[1]))
wingspan = next(entry for entry in design["phenotypes"] if entry["column"] == "pt_wingspan")
for name in ("pt_wing span", "pt_wing_span"):
    design["phenotypes"].append(dict(copy.deepcopy(wingspan), column=name))
json.dump(design, open(sys.argv[2], "w"))
PY
    association_direct "$sb/run" \
        "${ASSOCIATION_OPTIONS/\"pt_wingspan\"/\"pt_wing span\",\"pt_wing_span\"}" "$sb/clash.json"
    assert_contains "$(cat "$sb/run/out.txt")" \
        "the phenotypes 'pt_wing span' and 'pt_wing_span' would be published under one name, association_pt_wing_span.tsv" \
        "the refusal names both and the file they would share"
    assert_no_file "$sb/run/permutations.tsv" "and nothing is published"
}

# The row the report's site table gives one site of the phenotype $2, out of its two published
# tables in $1: every number as REPORT_NUMBER_AWK prints it, the leverage to two digits and the
# rest to three, and a flagged site's S as the word. The allele is the one of the largest |t|, or
# of the steepest slope where the site is flagged, at six significant digits, between two that tie
# the one whose slope is positive, and past 20 bases its first 12 and its length. A site the allele
# table holds no row for shows NA for both.
#
# awk reads Inf as 0 (see assert_close), so nothing here converts a flagged site's S or t.
report_site_row() {
    local run="$1" phenotype="$2" chrom="$3" pos="$4"
    awk -F'\t' -v c="$chrom" -v s="$pos" "$REPORT_NUMBER_AWK"'
        function cell(x, d) { return "\"" rnum(x, d) "\"" }
        function allele_text(a) {
            return length(a) > 20 ? substr(a, 1, 12) "... (" length(a) " bases)" : a
        }
        FNR == 1 { split("", h); for (i = 1; i <= NF; i++) h[$i] = i; next }
        $(h["chrom"]) != c || $(h["pos"]) != s { next }
        FILENAME ~ /\/association_[^\/]*[.]tsv$/ {
            flagged = $(h["zero_variance"]) == 1
            row = "    \"" c "\", \"" commas(s) "\", \"" $(h["kind"]) "\", " cell($(h["k"]), 3) \
                  ", " cell($(h["n_observed"]), 3) ", " \
                  (flagged ? "\"flagged\"" : cell($(h["S"]), 3)) ", " \
                  cell($(h["perm_p"]), 3) ", " cell($(h["fdr_p"]), 3)
            leverage = cell($(h["max_leverage"]), 2)
            next
        }
        {
            size = flagged ? $(h["b1"]) : $(h["t"])
            if (size < 0) size = -size
            size = sprintf("%.6g", size) + 0
            slope = $(h["b1"]) + 0
            if (!seen++ || size > best || (size == best && slope > 0 && chosen <= 0)) {
                best = size; allele = $(h["allele"]); chosen = slope
            }
        }
        END {
            if (row == "") exit
            print row ", " (seen ? "\"" allele_text(allele) "\", " cell(chosen, 3) \
                                 : "\"NA\", \"NA\"") ", " leverage ","
        }' "$run/association_$phenotype.tsv" "$run/alleles_$phenotype.tsv"
}

# The sites of the phenotype $2 in the order its table gives them, out of its site table in $1: the
# smallest perm_p first, a flagged site ahead of the others it ties with, then the larger |S|, then
# file order. One "chrom<TAB>pos" a line.
report_site_order() {
    awk -F'\t' -v OFS='\t' '
        NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
        $(h["perm_p"]) == "NA" { next }
        {
            flagged = $(h["zero_variance"]) == 1
            size = $(h["S"]) + 0
            if (size < 0) size = -size
            print $(h["perm_p"]), (flagged ? 0 : 1), (flagged ? 0 : size), NR, $(h["chrom"]), $(h["pos"])
        }' "$1/association_$2.tsv" \
        | LC_ALL=C sort -t "$(printf '\t')" -k1,1g -k2,2n -k3,3gr -k4,4n | cut -f5,6
}

# The first two cells of each row of the table in the report.md text in $1 whose caption holds $2,
# as "chrom<TAB>pos" with the position's thousands marks taken out.
report_table_sites() {
    printf '%s\n' "$1" | awk -v want="$2" '
        /^#layout\(region/ { n = 0 }
        /^  let flat = \($/ { inside = 1; next }
        inside && /^  \)$/ { inside = 0; next }
        inside { rows[++n] = $0; next }
        index($0, "caption: \"") && index($0, want) {
            for (i = 1; i <= n; i++) {
                split(rows[i], cell, "\", \"")
                sub(/^ *"/, "", cell[1])
                gsub(",", "", cell[2])
                print cell[1] "\t" cell[2]
            }
            exit
        }'
}

# The rows of the report's table of what each fit assumed, out of permutations.tsv in $1, as
# report.md holds them.
report_measures_rows() {
    awk -F'\t' "$REPORT_NUMBER_AWK"'
        function add(label, value) {
            if (!(label in line)) order[++m] = label
            line[label] = line[label] ", \"" value "\""
        }
        NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
        {
            add("Units", rnum($(h["units"]), 3))
            add("Rearrangements", rnum($(h["permutations"]), 3) \
                ($(h["exhaustive"]) == "TRUE" ? ", every one" : ", sampled"))
            add("Smallest p the design allows", rnum($(h["design_floor"]), 3))
            add("Smallest p this run could report", rnum($(h["floor"]), 3))
            add("Sites read", rnum($(h["sites"]), 3))
            add("Sites tested", rnum($(h["tested"]), 3))
            add("Selected, fdr_p \342\211\244 0.05", rnum($(h["selected"]), 3))
            add("dispersion", rnum($(h["dispersion"]), 3))
            add("depth_phenotype_cor", rnum($(h["depth_phenotype_cor"]), 3))
            add("lambda_gc", rnum($(h["lambda_gc"]), 3))
            add("Alleles a site, tested", rnum($(h["arity_mean"]), 3))
            add("Alleles a site, selected", rnum($(h["arity_selected"]), 3))
        }
        END { for (i = 1; i <= m; i++) print "    \"" order[i] "\"" line[order[i]] "," }' \
        "$1/permutations.tsv"
}

# The rows of the report's phenotype table for $2, out of phenotype.tsv in $1, each cell as written.
report_phenotype_rows() {
    awk -F'\t' -v p="$2" '
        NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
        $(h["phenotype"]) == p {
            print "    \"" $(h["unit"]) "\", \"" $(h["pool"]) "\", \"" $(h["shown"]) "\", \"" \
                  $(h["value"]) "\", \"" $(h["fitted"]) "\","
        }' "$1/phenotype.tsv"
}

# The sentence the report's site table gives one phenotype's count at the floor, out of the
# published tables in $1: the tested sites whose perm_p equals the run's smallest floor to within
# printing.
report_floor_count() {
    awk -F'\t' -v p="$2" '
        FNR == 1 { split("", h); for (i = 1; i <= NF; i++) h[$i] = i; next }
        FILENAME ~ /permutations[.]tsv$/ {
            if ($(h["phenotype"]) != p) next
            if (least == "" || $(h["floor"]) + 0 < least) least = $(h["floor"]) + 0
            next
        }
        $(h["perm_p"]) != "NA" { tested++; if ($(h["perm_p"]) + 0 <= least * (1 + 1e-6)) at++ }
        END { printf "%d of the %d tested sites %s the smallest p this run could report",
                     at, tested, (at == 1 ? "reaches" : "reach") }' \
        "$1/permutations.tsv" "$1/association_$2.tsv"
}

# The caption of one phenotype's site table in the report.md in $1. Each phenotype's caption
# carries a count that can be the other's word for word, so a count is looked for in its own.
report_site_caption() {
    printf '%s\n' "$1" | grep -F 'figure(kind: table, caption: ' | grep -E "sites of $2[, ]"
}

# THE REPORT'S TABLES, read out of the typst they are drawn with: no Nextflow and no PDF.
#
# Both phenotypes over both depth tables, and every expectation is read out of the published
# tables here by awk rather than from the R the report runs. chr1:700 is biallelic, so its two
# alleles carry one |t| with opposite slopes and the report names the one whose slope is
# positive: for pt_wingspan that is the ALT, which is the case that tells the rule from taking the
# first row. At chr1:400 the two |t| differ in the fifteenth digit, which is what tells a
# comparison at six digits from one at full precision. pt_resistant's chr10:1600 and chr10:1800
# are flagged.
test_association_report_lays_out_the_sites() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-report-md")
    association_corpus "$sb"
    local options
    options=$(printf '%s' "$ASSOCIATION_OPTIONS" \
        | sed 's/"phenotypes":\["pt_wingspan"\]/"phenotypes":["pt_wingspan","pt_resistant"]/')
    assert_contains "$options" '"pt_resistant"' "the options ask for both phenotypes"
    association_direct "$sb/run" "$options" "" "Test_snp_depth.tsv,Test_indel_depth.tsv"
    if [ ! -s "$sb/run/association_pt_wingspan.tsv" ]; then
        fail_case "nothing published"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    analysis_render_report "$sb/run" "$sb/report" "$REPO_ROOT/modules/association/report.Rmd" md \
        || { fail_case "the report should knit: $(cat "$sb/report/report_knit.log")"; return; }
    local md; md=$(cat "$sb/report/report.md")

    local expected
    while IFS= read -r expected; do
        assert_contains "$md" "$expected" "the design table holds permutations.tsv: $expected"
    done < <(report_measures_rows "$sb/run")

    local phenotype reach
    for phenotype in pt_wingspan pt_resistant; do
        while IFS= read -r expected; do
            assert_contains "$md" "$expected" "$phenotype as phenotype.tsv holds it: $expected"
        done < <(report_phenotype_rows "$sb/run" "$phenotype")
        assert_eq "$(report_site_order "$sb/run" "$phenotype")" \
                  "$(report_table_sites "$md" "sites of $phenotype,")" \
                  "$phenotype: every tested site, in the order the caption gives"
        reach=$(report_floor_count "$sb/run" "$phenotype")
        assert_contains "$(report_site_caption "$md" "$phenotype")" "$reach" "$phenotype: $reach"
    done

    local site row chrom pos
    for site in pt_wingspan:chr1:700 pt_wingspan:chr2:550 pt_wingspan:chr1:400 \
                pt_resistant:chr1:700 pt_resistant:chr1:400 \
                pt_resistant:chr10:1600 pt_resistant:chr10:1800; do
        IFS=: read -r phenotype chrom pos <<< "$site"
        row=$(report_site_row "$sb/run" "$phenotype" "$chrom" "$pos")
        [ -n "$row" ] || { fail_case "$site: no row to expect in $sb/run"; continue; }
        assert_contains "$md" "$row" "$site is laid out from its tables: $row"
    done
    assert_contains "$(report_site_row "$sb/run" pt_wingspan chr1 700)" '"T", "0.0587",' \
        "the corpus gives pt_wingspan's chr1:700 the ALT, T, as the allele that rises"
    assert_contains "$(report_site_row "$sb/run" pt_resistant chr10 1600)" '"flagged"' \
        "and pt_resistant's chr10:1600 is flagged"

    local coded
    coded=$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                        $(h["phenotype"]) == "pt_resistant" { print $(h["coded_one"]); exit }' \
            "$sb/run/phenotype.tsv")
    assert_eq "present" "$coded" "the corpus codes pt_resistant's present as 1"
    assert_contains "$md" "more frequent in the units coded $coded" \
        "a binary phenotype's slope reads by the level coded 1"
    assert_contains "$md" "more frequent at the higher value" "and a quantitative one's by its value"
    assert_not_contains "$md" "can reach is" "six units put the floor below 0.05"
    assert_not_contains "$md" "NA is a site" "every site is in the allele table at reportTop 100000"

    # Two states no corpus site holds, planted in the published tables. pt_wingspan's chr1:700 one
    # step above the floor, 2/720: it is not at the floor, however the two were printed. And a
    # third allele at the flagged chr10:1600 of pt_resistant whose |t| is the largest and whose
    # slope is not the steepest: a flagged site's |t| is not comparable, so its slope decides.
    awk -F'\t' -v OFS='\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; print; next }
                            $(h["chrom"]) == "chr1" && $(h["pos"]) == 700 {
                                $(h["perm_p"]) = sprintf("%.15g", 2 / 720)
                            }
                            { print }' "$sb/run/association_pt_wingspan.tsv" > "$sb/stepped.tsv" \
        && mv "$sb/stepped.tsv" "$sb/run/association_pt_wingspan.tsv"
    awk -F'\t' -v OFS='\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; print; next }
                            $(h["chrom"]) == "chr10" && $(h["pos"]) == 1600 && $(h["b1"]) > 0 {
                                $(h["t"]) = "1e16"
                            }
                            { print }
                            END { print "snp", "chr10", "1600", "C", "0.5", "0.1", "Inf", "0" }' \
        "$sb/run/alleles_pt_resistant.tsv" > "$sb/planted.tsv" \
        && mv "$sb/planted.tsv" "$sb/run/alleles_pt_resistant.tsv"
    analysis_render_report "$sb/run" "$sb/planted" "$REPO_ROOT/modules/association/report.Rmd" md \
        || { fail_case "the planted report should knit: $(cat "$sb/planted/report_knit.log")"; return; }
    md=$(cat "$sb/planted/report.md")
    assert_eq "0.00277777777777778" "$(site_cell "$sb/run/association_pt_wingspan.tsv" chr1 700 perm_p)" \
        "chr1:700 now sits one step above the floor"
    reach=$(report_floor_count "$sb/run" pt_wingspan)
    assert_contains "$(report_site_caption "$md" pt_wingspan)" "$reach" \
        "a site one step above the floor is not counted at it: $reach"
    row=$(report_site_row "$sb/run" pt_resistant chr10 1600)
    assert_contains "$row" '"G", "1",' "the planted C has the largest |t| and G the steepest slope"
    assert_contains "$md" "$row" "and the report names the steepest: $row"
}

# A TABLE CUT AT TWENTY, a sampled run, an allele table that holds three sites, and every sequence
# named for a Manhattan plot: the paths a real run takes that the corpus does not.
#
# The corpus's SNP table twice over, the copy 5,000 bases on, gives 28 sites and 26 tested: chr10:1500
# and its copy are flagged untested. A budget of 100 rearrangements cannot enumerate 720, so the
# run's floor, 1/101, parts from the design's, 1/720. reportBelow 0 and reportTop 3 leave 23 of
# the 26 with no allele rows.
test_the_report_takes_the_paths_a_real_run_takes() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-report-paths")
    association_corpus "$sb"
    local table="$CORPUS_DIR/Frequencies/Test_snp_depth.tsv"
    awk -F'\t' -v OFS='\t' 'NR == 1 { print; next }
                            { print; $2 = $2 + 5000; copy[++n] = $0 }
                            END { for (i = 1; i <= n; i++) print copy[i] }' "$table" > "$table.new" \
        && mv "$table.new" "$table"
    association_direct "$sb/run" \
        '{"phenotypes":["pt_wingspan"],"permutations":100,"dispersion":0,"fdr":"BH","reportBelow":0,"reportTop":3,"chromosomes":["chr1","chr2","chr10"],"binSize":100000,"workers":1,"usecpp":false}'
    if [ ! -s "$sb/run/association_pt_wingspan.tsv" ]; then
        fail_case "nothing published"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    analysis_render_report "$sb/run" "$sb/report" "$REPO_ROOT/modules/association/report.Rmd" md \
        || { fail_case "the report should knit: $(cat "$sb/report/report_knit.log")"; return; }
    local md; md=$(cat "$sb/report/report.md")

    assert_eq "26" "$(report_site_order "$sb/run" pt_wingspan | grep -c .)" "26 tested sites"
    assert_contains "$md" "The 20 sites of pt_wingspan with the smallest permutation p" \
        "the table says it shows twenty"
    assert_eq "$(report_site_order "$sb/run" pt_wingspan | head -20)" \
              "$(report_table_sites "$md" "sites of pt_wingspan with")" \
              "and they are the first twenty in the order its caption gives"

    local expected
    while IFS= read -r expected; do
        assert_contains "$md" "$expected" "the design table holds permutations.tsv: $expected"
    done < <(report_measures_rows "$sb/run")
    assert_contains "$(report_measures_rows "$sb/run")" '"100, sampled"' "the run sampled"
    assert_eq "0.00990" "$(awk -F'\t' "$REPORT_NUMBER_AWK"'
                            NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                            { print rnum($(h["floor"]), 3); exit }' "$sb/run/permutations.tsv")" \
              "and could report 1/101 where the design allows 1/720"

    assert_contains "$md" '"NA", "NA",' "a site the allele table does not hold shows NA"
    assert_contains "$md" "NA is a site alleles_pt_wingspan.tsv holds no row for" \
        "and the caption says what NA means"

    assert_contains "$md" "## Association along a sequence" "every named sequence is drawn"
    local at1 at2 at10
    at1=$(grep -n -F 'Association along chr1 (manhattan\_chr1\.png)' <<< "$md" | cut -d: -f1)
    at2=$(grep -n -F 'Association along chr2 (manhattan\_chr2\.png)' <<< "$md" | cut -d: -f1)
    at10=$(grep -n -F 'Association along chr10 (manhattan\_chr10\.png)' <<< "$md" | cut -d: -f1)
    if [ -z "$at1" ] || [ -z "$at2" ] || [ -z "$at10" ]; then
        fail_case "a Manhattan plot is missing its caption, the file name escaped: $at1 $at2 $at10"
    elif [ "$at1" -gt "$at2" ] || [ "$at2" -gt "$at10" ]; then
        fail_case "the Manhattan plots are in file-name order, not the tables' chr1, chr2, chr10"
    fi
    assert_eq "4" "$(grep -c '^!\[' <<< "$md")" "qq.png and three Manhattan plots are placed"
}

# THE DESIGN AND THE SCALE ARE READ BACK IN WORDS. Three units of two put the smallest p any site
# can reach at 1/6, which the report says before any site; every fit in a run shares that floor,
# as it is set by the units alone. An ordinal phenotype is read as each level's place in its order,
# so a positive slope means further along that order, not toward any one level.
test_the_report_says_what_the_design_and_the_scale_allow() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-report-scale")
    association_corpus "$sb"
    paired_design "$CORPUS_DIR/design.json" "$sb/three.json"
    association_direct "$sb/three" "$ASSOCIATION_OPTIONS" "$sb/three.json"
    analysis_render_report "$sb/three" "$sb/three-report" \
        "$REPO_ROOT/modules/association/report.Rmd" md \
        || { fail_case "the report should knit: $(cat "$sb/three-report/report_knit.log")"; return; }
    assert_contains "$(cat "$sb/three-report/report.md")" \
        "**With 3 units, the smallest p any site can reach is 0.167, above 0.05.** The sites below are a ranking of effect sizes and not a test." \
        "three units cannot reach 0.05, and the report says so first"

    python3 - "$CORPUS_DIR/design.json" "$sb/ordinal.json" <<'PY'
import json, sys
design = json.load(open(sys.argv[1]))
levels = ["low", "mid", "high"]
stage = {"TestSample1": 0, "TestSample2": 1, "TestSample3": 0,
         "TestSample4": 2, "TestSample5": 1, "TestSample6": 2}
design["phenotypes"].append({
    "column": "pt_stage", "kind": "ordinal", "levels": levels,
    "values": [{"pool": entry["pool"], "shown": levels[stage[entry["pool"]]],
                "group": stage[entry["pool"]], "value": float(stage[entry["pool"]])}
               for entry in design["pools"]]})
json.dump(design, open(sys.argv[2], "w"))
PY
    association_direct "$sb/ordinal" "${ASSOCIATION_OPTIONS/pt_wingspan/pt_stage}" "$sb/ordinal.json"
    if [ ! -s "$sb/ordinal/association_pt_stage.tsv" ]; then
        fail_case "the ordinal run published nothing"$'\n'"$(cat "$sb/ordinal/out.txt")"
        return
    fi
    analysis_render_report "$sb/ordinal" "$sb/ordinal-report" \
        "$REPO_ROOT/modules/association/report.Rmd" md \
        || { fail_case "the report should knit: $(cat "$sb/ordinal-report/report_knit.log")"; return; }
    local md; md=$(cat "$sb/ordinal-report/report.md")
    assert_contains "$md" "Each level is read as its place in the order low < mid < high, from 0" \
        "the phenotype table says how the levels were read"
    assert_contains "$md" "more frequent further along low < mid < high" \
        "and a positive slope reads along the order"
    assert_not_contains "$md" "units coded mid" "never toward the level coded 1"
}

# ONE CASE THROUGH NEXTFLOW, and it is what every other case here cannot do. The rest call the
# module's R directly, which proves the arithmetic and says nothing about main.nf - so a fault
# in how the PROCESS assembles its command survives every one of them.
#
# It survived exactly that way. `cp ${compiled} published/allele_frequencies.cpp` interpolated
# the Groovy LIST moduleCompiledFiles() returns, so the process ran `cp [/path/to/x.cpp]` and
# died on the brackets. basicstats has this case and failed on it in a full run; association did
# not have one and passed the same run with the identical line.
#
# The fixture needs a PHENOTYPE, which the shared baseline has no column for: every other
# analysis suite runs on exp_ variables alone. pt_wingspan is added here over the six pools the
# planted results were produced from.
#
# ONE VALUE PER UNIT, and the baseline's units are the three populations followed through two
# timepoints - so both rows of a population carry the same wingspan. association fits on units
# and a unit takes one value; two values on one unit is repeated measures, which it refuses by
# design and says so. Giving each row its own value is the obvious thing to write here and the
# module is right to reject it.
test_association_runs_through_the_frame() {
    analysis_ready single || return
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    analysis_write_metadata "$ANALYSIS_SB" 'SampleID,RG_Sample,RG_Library,RG_Platform,RG_PlatformUnit,exp_population,exp_time,pt_wingspan
TestSample1,TestSample1,Lib1,ILLUMINA,Unit1,Pop1,T1,10.5
TestSample2,TestSample2,Lib1,ILLUMINA,Unit1,Pop1,T2,10.5
TestSample3,TestSample3,Lib1,ILLUMINA,Unit1,Pop2,T1,13.8
TestSample4,TestSample4,Lib1,ILLUMINA,Unit1,Pop2,T2,13.8
TestSample5,TestSample5,Lib1,ILLUMINA,Unit1,Pop3,T1,16.4
TestSample6,TestSample6,Lib1,ILLUMINA,Unit1,Pop3,T2,16.4'
    # A pt_ column is RECORDED by default and becomes a phenotype only once declared with a
    # measurement scale - which is the layer working as designed, and is what a module author
    # writing this case for the first time will trip over.
    # $ANALYSIS_TIME_BLOCK is carried along because this REPLACES main/analysis.config rather
    # than adding to it, and the baseline put the timeVar declaration there - the fixture has an
    # exp_time column, and the layer refuses one it has not been told how to read.
    analysis_write_metadata_config "$ANALYSIS_SB" \
        "$ANALYSIS_TIME_BLOCK
        phenotypes { pt_wingspan { kind = 'quantitative' } }"
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    cat > "$ANALYSIS_SB/main/association.config" <<'CFG'
params {
    analysis {
        modules {
            association {
                phenotypes = ['pt_wingspan']
            }
        }
    }
}
CFG

    local status; status=$(analysis_run_module association)
    assert_status 0 "$status" "association should run; see $ANALYSIS_SB/run.out"

    local dir="$ANALYSIS_SB/main/Analysis/Results/association"
    assert_file "$dir/association_pt_wingspan.tsv" "the site table, named after its phenotype"
    assert_file "$dir/alleles_pt_wingspan.tsv" "and its allele table"
    assert_file "$dir/permutations.tsv" "the diagnostics that say what it assumed"
    assert_file "$dir/phenotype.tsv" "the phenotype as it was fitted"
    assert_file "$dir/association.R" "the script that produced them"
    # The one the bug above destroyed: a compiled source is published whether or not the run used
    # it, so its absence is a broken process rather than a choice about the hot path.
    assert_file "$dir/allele_frequencies.cpp" "the compiled parse, published either way"
    assert_contains "$(cat "$dir/association.R")" "allele_frequencies <- function" \
        "the libraries it declares must be folded into the published script"

    # association lays out its own report, and the frame knits it under its header.
    if ! have_report_tools; then
        skip_case "the analysis environment has no pandoc and typst"; return
    fi
    if ! command -v pdftotext > /dev/null 2>&1 || ! command -v pdfimages > /dev/null 2>&1; then
        skip_case "no pdftotext and pdfimages to read the report back"; return
    fi
    assert_file "$dir/report.pdf" "the report is built; see $ANALYSIS_SB/run.out"
    local text section; text=$(pdf_text "$dir/report.pdf")
    for section in "The phenotype as it was read" "What the design can show" "The strongest sites" \
                   "The p-values against the uniform"; do
        assert_contains "$text" "$section" "the report has its '$section' section"
    done
    local floor; floor=$(published_cell "$dir/permutations.tsv" pt_wingspan design_floor)
    assert_contains "$text" "$(awk -v x="$floor" "$REPORT_NUMBER_AWK"'BEGIN { print rnum(x, 3) }')" \
        "the design's floor, $floor, is printed"
    assert_eq "1" "$(pdf_figures "$dir/report.pdf")" "qq.png is placed, and no sequence was named"
    assert_eq "" "$(pdf_overlapping_words "$dir/report.pdf")" "and no word is printed over another"
    assert_eq "" "$(pdf_missing_words "$dir/report.pdf" Measure Leverage Sequence Position)" \
              "or into its neighbor"
}
