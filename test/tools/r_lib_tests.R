#!/usr/bin/env Rscript
#
# Unit tests for analysis/lib/R/, run by a bare Rscript against whatever R is on the machine.
#
#     r_lib_tests.R <library directory> [section]
#
# Every expected value below is hand-computed and written out in the comment beside it, so a
# case that starts failing says which arithmetic changed rather than which number moved.
# Sections are named for the function they cover; without one, all of them run.
#
# Base R only, like the library itself. Exits 1 on the first failure of the section.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: r_lib_tests.R <library directory> [section]")
lib <- args[1]
section <- if (length(args) > 1) args[2] else "all"

sources <- list.files(lib, pattern = "[.]R$", full.names = TRUE)
if (length(sources) == 0) stop("no R sources in ", lib)
for (path in sources) source(path)

RAN <- 0
FAILED <- character(0)

check <- function(label, got, want, tol = 1e-9) {
    RAN <<- RAN + 1
    if (is.na(want) && is.na(got)) return(invisible(NULL))
    if (is.na(want) != is.na(got) || (!is.na(want) && abs(got - want) > tol)) {
        FAILED <<- c(FAILED, sprintf("%s: expected %s, got %s", label, format(want), format(got)))
    }
    invisible(NULL)
}

refuses <- function(label, expr) {
    RAN <<- RAN + 1
    if (!inherits(try(expr, silent = TRUE), "try-error")) {
        FAILED <<- c(FAILED, sprintf("%s: should have stopped and did not", label))
    }
    invisible(NULL)
}

# For a refusal whose MESSAGE is the point. Bad input often stops R somewhere further down of
# its own accord, and refuses() cannot tell that from a check that named the problem: deleting
# the raggedness refusal in allele_frequencies() leaves R saying "incorrect length for 'group'",
# which passes refuses() and tells a user nothing.
refuses_with <- function(label, pattern, expr) {
    RAN <<- RAN + 1
    caught <- try(expr, silent = TRUE)
    if (!inherits(caught, "try-error")) {
        FAILED <<- c(FAILED, sprintf("%s: should have stopped and did not", label))
    } else if (!grepl(pattern, as.character(caught), fixed = TRUE)) {
        FAILED <<- c(FAILED, sprintf("%s: stopped without saying '%s': %s",
                                     label, pattern, trimws(as.character(caught))))
    }
    invisible(NULL)
}

wanted <- function(name) section == "all" || section == name

# ---------------------------------------------------------------------------------------

if (wanted("harmonic_mean")) {
    # 3 / (1/1 + 1/2 + 1/4) = 3 / 1.75
    check("harmonic mean of 1, 2, 4", harmonic_mean(c(1, 2, 4)), 3 / 1.75)
    # 4 / (3/10 + 1/20) = 4 / 0.35
    check("weighted", harmonic_mean(c(10, 20), c(3, 1)), 4 / 0.35)

    # THE PROPERTY THE WEIGHTS EXIST FOR. A depth histogram is one row per depth and a count of
    # the positions at it, so weighting must give exactly what expanding it back out would.
    check("a weight is a repeat",
          harmonic_mean(c(10, 20), c(3, 1)),
          harmonic_mean(c(10, 10, 10, 20)))

    check("NA drops its pair", harmonic_mean(c(4, NA, 4)), 4)
    check("a position with no reads carries none", harmonic_mean(c(10, 0)), 0)
    check("nothing to average", harmonic_mean(numeric(0)), NA_real_)
    refuses("a negative depth", harmonic_mean(c(10, -1)))
}

if (wanted("n_eff")) {
    # 200 * 50 / (200 + 50 - 1) = 10000 / 249
    check("100 diploids at depth 50", n_eff(200, 50), 10000 / 249)
    # 2 * 2 / (2 + 2 - 1) = 4/3
    check("one diploid at depth 2", n_eff(2, 2), 4 / 3)

    # BOTH LIMITS. Unlimited depth can only ever be worth the pool; an unlimited pool can only
    # ever be worth the reads.
    check("depth cannot beat the pool", n_eff(200, 1e12), 200, tol = 1e-3)
    check("the pool cannot beat the depth", n_eff(1e12, 50), 50, tol = 1e-3)

    # A single chromosome is worth one however deeply it is read - which is why the module
    # refuses that pool rather than dividing by n_eff - 1.
    check("one chromosome", n_eff(1, 10), 1)

    check("no reads is not zero information, it is none", n_eff(200, 0), NA_real_)
    refuses("a pool of no chromosomes", n_eff(0, 10))
    refuses("a negative depth", n_eff(200, -1))
}

