#!/usr/bin/env Rscript
#
# The same simulated data through an independently written tool.
#
#     external.R <library directory> <work directory> [sites] [seed]
#
# Everything in calibrate.R judges our arithmetic against our own idea of the truth. This judges
# it against BayPass (Gautier 2015), which is Fortran, Bayesian, MCMC, models population structure
# through an Omega matrix and returns a Bayes factor rather than a p-value. Nothing about it
# resembles what we do except the question it answers.
#
# SO THE TWO ARE NEVER COMPARED TO EACH OTHER DIRECTLY. Different statistics on different scales
# cannot agree numerically and it would mean nothing if they did. Both are scored against the
# sites that were PLANTED, which neither of them can see, and the comparison is which one finds
# them.
#
# Two datasets, and the second is the point. The first is biallelic, which BayPass reads natively.
# The second is triallelic with the signal split across both alternates - a shape its input format
# cannot express, so a user has to choose how to reduce it, and this measures what each choice
# costs.
#
# Base R only, and BayPass on the PATH as `g_baypass`.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: external.R <library directory> <work directory> [sites] [seed]")
lib <- args[1]
work <- args[2]
sites <- if (length(args) > 2) as.integer(args[3]) else 2000L
seed <- if (length(args) > 3) as.integer(args[4]) else 20260907L

# `recursive` because a library is a DIRECTORY under modules/lib/ and its .R sits inside it, so
# a flat listing returns nothing - and sourcing nothing here would score BayPass against an
# empty library rather than against ours, which is a result that looks like a finding.
sources <- list.files(lib, pattern = "[.]R$", full.names = TRUE, recursive = TRUE)
if (length(sources) == 0) stop("no R sources in ", lib)
for (path in sources) source(path)
here <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
source(file.path(here, "lib.R"))

dir.create(work, recursive = TRUE, showWarnings = FALSE)
set.seed(seed)

POOLS <- 20L
N_CHROM <- 100L
DEPTH <- 200L
PLANTED <- 100L
SLOPE <- 0.030
DRAWS <- 999L
Y <- as.vector(scale(seq_len(POOLS)))

if (nchar(Sys.which("g_baypass")) == 0) {
    stop("external.R: g_baypass is not on the PATH. It is `conda install -c bioconda baypass` ",
         "and the analysis environment is where the rest of this runs.")
}

# ---------------------------------------------------------------------------------------

# BayPass reads one row per SNP and two columns per population, the two allele counts side by
# side; the pool sizes are HAPLOID, which is n_chrom exactly, and the covariate is one row.
run_baypass <- function(name, reference, alternate) {
    stem <- file.path(work, name)
    counts <- matrix(0L, nrow = nrow(reference), ncol = 2L * ncol(reference))
    counts[, seq(1L, ncol(counts), by = 2L)] <- as.integer(reference)
    counts[, seq(2L, ncol(counts), by = 2L)] <- as.integer(alternate)
    write.table(counts, paste0(stem, ".geno"), row.names = FALSE, col.names = FALSE,
                quote = FALSE)
    write.table(matrix(rep(N_CHROM, ncol(reference)), nrow = 1L), paste0(stem, ".poolsize"),
                row.names = FALSE, col.names = FALSE, quote = FALSE)
    write.table(matrix(Y, nrow = 1L), paste0(stem, ".cov"), row.names = FALSE,
                col.names = FALSE, quote = FALSE)

    status <- system2("g_baypass",
                      c("-pooldatafile", paste0(stem, ".geno"),
                        "-poolsizefile", paste0(stem, ".poolsize"),
                        "-efile", paste0(stem, ".cov"),
                        "-outprefix", stem, "-nthreads", "4", "-seed", as.character(seed)),
                      stdout = paste0(stem, ".log"), stderr = paste0(stem, ".log"))
    if (status != 0) {
        stop("external.R: g_baypass exited ", status, "; see ", paste0(stem, ".log"))
    }
    summary <- paste0(stem, "_summary_betai_reg.out")
    if (!file.exists(summary)) {
        summary <- paste0(stem, "_summary_betai.out")
    }
    if (!file.exists(summary)) {
        stop("external.R: g_baypass wrote no covariate summary beside ", stem)
    }
    table <- read.table(summary, header = TRUE)
    column <- grep("^BF", names(table), value = TRUE)[1]
    if (is.na(column)) stop("external.R: no BF column in ", summary, ": ",
                            paste(names(table), collapse = " "))
    table[order(table$MRK), column]
}

