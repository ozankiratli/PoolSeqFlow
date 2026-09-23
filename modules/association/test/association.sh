#!/bin/bash
# association, against the analytic corpus its own tools build.
# cost: jvm
# covers: modules/association/ modules/lib/
# covers: test/tools/freq_corpus.py
# covers: analysis.nf modules/association/main.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
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

# One cell of the site table, found by position rather than by column number.
site_cell() {
    awk -F'\t' -v c="$2" -v p="$3" -v col="$4" '
        NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
        $(h["chrom"]) == c && $(h["pos"]) == p { print $(h[col]); exit }' "$1"
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
# support: four units allow 24 rearrangements and a floor of 2/24, and sampling 150 draws from
# them reaches under 0.05 by luck alone. Six units allow 720, so a budget above that must be
# spent enumerating and the reported count must be exactly 720.
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

# The two floors, which are different numbers and are both owed to a reader, and the diagnostics
# beside them.
#
# `floor` is the smallest p this RUN could report; `design_floor` is the smallest the DESIGN can
# reach by rearrangement at all - two over the units factorial, because reversing the phenotype
# negates every slope and leaves the statistic alone, so the reversal always ties.
test_both_floors_and_the_diagnostics_are_published() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-floors")
    association_corpus "$sb"
    association_direct "$sb/run" "$ASSOCIATION_OPTIONS"
    assert_close "$(published_cell "$sb/run/permutations.tsv" pt_wingspan design_floor)" \
                 "0.00277777777777778" "the design floor is 2/720 and not 1/720"
    local column
    for column in dispersion depth_phenotype_cor lambda_gc arity_mean; do
        [ -n "$(published_cell "$sb/run/permutations.tsv" pt_wingspan "$column")" ] \
            || fail_case "permutations.tsv has no $column: a guard that passes tells nobody anything"
    done
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
    python3 - "$CORPUS_DIR/design.json" "$sb/paired.json" <<'PY'
import json, sys
design = json.load(open(sys.argv[1]))
pools = [entry["pool"] for entry in design["pools"]]
design["units"] = [
    {"label": "U%d" % (i + 1), "key": {"exp_population": "Pop%d" % (i + 1)},
     "pools": pools[2 * i:2 * i + 2], "members": pools[2 * i:2 * i + 2]}
    for i in range(len(pools) // 2)]
# The phenotype has to agree inside a unit or the module refuses, which is the next case.
for entry in design["phenotypes"]:
    for i, value in enumerate(entry["values"]):
        value["value"] = entry["values"][2 * (i // 2)]["value"]
json.dump(design, open(sys.argv[2], "w"))
PY
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

# The compiled parse and the R one are the same table or one of them is wrong.
test_both_paths_through_the_parse_agree() {
    if ! have_analysis_r; then skip_case "no analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/assoc-paths")
    association_corpus "$sb"
    association_direct "$sb/plain" "$ASSOCIATION_OPTIONS"
    association_direct "$sb/compiled" "${ASSOCIATION_OPTIONS/\"usecpp\":false/\"usecpp\":true}"
    if [ ! -s "$sb/compiled/association.tsv" ]; then
        skip_case "the compiled path did not build: $(tail -3 "$sb/compiled/out.txt")"
        return
    fi
    diff -q "$sb/plain/association.tsv" "$sb/compiled/association.tsv" >/dev/null \
        || fail_case "the compiled parse and the R parse published different site tables"
    diff -q "$sb/plain/association_alleles.tsv" "$sb/compiled/association_alleles.tsv" \
        >/dev/null \
        || fail_case "the compiled parse and the R parse published different allele tables"
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