if (wanted("pool_n_eff")) {
    # 1 / (1/200 + (1 - 1/200)/50) = 1 / (0.005 + 0.0199)
    check("100 diploids, harmonic depth 50", pool_n_eff(200, 50), 1 / (0.005 + 0.995 / 50))

    # THE COLLAPSE IS EXACT, NOT AN APPROXIMATION. 1/n_eff is linear in 1/depth, so over a
    # single depth the two-number form and the per-site form are the same number.
    check("one depth, one answer", pool_n_eff(200, 50), n_eff(200, 50))
    check("and again at another depth", pool_n_eff(64, 12), n_eff(64, 12))

    check("depth cannot beat the pool", pool_n_eff(200, 1e12), 200, tol = 1e-3)
    check("the pool cannot beat the depth", pool_n_eff(1e12, 50), 50, tol = 1e-3)
    check("no reads", pool_n_eff(200, 0), NA_real_)
    refuses("a pool of no chromosomes", pool_n_eff(0, 10))
}

if (wanted("pool_sensitivity")) {
    # The manual's own table, which the false-positive filter computes the same way in awk.
    check("10 diploids", pool_sensitivity(2, 10), 0.025)
    check("25 diploids", pool_sensitivity(2, 25), 0.01)
    check("50 diploids", pool_sensitivity(2, 50), 0.005)
    check("100 diploids", pool_sensitivity(2, 100), 0.0025)
    check("200 diploids", pool_sensitivity(2, 200), 0.00125)
    # Ploidy is not assumed. A haploid pool of 100 detects twice as high a frequency.
    check("100 haploids", pool_sensitivity(1, 100), 0.005)
    refuses("no individuals", pool_sensitivity(2, 0))
}

