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
