#!/bin/bash
# basicstats, against the analytic corpus its own tools build.
# cost: jvm
# covers: analysis/modules/basicstats/ analysis/lib/R/ analysis/lib/cpp/
# covers: test/tools/freq_corpus.py
# covers: analysis.nf analysis/modules/basicstats/main.nf
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and re-proving it here would
# cost minutes a case.

# Run the module's R directly over the corpus, under one set of options, into $1.
#
# Every .R in the shared library rather than the list main.nf names: they are standalone
# function definitions, so a superset is harmless, and the case then cannot go stale when that
# list changes. The Nextflow case above is what proves main.nf assembles the same thing.
basicstats_direct() {
    local dest="$1" options="$2" corpus="$3" rscript="${4:-Rscript}" bin=""
    mkdir -p "$dest"
    cat "$REPO_ROOT"/analysis/lib/R/*.R "$REPO_ROOT/analysis/modules/basicstats/basicstats.R" \
        > "$dest/basicstats.R"
    printf '%s' "$options" > "$dest/options.json"
    # An environment's R drives an environment's compiler - conda's is
    # x86_64-conda-linux-gnu-c++, which lives in that environment and nowhere else - so an R
    # named by absolute path cannot build the C++ unless its own bin is ahead on PATH. This is
    # what `conda activate` does for the wrapper, and Rcpp reports it as "tools not found".
    [ "$rscript" = "Rscript" ] || bin="$(dirname "$rscript"):"
    ( cd "$corpus/Frequencies" && PATH="${bin}$PATH" "$rscript" --vanilla "$dest/basicstats.R" \
        --design "$corpus/design.json" --pools "$corpus/pools.json" \
        --options "$dest/options.json" \
        --cpp "$REPO_ROOT/analysis/lib/cpp/site_diversity.cpp" \
        --depths 'Test_indel_depth.tsv,Test_snp_depth.tsv' \
        --histograms "$(find "$corpus/Reports/Depth" -name '*_depth_histogram.tsv' | sort | paste -sd,)" \
        --out "$dest" ) > "$dest/out.txt" 2>&1
}

# A library holding everything the user library holds except $1, for a case that needs a
# package to be absent on a machine that has it. R_LIBS_USER REPLACES the user library rather
# than adding to it, so the rest of what the module needs has to be linked back in.
r_lib_without() {
    local hide="$1" dest="$2" user entry
    user=$(Rscript --vanilla -e 'cat(Sys.getenv("R_LIBS_USER"))' 2>/dev/null)
    mkdir -p "$dest"
    [ -d "$user" ] || return 0
    for entry in "$user"/*; do
        [ -d "$entry" ] || continue
        [ "$(basename "$entry")" = "$hide" ] && continue
        ln -sfn "$entry" "$dest/$(basename "$entry")"
    done
}

# ---------------------------------------------------------------------------------------
# basicstats, which a release ships. Unlike every module above it this one is not planted by
# the case - it is in the store because the release carries it, which is also why an error in
# it stops every other case in this suite.
# The fixture is six pools of one library each, exp_population over three levels and exp_time
# over two, at the template's poolSize 100 and ploidy 2.
test_basicstats_publishes_a_row_for_every_pool() {
    analysis_ready single || return
    if ! have_r; then skip_case "no Rscript"; return; fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(analysis_run_module basicstats)
    assert_status 0 "$status" "basicstats should run; see $ANALYSIS_SB/run.out"

    local folder="$ANALYSIS_SB/main/Analysis/Results/basicstats"
    assert_file "$folder/design.tsv" "the design table is published"
    assert_file "$folder/basicstats.R" "and the script that produced it"
    assert_file "$folder/CITATIONS.md" "and what to cite for it"

    local table; table=$(cat "$folder/design.tsv" 2>/dev/null)
    assert_eq 7 "$(printf '%s\n' "$table" | wc -l)" "a header and one row per pool"
    assert_contains "$table" "pool	libraries	n_libraries	exp_population	exp_time	pool_size	ploidy	n_chrom	detection_limit" \
        "every experimental variable gets a column of its own, between the pool and its size"
    # 100 individuals at ploidy 2 is 200 chromosomes and a detection limit of 1/(2*2*100).
    assert_contains "$table" "TestSample1	TestSample1	1	Pop1	T1	100	2	200	0.0025" \
        "and each row carries the design and the figures it was produced under"
}

# THE METHODS ARE CITED, NOT ONLY THE SOFTWARE. A diversity estimate a reader cannot trace to a
# definition is one they cannot check, and the two n_eff forms in circulation differ.
test_basicstats_cites_the_statistics_it_computes() {
    analysis_ready single || return
    if ! have_r; then skip_case "no Rscript"; return; fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_run_module basicstats > /dev/null

    local folder="$ANALYSIS_SB/main/Analysis/Results/basicstats"
    local cites; cites=$(cat "$folder/CITATIONS.md" 2>/dev/null)
    assert_contains "$cites" "10.1073/pnas.70.12.3321" "Nei, for the diversity statistic"
    assert_contains "$cites" "10.1534/genetics.118.300900" "Hivert, for the effective sample size"
    assert_contains "$cites" "10.1111/mec.12522" "Ferretti, for why a pooled estimate needs correcting"
    assert_contains "$cites" "PoolSeqFlow" "beside the pipeline itself"
    assert_contains "$(cat "$folder/references.bib" 2>/dev/null)" "@article{nei1973diversity" \
        "and the BibTeX is beside it"
}

# Rule 15 asks for the script, and rule 15's gap is a driver that sources code the reader does
# not have. What is published is the shared library folded into the module's own script, so the
# functions that computed the numbers are in the file.
test_basicstats_publishes_the_library_it_computed_with() {
    analysis_ready single || return
    if ! have_r; then skip_case "no Rscript"; return; fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_run_module basicstats > /dev/null

    local script; script=$(cat "$ANALYSIS_SB/main/Analysis/Results/basicstats/basicstats.R" 2>/dev/null)
    assert_contains "$script" "n_eff <- function" "n_eff travels with the result"
    assert_contains "$script" "site_diversity <- function" "and so does gene diversity"
    assert_contains "$script" "analysis frame 2026" "under the frame version that defined them"
}

# THE WIRING, ONCE, THROUGH NEXTFLOW: the depth tables are staged, the settings reach the R,
# and the three tables it computes from them are published. The arithmetic in them is checked
# by the case below this one, which calls the same R directly and costs no JVM.
test_basicstats_publishes_what_it_measured() {
    analysis_ready single || return
    if ! have_r; then skip_case "no Rscript"; return; fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    local status; status=$(analysis_run_module basicstats)
    assert_status 0 "$status" "basicstats should run; see $ANALYSIS_SB/run.out"

    local folder="$ANALYSIS_SB/main/Analysis/Results/basicstats"
    assert_file "$folder/sites.tsv" "the site counts are published"
    assert_file "$folder/depth.tsv" "and the depth summaries"
    assert_file "$folder/diversity.tsv" "and the diversity"
    assert_file "$folder/site_diversity.cpp" "and the compiled path, used or not"

    # THE DEFAULT, END TO END. No flag was given, so the compiled path is what must have run -
    # and the published script's header is the only record of which one did.
    assert_contains "$(head -4 "$folder/basicstats.R" 2>/dev/null)" "site_diversity.cpp" \
        "a run given no flag takes the compiled path"

    # THE ORDER OF THE SEQUENCES IS THE TABLE'S, NOT R's. sort() puts chr10 between chr1 and
    # chr2, which would misorder every genome whose sequences are numbered.
    assert_eq "chr1 chr2 chr10" \
        "$(awk -F'\t' 'NR > 1 && $2 == "snp" { printf "%s%s", sep, $1; sep = " " }' \
             "$folder/sites.tsv" 2>/dev/null)" \
        "the sequences keep the order the depth table gave them"

    # One number out of each table, against the corpus's own arithmetic.
    assert_close "$(published_cell2 "$folder/sites.tsv" chr2 snp alleles)" \
        "$(corpus_expects sites.chr2.snp.alleles)" "chr2 holds a triallelic and a tetrallelic site"
    assert_close "$(published_cell2 "$folder/depth.tsv" TestSample1 chr1 depth_harmonic)" \
        "$(corpus_expects depth.TestSample1.chr1.harmonic)" "the harmonic depth on chr1"
    assert_close "$(published_cell "$folder/diversity.tsv" TestSample1 h_sum)" \
        "$(corpus_expects pool.TestSample1.h_sum)" "the diversity summed over the called sites"

    # The README the frame renders has to name every file, or a reader of the folder has no
    # account of one of them.
    local readme; readme=$(cat "$folder/README.md" 2>/dev/null)
    for name in design.tsv sites.tsv depth.tsv diversity.tsv basicstats.R site_diversity.cpp; do
        assert_contains "$readme" "\`$name\`" "the README accounts for $name"
    done
}

# EVERY NUMBER THE MODULE PUBLISHES, AGAINST ARITHMETIC DONE SOMEWHERE ELSE. The expectations
# come from plain Python loops in test/tools/freq_corpus.py that share nothing with the R, so a
# change made to both at once still fails.
test_basicstats_computes_what_the_corpus_says() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-direct")
    rm -rf "$sb"; mkdir -p "$sb"
    CORPUS_DIR="$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"

    basicstats_direct "$sb/plain" '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false}' "$sb"
    assert_file "$sb/plain/diversity.tsv" "the module should run: $(cat "$sb/plain/out.txt" 2>/dev/null)"

    local pool
    for pool in TestSample1 TestSample2 TestSample3 TestSample4 TestSample5 TestSample6; do
        assert_close "$(published_cell "$sb/plain/diversity.tsv" "$pool" h_sum)" \
            "$(corpus_expects "pool.$pool.h_sum")" "$pool: gene diversity summed over sites"
        assert_close "$(published_cell "$sb/plain/diversity.tsv" "$pool" pi_per_called_site)" \
            "$(corpus_expects "pool.$pool.pi")" "$pool: per called site"
        assert_close "$(published_cell "$sb/plain/diversity.tsv" "$pool" n_eff_harmonic)" \
            "$(corpus_expects "pool.$pool.n_eff_harmonic")" "$pool: effective sample size"
        assert_close "$(published_cell "$sb/plain/diversity.tsv" "$pool" depth_harmonic)" \
            "$(corpus_expects "pool.$pool.depth_harmonic")" "$pool: harmonic depth"
        # EVERY POOL, because what separates one segregating rule from another is which pool it
        # is wrong about. The two limbs of max(detection limit, minReads/depth) part at
        # TestSample2's 1 read in 100 and TestSample3's 3; the pool's own major allele parts
        # from the cohort's at chr2:400, where two pools hold no reference read at all.
        assert_eq "$(corpus_expects "pool.$pool.segregating")" \
            "$(published_cell "$sb/plain/diversity.tsv" "$pool" segregating)" \
            "$pool: segregating sites"
    done

    # An allele count is rows of the FREQUENCY table, not of the depth table: chr2's two SNP
    # records carry three and four alleles, so seven rows come off two sites.
    assert_eq "$(corpus_expects sites.chr2.snp.alleles)" \
        "$(published_cell2 "$sb/plain/sites.tsv" chr2 snp alleles)" \
        "an allele count is rows of the frequency table, not of the depth table"
    assert_eq "$(corpus_expects sites.chr10.indel.alleles)" \
        "$(published_cell2 "$sb/plain/sites.tsv" chr10 indel alleles)" \
        "indels are counted apart from SNPs"
    assert_eq "$(corpus_expects sites.chr1.snp.sites)" \
        "$(published_cell2 "$sb/plain/sites.tsv" chr1 snp sites)" \
        "and a site is a record however many alleles it holds"

    # THE ORDER OF THE SEQUENCES IS THE TABLE'S, NOT R's. sort() puts chr10 between chr1 and
    # chr2, which would misorder every genome whose sequences are numbered.
    assert_eq "chr1 chr2 chr10" \
        "$(awk -F'\t' 'NR > 1 && $2 == "snp" { printf "%s%s", sep, $1; sep = " " }' \
             "$sb/plain/sites.tsv")" \
        "sites.tsv keeps the order the depth table gave them"
    assert_eq "chr1 chr2 chr10" \
        "$(awk -F'\t' '$1 == "TestSample1" { printf "%s%s", sep, $2; sep = " " }' \
             "$sb/plain/depth.tsv")" \
        "and so does depth.tsv, per pool"
}

# EVERY LEVEL AND EVERY SOURCE THE DATA SUPPORTS. The histogram figures are hand-computed from
# two-bin histograms in the corpus; the called figures come off the depth table. The invariant
# between them is what a reader will check first, and it holds for a reason - the calls are
# left-censored at vcffilter.minDP where the histogram counts every covered position.
test_the_effective_size_is_reported_at_both_levels() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-neff")
    rm -rf "$sb"; mkdir -p "$sb"
    CORPUS_DIR="$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"
    basicstats_direct "$sb/run" '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false}' "$sb"
    assert_file "$sb/run/neff.tsv" "the module should run: $(cat "$sb/run/out.txt" 2>/dev/null)"

    local pool
    for pool in TestSample1 TestSample4 TestSample6; do
        local hist called
        hist=$(awk -F'\t' -v p="$pool" '$1=="library" && $2==p && $4=="histogram" {print $6}' "$sb/run/neff.tsv")
        assert_close "$hist" "$(corpus_expects "histogram.$pool.harmonic")" \
            "$pool: harmonic depth over every covered position"
        assert_close "$(awk -F'\t' -v p="$pool" '$1=="library" && $2==p && $4=="histogram" {print $8}' "$sb/run/neff.tsv")" \
            "$(corpus_expects "histogram.$pool.n_eff")" "$pool: and what it is worth"

        # A pool of one library has nothing to add, so its pool row is exact and equals the
        # library row - which is what makes a merged pool's row visibly different.
        assert_eq "exact" \
            "$(awk -F'\t' -v p="$pool" '$1=="pool" && $2==p && $4=="histogram" {print $9}' "$sb/run/neff.tsv")" \
            "$pool: one library is not a bound"

        # THE INVARIANT. Called sites carry at least vcffilter.minDP reads in every sample by
        # construction, so their harmonic depth cannot be below the genome-wide one.
        called=$(awk -F'\t' -v p="$pool" '$1=="pool" && $2==p && $4=="called" {print $6}' "$sb/run/neff.tsv")
        awk -v a="$called" -v b="$hist" 'BEGIN { exit !(a > b) }' \
            || fail_case "$pool: the called depth ($called) must exceed the genome-wide one ($b)"
    done

    assert_eq "" \
        "$(awk -F'\t' '$1=="library" && $4=="called"' "$sb/run/neff.tsv")" \
        "there is no per-library row from the called sites: the tables are per pool"
}

# A MERGED POOL, where the two levels are genuinely different and the pool figure is a bound.
# The corpus's --merged layout is three pools of two libraries: the depth table is named by
# RG_Sample and the histograms by SampleID, which is the only shape that separates them.
test_a_merged_pool_reports_a_bound() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-merged")
    rm -rf "$sb"; mkdir -p "$sb"
    CORPUS_DIR="$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb" --merged
    basicstats_direct "$sb/run" '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false}' "$sb"
    assert_file "$sb/run/neff.tsv" "the module should run: $(cat "$sb/run/out.txt" 2>/dev/null)"

    # Both libraries appear under their pool, and the pool figure is their harmonic means added.
    assert_eq "TestSample1 TestSample2" \
        "$(awk -F'\t' '$1=="library" && $3=="PoolA" {printf "%s%s", sep, $2; sep=" "}' "$sb/run/neff.tsv")" \
        "a merged pool lists the libraries that went into it"
    assert_close "$(awk -F'\t' '$1=="pool" && $2=="PoolA" && $4=="histogram" {print $6}' "$sb/run/neff.tsv")" \
        "$(corpus_expects merged.PoolA.harmonic)" "PoolA: 40 + 60, the parts' harmonic means added"
    assert_close "$(awk -F'\t' '$1=="pool" && $2=="PoolA" && $4=="histogram" {print $8}' "$sb/run/neff.tsv")" \
        "$(corpus_expects merged.PoolA.n_eff)" "PoolA: and the effective size that gives"

    # THE LABEL IS THE POINT. A number a reader takes for a measurement, when it is a bound,
    # is the failure this column exists to prevent.
    local pool
    for pool in PoolA PoolB PoolC; do
        assert_eq "lower_bound" \
            "$(awk -F'\t' -v p="$pool" '$1=="pool" && $2==p && $4=="histogram" {print $9}' "$sb/run/neff.tsv")" \
            "$pool: a merged pool's genome-wide figure says it is a bound"
        assert_eq "exact" \
            "$(awk -F'\t' -v p="$pool" '$1=="pool" && $2==p && $4=="called" {print $9}' "$sb/run/neff.tsv")" \
            "$pool: while the called-site figure is measured directly"
    done
}

# A PLOT ONLY FOR WHAT YOU NAMED. The default draws nothing, which is the behaviour a genome
# with hundreds of scaffolds needs; the run has to say what it could have drawn instead, or the
# setting is undiscoverable.
test_a_depth_plot_is_drawn_only_for_named_sequences() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    if ! have_r_package ggplot2; then skip_case "no ggplot2"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-plots")
    rm -rf "$sb"; mkdir -p "$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"

    basicstats_direct "$sb/none" \
        '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false,"chromosomes":[]}' "$sb"
    assert_eq "0" "$(find "$sb/none" -name 'depth_*.png' | wc -l)" \
        "nothing is drawn until a sequence is named"
    local said; said=$(cat "$sb/none/out.txt" 2>/dev/null)
    assert_contains "$said" "chr1 (3 called SNP sites)" "and the candidates are listed to copy from"
    assert_contains "$said" "chr10 (2 called SNP sites)" "every one of them, chr10 included"

    basicstats_direct "$sb/two" \
        '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false,"chromosomes":["chr1","chr10"]}' "$sb"
    assert_file "$sb/two/depth_chr1.png" "a named sequence gets a plot"
    assert_file "$sb/two/depth_chr10.png" "each named sequence, not just the first"
    assert_no_file "$sb/two/depth_chr2.png" "and no others"

    # A sequence with no called site is invisible in the published tables and cannot be told
    # from one the reference does not have, so an empty plot would assert something the data
    # does not say.
    basicstats_direct "$sb/bad" \
        '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false,"chromosomes":["chrZ"]}' "$sb"
    assert_eq "0" "$(find "$sb/bad" -name 'depth_*.png' | wc -l)" "an unknown sequence draws nothing"
    assert_contains "$(cat "$sb/bad/out.txt" 2>/dev/null)" "It has: chr1, chr2, chr10" \
        "and the refusal names what the tables do hold"
}

# BOTH IMPLEMENTATIONS AND EVERY BIN SIZE GIVE ONE ANSWER. The compiled path and the bins exist
# to make a large genome finish, and either is worthless if it moves a number: sites are
# independent, so a bin boundary must be invisible, and the C++ is judged against the R.
test_every_path_through_the_hot_loop_agrees() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-paths")
    rm -rf "$sb"; mkdir -p "$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"

    basicstats_direct "$sb/ref" '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false}' "$sb"
    assert_file "$sb/ref/diversity.tsv" "the reference run: $(cat "$sb/ref/out.txt" 2>/dev/null)"

    local name options
    for name in bins1 bins3; do
        case $name in
            bins1) options='{"minReads":2,"binSize":1,"workers":1,"usecpp":false}' ;;
            bins3) options='{"minReads":2,"binSize":3,"workers":1,"usecpp":false}' ;;
        esac
        basicstats_direct "$sb/$name" "$options" "$sb"
        assert_eq "" "$(diff "$sb/ref/diversity.tsv" "$sb/$name/diversity.tsv" 2>&1)" \
            "$name: a bin boundary must not move a number"
        assert_eq "" "$(diff "$sb/ref/depth.tsv" "$sb/$name/depth.tsv" 2>&1)" \
            "$name: nor a depth summary"
    done

    # Rcpp needs a compiler, which is not shipped and is not on every machine.
    if ! have_rcpp; then skip_case "no Rcpp and compiler"; return; fi
    basicstats_direct "$sb/cpp" '{"minReads":2,"binSize":4,"workers":1,"usecpp":true}' "$sb"
    assert_eq "" "$(diff "$sb/ref/diversity.tsv" "$sb/cpp/diversity.tsv" 2>&1)" \
        "the compiled path must agree with the R it replaces: $(cat "$sb/cpp/out.txt" 2>/dev/null)"
    assert_eq "" "$(diff "$sb/ref/depth.tsv" "$sb/cpp/depth.tsv" 2>&1)" \
        "on the depth summaries too"
    assert_contains "$(cat "$sb/cpp/out.txt" 2>/dev/null)" "compiled path" \
        "and it says which path it took"
}

# THE PARALLEL PATH, in the environment that carries doFuture. Sites are independent, so a bin
# handed to another process must give exactly what one process gives; a difference here is the
# loop carrying state between bins that it should not.
test_the_parallel_path_agrees_with_the_sequential_one() {
    local rscript; rscript=$(analysis_rscript)
    if [ -z "$rscript" ]; then skip_case "no analysis environment"; return; fi
    if ! have_analysis_r_package doFuture; then skip_case "no doFuture"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-parallel")
    rm -rf "$sb"; mkdir -p "$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"

    basicstats_direct "$sb/one" \
        '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false}' "$sb" "$rscript"
    assert_file "$sb/one/diversity.tsv" \
        "the sequential reference: $(cat "$sb/one/out.txt" 2>/dev/null)"
    basicstats_direct "$sb/many" \
        '{"minReads":2,"binSize":2,"workers":2,"usecpp":false}' "$sb" "$rscript"
    assert_eq "" "$(diff "$sb/one/diversity.tsv" "$sb/many/diversity.tsv" 2>&1)" \
        "two workers must give what one gives: $(cat "$sb/many/out.txt" 2>/dev/null)"
    assert_eq "" "$(diff "$sb/one/depth.tsv" "$sb/many/depth.tsv" 2>&1)" \
        "on the depth summaries too"
    assert_contains "$(cat "$sb/many/out.txt" 2>/dev/null)" "2 workers" \
        "and it says how the work was divided"
}

# WORKERS AND usecpp TOGETHER, which is the combination that breaks on its own. A compiled
# function cannot be sent to a worker process, so each one has to source the C++ for itself the
# first time it is asked - and the failure is a worker erroring, not a wrong number.
test_a_worker_compiles_the_hot_path_for_itself() {
    local rscript; rscript=$(analysis_rscript)
    if [ -z "$rscript" ]; then skip_case "no analysis environment"; return; fi
    if ! have_analysis_r_package doFuture; then skip_case "no doFuture"; return; fi
    if ! have_analysis_r_package Rcpp; then skip_case "no Rcpp in the analysis environment"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-parallel-cpp")
    rm -rf "$sb"; mkdir -p "$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"

    basicstats_direct "$sb/one" \
        '{"minReads":2,"binSize":100000,"workers":1,"usecpp":false}' "$sb" "$rscript"
    basicstats_direct "$sb/manycpp" \
        '{"minReads":2,"binSize":2,"workers":2,"usecpp":true}' "$sb" "$rscript"
    assert_file "$sb/manycpp/diversity.tsv" \
        "the compiled path must survive being handed to a worker: $(cat "$sb/manycpp/out.txt" 2>/dev/null)"
    assert_eq "" "$(diff "$sb/one/diversity.tsv" "$sb/manycpp/diversity.tsv" 2>&1)" \
        "and give what the vectorised R in one process gives"
}

# A parallel run needs doFuture, and the module must say so rather than dropping to one worker:
# a run that quietly took a different path is a run whose timings mean nothing.
#
# doFuture is hidden rather than assumed absent. Gating on whether the machine happens to have
# it makes the case skip on every properly provisioned one - which is every machine that would
# ever run it - and the refusal would then be tested nowhere.
test_basicstats_refuses_workers_it_cannot_use() {
    if ! have_r; then skip_case "no Rscript"; return; fi
    local sb; sb=$(guard_path "$TEST_TMPDIR/basicstats-workers")
    rm -rf "$sb"; mkdir -p "$sb"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$sb" "$sb"
    r_lib_without doFuture "$sb/nolib"

    local saved="${R_LIBS_USER-}"
    export R_LIBS_USER="$sb/nolib"
    basicstats_direct "$sb/many" '{"minReads":2,"binSize":2,"workers":4,"usecpp":false}' "$sb"
    if [ -n "$saved" ]; then export R_LIBS_USER="$saved"; else unset R_LIBS_USER; fi

    assert_no_file "$sb/many/diversity.tsv" "nothing is published when the run cannot go parallel"
    assert_contains "$(cat "$sb/many/out.txt" 2>/dev/null)" "doFuture is not installed" \
        "and it names the package it wanted"
    assert_contains "$(cat "$sb/many/out.txt" 2>/dev/null)" "set workers to 1" \
        "and says what to do instead"
}