if (wanted("site_diversity")) {
    # ONE SITE AT A TIME, which is the shape site_diversity() replaced and which survives here
    # as the oracle rather than in the library. It is three lines and correct by inspection;
    # the vectorised form is not, and that asymmetry is the whole reason to keep it.
    per_site <- function(cell) {
        counts <- split_counts(cell)
        total <- sum(counts)
        if (!is.finite(total) || total <= 0) return(NA_real_)
        p <- counts / total
        1 - sum(p * p)
    }

    # THE CASE THE VECTORISED FORM EXISTS TO GET WRONG. 1 - sum(p^2) sums over the ALLELES of a
    # site; summing over sites instead collapses these answers into one number, and every arity
    # below contributes a different count of terms to the grouping.
    cells <- c("50,50", "40,40,20", "25,25,25,25", "100,0", "70,30")
    got <- site_diversity(cells)
    check("one answer per site, not one for the lot", length(got$h), length(cells))
    for (i in seq_along(cells)) {
        check(sprintf("site %d agrees with one site at a time", i), got$h[i], per_site(cells[i]))
        check(sprintf("site %d depth is the row sum", i),
              got$depth[i], sum(split_counts(cells[i])))
    }

    # RAGGED AND RANDOM, where the oracle earns its place: a fixed list of cells is covered by
    # the literals below, and only arities in a shuffled order catch a grouping that happens to
    # be right on the cases someone thought to write down. Seeded, so a failure reproduces.
    set.seed(20260904)
    many <- vapply(seq_len(500), function(i) {
        paste(sample(0:400, sample(2:4, 1), replace = TRUE), collapse = ",")
    }, "")
    check("500 mixed-arity sites agree, one by one",
          max(abs(site_diversity(many)$h - vapply(many, per_site, 0)), na.rm = TRUE), 0)

    # The values themselves, hand-computed, so a change to the vectorised form and the oracle
    # at once still fails.
    check("an even biallelic site", got$h[1], 0.5)
    # 2p(1-p) is what H reduces to on two alleles, and the reason it is not written that way is
    # that it cannot be written that way on three.
    check("and it is 2p(1-p) there", got$h[5], 2 * 0.7 * 0.3)
    # 1 - (0.16 + 0.16 + 0.04)
    check("a triallelic site", got$h[2], 0.64)
    # 1 - 4 * 0.25^2. Higher than any biallelic site, which is the whole point: the
    # product-of-frequencies shape scored this LOWER than an even biallelic one.
    check("a tetrallelic site", got$h[3], 0.75)
    check("a fixed site", got$h[4], 0)

    # THE HALF-SCALE IDENTITY, on the worked example the design was settled with.
    # Alleles at 0.5, 0.2, 0.3: sum over i<j of p_i*p_j = 0.10 + 0.15 + 0.06 = 0.31, and
    # H = 1 - (0.25 + 0.04 + 0.09) = 0.62.
    check("H is twice the pairwise sum", site_diversity("50,20,30")$h, 2 * 0.31)
    # 1 - 3*(1/3)^2
    check("three alleles at a third each", site_diversity("10,10,10")$h, 2 / 3)
    check("counts need not be frequencies",
          site_diversity("7,3")$h, site_diversity("70,30")$h)

    # A cell of zeroes is depth 0, and no frequency exists there to weight.
    empty <- site_diversity(c("30,10", "0,0", "20,20"))
    check("no reads is no diversity", empty$h[2], NA_real_)
    check("no reads is depth zero", empty$depth[2], 0)
    check("its neighbours are untouched", empty$h[3], 0.5)

    # bcftools' missing value takes the site with it rather than counting as zero reads.
    missing <- site_diversity(c("30,10", "30,."))
    check("a missing count", missing$h[2], NA_real_)
    check("the site before it", missing$h[1], 0.375)

    check("no sites at all", length(site_diversity(character(0))$h), 0)
}

