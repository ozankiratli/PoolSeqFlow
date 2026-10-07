#!/bin/bash
# association, against the analytic corpus its own tools build.
# cost: jvm
# env: analysis
# covers: modules/association/ modules/lib/
# covers: test/tools/freq_corpus.py
# covers: analysis.nf modules/association/main.nf
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

# Run the module's R directly over the corpus, under one set of options, into $1.
#
# Every library's .R rather than the list the manifest names: they are standalone function
# definitions, so a superset is harmless, and the case then cannot go stale when that list
# changes. The Nextflow case is what proves main.nf assembles the same thing, and 00_static is
# what proves the manifest declares exactly what the module calls.
association_direct() {
    local dest="$1" options="$2" design="${3:-}"
    mkdir -p "$dest"
    [ -n "$design" ] || design="$CORPUS_DIR/design.json"
    cat "$REPO_ROOT"/modules/lib/*/*.R \
        "$REPO_ROOT/modules/association/association.R" > "$dest/association.R"
    printf '%s' "$options" > "$dest/options.json"
    ( cd "$CORPUS_DIR/Frequencies" && "$(analysis_rscript)" --vanilla "$dest/association.R" \
        --design "$design" --pools "$CORPUS_DIR/pools.json" \
        --options "$dest/options.json" \
        --cpp "$REPO_ROOT/modules/lib/allele_frequencies/allele_frequencies.cpp" \
        --depths 'Test_snp_depth.tsv' --out "$dest" ) > "$dest/out.txt" 2>&1
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
            assert_close "$(site_cell "$run/association.tsv" "$chrom" "$pos" "$column")" \
                         "$(oracle_value "$oracle" "assoc.$chrom.$pos.$column")" \
                         "$chrom:$pos: $column against the oracle"
        done
    done < <(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                         { print $(h["chrom"]) "\t" $(h["pos"]) }' "$run/association.tsv")
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
        sites="$sb/${prefix}/association.tsv"
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
    assert_close "$(site_cell "$sb/run/association.tsv" chr1 700 perm_p)" \
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
    if [ ! -s "$sb/run/association.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi

    local site chrom pos read
    for site in chr1:100:6 chr1:250:5 chr2:250:5 chr1:700:4 chr2:100:3 chr10:500:2 chr1:400:1 \
                chr2:400:1; do
        IFS=: read -r chrom pos read <<< "$site"
        assert_eq "$read" "$(site_cell "$sb/run/association.tsv" "$chrom" "$pos" n_observed)" \
                  "$chrom:$pos is read in $read units"
    done
    agrees_with_oracle "$sb/run" "$sb/oracle.tsv" S perm_p fdr_p mean_weight max_leverage
    assert_eq "NA" "$(site_cell "$sb/run/association.tsv" chr10 500 fdr_p)" \
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
                    "$sb/run/association.tsv")" \
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
    if [ ! -s "$sb/run/association.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    assert_eq "3" "$(site_cell "$sb/run/association.tsv" chr1 700 n_observed)" \
              "U1 is still read at chr1:700 through TestSample1"
    assert_eq "2" "$(site_cell "$sb/run/association.tsv" chr2 550 n_observed)" \
              "U2 is not read at chr2:550, where both of its pools were emptied"
    local stat; stat=$(site_cell "$sb/run/association.tsv" chr1 700 S)
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
        if [ ! -s "$sb/$run/association.tsv" ]; then
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
        assert_eq "3" "$(site_cell "$sb/flat/association.tsv" "$chrom" "$pos" n_observed)" \
                  "$chrom:$pos is read in three units that share a wingspan"
        for column in S perm_p fdr_p max_leverage zero_variance; do
            assert_eq "NA" "$(site_cell "$sb/flat/association.tsv" "$chrom" "$pos" "$column")" \
                      "$chrom:$pos has no spread in the phenotype, so no $column"
        done
        assert_eq "1" "$(site_cell "$sb/alone/association.tsv" "$chrom" "$pos" n_observed)" \
                  "$chrom:$pos is read in TestSample1 alone"
    done <<< "$sites"
    assert_eq "NA" "$(published_cell "$sb/alone/permutations.tsv" pt_wingspan dispersion)" \
              "no site read in two units leaves theta unestimated"
    agrees_with_oracle "$sb/alone" "$sb/oracle.tsv" mean_weight
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
    if [ ! -s "$sb/run/association.tsv" ]; then
        fail_case "the run published nothing"$'\n'"$(cat "$sb/run/out.txt")"
        return
    fi
    for pos in 213 341 399; do
        assert_close "$(site_cell "$sb/run/association.tsv" chr3 "$pos" perm_p)" \
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
    [ -s "$sb/run/association.tsv" ] \
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
    if [ ! -s "$sb/compiled/association.tsv" ]; then
        fail_case "the compiled path did not build: $(tail -3 "$sb/compiled/out.txt")"
        return
    fi
    diff -q "$sb/plain/association.tsv" "$sb/compiled/association.tsv" >/dev/null \
        || fail_case "the compiled parse and the R parse published different site tables"
    diff -q "$sb/plain/association_alleles.tsv" "$sb/compiled/association_alleles.tsv" \
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
    assert_file "$dir/association.tsv" "the site table"
    assert_file "$dir/permutations.tsv" "the diagnostics that say what it assumed"
    assert_file "$dir/phenotype.tsv" "the phenotype as it was fitted"
    assert_file "$dir/association.R" "the script that produced them"
    # The one the bug above destroyed: a compiled source is published whether or not the run used
    # it, so its absence is a broken process rather than a choice about the hot path.
    assert_file "$dir/allele_frequencies.cpp" "the compiled parse, published either way"
    assert_contains "$(cat "$dir/association.R")" "allele_frequencies <- function" \
        "the libraries it declares must be folded into the published script"
}