# Precision at the number of sites that were actually planted. Both methods are asked for their
# best PLANTED guesses and scored on how many are right, which is a comparison the two scales can
# both take part in.
recovered <- function(score, truth, decreasing = TRUE) {
    ranked <- order(score, decreasing = decreasing, na.last = NA)
    sum(truth[head(ranked, PLANTED)]) / PLANTED
}

cat(sprintf("external.R  %d pools, n_chrom %d, depth %d, %d sites of which %d planted\n",
            POOLS, N_CHROM, DEPTH, sites, PLANTED))
cat(sprintf("            slope %.3f, %d permutation draws, seed %d\n\n", SLOPE, DRAWS, seed))

# ---------------------------------------------------------------------------------------
# Dataset A: biallelic, which BayPass reads as it stands.

planted <- c(rep(TRUE, PLANTED), rep(FALSE, sites - PLANTED))
loud <- simulate_effect(PLANTED, rep(DEPTH, POOLS), N_CHROM, 0.50, SLOPE, Y)
quiet <- simulate_effect(sites - PLANTED, rep(DEPTH, POOLS), N_CHROM, 0.50, 0, Y)
freq <- rbind(loud$freq, quiet$freq)
depth <- matrix(DEPTH, nrow = sites, ncol = POOLS)
weight <- n_eff(N_CHROM, depth)
weight <- 1 / (theta_of(freq, weight) + 1 / weight)

ours <- residual_p(freq, weight, Y, DRAWS)
alternate <- round(freq * DEPTH)
theirs <- run_baypass("biallelic", DEPTH - alternate, alternate)

cat("A. BIALLELIC - both tools read the same table\n\n")
cat(sprintf("%28s %12s\n", "", "planted found"))
cat(sprintf("%28s %11.1f%%\n", "PoolSeqFlow, residual perm", 100 * recovered(ours, planted, FALSE)))
cat(sprintf("%28s %11.1f%%\n", "BayPass, BF", 100 * recovered(theirs, planted)))
cat(sprintf("\n  Spearman between -log10(p) and BF over all %d sites: %.3f\n", sites,
            suppressWarnings(cor(-log10(ours), theirs, method = "spearman",
                                 use = "complete.obs"))))

# ---------------------------------------------------------------------------------------
# Dataset B: triallelic, in the two shapes that need opposite reductions.

triallelic <- function(name, generator, slope) {
    loud <- generator(PLANTED, rep(DEPTH, POOLS), N_CHROM, slope, Y)
    quiet <- generator(sites - PLANTED, rep(DEPTH, POOLS), N_CHROM, 0, Y)
    freq <- rbind(loud$freq, quiet$freq)
    site <- rep.int(seq_len(sites), rep.int(3L, sites))
    weight <- n_eff(N_CHROM, depth)
    weight <- 1 / (theta_of(freq[seq(1, nrow(freq), by = 3), ], weight) + 1 / weight)

    ours <- residual_p_multi(freq, weight, site, sites, Y, DRAWS)
    counts <- round(freq * DEPTH)
    reference <- counts[seq(1, nrow(counts), by = 3), , drop = FALSE]
    first <- counts[seq(2, nrow(counts), by = 3), , drop = FALSE]
    second <- counts[seq(3, nrow(counts), by = 3), , drop = FALSE]

    c(ours = recovered(ours, planted, FALSE),
      first = recovered(run_baypass(paste0(name, "_first"), reference, first), planted),
      summed = recovered(run_baypass(paste0(name, "_summed"), reference, first + second),
                         planted))
}

split <- triallelic("split", simulate_split, SLOPE / 2)
opposed <- triallelic("opposed", simulate_opposed, SLOPE / 2)

cat("\n\nB. TRIALLELIC - BayPass takes two counts per pool, so the site must be reduced first\n\n")
cat(sprintf("%30s %16s %16s\n", "", "both alternates", "alternates move"))
cat(sprintf("%30s %16s %16s\n", "", "rise together", "against each other"))
cat(sprintf("%30s %15.1f%% %15.1f%%\n", "PoolSeqFlow, max over all",
            100 * split["ours"], 100 * opposed["ours"]))
cat(sprintf("%30s %15.1f%% %15.1f%%\n", "BayPass, first alternate",
            100 * split["first"], 100 * opposed["first"]))
cat(sprintf("%30s %15.1f%% %15.1f%%\n", "BayPass, alternates summed",
            100 * split["summed"], 100 * opposed["summed"]))

cat("\n  Neither reduction is right for both columns, and a genome holds both shapes. Summing\n")
cat("  the alternates recovers a signal the reference carries and destroys one the alternates\n")
cat("  carry between them; reading one alternate does the reverse. Nothing in the data says\n")
cat("  which a site is, and the module is never asked, because it reads every allele.\n")