if (wanted("allele_frequencies")) {
    # THE WORKED EXAMPLE THE FUNCTION'S OWN COMMENT PRINTS, checked value by value. Two pools
    # over a biallelic site and a triallelic one, so the shapes differ between the two rows.
    got <- allele_frequencies(list(A = c("50,50", "40,40,20"),
                                   B = c("30,10", "10,10,10")))

    # ONE ROW PER SITE IN `depth` AND ONE PER ALLELE IN `freq`, which is the whole reason the
    # site index is returned: the two tables are different lengths and are read together.
    check("two sites of depth", nrow(got$depth), 2)
    check("five allele rows", nrow(got$freq), 5)
    check("the site index is one per allele row", length(got$site), 5)
    check("the first site is biallelic", got$alleles[1], 2)
    check("the second is triallelic", got$alleles[2], 3)
    check("allele row 2 belongs to site 1", got$site[2], 1)
    check("allele row 3 belongs to site 2", got$site[3], 2)

    check("A is 100 deep at site 1", got$depth[1, "A"], 100)
    check("B is 40 deep at site 1", got$depth[1, "B"], 40)
    check("B is 30 deep at site 2", got$depth[2, "B"], 30)
    check("A's REF at site 1", got$freq[1, "A"], 0.5)
    check("B's REF at site 1", got$freq[1, "B"], 0.75)
    check("B's ALT at site 1", got$freq[2, "B"], 0.25)
    check("A's second ALT at site 2", got$freq[5, "A"], 0.2)
    check("B's third allele at site 2", got$freq[5, "B"], 1 / 3)

    # THE PROPERTY EVERY CONSUMER LEANS ON. The k frequencies of a site sum to 1, which is what
    # makes a site k - 1 free tests rather than k. Summed with the site index, so a grouping
    # that ran over sites instead of over a site's alleles gives 2 here and not 1.
    for (pool in c("A", "B")) {
        sums <- as.vector(rowsum(got$freq[, pool], got$site, reorder = FALSE))
        check(sprintf("%s's site 1 sums to one", pool), sums[1], 1)
        check(sprintf("%s's site 2 sums to one", pool), sums[2], 1)
    }

    # The two library functions must not disagree about what a depth is: one is what a module
    # weights by and the other is what it corrects diversity with.
    one <- c("50,50", "40,40,20", "25,25,25,25", "0,0", "70,30")
    check("depth agrees with site_diversity, site by site",
          max(abs(allele_frequencies(list(one))$depth[, 1] - site_diversity(one)$depth)), 0)

    # ONE ALT LIST SERVES EVERY POOL, so a site whose cells differ in length is not the table
    # this reads. Refused rather than recycled: R would recycle the shorter one silently.
    # ON THE MESSAGE, because R stops on a ragged row by itself a few lines later and says
    # "incorrect length for 'group'". The site and the two pools are what makes the refusal
    # worth writing, so that is what is asserted.
    refuses_with("a site with three counts in one pool and two in another", "at site 2",
                 allele_frequencies(list(A = c("50,50", "40,40,20"), B = c("30,10", "10,10"))))
    refuses_with("columns of different lengths", "the same table read down the same rows",
                 allele_frequencies(list(A = c("50,50", "40,60"), B = "30,10")))
    refuses("no pools at all", allele_frequencies(list()))

    # AN EMPTY CELL, WHICH IS THE ONE THAT DOES NOT ANNOUNCE ITSELF. It contributes no allele
    # row, so rowsum() returns one total fewer than there are sites and every depth below moves
    # up a row: with A = c("", "40,60") site 1 reported a depth of 100 that belonged to site 2.
    # Nothing was NA and nothing was ragged - both rows were simply wrong.
    refuses_with("an empty cell", "has no counts at site 1",
                 allele_frequencies(list(A = c("", "40,60"))))
    refuses_with("an empty cell further down", "has no counts at site 2",
                 allele_frequencies(list(A = c("40,60", ""), B = c("10,10", "20,20"))))

    # A pool with no reads at a site has a depth of zero and no frequency. 0/0 would be NaN and
    # a floor at zero would read as "we observed p = 0", which is not what an empty cell says.
    empty <- allele_frequencies(list(A = c("30,10", "0,0", "20,20")))
    check("no reads is depth zero", empty$depth[2, 1], 0)
    check("and no frequency", empty$freq[3, 1], NA_real_)
    check("its neighbours are untouched", empty$freq[5, 1], 0.5)

    # bcftools' missing value takes that pool's whole site with it, as it does in
    # site_diversity(): a site is not partly observed for a pool.
    missing <- allele_frequencies(list(A = c("30,10", "30,.")))
    check("a missing count is a missing depth", missing$depth[2, 1], NA_real_)
    check("and no frequency for either allele", missing$freq[3, 1], NA_real_)
    check("nor for the allele beside it", missing$freq[4, 1], NA_real_)
    check("the site before it stands", missing$freq[1, 1], 0.75)

    # ONE POOL'S MISSING SITE IS ITS OWN. A module drops that pool from the fit at that row and
    # reduces n; taking the site out for everybody would be a different filter entirely.
    partial <- allele_frequencies(list(A = c("30,10", "30,."), B = c("50,50", "20,20")))
    check("the other pool still has its depth", partial$depth[2, "B"], 40)
    check("and its frequency", partial$freq[3, "B"], 0.5)

    # RAGGED AND RANDOM, against one site at a time. A fixed list of cells is covered by the
    # literals above; only arities in a shuffled order catch a grouping that happens to be
    # right on the cases someone thought to write down. Seeded, so a failure reproduces.
    per_site_freq <- function(cell) {
        counts <- split_counts(cell)
        total <- sum(counts)
        if (!is.finite(total) || total <= 0) return(rep(NA_real_, length(counts)))
        counts / total
    }
    set.seed(20260906)
    arity <- sample(2:4, 500, replace = TRUE)
    many <- lapply(1:2, function(pool) vapply(arity, function(k) {
        paste(sample(0:400, k, replace = TRUE), collapse = ",")
    }, ""))
    wide <- allele_frequencies(many)
    for (pool in 1:2) {
        oracle <- unlist(lapply(many[[pool]], per_site_freq), use.names = FALSE)
        check(sprintf("pool %d: 500 mixed-arity sites agree, one by one", pool),
              max(abs(wide$freq[, pool] - oracle), na.rm = TRUE), 0)
        check(sprintf("pool %d: and the same rows are missing", pool),
              identical(is.na(wide$freq[, pool]), is.na(oracle)), TRUE)
    }
    check("the allele rows are the arities added up", nrow(wide$freq), sum(arity))
    check("the site index runs to the last site", wide$site[nrow(wide$freq)], 500)

    check("no sites at all", nrow(allele_frequencies(list(A = character(0)))$freq), 0)
}

