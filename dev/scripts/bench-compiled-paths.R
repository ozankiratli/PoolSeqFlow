#!/usr/bin/env Rscript
#
# The vectorized R against the compiled path, for every derivation in analysis/lib/ that has
# both. This is what the manual's table under "How long the per-site work takes" was measured
# with, and re-running it is how that table is checked rather than trusted.
#
#     dev/scripts/bench-compiled-paths.R [sites...]      default 3200000
#
# Needs Rcpp and a compiler. dev/ carries export-ignore, so this file never ships to a user.
#
# CPU TIME (user + sys), not elapsed, and the minimum of REPS runs: a development machine
# carries other work, and elapsed time on a loaded one measures the load.
#
# THE SIZE IS THE POINT AND NOT A PARAMETER TO SHRINK. At a few tens of thousands of sites the
# corpus sits in cache and the compiled path looks two to three times better than it is over a
# genome; below about ten thousand the whole call is shorter than the clock's resolution, and a
# figure extrapolated from there is arbitrary. Anything published from this should come from a
# corpus large enough that a single pool's cells exceed L3.

args <- commandArgs(trailingOnly = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE),
                                                                 value = TRUE)[1])), "../.."))
sizes <- if (length(args) > 0) as.numeric(args) else 3.2e6
REPS <- 5
POOLS <- 6

# Every library, from the sources rather than from an installation. A library is a directory
# under modules/lib/ holding its .R and, where it has one, the .cpp beside it - so `recursive`
# is what reaches into them, and a library added later is picked up with no edit here.
libs <- file.path(repo, "modules/lib")
for (f in list.files(libs, pattern = "[.]R$", full.names = TRUE, recursive = TRUE)) {
    source(f)
}
for (f in list.files(libs, pattern = "[.]cpp$", full.names = TRUE, recursive = TRUE)) {
    Rcpp::sourceCpp(f)
}

# A published depth table is overwhelmingly biallelic. A uniform draw over arities would give
# the compiled path more digits to parse per site than a real cohort does.
corpus <- function(n, pools) {
    arity <- sample(c(2L, 3L, 4L), n, replace = TRUE, prob = c(0.92, 0.07, 0.01))
    lapply(seq_len(pools), function(p) {
        vapply(arity, function(k) paste(sample(20:400, k, replace = TRUE), collapse = ","), "")
    })
}

cpu <- function(fn) {
    best <- Inf
    for (i in seq_len(REPS)) {
        gc(FALSE)
        before <- proc.time()
        invisible(fn())
        after <- proc.time()
        best <- min(best, (after[["user.self"]] - before[["user.self"]]) +
                          (after[["sys.self"]] - before[["sys.self"]]))
    }
    best
}

row <- function(what, reads, n, r, k) {
    cat(sprintf("| %-20s | %-9s | %6.0f s | %5.0f s | %3.0fx |\n",
                what, reads, r / n * 1e8, k / n * 1e8, r / k))
}

cat(R.version.string, "\n")
cat("corpus: 92% biallelic, 7% triallelic, 1% tetrallelic; best of", REPS, "runs, CPU time\n\n")

for (n in sizes) {
    set.seed(1)
    cells <- corpus(n, POOLS)
    names(cells) <- paste0("Pool", seq_len(POOLS))
    one <- cells[1]
    cat(sprintf("%.0f sites, one pool's cells being %.0f MB\n\n",
                n, as.numeric(object.size(cells[[1]])) / 1024^2))

    cat("| Derivation | Reads | Vectorized R | Compiled | Ratio |\n")
    cat("|---|---|---|---|---|\n")
    row("`site_diversity`", "one pool", n,
        cpu(function() site_diversity(cells[[1]])),
        cpu(function() site_diversity_cpp(cells[[1]])))
    row("`allele_frequencies`", "one pool", n,
        cpu(function() allele_frequencies(one)),
        cpu(function() allele_frequencies_cpp(one)))
    row("`allele_frequencies`", "six pools", n,
        cpu(function() allele_frequencies(cells)),
        cpu(function() allele_frequencies_cpp(cells)))

    # nei_distance reads what the parse returns rather than the cells, so the corpus is parsed
    # once here and only the accumulation is timed.
    #
    # ITS RATIO IS NOT THE PARSERS' RATIO AND SHOULD NOT BE AVERAGED WITH THEM. The two above
    # are string splits, memory-bandwidth bound, and land near ten. This one is k(k-1)/2
    # separate rowsum() passes over the allele matrix — fifteen at six pools — so what the
    # compiled form removes is interpreted call overhead that scales with the PAIR count, not
    # with the site count. Expect it to climb with more pools where the parsers' will not.
    parsed <- allele_frequencies_cpp(cells)
    ne <- vapply(seq_len(POOLS), function(i) n_eff(100, parsed$depth[, i]),
                 numeric(nrow(parsed$depth)))
    row("`nei_distance`", "six pools", n,
        cpu(function() nei_distance(parsed$freq, parsed$site, ne)),
        cpu(function() nei_distance_cpp(parsed$freq, as.integer(parsed$site), ne)))
    cat("\nseconds are per 100 million called sites, in one pass\n\n")

    rm(cells, one, parsed, ne)
    gc(FALSE)
}