if (wanted("chunk_ranges")) {
    check("seven in threes: how many", length(chunk_ranges(7, 3)), 3)
    check("first chunk starts at one", chunk_ranges(7, 3)[[1]][1], 1)
    check("first chunk ends at three", chunk_ranges(7, 3)[[1]][2], 3)
    check("the last chunk is short", chunk_ranges(7, 3)[[3]][1], 7)
    check("and ends at n", chunk_ranges(7, 3)[[3]][2], 7)

    # THE PROPERTY EVERY BINNED RESULT DEPENDS ON: the chunks are 1..n exactly once, in order.
    # A gap drops sites from a sum and an overlap counts them twice, both silently.
    for (pair in list(c(7, 3), c(100, 7), c(5, 5), c(5, 99), c(1, 1))) {
        covered <- unlist(lapply(chunk_ranges(pair[1], pair[2]),
                                 function(r) seq.int(r[1], r[2])))
        check(sprintf("%d in %ds covers 1..n once, in order", pair[1], pair[2]),
              identical(covered, seq_len(pair[1])), TRUE)
    }

    check("nothing to chunk", length(chunk_ranges(0, 10)), 0)
    refuses("a chunk of no items", chunk_ranges(10, 0))
    refuses("a negative count", chunk_ranges(-1, 10))
}

if (wanted("nei_distance")) {
    # ONE SITE, TWO POOLS, correction switched off by an infinite effective size.
    # A = (0.6, 0.4), B = (0.3, 0.7). J_A = 0.52, J_B = 0.58, J_AB = 0.46.
    # (0.52 + 0.58) / 2 - 0.46 = 0.09, which is also 1/2 * (0.09 + 0.09).
    one <- nei_distance(cbind(c(0.6, 0.4), c(0.3, 0.7)), c(1, 1), matrix(Inf, 1, 2))
    check("Nei's minimum distance, biallelic", one$raw[1, 2], 0.09)
    check("nothing to correct at infinite n_eff", one$corrected[1, 2], 0.09)
    check("one site counted", one$sites[1, 2], 1)
    check("the matrix is symmetric", one$raw[2, 1], 0.09)
    check("a pool is no distance from itself", one$raw[1, 1], 0)

    # THE SUM RUNS OVER EVERY ALLELE INCLUDING THE REFERENCE, so a triallelic site contributes
    # three terms. A = (0.5, 0.3, 0.2), B = (0.2, 0.3, 0.5): J_A = J_B = 0.38, J_AB = 0.29,
    # (0.38 + 0.38) / 2 - 0.29 = 0.09.
    tri <- nei_distance(cbind(c(0.5, 0.3, 0.2), c(0.2, 0.3, 0.5)), c(1, 1, 1),
                        matrix(Inf, 1, 2))
    check("triallelic", tri$raw[1, 2], 0.09)

    # THE CORRECTION IS THE UNBIASED HOMOZYGOSITY, (n * sum(p^2) - 1) / (n - 1), which is
    # sum(p^2) - h / (n - 1). At n_eff = 51, J_A = 0.52 and h_A = 0.48: 0.52 - 0.48/50 = 0.5104.
    # At n_eff = 26 for B, 0.58 - 0.42/25 = 0.5632. (0.5104 + 0.5632) / 2 - 0.46 = 0.0768.
    adj <- nei_distance(cbind(c(0.6, 0.4), c(0.3, 0.7)), c(1, 1), matrix(c(51, 26), 1))
    check("the unbiased form", adj$corrected[1, 2], 0.0768)
    check("raw is left uncorrected beside it", adj$raw[1, 2], 0.09)

    # SUMS, NOT MEANS, so bins add. Two sites of 0.09 accumulate to 0.18 over two sites.
    two <- nei_distance(cbind(c(0.6, 0.4, 0.6, 0.4), c(0.3, 0.7, 0.3, 0.7)), c(1, 1, 2, 2),
                        matrix(Inf, 2, 2))
    check("two sites accumulate", two$raw[1, 2], 0.18)
    check("and are counted", two$sites[1, 2], 2)
    folded <- add_distance(add_distance(NULL, one), one)
    check("the same total, one bin at a time", folded$raw[1, 2], two$raw[1, 2])
    check("with the same site count", folded$sites[1, 2], two$sites[1, 2])

    # A POOL WITH NO READS DROPS THAT SITE FOR ITS OWN PAIRS AND LEAVES THE OTHERS ALONE, so
    # two pairs of one run can rest on different numbers of sites. B is missing at site 2.
    gap <- nei_distance(cbind(c(0.6, 0.4, 0.5, 0.5), c(0.3, 0.7, NA, NA), c(0.2, 0.8, 0.1, 0.9)),
                        c(1, 1, 2, 2), matrix(Inf, 2, 3))
    check("the pair with the gap loses the site", gap$sites[1, 2], 1)
    check("the pair without it keeps both", gap$sites[1, 3], 2)

    # n_eff IS 1 AT DEPTH 1 WHATEVER THE POOL HOLDS, and one gene copy has no diversity to
    # correct with: h is zero by construction and the correction lands on 0/0.
    check("n_eff at depth 1", n_eff(100, 1), 1)
    spent <- nei_distance(cbind(c(0.6, 0.4), c(0.3, 0.7)), c(1, 1), matrix(c(1, 80), 1))
    check("the site drops rather than returning NaN", spent$sites[1, 2], 0)
    check("and takes the raw sum with it", spent$raw[1, 2], 0)

    refuses_with("pools that do not match", "read in the same order",
                 nei_distance(cbind(c(0.6, 0.4)), c(1, 1), matrix(Inf, 1, 2)))
    refuses_with("sites that do not match", "one parse of one table",
                 nei_distance(cbind(c(0.6, 0.4), c(0.3, 0.7)), c(1, 1), matrix(Inf, 2, 2)))
}

if (wanted("mean_distance")) {
    total <- matrix(c(0, 0.18, 0.18, 0), 2)
    counts <- matrix(c(0, 2, 2, 0), 2)
    check("the per-site mean", mean_distance(total, counts)[1, 2], 0.09)
    check("a pool is no distance from itself", mean_distance(total, counts)[1, 1], 0)

    # EACH PAIR IS DIVIDED BY ITS OWN COUNT. A-B saw 2 sites and A-C saw 4; dividing both by
    # one shared count would make the pair with more sites look the further apart.
    uneven <- mean_distance(matrix(c(0, 0.18, 0.36, 0.18, 0, 0, 0.36, 0, 0), 3),
                            matrix(c(0, 2, 4, 2, 0, 0, 4, 0, 0), 3))
    check("A-B over its two sites", uneven[1, 2], 0.09)
    check("A-C over its four", uneven[1, 3], 0.09)
    check("a pair with no site in common", uneven[2, 3], NA_real_)
}

if (wanted("split_counts")) {
    check("two alleles, first value", split_counts("30,5")[1], 30)
    check("two alleles, second value", split_counts("30,5")[2], 5)
    check("three alleles", length(split_counts("30,5,2")), 3)
    check("a single count", split_counts("12")[1], 12)
    check("bcftools' missing value", split_counts(".")[1], NA_real_)
    check("one allele missing", split_counts("30,.")[2], NA_real_)
    check("zero is a count", split_counts("0,7")[1], 0)
}

# ---------------------------------------------------------------------------------------

if (length(FAILED) > 0) {
    for (line in FAILED) cat("FAIL ", line, "\n", sep = "")
    cat(sprintf("%d of %d checks failed\n", length(FAILED), RAN))
    quit(status = 1)
}
cat(sprintf("%d checks passed\n", RAN))
