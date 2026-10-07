#!/usr/bin/env Rscript
#
# Calibration measurements for the analysis layer, against data simulated from a known truth.
#
#     calibrate.R <library directory> [section] [replicates] [seed]
#
# Sections are named for what they judge; without one, all of them run, and `missing` runs the
# five missing_* sections. Each prints its measurements as a table and then a verdict, because
# these numbers are written up as well as checked. Exits 1 if any section fails.
#
# Base R only, like the library it judges.
#
# THE SIMULATION NEVER CALLS THE LIBRARY. Every draw below is rbinom and arithmetic, so a wrong
# library function cannot cancel against itself and report agreement. dev/validation/README.md
# says why that is the whole basis for treating a number here as evidence. The estimators of the
# missing_* sections go further and call the modules' own functions, parsed out of association.R
# and mds.R, so what they judge is the code that ships.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: calibrate.R <library directory> [section] [replicates] [seed]")
lib        <- args[1]
section    <- if (length(args) > 1) args[2] else "all"
replicates <- if (length(args) > 2) as.integer(args[3]) else 200000L
seed       <- if (length(args) > 3) as.integer(args[4]) else 20260907L

# `recursive` because a library is a DIRECTORY under modules/lib/ and its .R sits inside it, so
# a flat listing of the store or the source tree returns nothing at all.
sources <- list.files(lib, pattern = "[.]R$", full.names = TRUE, recursive = TRUE)
if (length(sources) == 0) stop("no R sources in ", lib)
for (path in sources) source(path)

# The generators and estimators, shared with external.R so the two cannot drift apart. Found
# beside this script rather than relative to the working directory.
here <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
source(file.path(here, "lib.R"))

# Where the missing_* sections find the modules: a library is modules/lib/<name>/ and a module
# modules/<name>/, so the library directory's parent holds both and they come from one tree.
MODULES_DIR <- dirname(normalizePath(lib))

# ---------------------------------------------------------------------------------------
# n_eff: the effective sample size IS the variance of a two-stage pooled draw
#
# A pool of n_chrom chromosomes at true frequency p, sequenced to depth d, is two samplings:
#
#     K ~ Binomial(n_chrom, p)         which chromosomes went into the pool
#     A ~ Binomial(d, K / n_chrom)     which of those the reads happened to sample
#     f = A / d                        what the depth table records
#
# Conditioning on K and adding the two variances gives
#
#     Var(f) = p(1-p) * (n_chrom + d - 1) / (n_chrom * d)  =  p(1-p) / n_eff
#
# with n_eff = n_chrom * d / (n_chrom + d - 1). Every weight in the analysis layer rests on that
# identity holding, so it is measured here rather than asserted.
#
# n_eff() takes the two arguments as one number each and ploidy never appears in it: a pool
# enters only through n_chrom = ploidy * poolSize. The grid holds three ploidies reaching
# n_chrom = 100 by different routes, which is what that claim looks like when it is exercised.
#
# The form n_chrom*d / (n_chrom + d) is also in circulation and is measured in the same pass.
# The two differ by (n + d) / (n + d - 1): under 1% at ordinary depths, and 7% for a pool of
# five diploids read at 5x, which is why the grid holds one of those.
section_n_eff <- function(replicates) {
    pools <- list(list(ploidy = 2, size =   5, depths = c(  5,  20,  200)),
                  list(ploidy = 2, size =  25, depths = c( 10,  50,  500)),
                  list(ploidy = 2, size =  50, depths = c( 30, 100, 1000)),
                  list(ploidy = 1, size = 100, depths = c( 30, 100, 1000)),
                  list(ploidy = 4, size =  25, depths = c( 30, 100, 1000)),
                  list(ploidy = 2, size = 200, depths = c( 50, 400, 4000)))
    frequencies <- c(0.05, 0.25, 0.50)

    cat(sprintf("%6s %5s %8s %6s %6s  %12s %12s %8s %8s %9s\n",
                "ploidy", "pool", "n_chrom", "depth", "p",
                "observed", "n_eff", "ratio", "z", "z(n+d)"))

    ours <- numeric(0)
    rival <- numeric(0)
    for (pool in pools) {
        n_chrom <- pool$ploidy * pool$size
        for (depth in pool$depths) {
            for (p in frequencies) {
                carried <- rbinom(replicates, n_chrom, p)
                read    <- rbinom(replicates, depth, carried / n_chrom) / depth
                got     <- moments(read)

                predicted <- p * (1 - p) / n_eff(n_chrom, depth)
                without   <- p * (1 - p) * (n_chrom + depth) / (n_chrom * depth)
                z         <- (got$variance - predicted) / got$se
                z_without <- (got$variance - without) / got$se
                ours      <- c(ours, z)
                rival     <- c(rival, z_without)

                cat(sprintf("%6d %5d %8d %6d %6.2f  %12.3e %12.3e %8.4f %8.2f %9.2f\n",
                            pool$ploidy, pool$size, n_chrom, depth, p,
                            got$variance, predicted, got$variance / predicted, z, z_without))
            }
        }
    }

    # Five sigma over this many cells is a false alarm about once in 70,000 runs, so a failure
    # here is the identity and not the draw.
    worst <- max(abs(ours))
    cat(sprintf("\n  %d cells, %d replicates each\n", length(ours), replicates))
    cat(sprintf("  n_eff = n*d/(n + d - 1):  largest deviation %.2f standard errors\n", worst))
    cat(sprintf("  n_eff = n*d/(n + d)    :  largest deviation %.2f standard errors\n",
                max(abs(rival))))
    if (worst >= 5) {
        cat("  FAIL: the variance of a two-stage draw is not p(1-p)/n_eff\n")
        return(FALSE)
    }
    cat("  PASS\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# parametric: what the closed-form t says about a null site, and where it stops being true
#
# The weighted fit is exact under normal errors. A pooled frequency is not normal - it is one
# binomial inside another, discrete and skewed - and the gap between the two is what a published
# t and its p-value carry into a Manhattan plot. Measured against sites drawn with no association
# at all, so every rejection below is a false one.
#
# This section reports and never fails. The numbers are the argument for publishing a permutation
# p, and gating on them would make that argument a test result rather than a measurement.
section_parametric <- function(replicates) {
    pools   <- 6
    n_chrom <- 100
    y       <- rnorm(pools)
    alpha   <- c(0.05, 0.01, 0.001, 0.0001)

    cat(sprintf("  %d pools, n_chrom %d, quantitative phenotype, df %d\n\n",
                pools, n_chrom, pools - 2))
    cat(sprintf("%7s %6s %9s %9s %9s %9s %10s %11s\n",
                "depth", "p", "sites", "degenerate", "FPR .05", "FPR .01", "FPR .001",
                "FPR .0001"))

    for (depth in c(30, 100, 1000)) {
        for (p in c(0.05, 0.25, 0.50)) {
            drawn <- simulate_null(replicates, pools, n_chrom, depth, p)
            fit   <- weighted_fit(drawn$freq, n_eff(n_chrom, drawn$depth), y)
            kept  <- fit$t[!fit$degenerate]
            rate  <- vapply(alpha,
                            function(a) mean(2 * pt(-abs(kept), pools - 2) <= a),
                            numeric(1))
            cat(sprintf("%7d %6.2f %9d %9d %9.4f %9.4f %10.5f %11.6f\n",
                        depth, p, length(kept), sum(fit$degenerate),
                        rate[1], rate[2], rate[3], rate[4]))
        }
    }
    cat("\n  reported, not gated: every rate above should read its own alpha.\n")
    cat("  The last column needs a deep run to be read - at this many sites it counts tens\n")
    cat("  of events, and the far tail is where four degrees of freedom are extrapolated.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# permutation: the published p, over the same null sites
#
# The whole set of relabelings is enumerated at six pools, so this is the exact test and not an
# approximation of it. Its granularity is 1/720, which is why the smallest alpha the parametric
# section reports is missing here: no site can attain it, and that is the floor the module prints
# in its own header.
#
# The parametric rate is recomputed on the identical sites, so the two columns differ by the
# method and by nothing else.
#
# THE GATE IS ONE-SIDED. A permutation test over discrete data is conservative: shallow reads of
# a rare allele put the same frequency in several pools, tied relabelings then give tied
# statistics, and every tie counts toward the p-value. Rejecting below alpha is the test being
# safe; rejecting above it is the test being wrong. The ratio is printed either way, because a
# user who asked for 0.01 and got a quarter of it is owed the number.
section_permutation <- function(replicates) {
    pools   <- 6
    n_chrom <- 100
    sites   <- max(2000L, replicates %/% 10L)
    y       <- rnorm(pools)
    labels  <- relabelings(y)

    cat(sprintf("  %d pools, n_chrom %d, %d sites per cell, all %d relabelings\n\n",
                pools, n_chrom, sites, nrow(labels)))
    cat(sprintf("%7s %6s %9s %11s %11s %11s %11s\n",
                "depth", "p", "kept", "perm .05", "param .05", "perm .01", "param .01"))

    ok <- TRUE
    tightest <- 1
    for (depth in c(30, 1000)) {
        for (p in c(0.05, 0.50)) {
            drawn <- simulate_null(sites, pools, n_chrom, depth, p)
            wt    <- n_eff(n_chrom, drawn$depth)
            fit   <- weighted_fit(drawn$freq, wt, y)
            keep  <- !fit$degenerate
            seen  <- abs(fit$t[keep])
            freq  <- drawn$freq[keep, , drop = FALSE]
            wt    <- wt[keep, , drop = FALSE]

            reached <- integer(length(seen))
            for (row in seq_len(nrow(labels))) {
                under <- abs(weighted_fit(freq, wt, labels[row, ])$t)
                under[!is.finite(under)] <- Inf
                reached <- reached + (under >= seen)
            }
            permuted <- reached / nrow(labels)
            closed   <- 2 * pt(-seen, pools - 2)

            # Four standard errors of a rate measured over this many sites, above alpha only.
            for (a in c(0.05, 0.01)) {
                rate     <- mean(permuted <= a)
                tightest <- min(tightest, rate / a)
                if (rate - a > 4 * sqrt(a * (1 - a) / length(seen))) ok <- FALSE
            }
            cat(sprintf("%7d %6.2f %9d %11.4f %11.4f %11.4f %11.4f\n",
                        depth, p, length(seen),
                        mean(permuted <= 0.05), mean(closed <= 0.05),
                        mean(permuted <= 0.01), mean(closed <= 0.01)))
        }
    }
    if (!ok) {
        cat("\n  FAIL: the permutation p rejects MORE often than the alpha it was asked for\n")
        return(FALSE)
    }
    cat(sprintf("\n  PASS: no permutation rate exceeds its alpha; the tightest cell tests at\n"))
    cat(sprintf("  %.2f of the alpha it was asked for, which is ties and not error.\n", tightest))
    TRUE
}

# ---------------------------------------------------------------------------------------
# units: pools that are not independent, which is the assumption the other sections all held
#
# Two pools from one cage agree with each other beyond what their depths explain, because they
# sample the same population. Every estimator below sees the identical sites; they differ only in
# what they believe about how many independent observations are in front of them.
#
#   pools df10   every pool an observation. What the arithmetic gives if nobody asks
#   pools df4    the same t, read against the unit count. Module rule 17c, taken literally
#   means df4    each unit's pools averaged with their weights first, then fitted. Six points
#   perm pool    the same 12-pool fit, phenotype permuted over POOLS - which breaks the clusters
#   perm unit    the same 12-pool fit, phenotype permuted over UNITS - which preserves them
#
# At dispersion 0 the units are interchangeable and every column must read its alpha; that cell is
# the control, and it is what says a difference further down is the clustering and not the draw.
section_units <- function(replicates) {
    units    <- 6L
    per_unit <- 2L
    pools    <- units * per_unit
    n_chrom  <- 100L
    depth    <- 100L
    p        <- 0.25
    sites    <- max(2000L, replicates %/% 20L)
    draws    <- 500L
    y_unit   <- rnorm(units)
    y_pool   <- rep(y_unit, each = per_unit)
    alpha    <- 0.05

    cat(sprintf("  %d units of %d pools, n_chrom %d, depth %d, p %.2f\n", units, per_unit,
                n_chrom, depth, p))
    cat(sprintf("  %d sites per cell, %d sampled relabelings, alpha %.2f\n\n",
                sites, draws, alpha))
    cat(sprintf("%12s %11s %11s %11s %11s %11s\n",
                "dispersion", "pools df10", "pools df4", "means df4", "perm pool", "perm unit"))

    ok <- TRUE
    for (dispersion in c(0, 0.02, 0.05, 0.10)) {
        drawn <- simulate_clustered(sites, units, per_unit, n_chrom, depth, p, dispersion)
        wt    <- n_eff(n_chrom, drawn$depth)
        wide  <- weighted_fit(drawn$freq, wt, y_pool)

        held      <- matrix(0, nrow = sites, ncol = units)
        collapsed <- matrix(0, nrow = sites, ncol = units)
        for (unit in seq_len(units)) {
            cols              <- ((unit - 1L) * per_unit + 1L):(unit * per_unit)
            mine              <- wt[, cols, drop = FALSE]
            held[, unit]      <- rowSums(mine)
            collapsed[, unit] <- rowSums(mine * drawn$freq[, cols, drop = FALSE]) / held[, unit]
        }
        narrow <- weighted_fit(collapsed, held, y_unit)

        keep   <- !wide$degenerate & !narrow$degenerate
        seen   <- abs(wide$t[keep])
        freq_k <- drawn$freq[keep, , drop = FALSE]
        wt_k   <- wt[keep, , drop = FALSE]

        over_pool <- integer(length(seen))
        over_unit <- integer(length(seen))
        for (draw in seq_len(draws)) {
            loose <- abs(weighted_fit(freq_k, wt_k, sample(y_pool))$t)
            tight <- abs(weighted_fit(freq_k, wt_k, rep(sample(y_unit), each = per_unit))$t)
            loose[!is.finite(loose)] <- Inf
            tight[!is.finite(tight)] <- Inf
            over_pool <- over_pool + (loose >= seen)
            over_unit <- over_unit + (tight >= seen)
        }

        rate <- c(mean(2 * pt(-seen, pools - 2) <= alpha),
                  mean(2 * pt(-seen, units - 2) <= alpha),
                  mean(2 * pt(-abs(narrow$t[keep]), units - 2) <= alpha),
                  mean(sampled_p(over_pool, draws) <= alpha),
                  mean(sampled_p(over_unit, draws) <= alpha))

        # The two the module is entitled to rely on. The other three are measured to show what
        # they cost, and a wrong one there is the finding rather than a failure.
        margin <- 4 * sqrt(alpha * (1 - alpha) / length(seen))
        if (any(rate[c(3, 5)] - alpha > margin)) ok <- FALSE
        if (dispersion == 0 && abs(rate[1] - alpha) > margin) ok <- FALSE

        cat(sprintf("%12.2f %11.4f %11.4f %11.4f %11.4f %11.4f\n", dispersion, rate[1], rate[2],
                    rate[3], rate[4], rate[5]))
    }

    if (!ok) {
        cat("\n  FAIL: an estimator the module relies on rejects more often than its alpha\n")
        return(FALSE)
    }
    cat("\n  PASS: unit means and unit-level permutation hold at every dispersion\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# weights: the weight model itself being wrong, which is the one thing permuting cannot repair
#
# A weight says how precisely a pool's frequency was measured. Get it wrong by a constant and
# nothing happens - t is invariant under w -> c*w, and the residual scale absorbs it. Get the
# RELATIVE weights wrong and the fit believes the wrong pools.
#
# Uneven pooling is where that comes from. A pool whose DNA was quantified badly carries more
# variance than its size implies, and the excess sits with the pool rather than with the depth:
# at low depth it is invisible under read sampling, at high depth it is the whole error. So the
# damage needs BOTH uneven contribution and depths that differ, and it lands on the phenotype
# only when the depths line up with it.
#
# The permutation column is the point of this section. Permuting a label cannot restore
# exchangeability that the pools never had, so it fails alongside the closed form rather than
# rescuing it - which is what makes a refusal on cor(depth, phenotype) necessary rather than tidy.
#
# EVERY CELL IS AVERAGED OVER MANY POOLINGS, and the mean and the worst are both reported. Six
# contribution vectors are six draws, so how badly one arrangement misleads the fit is itself
# random and a cell measured from a single pooling says only what happened once. Read at 10,000
# sites per cell this section reported a worst rate of 0.0716; the same cell at 50,000 read
# 0.0521, and the difference was which vectors the stream happened to hand out.
section_weights <- function(replicates) {
    pools  <- 6L
    n_ind  <- 50L
    ploidy <- 2L
    p      <- 0.25
    reps   <- 10L
    sites  <- max(1000L, replicates %/% 100L)
    draws  <- 300L
    alpha  <- 0.05
    y      <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)

    patterns <- list(flat    = rep(200L, pools),
                     mixed   = c(200L, 1000L, 30L, 30L, 1000L, 200L),
                     tilted  = c(30L, 200L, 1000L, 30L, 200L, 1000L),
                     aligned = c(30L, 30L, 200L, 200L, 1000L, 1000L))
    spreads  <- c(Inf, 5, 1)

    # One depth for every pool has no correlation to report rather than a correlation of zero,
    # and cor() warns about the difference instead of saying it.
    alignment <- function(depths) if (sd(depths) == 0) NA_real_ else cor(y, depths)

    cat(sprintf("  %d pools of %d individuals at ploidy %d, p %.2f\n", pools, n_ind, ploidy, p))
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabelings, alpha %.2f\n\n",
                reps, sites, draws, alpha))
    cat(sprintf("%9s %12s %10s %10s %10s %10s %10s\n", "depth", "concentration", "cor(y,d)",
                "param mean", "param sd", "perm mean", "perm sd"))

    ok    <- TRUE
    worst <- alpha
    for (name in names(patterns)) {
        depths  <- patterns[[name]]
        closed  <- numeric(reps)
        shuffle <- numeric(reps)
        for (spread in spreads) {
            for (rep in seq_len(reps)) {
                drawn <- simulate_skewed(sites, depths, n_ind, ploidy, p, spread)
                wt    <- n_eff(n_ind * ploidy, drawn$depth)
                fit   <- weighted_fit(drawn$freq, wt, y)
                keep  <- !fit$degenerate
                seen  <- abs(fit$t[keep])

                over <- integer(length(seen))
                for (draw in seq_len(draws)) {
                    under <- abs(weighted_fit(drawn$freq[keep, , drop = FALSE],
                                              wt[keep, , drop = FALSE], sample(y))$t)
                    under[!is.finite(under)] <- Inf
                    over <- over + (under >= seen)
                }
                closed[rep]  <- mean(2 * pt(-seen, pools - 2) <= alpha)
                shuffle[rep] <- mean(sampled_p(over, draws) <= alpha)
            }
            worst <- max(worst, mean(closed), mean(shuffle))

            # The spread ACROSS poolings, not a binomial one over sites. Sites inside one pooling
            # share a phenotype and a set of permutation draws, so they are not the independent
            # trials a binomial margin assumes: at 100,000 sites that margin called the control
            # itself a failure, and an exhaustive-enumeration probe on the same shape read 0.0508.
            if (name == "flat" && !is.finite(spread) &&
                (abs(mean(closed)  - alpha) > 4 * sd(closed)  / sqrt(reps) ||
                 abs(mean(shuffle) - alpha) > 4 * sd(shuffle) / sqrt(reps))) {
                ok <- FALSE
            }

            cat(sprintf("%9s %12s %10.3f %10.4f %10.4f %10.4f %10.4f\n", name,
                        if (is.finite(spread)) sprintf("%.0f", spread) else "even",
                        alignment(depths), mean(closed), sd(closed),
                        mean(shuffle), sd(shuffle)))
        }
    }

    if (!ok) {
        cat("\n  FAIL: an even pool at one depth is not calibrated, so nothing above can be read\n")
        return(FALSE)
    }
    cat(sprintf("\n  PASS: the control holds. Worst mean rate anywhere above: %.4f against %.2f\n",
                worst, alpha))
    cat("  Read the sd column beside the mean: it is the spread over poolings, and a study is\n")
    cat("  one draw from it rather than the average of ten.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# dispersion: one weight expression whose limits are the regimes, against three of them
#
# The fit asserts Var(f_i) = sigma^2 / n_eff_i. Uneven pooling leaves the truth at
#
#     Var(f_i) = p(1-p) * [ (1 - k_i/n_chrom)/d_i + k_i/n_chrom ]
#
# for a skew factor k_i >= 1, so the excess over the model is p(1-p)(k_i - 1)/n_chrom: it does
# not shrink with depth, which is why deep pools are where it dominates and why it only reaches
# the answer when depth lines up with the phenotype.
#
# Written as one variance with two terms, Var(f_i) = p(1-p) * (theta + 1/n_eff_i), the weight
# 1/(theta + 1/n_eff_i) reduces to n_eff where read sampling dominates and flattens toward equal
# where it does not. So low-and-uneven, deep-and-even and deep-and-uneven are limits of one
# expression rather than three corrections to choose between.
#
# `theta` is estimated from the residual scatter across sites and never declared. Equal weights
# are measured beside it to say whether the estimate is doing something better than flattening.
section_dispersion <- function(replicates) {
    pools <- 6L
    n_ind <- 50L
    ploidy <- 2L
    n_chrom <- n_ind * ploidy
    p <- 0.25
    reps <- 10L
    sites <- max(1000L, replicates %/% 100L)
    draws <- 200L
    alpha <- 0.05
    y <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)

    patterns <- list(flat = rep(200L, pools),
                     mixed = c(200L, 1000L, 30L, 30L, 1000L, 200L),
                     aligned = c(30L, 30L, 200L, 200L, 1000L, 1000L))
    spreads <- c(Inf, 1)

    cat(sprintf("  %d pools of %d individuals, n_chrom %d, p %.2f\n", pools, n_ind, n_chrom, p))
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabelings, alpha %.2f\n\n",
                reps, sites, draws, alpha))
    cat(sprintf("%9s %14s %10s %11s %11s %11s\n", "depth", "concentration", "theta",
                "n_eff", "two-term", "equal"))

    ok <- TRUE
    for (name in names(patterns)) {
        depths <- patterns[[name]]
        for (spread in spreads) {
            rates <- matrix(0, nrow = reps, ncol = 3)
            thetas <- numeric(reps)
            for (rep in seq_len(reps)) {
                drawn <- simulate_skewed(sites, depths, n_ind, ploidy, p, spread)
                sampling <- n_eff(n_chrom, drawn$depth)
                theta <- theta_of(drawn$freq, sampling)
                thetas[rep] <- theta

                schemes <- list(sampling,
                                1 / (theta + 1 / sampling),
                                matrix(1, nrow = nrow(sampling), ncol = ncol(sampling)))
                for (which in seq_along(schemes)) {
                    weight <- schemes[[which]]
                    fit <- weighted_fit(drawn$freq, weight, y)
                    keep <- !fit$degenerate
                    seen <- abs(fit$t[keep])
                    over <- integer(length(seen))
                    for (draw in seq_len(draws)) {
                        under <- abs(weighted_fit(drawn$freq[keep, , drop = FALSE],
                                                  weight[keep, , drop = FALSE], sample(y))$t)
                        under[!is.finite(under)] <- Inf
                        over <- over + (under >= seen)
                    }
                    rates[rep, which] <- mean(sampled_p(over, draws) <= alpha)
                }
            }
            mean_rate <- colMeans(rates)
            if (name == "flat" && !is.finite(spread) &&
                any(abs(mean_rate - alpha) > 4 * apply(rates, 2, sd) / sqrt(reps))) ok <- FALSE

            cat(sprintf("%9s %14s %10.5f %11.4f %11.4f %11.4f\n", name,
                        if (is.finite(spread)) sprintf("%.0f", spread) else "even",
                        mean(thetas), mean_rate[1], mean_rate[2], mean_rate[3]))
        }
    }

    if (!ok) {
        cat("\n  FAIL: the control does not hold, so nothing above can be read\n")
        return(FALSE)
    }
    cat("\n  PASS: the control holds. An even pool should estimate theta near 0; concentration 1\n")
    cat(sprintf("  should reach about %.4f, which is (k - 1)/n_chrom at k = 100/51.\n",
                (100 / 51 - 1) / n_chrom))
    TRUE
}

# ---------------------------------------------------------------------------------------

section_exchangeable <- function(replicates) {
    pools <- 6L
    n_ind <- 50L
    ploidy <- 2L
    n_chrom <- n_ind * ploidy
    p <- 0.25
    reps <- 10L
    sites <- max(1000L, replicates %/% 100L)
    draws <- 200L
    alpha <- 0.05
    y <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)

    patterns <- list(flat = rep(200L, pools),
                     mixed = c(200L, 1000L, 30L, 30L, 1000L, 200L),
                     aligned = c(30L, 30L, 200L, 200L, 1000L, 1000L))

    cat(sprintf("  %d pools of %d individuals, n_chrom %d, p %.2f\n", pools, n_ind, n_chrom, p))
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabelings, alpha %.2f\n\n",
                reps, sites, draws, alpha))
    cat(sprintf("%9s %14s %10s %12s %12s %12s\n", "depth", "concentration", "cor(y,d)",
                "labels", "residuals", "resid+theta"))

    ok <- TRUE
    for (name in names(patterns)) {
        depths <- patterns[[name]]
        for (spread in c(Inf, 1)) {
            rates <- matrix(0, nrow = reps, ncol = 3)
            for (rep in seq_len(reps)) {
                drawn <- simulate_skewed(sites, depths, n_ind, ploidy, p, spread)
                sampling <- n_eff(n_chrom, drawn$depth)
                corrected <- 1 / (theta_of(drawn$freq, sampling) + 1 / sampling)

                fit <- weighted_fit(drawn$freq, sampling, y)
                keep <- !fit$degenerate
                seen <- abs(fit$t[keep])
                over <- integer(length(seen))
                for (draw in seq_len(draws)) {
                    under <- abs(weighted_fit(drawn$freq[keep, , drop = FALSE],
                                              sampling[keep, , drop = FALSE], sample(y))$t)
                    under[!is.finite(under)] <- Inf
                    over <- over + (under >= seen)
                }
                rates[rep, 1] <- mean(sampled_p(over, draws) <= alpha)
                rates[rep, 2] <- residual_permutation(drawn$freq, sampling, y, draws, alpha)
                rates[rep, 3] <- residual_permutation(drawn$freq, corrected, y, draws, alpha)
            }
            mean_rate <- colMeans(rates)
            if (name == "flat" && !is.finite(spread) &&
                any(abs(mean_rate - alpha) > 4 * apply(rates, 2, sd) / sqrt(reps))) ok <- FALSE

            cat(sprintf("%9s %14s %10.3f %12.4f %12.4f %12.4f\n", name,
                        if (is.finite(spread)) sprintf("%.0f", spread) else "even",
                        if (sd(depths) == 0) NA_real_ else cor(y, depths),
                        mean_rate[1], mean_rate[2], mean_rate[3]))
        }
    }

    if (!ok) {
        cat("\n  FAIL: the control does not hold, so nothing above can be read\n")
        return(FALSE)
    }
    cat("\n  PASS: the control holds. Read the aligned rows against the labels column - that is\n")
    cat("  the cell the label scheme cannot do, and the one this section exists to answer.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# breakdown: how far the two-term weights carry, and where the guard has to sit
#
# `exchangeable` showed the residual scheme holding at theta near 0.0096. A guard needs the value
# where it stops holding, not the value where it was last seen working, so this pushes the
# pooling from even to catastrophic on the depth pattern that was hardest - aligned - and reads
# all three schemes at each step.
#
# Concentration 0.02 leaves an effective pool of about two individuals out of fifty. Nobody
# sequences that on purpose; it is here to find the wall.
section_breakdown <- function(replicates) {
    pools <- 6L
    n_ind <- 50L
    ploidy <- 2L
    n_chrom <- n_ind * ploidy
    p <- 0.25
    reps <- 8L
    sites <- max(1000L, replicates %/% 100L)
    draws <- 200L
    alpha <- 0.05
    y <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)
    depths <- c(30L, 30L, 200L, 200L, 1000L, 1000L)

    cat(sprintf("  %d pools of %d individuals, depths aligned with the phenotype (cor %.3f)\n",
                pools, n_ind, cor(y, depths)))
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabelings, alpha %.2f\n\n",
                reps, sites, draws, alpha))
    cat(sprintf("%14s %9s %10s %10s %11s %12s %12s\n", "concentration", "eff.pool",
                "theta true", "theta est", "labels", "residuals", "resid+theta"))

    for (spread in c(Inf, 5, 1, 0.5, 0.2, 0.1, 0.05, 0.02)) {
        rates <- matrix(0, nrow = reps, ncol = 3)
        seen <- numeric(reps)
        for (rep in seq_len(reps)) {
            drawn <- simulate_skewed(sites, depths, n_ind, ploidy, p, spread)
            sampling <- n_eff(n_chrom, drawn$depth)
            theta <- theta_of(drawn$freq, sampling)
            seen[rep] <- theta
            corrected <- 1 / (theta + 1 / sampling)

            fit <- weighted_fit(drawn$freq, sampling, y)
            keep <- !fit$degenerate
            top <- abs(fit$t[keep])
            over <- integer(length(top))
            for (draw in seq_len(draws)) {
                under <- abs(weighted_fit(drawn$freq[keep, , drop = FALSE],
                                          sampling[keep, , drop = FALSE], sample(y))$t)
                under[!is.finite(under)] <- Inf
                over <- over + (under >= top)
            }
            rates[rep, 1] <- mean(sampled_p(over, draws) <= alpha)
            rates[rep, 2] <- residual_permutation(drawn$freq, sampling, y, draws, alpha)
            rates[rep, 3] <- residual_permutation(drawn$freq, corrected, y, draws, alpha)
        }
        truth <- theta_true(spread, n_ind, n_chrom)
        cat(sprintf("%14s %9.1f %10.5f %10.5f %11.4f %12.4f %12.4f\n",
                    if (is.finite(spread)) sprintf("%.2f", spread) else "even",
                    n_ind / (1 + truth * n_chrom), truth, mean(seen),
                    colMeans(rates)[1], colMeans(rates)[2], colMeans(rates)[3]))
    }

    cat("\n  Reported, not gated. The guard goes where resid+theta leaves the band, and the\n")
    cat("  effective pool column is what that value means to someone holding a pipette.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# floor: what residual permutation does to the smallest p a 3-against-3 design can reach
#
# The label scheme's floor is combinatorial. Six pools split three and three give
# choose(6,3) = 20 assignments, the complementary one always ties because swapping every label
# negates t and leaves |t| alone, so nothing can score below 2/20 = 0.1 and no site in such a
# design can survive any correction.
#
# The residual scheme moves residuals rather than labels, so it has 6! = 720 rearrangements and a
# floor of 1/720 where the pools' weights differ. At the flat depths below they do not:
# rearranging residuals inside a group then changes no group mean, the 720 tie as the labels do,
# and the flat rows cannot go below 0.1 either - 72 of 720, measured through the module on 3000
# null sites on 2026-10-05. The resolution is real under the model - these are enumerated
# exhaustively here, so what the table shows is exact and not a sampling artifact -
# but it is bought with the variance model, and the manual has to say which of the two it is
# quoting.
section_floor <- function(replicates) {
    pools <- 6L
    n_ind <- 50L
    ploidy <- 2L
    n_chrom <- n_ind * ploidy
    p <- 0.25
    reps <- 6L
    sites <- max(500L, replicates %/% 200L)
    y <- c(0, 0, 0, 1, 1, 1)

    moves <- relabelings(seq_len(pools))
    assignments <- unique(relabelings(y))

    cat(sprintf("  binary phenotype, %d against %d, %d sites per pooling, %d poolings\n",
                sum(y == 0), sum(y == 1), sites, reps))
    cat(sprintf("  %d distinct label assignments, %d residual rearrangements\n\n",
                nrow(assignments), nrow(moves)))
    cat(sprintf("%9s %13s %10s %10s %10s %10s\n", "depth", "scheme", "attainable",
                "smallest", "FPR .05", "FPR .10"))

    for (name in c("flat", "aligned")) {
        depths <- if (name == "flat") rep(200L, pools) else c(30L, 30L, 200L, 200L, 1000L, 1000L)
        got <- list(labels = matrix(0, reps, 3), residuals = matrix(0, reps, 3))
        for (rep in seq_len(reps)) {
            drawn <- simulate_skewed(sites, depths, n_ind, ploidy, p, 1)
            sampling <- n_eff(n_chrom, drawn$depth)
            weight <- 1 / (theta_of(drawn$freq, sampling) + 1 / sampling)

            fit <- weighted_fit(drawn$freq, weight, y)
            keep <- !fit$degenerate
            top <- abs(fit$t[keep])
            held <- weight[keep, , drop = FALSE]
            values <- drawn$freq[keep, , drop = FALSE]

            over <- integer(length(top))
            for (row in seq_len(nrow(assignments))) {
                under <- abs(weighted_fit(values, held, assignments[row, ])$t)
                under[!is.finite(under)] <- Inf
                over <- over + (under >= top - 1e-12)
            }
            byLabel <- over / nrow(assignments)

            root <- sqrt(held)
            center <- rowSums(held * values) / rowSums(held)
            z <- (values - center) * root
            over <- integer(length(top))
            for (row in seq_len(nrow(moves))) {
                rebuilt <- center + z[, moves[row, ], drop = FALSE] / root
                under <- abs(weighted_fit(rebuilt, held, y)$t)
                under[!is.finite(under)] <- Inf
                over <- over + (under >= top - 1e-12)
            }
            byResidual <- over / nrow(moves)

            got$labels[rep, ] <- c(min(byLabel), mean(byLabel <= 0.05), mean(byLabel <= 0.10))
            got$residuals[rep, ] <- c(min(byResidual), mean(byResidual <= 0.05),
                                      mean(byResidual <= 0.10))
        }
        for (scheme in names(got)) {
            summary <- colMeans(got[[scheme]])
            cat(sprintf("%9s %13s %10.5f %10.5f %10.4f %10.4f\n", name, scheme,
                        1 / if (scheme == "labels") nrow(assignments) else nrow(moves),
                        summary[1], summary[2], summary[3]))
        }
    }

    cat("\n  Reported, not gated. `smallest` is the best p any site actually reached, averaged\n")
    cat("  over poolings; for labels it should sit at 2/20 and never at 1/20.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# arity: whether the site statistic is fair to sites holding different numbers of alleles
#
# S is the largest |t| over every allele of a site, so a site with four alleles offers four
# chances at a large one where a biallelic site offers two. Nothing corrects for that, because
# the p is read against a null built from the SAME site: same k, same alleles, same sum-to-one
# constraint. It should therefore be exact at any arity, and the alternative that was measured at
# 38% inflated - the smallest allele p multiplied by k - 1 - is read beside it.
#
# MOVING WHOLE POOL COLUMNS PRESERVES THE CONSTRAINT. A pool's residuals sum to zero across its
# alleles, so a rebuilt pool's frequencies still sum to one exactly. Permuting alleles
# independently would break that and would be a different null.
section_arity <- function(replicates) {
    pools <- 6L
    n_chrom <- 100L
    reps <- 6L
    sites <- max(500L, replicates %/% 200L)
    draws <- 200L
    alpha <- 0.05
    y <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)
    depths <- c(200L, 1000L, 30L, 30L, 1000L, 200L)

    truths <- list(`2` = c(0.75, 0.25),
                   `3` = c(0.60, 0.25, 0.15),
                   `4` = c(0.50, 0.25, 0.15, 0.10))

    cat(sprintf("  %d pools, n_chrom %d, %d sites per pooling, %d poolings, alpha %.2f\n\n",
                pools, n_chrom, sites, reps, alpha))
    cat(sprintf("%7s %12s %14s %16s\n", "k", "residual p", "min all x (k-1)",
                "min alts x (k-1)"))

    held <- list()
    for (name in names(truths)) {
        rates <- matrix(0, nrow = reps, ncol = 3)
        chosen <- numeric(reps)
        for (rep in seq_len(reps)) {
            drawn <- simulate_arity(sites, depths, n_chrom, truths[[name]])
            weight <- n_eff(n_chrom, drawn$depth)
            fit <- fit_multi(drawn$freq, weight, drawn$site, y)
            observed <- site_statistic(fit$t, drawn$site, sites)

            root <- sqrt(weight)
            total <- rowSums(weight)
            center <- rowSums(weight[drawn$site, ] * drawn$freq) / total[drawn$site]
            z <- (drawn$freq - center) * root[drawn$site, ]

            over <- integer(sites)
            for (draw in seq_len(draws)) {
                moved <- sample(pools)
                rebuilt <- center + z[, moved, drop = FALSE] / root[drawn$site, , drop = FALSE]
                under <- site_statistic(fit_multi(rebuilt, weight, drawn$site, y)$t,
                                        drawn$site, sites)
                reached <- !is.na(under) & under >= observed
                over <- over + reached
            }
            permuted <- sampled_p(over, draws)
            permuted[is.na(observed)] <- NA_real_

            # The two alternatives the design rejected, on the identical sites and corrected the
            # same way, so what separates them is which alleles they look at and nothing else.
            each <- 2 * pt(-abs(fit$t), pools - 2)
            bound <- length(truths[[name]]) - 1
            smallest <- tapply(each, drawn$site, function(v) min(v, na.rm = TRUE))
            alternates <- tapply(seq_along(each), drawn$site,
                                 function(i) min(each[i[-1]], na.rm = TRUE))
            rates[rep, ] <- c(mean(permuted <= alpha, na.rm = TRUE),
                              mean(pmin(1, smallest * bound) <= alpha),
                              mean(pmin(1, alternates * bound) <= alpha))
            chosen[rep] <- mean(permuted <= alpha, na.rm = TRUE)
        }
        held[[name]] <- chosen
        cat(sprintf("%7s %12.4f %14.4f %16.4f\n", name, colMeans(rates)[1],
                    colMeans(rates)[2], colMeans(rates)[3]))
    }

    # If every arity selects at the same rate, a mixed genome's selected set carries the same
    # composition as the genome. That is the claim a reader makes when they see multiallelic
    # sites at the top of a table, so it is stated as a ratio rather than left to be inferred.
    cat("\n  selection rate relative to biallelic:")
    for (name in names(held)) {
        cat(sprintf("  k=%s %.2fx", name, mean(held[[name]]) / mean(held[["2"]])))
    }
    cat("\n  Reported, not gated.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# power: what the thing can see, which nothing measured so far says anything about
#
# Every section above asks when the test lies. A test that never rejects never lies, so none of
# them is evidence that the module is worth running. This is the other half.
#
# The label scheme ran at two thirds of its nominal rate wherever depths were uneven. That is
# not safety, it is sensitivity given away, and the size of the gift is the first table below.
section_power <- function(replicates) {
    pools <- 6L
    n_chrom <- 100L
    base <- 0.50
    reps <- 4L
    sites <- max(400L, replicates %/% 250L)
    draws <- 100L
    alpha <- 0.05
    y <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)
    slopes <- c(0, 0.04, 0.08, 0.14)

    cat(sprintf("  %d pools, n_chrom %d, base frequency %.2f, %d sites per cell, alpha %.2f\n\n",
                pools, n_chrom, base, sites * reps, alpha))
    cat(sprintf("%9s %8s %12s %14s\n", "depth", "slope", "labels", "resid+theta"))

    for (name in c("flat", "mixed")) {
        depths <- if (name == "flat") rep(200L, pools) else
            c(200L, 1000L, 30L, 30L, 1000L, 200L)
        for (slope in slopes) {
            rates <- matrix(0, nrow = reps, ncol = 2)
            for (rep in seq_len(reps)) {
                drawn <- simulate_effect(sites, depths, n_chrom, base, slope, y)
                sampling <- n_eff(n_chrom, drawn$depth)
                corrected <- 1 / (theta_of(drawn$freq, sampling) + 1 / sampling)

                fit <- weighted_fit(drawn$freq, sampling, y)
                keep <- !fit$degenerate
                top <- abs(fit$t[keep])
                over <- integer(length(top))
                for (draw in seq_len(draws)) {
                    under <- abs(weighted_fit(drawn$freq[keep, , drop = FALSE],
                                              sampling[keep, , drop = FALSE], sample(y))$t)
                    under[!is.finite(under)] <- Inf
                    over <- over + (under >= top)
                }
                rates[rep, 1] <- mean(sampled_p(over, draws) <= alpha)
                rates[rep, 2] <- residual_permutation(drawn$freq, corrected, y, draws, alpha)
            }
            cat(sprintf("%9s %8.2f %12.4f %14.4f\n", name, slope,
                        colMeans(rates)[1], colMeans(rates)[2]))
        }
    }

    cat("\n  A triallelic site where both alternates rise and the reference falls by their sum:\n")
    cat(sprintf("%9s %8s %12s %14s %16s\n", "depth", "slope", "max all", "min alts x2",
                "min all x2"))
    depths <- rep(200L, pools)
    for (slope in slopes[-1]) {
        rates <- matrix(0, nrow = reps, ncol = 3)
        for (rep in seq_len(reps)) {
            drawn <- simulate_split(sites, depths, n_chrom, slope, y)
            weight <- n_eff(n_chrom, drawn$depth)
            fit <- fit_multi(drawn$freq, weight, drawn$site, y)
            observed <- site_statistic(fit$t, drawn$site, sites)

            root <- sqrt(weight)
            center <- rowSums(weight[drawn$site, ] * drawn$freq) / rowSums(weight)[drawn$site]
            z <- (drawn$freq - center) * root[drawn$site, ]
            over <- integer(sites)
            for (draw in seq_len(draws)) {
                rebuilt <- center + z[, sample(pools), drop = FALSE] / root[drawn$site, ,
                                                                           drop = FALSE]
                under <- site_statistic(fit_multi(rebuilt, weight, drawn$site, y)$t,
                                        drawn$site, sites)
                over <- over + (!is.na(under) & under >= observed)
            }
            each <- 2 * pt(-abs(fit$t), pools - 2)
            alternates <- tapply(seq_along(each), drawn$site,
                                 function(i) min(each[i[-1]], na.rm = TRUE))
            smallest <- tapply(each, drawn$site, function(v) min(v, na.rm = TRUE))
            rates[rep, ] <- c(mean(sampled_p(over, draws) <= alpha, na.rm = TRUE),
                              mean(pmin(1, alternates * 2) <= alpha),
                              mean(pmin(1, smallest * 2) <= alpha))
        }
        cat(sprintf("%9s %8.2f %12.4f %14.4f %16.4f\n", "flat", slope, colMeans(rates)[1],
                    colMeans(rates)[2], colMeans(rates)[3]))
    }

    cat("\n  Reported, not gated. The slope 0 row of the first table is the false-positive rate\n")
    cat("  and belongs at alpha; every other row is power and belongs as high as it can get.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# pools: everything above was measured at six pools, and six is not a general claim
#
# Two questions the other sections cannot answer. Does the label scheme's failure at aligned depth
# grow or shrink as pools are added - more pools means a finer depth ladder but also a much larger
# permutation set, and those pull opposite ways. And how many pools does an effect of a given size
# need, which is the question a researcher asks before they sequence anything rather than after.
#
# The phenotype is a straight line in the pool index and `aligned` puts the depths in ascending
# blocks over the same index, which at six pools is the exact pattern that produced 0.0609. Pooling
# is EVEN throughout: theta is then near zero and the two schemes differ only in what they permute,
# which is what isolates the effect of n. Concentration is `breakdown`'s question, not this one.
#
# A first pass at concentration 1 showed the label scheme's failure largely gone, because heavy
# pooling skew makes every pool noisy and swamps the depth differences that break exchangeability.
# That is a real interaction and it is why this arm holds pooling still.
section_pools <- function(replicates) {
    n_chrom <- 100L
    n_ind <- 50L
    ploidy <- 2L
    base <- 0.50
    reps <- 5L
    sites <- max(500L, replicates %/% 200L)
    draws <- 150L
    alpha <- 0.05
    slope <- 0.04
    counts <- c(4L, 6L, 8L, 12L, 20L, 30L)

    measure <- function(freq, depths, y, weight) {
        fit <- weighted_fit(freq, weight, y)
        keep <- !fit$degenerate
        top <- abs(fit$t[keep])
        held <- weight[keep, , drop = FALSE]
        values <- freq[keep, , drop = FALSE]
        over <- integer(length(top))
        for (draw in seq_len(draws)) {
            under <- abs(weighted_fit(values, held, sample(y))$t)
            under[!is.finite(under)] <- Inf
            over <- over + (under >= top)
        }
        mean(sampled_p(over, draws) <= alpha)
    }

    cat(sprintf("  n_chrom %d, %d sites per pooling, %d poolings, %d relabelings, alpha %.2f\n",
                n_chrom, sites, reps, draws, alpha))
    cat(sprintf("  pooling EVEN throughout; power measured at slope %.2f\n\n",
                slope))
    # The smallest p a design of this size can reach by relabeling at all. y below is evenly
    # spaced, so reversing it negates the slope and leaves |t| alone: the reversal always ties
    # with the observed one and the floor is TWO over the number of orderings. That holds for this
    # y and for moving labels. The module moves residuals and its design_floor is ONE over the
    # count, since an uneven phenotype or unequal depths break the tie.
    cat(sprintf("%6s %9s %10s %10s %12s %14s %12s %14s\n", "pools", "depth", "cor(y,d)",
                "floor", "null labels", "null resid+th", "pow labels", "pow resid+th"))

    for (n in counts) {
        y <- as.vector(scale(seq_len(n)))
        ladder <- list(flat = rep(200L, n),
                       aligned = sort(rep(c(30L, 200L, 1000L), length.out = n)))
        for (name in names(ladder)) {
            depths <- ladder[[name]]
            null <- matrix(0, nrow = reps, ncol = 2)
            seen <- matrix(0, nrow = reps, ncol = 2)
            for (rep in seq_len(reps)) {
                quiet <- simulate_skewed(sites, depths, n_ind, ploidy, base, Inf)
                sampling <- n_eff(n_chrom, quiet$depth)
                corrected <- 1 / (theta_of(quiet$freq, sampling) + 1 / sampling)
                null[rep, 1] <- measure(quiet$freq, depths, y, sampling)
                null[rep, 2] <- residual_permutation(quiet$freq, corrected, y, draws, alpha)

                loud <- simulate_effect(sites, depths, n_chrom, base, slope, y)
                sampling <- n_eff(n_chrom, loud$depth)
                corrected <- 1 / (theta_of(loud$freq, sampling) + 1 / sampling)
                seen[rep, 1] <- measure(loud$freq, depths, y, sampling)
                seen[rep, 2] <- residual_permutation(loud$freq, corrected, y, draws, alpha)
            }
            cat(sprintf("%6d %9s %10.3f %10.5f %12.4f %14.4f %12.4f %14.4f\n", n, name,
                        if (sd(depths) == 0) NA_real_ else cor(y, depths),
                        2 / factorial(n),
                        colMeans(null)[1], colMeans(null)[2],
                        colMeans(seen)[1], colMeans(seen)[2]))
        }
    }

    cat("\n  Reported, not gated. The null columns belong at alpha at every n; the power columns\n")
    cat("  are what a researcher is buying when they sequence another pool.\n")
    TRUE
}

# =======================================================================================
# Unread cells
#
# Every section above reads tables in which every pool was read at every site. With
# vcffilter.keepLowDepthAsZero on, step 7 writes a cell below vcffilter.minDP as unread -- zero
# reads of every allele -- and keeps a site while minSamples of its cells remain, so each site
# reaches the modules read in its own subset of the units. association rearranges a site among
# the m units it was read in, tests it only when m is at least three and the phenotype varies
# over them, and publishes theta, lambda_gc and depth_phenotype_cor over whatever was read; mds
# averages each pair over its own sites. The five sections below ask whether those numbers still
# mean what they say.
#
# THE ESTIMATORS ARE THE MODULES' OWN FUNCTIONS, parsed out of association.R and mds.R by
# module_functions(), so a section measures the code that ships and a module change is picked up
# without a second copy to keep in step. The fifteen lines of association's main loop that
# association_run() restates are held to the shipped script by agree.R, which has to agree
# before any number here is read. The generators are rbinom and arithmetic, as everywhere else.
#
# EACH SECTION SEEDS ITSELF, from seed plus its own offset, so that it reproduces when run alone
# and adding one does not move the numbers the sections above have published.

Y_Q <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)
Y_B <- c(0, 0, 0, 1, 1, 1)
DEPTH_FLAT <- rep(200L, 6)
DEPTH_MIXED <- c(200L, 1000L, 30L, 30L, 1000L, 200L)
DEPTH_ALIGNED <- c(30L, 30L, 200L, 200L, 1000L, 1000L)

# ---------------------------------------------------------------------------------------
# missing_null: is a site read in only m of its units still given an exact m-unit p?
#
# Each site is rearranged among the m units it was read in, so its enumerated p should be the
# exact m-unit permutation test: never below 1/m!, the identity being the one order sure to tie;
# equal to a brute-force enumeration of the m! orders; and rejecting at no more than the largest
# rate an exact test can attain, floor(alpha m!)/m! -- which is 0 at three units, 1/24 at four and
# alpha from five. Never against alpha itself: a rate of 0.032 at four units is a test at its
# ceiling and not a conservative one.
#
# TIER 1 lays out EVERY pattern of read units, not a random draw of them, because the module
# groups sites by which units were read and a grouping bug shows only on the patterns it gets
# wrong: grouping by HOW MANY units were read instead of which passes every rate gate and fails
# the oracle at thousands of sites. Seven cells -- three depth patterns, a binary phenotype, three
# alleles, and a near-collinear block where S reaches 1e4 and the tie tolerance is what decides --
# each checked by deterministic gates that cannot pass by luck:
#
#   H1  no tested site has a p below 1/m!
#   H2  n_observed is the number of units the generator read
#   H3  a site read in fewer than three units, over units sharing one phenotype value, or holding
#       an allele no read cell carries, has no S, perm_p or fdr_p
#   H4  every tested p equals the brute-force m-unit p within 1e-9, and every unflagged S equals
#       lib.R's fit_multi within 1e-9 relative
#   H5  at flat depth, a site read in every unit gets the same p in the whole table as alone
#   H6  the rearrangement the module rejected -- unread units zeroed and one rearrangement of all
#       six -- must be SEEN: some p below 1/m!, and most partly read sites disagreeing with the
#       oracle. A section that could not tell it from the module would be blind.
#
# TIER 2 reads the strata at resolution, where only the rates are left to judge. At flat depth
# every read unit has the same weight and the test is exact, so m = 5 and 6 are the control and
# are gated two-sided; m = 4 sits 20 to 30 percent under its bound from count ties alone -- any
# tie among four frequencies makes 1/24 unreachable -- and is gated one-sided like every other
# cell.
#
# TWO ARMS take the other paths. Eight units exceed what the module enumerates, so it samples,
# and a sampled p is (1 + reached)/(1 + B) with reached ~ Binomial(B, exact): its mean over the
# exact p is exactly (1 - exact)/(1 + B), and the arm gates that difference at zero. And units of
# two lanes of one pool, the only place roll_up's na.rm decides anything: a unit read through one
# lane of two must stay a unit read.
#
# OFF, step 7's default rule, needs no table of its own here: it keeps exactly the sites read in
# every unit, and H5 shows such a site gets the same p either way at flat depth. At mixed depth
# its p moves with theta, which is estimated over the whole table, so the two rules are never
# compared site by site.

# Sites per read pattern so that each stratum of m units holds about `total` sites per cohort:
# one site for each pattern of one or two units, which association does not test.
per_set_for <- function(total, units = 6L) c(1, 1, ceiling(total / choose(units, 3:units)))

# One cohort of a tier-1 cell: every pattern of read units, and two PHANTOM sites per pattern of
# three or more whose ALT no read cell holds -- the allele the false-positive filter admits on
# reads the mask then writes as unread.
tier1_cohort <- function(cell, total) {
    reads <- enumerated_reads(per_set_for(if (isTRUE(cell$collinear)) max(30L, total %/% 8L)
                                          else total))
    phantom <- enumerated_reads(c(0, 0, 2, 2, 2, 2))
    read <- rbind(reads$read, phantom$read)
    is_phantom <- c(rep(FALSE, nrow(reads$read)), rep(TRUE, nrow(phantom$read)))
    depth <- matrix(cell$depth, nrow(read), 6, byrow = TRUE) * read
    if (isTRUE(cell$collinear)) {
        truth <- matrix(0.5 + 0.30 * (cell$y - mean(cell$y)), nrow(read), 6, byrow = TRUE)
        truth[is_phantom, ] <- 0
        counts <- simulate_cells(depth, cell$n_chrom, truth)$counts
    } else if (is.null(cell$alleles)) {
        counts <- simulate_cells(depth, 100L, ifelse(is_phantom, 0, 0.5))$counts
    } else {
        truth <- matrix(c(0.60, 0.25, 0.15), nrow(read), 3, byrow = TRUE)
        truth[is_phantom, ] <- matrix(c(1, 0, 0), sum(is_phantom), 3, byrow = TRUE)
        counts <- simulate_alleles(depth, 100L, truth)
    }
    list(counts = counts, read = read, size = rowSums(read), id = c(reads$id, phantom$id),
         phantom = is_phantom)
}

missing_null_patterns <- function(replicates) {
    set.seed(seed + 101)
    total <- max(120L, replicates %/% 800L)
    cohorts <- 3L
    alpha <- 0.05
    cells <- list(
        list(name = "flat quantitative", depth = DEPTH_FLAT, y = Y_Q),
        list(name = "mixed quantitative", depth = DEPTH_MIXED, y = Y_Q),
        list(name = "aligned quantitative", depth = DEPTH_ALIGNED, y = Y_Q),
        list(name = "flat binary", depth = DEPTH_FLAT, y = Y_B),
        list(name = "mixed binary", depth = DEPTH_MIXED, y = Y_B),
        list(name = "mixed triallelic", depth = DEPTH_MIXED, y = Y_Q, alleles = 3),
        list(name = "near-collinear", depth = rep(20000L, 6), y = Y_Q, n_chrom = 5000L,
             collinear = TRUE))
    # 3 against 3 at equal depth cannot reach 0.05 at all, and the near-collinear sites are not
    # null, so neither carries a rate.
    rated <- !(vapply(cells, function(cell) cell$name, "") %in% c("flat binary", "near-collinear"))

    cat("  six units, n_chrom 100, p 0.5; three alleles at 0.60/0.25/0.15; near-collinear:\n")
    cat("  n_chrom 5000, depth 20000, frequency linear in the phenotype\n")
    cat(sprintf("  tier 1: every pattern of read units, %d sites per stratum per cohort,\n", total))
    cat(sprintf("  %d cohorts per cell, p enumerated over 720 rearrangements\n\n", cohorts))
    cat(sprintf("  %-22s %2s %7s %9s %8s %8s %8s %8s\n", "cell", "m", "tested", "rate .05",
                "bound", "min p", "1/m!", "no stat"))

    bad <- c(floor = 0L, count = 0L, na = 0L, oracle = 0L, statistic = 0L)
    checked <- 0L
    unexplained <- 0L
    degenerate <- 0L
    alone <- NA_real_
    pooled <- matrix(0, 2, 4, dimnames = list(c("hits", "tested"), 3:6))
    cohort_rates <- vector("list", 4)
    for (index in seq_along(cells)) {
        cell <- cells[[index]]
        n_chrom <- if (is.null(cell$n_chrom)) 100L else cell$n_chrom
        hits <- matrix(0, cohorts, 4)
        tested_n <- matrix(0, cohorts, 4)
        nostat <- matrix(0, cohorts, 4)
        stratum <- matrix(0, cohorts, 4)
        smallest <- rep(1, 4)
        for (r in seq_len(cohorts)) {
            co <- tier1_cohort(cell, total)
            run <- association_run(co$counts, n_chrom, cell$y)
            s <- run$sites
            tested <- !is.na(s$S)
            checked <- checked + sum(tested)

            bad["floor"] <- bad["floor"] + sum(tested & s$perm_p < 1 / factorial(s$m) - 1e-12)
            bad["count"] <- bad["count"] + sum(s$m != co$size)
            constant <- vapply(seq_along(co$size), function(i) {
                length(unique(cell$y[co$read[i, ] == 1L])) < 2
            }, NA)
            must_na <- co$size < 3 | constant | co$phantom
            bad["na"] <- bad["na"] +
                sum(must_na & (!is.na(s$S) | !is.na(s$perm_p) | !is.na(s$fdr_p)))
            unexplained <- unexplained + sum(!must_na & !tested)
            degenerate <- degenerate + sum(tested & !is.na(s$flagged) & s$flagged == 1L)

            exact <- oracle_by_set(run, cell$y, co$id, co$read)
            own <- attr(exact, "S")
            bad["oracle"] <- bad["oracle"] + sum(tested & abs(exact - s$perm_p) > 1e-9)
            unflagged <- tested & !is.na(s$flagged) & s$flagged == 0L & is.finite(s$S)
            bad["statistic"] <- bad["statistic"] +
                sum(unflagged & abs(s$S - own) > 1e-9 * pmax(1, abs(own)))

            for (k in 1:4) {
                here <- co$size == k + 2L & !co$phantom
                st <- here & tested
                tested_n[r, k] <- sum(st)
                hits[r, k] <- sum(s$perm_p[st] <= alpha + 1e-12)
                stratum[r, k] <- sum(here)
                nostat[r, k] <- sum(here & !tested)
                if (any(st)) smallest[k] <- min(smallest[k], s$perm_p[st])
            }

            # H5, on the first cohort of the flat cell: the sites read in every unit, alone.
            if (index == 1 && r == 1) {
                whole <- which(co$size == 6 & !co$phantom)
                by_itself <- association_run(lapply(co$counts, function(x) {
                    x[whole, , drop = FALSE]
                }), n_chrom, cell$y)
                alone <- max(abs(by_itself$sites$perm_p - s$perm_p[whole]))
            }
        }
        if (rated[index]) {
            pooled["hits", ] <- pooled["hits", ] + colSums(hits)
            pooled["tested", ] <- pooled["tested", ] + colSums(tested_n)
            for (k in 1:4) {
                cohort_rates[[k]] <- c(cohort_rates[[k]], hits[, k] / pmax(1, tested_n[, k]))
            }
        }
        for (k in 1:4) {
            m <- k + 2L
            cat(sprintf("  %-22s %2d %7d %9.4f %8.4f %8.4f %8.4f %7.1f%%\n",
                        if (k == 1) cell$name else "", m, sum(tested_n[, k]),
                        sum(hits[, k]) / max(1, sum(tested_n[, k])), exact_bound(m, alpha),
                        smallest[k], 1 / factorial(m), 100 * sum(nostat[, k]) / sum(stratum[, k])))
        }
    }

    ok <- TRUE
    line <- function(label, failed) {
        cat(sprintf("    %-66s %s\n", label,
                    if (failed == 0) "ok" else sprintf("FAIL (%d)", failed)))
        failed == 0
    }
    cat(sprintf("\n  hard checks over the %d tested sites of every cell above:\n", checked))
    ok <- line("H1 tested sites with a p below 1/m!", bad["floor"]) && ok
    ok <- line("H2 sites whose n_observed is not the units the generator read", bad["count"]) && ok
    ok <- line("H3 sites that must have no statistic and carry one", bad["na"]) && ok
    ok <- line("H4 tested sites whose p is not the brute-force m-unit p", bad["oracle"]) && ok
    ok <- line("H4 unflagged sites whose S is not lib.R's fit_multi S", bad["statistic"]) && ok
    same <- !is.na(alone) && alone <= 1e-9
    cat(sprintf("    %-66s %s\n",
                sprintf("H5 complete sites at flat depth, whole table against alone: %.1e", alone),
                if (same) "ok" else "FAIL"))
    ok <- same && ok
    cat(sprintf("    reported: %d tested sites flagged zero_variance; %d testable sites with no\n",
                degenerate, unexplained))
    cat("    statistic, whose read frequencies were all equal\n")

    # H6, on a fresh cohort of the mixed quantitative cell.
    co <- tier1_cohort(cells[[2]], total)
    run <- association_run(co$counts, 100, Y_Q)
    rejected <- rejected_p(run, Y_Q)
    s <- run$sites
    partly <- !is.na(s$S) & s$m < 6
    below <- sum(partly & rejected < 1 / factorial(s$m) - 1e-12)
    exact <- oracle_by_set(run, Y_Q, co$id, co$read)
    differ <- mean(abs(rejected - exact)[partly] > 1e-9)
    cat("\n  H6 the rejected rearrangement, unread units zeroed and one rearrangement of all\n")
    cat("    six units:\n")
    cat(sprintf("    %d of %d partly read sites below 1/m!; %.0f%% differ from the oracle;\n",
                below, sum(partly), 100 * differ))
    cat(sprintf("    at three units it rejects %.3f of them against a bound of 0\n",
                mean(rejected[partly & s$m == 3] <= alpha)))
    if (below == 0 || differ < 0.5) {
        cat("    FAIL: the rejected scheme is not seen, so H1 and H4 above cannot fail\n")
        ok <- FALSE
    }

    cat("\n  pooled over the cells that can reject, one-sided against the largest rate an exact\n")
    cat("  test attains:\n")
    for (k in 2:4) {
        m <- k + 2L
        bound <- exact_bound(m, alpha)
        rate <- pooled["hits", k] / pooled["tested", k]
        margin <- margin_exact(cohort_rates[[k]], pooled["tested", k], bound)
        pass <- isTRUE(rate - bound <= margin)
        cat(sprintf("    m=%d: rate %.4f on %d sites, bound %.4f, excess %+.4f, margin %.4f  %s\n",
                    m, rate, pooled["tested", k], bound, rate - bound, margin,
                    if (pass) "ok" else "FAIL"))
        ok <- pass && ok
    }
    ok
}

missing_null_strata <- function(replicates) {
    set.seed(seed + 102)
    total <- max(600L, replicates %/% 100L)
    cohorts <- 4L
    alpha <- 0.05
    cat(sprintf("  tier 2: %d sites per stratum per cohort, %d cohorts, quantitative phenotype,\n",
                total, cohorts))
    cat("  enumerated p; disp is the spread across cohorts over the binomial spread, 1 when\n")
    cat("  nothing is shared\n\n")
    cat(sprintf("  %-9s %2s %8s %9s %8s %9s %8s %9s %6s   %s\n", "depth", "m", "tested",
                "rate .05", "bound", "excess", "margin", "cohort sd", "disp", "verdict"))
    ok <- TRUE
    for (name in c("flat", "aligned")) {
        pattern <- switch(name, flat = DEPTH_FLAT, aligned = DEPTH_ALIGNED)
        hits <- matrix(0, cohorts, 3)
        tested_n <- matrix(0, cohorts, 3)
        for (r in seq_len(cohorts)) {
            reads <- enumerated_reads(c(0, 0, 0, ceiling(total / 15), ceiling(total / 6), total))
            depth <- matrix(pattern, nrow(reads$read), 6, byrow = TRUE) * reads$read
            s <- association_run(simulate_cells(depth, 100L, 0.5)$counts, 100, Y_Q)$sites
            for (k in 1:3) {
                st <- !is.na(s$S) & s$m == k + 3L
                tested_n[r, k] <- sum(st)
                hits[r, k] <- sum(s$perm_p[st] <= alpha + 1e-12)
            }
        }
        for (k in 1:3) {
            m <- k + 3L
            rates <- hits[, k] / tested_n[, k]
            rate <- sum(hits[, k]) / sum(tested_n[, k])
            bound <- exact_bound(m, alpha)
            margin <- margin_exact(rates, sum(tested_n[, k]), bound)
            control <- name == "flat" && m >= 5
            pass <- isTRUE(if (control) abs(rate - bound) <= margin else rate - bound <= margin)
            ok <- pass && ok
            cat(sprintf("  %-9s %2d %8d %9.4f %8.4f %+9.4f %8.4f %9.4f %6.2f   %s%s\n",
                        if (k == 1) name else "", m, sum(tested_n[, k]), rate, bound,
                        rate - bound, margin, sd(rates),
                        sd(rates) / sqrt(bound * (1 - bound) / mean(tested_n[, k])),
                        if (pass) "ok" else "FAIL", if (control) " (control, two-sided)" else ""))
        }
    }
    ok
}

missing_null_sampled <- function(replicates) {
    set.seed(seed + 103)
    units <- 8L
    budget <- 499L
    cohorts <- 6L
    sites <- max(150L, replicates %/% 700L)
    y <- as.vector(scale(c(-1.3, -0.9, -0.5, -0.1, 0.2, 0.6, 1.0, 1.7)))
    pattern <- c(200L, 1000L, 30L, 30L, 1000L, 200L, 100L, 400L)
    gap <- numeric(cohorts)
    rate <- numeric(cohorts)
    smallest <- numeric(cohorts)
    compared <- integer(cohorts)
    sampled <- TRUE
    counted <- TRUE
    for (r in seq_len(cohorts)) {
        read <- matrix(rbinom(sites * units, 1, 0.6), sites, units)
        depth <- matrix(pattern, sites, units, byrow = TRUE) * read
        counts <- simulate_cells(depth, 100L, 0.5)$counts
        run <- association_run(counts, 100, y, budget = budget)
        s <- run$sites
        tested <- !is.na(s$S)
        sampled <- sampled && identical(run$exhaustive, FALSE)
        counted <- counted && identical(as.integer(run$count), budget)
        rate[r] <- mean(s$perm_p[tested] <= 0.05)
        smallest[r] <- min(s$perm_p[tested])
        # The oracle enumerates m! orders, so it is read at five units or fewer.
        id <- apply(read, 1, paste, collapse = "")
        differences <- numeric(0)
        for (pattern_id in unique(id[tested & rowSums(read) <= 5])) {
            at <- which(id == pattern_id & tested)
            exact <- oracle_p(run, y, at, which(read[at[1], ] == 1L))
            differences <- c(differences, s$perm_p[at] - exact - (1 - exact) / (1 + budget))
        }
        gap[r] <- mean(differences)
        compared[r] <- length(differences)
    }
    margin <- margin_spread(gap, 1)
    centered <- isTRUE(abs(mean(gap)) <= margin)
    cat(sprintf("  sampled path: %d units, budget %d, %d sites x %d cohorts, each cell read with\n",
                units, budget, sites, cohorts))
    cat("  probability 0.6\n")
    cat(sprintf("    path taken: %s with %s rearrangements; smallest p %.4f against 1/(1+B)\n",
                if (sampled) "sampled" else "ENUMERATED",
                if (counted) as.character(budget) else "the WRONG number of", min(smallest)))
    cat(sprintf("    = %.4f\n", 1 / (1 + budget)))
    cat(sprintf("    p - exact p - (1 - exact)/(1+B) over %d sites read in five units or fewer:\n",
                sum(compared)))
    cat(sprintf("    mean %+.4f, sd over cohorts %.4f, margin %.4f  %s\n", mean(gap), sd(gap),
                margin, if (centered) "ok" else "FAIL"))
    cat(sprintf("    rate at .05 %.4f (sd over cohorts %.4f), reported\n", mean(rate), sd(rate)))
    sampled && counted && min(smallest) >= 1 / (1 + budget) - 1e-12 && centered
}

# Units of two lanes of ONE pool: the lanes share the chromosomes the pool carried and differ only
# in their reads. A unit read through one lane of two is still a unit read, and n_observed says so
# only while roll_up() sums with na.rm.
missing_null_lanes <- function(replicates) {
    set.seed(seed + 104)
    units <- 6L
    lanes <- 2L
    cohorts <- 5L
    size <- 10
    floor_dp <- 70L
    masked <- 0.4
    sites <- max(1000L, replicates %/% 100L)
    mu <- depth_for_masking(masked, floor_dp, size)
    groups <- unit_groups(rep(lanes, units))
    hits <- matrix(0, cohorts, 3)
    tested_n <- matrix(0, cohorts, 3)
    one_lane <- 0
    read_units <- 0
    miscounted <- 0
    for (r in seq_len(cohorts)) {
        carried <- matrix(rbinom(sites * units, 100L, 0.5), sites, units) / 100
        depth <- draw_depth(sites, rep(mu, units * lanes), size)
        alt <- matrix(rbinom(length(depth), as.vector(depth),
                             as.vector(carried[, rep(seq_len(units), each = lanes)])), sites)
        masked_table <- mask_cells(list(depth - alt, alt), floor_dp, 2L)
        s <- association_run(masked_table$counts, 100, Y_Q, groups = groups)$sites
        for (k in 1:3) {
            st <- !is.na(s$S) & s$m == k + 3L
            tested_n[r, k] <- sum(st)
            hits[r, k] <- sum(s$perm_p[st] <= 0.05 + 1e-12)
        }
        lanes_read <- masked_table$read[, seq(1, 12, by = 2)] +
            masked_table$read[, seq(2, 12, by = 2)]
        one_lane <- one_lane + sum(lanes_read == 1)
        read_units <- read_units + sum(lanes_read >= 1)
        miscounted <- miscounted + sum(s$m != rowSums(lanes_read >= 1))
    }
    cat(sprintf("  lanes: six units of two lanes of one pool, %.0f%% of lanes under %d reads,\n",
                100 * masked, floor_dp))
    cat(sprintf("  %d sites x %d cohorts; %.0f%% of the units read are read through one lane\n",
                sites, cohorts, 100 * one_lane / read_units))
    cat(sprintf("    sites whose n_observed is not the units with a lane read: %d  %s\n",
                miscounted, if (miscounted == 0) "ok" else "FAIL"))
    ok <- miscounted == 0
    for (k in 1:3) {
        m <- k + 3L
        bound <- exact_bound(m, 0.05)
        rate <- sum(hits[, k]) / sum(tested_n[, k])
        margin <- margin_exact(hits[, k] / tested_n[, k], sum(tested_n[, k]), bound)
        pass <- isTRUE(rate - bound <= margin)
        cat(sprintf("    m=%d: tested %5d  rate %.4f  bound %.4f  excess %+.4f  margin %.4f  %s\n",
                    m, sum(tested_n[, k]), rate, bound, rate - bound, margin,
                    if (pass) "ok" else "FAIL"))
        ok <- pass && ok
    }
    ok
}

section_missing_null <- function(replicates) {
    patterns <- missing_null_patterns(replicates)
    cat("\n")
    strata <- missing_null_strata(replicates)
    cat("\n")
    sampled <- missing_null_sampled(replicates)
    cat("\n")
    lanes <- missing_null_lanes(replicates)
    if (!(patterns && strata && sampled && lanes)) {
        cat("\n  FAIL: a site read in m units is not given the exact m-unit p\n")
        return(FALSE)
    }
    cat("\n  PASS: every read pattern gets the exact test over the units it was read in\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# missing_published: what the run says about itself when cells are unread
#
# Three numbers describe a run: lambda_gc, theta and depth_phenotype_cor. Each is taken over
# whatever was read, so each can move with missingness for reasons that have nothing to do with
# the data.
#
# LAMBDA_GC IS NOT 1 UNDER A PERFECT NULL. It is median(S^2) / qchisq(.5, 1), and S at a site read
# in m units is a t on m - 2 degrees of freedom, so S^2 is F(1, m - 2): 1.21 at six units, 1.47 at
# four, 2.20 at three, and higher again at sites of three or four alleles, where S is the largest of
# several. Masking moves sites to fewer units, so lambda_gc rises with nothing wrong. It is gated
# against the null of the run's own mix of m, with a stated 5% tolerance on reading discrete
# counts through an F, not a statistical margin; it fails if roll_up, theta or the degrees of
# freedom of the fit distorted S under masking.
#
# THETA IS GATED PAIRED. Each cohort is analyzed fully read and masked, and the difference is what
# is judged, because independent cohorts bury a bias of a few percent under the spread of theta
# itself. Masks that ignore the allele -- at random, by a depth floor, lined up with the
# phenotype -- must leave it alone. A library that failed at every site, and a table masked at
# 85%, must leave it finite: one pool unread everywhere used to make theta NA and a run that estimated it then
# tested nothing. Allele-linked loss is reported only: it is a model the weights do not hold, not
# a property the module is entitled to.

missing_published_composition <- function(replicates) {
    set.seed(seed + 201)
    units <- 6L
    floor_dp <- 20L
    size <- 10
    cohorts <- 12L
    sites <- max(2000L, replicates %/% 40L)
    ladder <- c(0.94, 0.70, 0.45, 0.25, 0.10, 0.07)
    cells <- list(even15 = list(masked = rep(0.15, 6)),
                  heavy30 = list(masked = rep(0.30, 6)),
                  ladder = list(masked = ladder),
                  aligned = list(masked = ladder, fixed = TRUE),
                  pattern = list(read = c(0.95, 0.85, 0.72, 0.60, 0.49, 0.35)),
                  rare30 = list(masked = rep(0.30, 6), rare = TRUE))
    gated <- c("even15", "heavy30", "ladder", "aligned")

    cat(sprintf("  %d cohorts x %d sites, six units, n_chrom 100, depth negative binomial of\n",
                cohorts, sites))
    cat(sprintf("  size %g, floor %d, minSamples 2. A cell is named by the share of a pool's\n",
                size, floor_dp))
    cat("  cells under the floor: ladder 94/70/45/25/10/7%, which pool is which drawn per\n")
    cat("  cohort, and aligned the same ladder with the shallowest pool at the lowest\n")
    cat("  phenotype; pattern reads every cell at depth 200 and unit i with probability\n")
    cat("  .95/.85/.72/.60/.49/.35, no floor; rare30 draws the ALT frequency from .005-.03\n")
    cat("  instead of .05-.95\n\n")
    cat(sprintf("  %-8s | %6s %6s | %6s %7s %5s | %4s %4s %4s %4s | %7s %7s %6s | %7s %7s | %6s\n",
                "cell", "OFF", "ON", "tested", "untest", "mean", "m=3", "m=4", "m=5", "m=6",
                "lambda", "null", "ratio", "theta", "OFF", "dpc"))
    cat(sprintf("  %-8s | %6s %6s | %6s %7s %5s | %4s %4s %4s %4s | %7s %7s %6s | %7s %7s | %6s\n",
                "", "kept", "kept", "of kept", "of kept", "m", "", "", "", "", "", "", "", "ON",
                "theta", ""))
    ok <- TRUE
    for (name in names(cells)) {
        cell <- cells[[name]]
        measured <- matrix(NA_real_, cohorts, 15)
        for (r in seq_len(cohorts)) {
            if (!is.null(cell$read)) {
                read <- matrix(rbinom(sites * units, 1, rep(cell$read, each = sites)), sites,
                               units)
                depth <- matrix(200L, sites, units) * read
            } else {
                masked <- if (isTRUE(cell$fixed)) cell$masked else sample(cell$masked)
                depth <- draw_depth(sites, depth_for_masking(masked, floor_dp, size), size)
            }
            p <- if (isTRUE(cell$rare)) runif(sites, 0.005, 0.03) else runif(sites, 0.05, 0.95)
            counts <- simulate_cells(depth, 100L, p)$counts
            floor_here <- if (is.null(cell$read)) floor_dp else 1L
            on <- mask_cells(counts, floor_here, 2L)
            off <- mask_cells(counts, floor_here, units)
            run <- association_run(on$counts, 100, Y_Q, permute = FALSE)
            run_off <- if (length(off$kept) >= 3) {
                association_run(off$counts, 100, Y_Q, permute = FALSE)
            } else NULL
            tested <- !is.na(run$sites$S)
            m <- run$sites$m[tested]
            measured[r, ] <- c(length(off$kept) / sites, length(on$kept) / sites,
                               sum(tested) / length(on$kept), 1 - sum(tested) / length(on$kept),
                               mean(m), mean(m == 3), mean(m == 4), mean(m == 5), mean(m == 6),
                               run$lambda_gc, lambda_expected(m),
                               run$lambda_gc / lambda_expected(m), run$theta,
                               if (is.null(run_off)) NA_real_ else run_off$theta,
                               run$depth_phenotype_cor)
        }
        mean_of <- function(i) mean(measured[, i], na.rm = TRUE)
        cat(sprintf(paste0("  %-8s | %6.3f %6.3f | %6.3f %7.3f %5.2f | %4.2f %4.2f %4.2f %4.2f |",
                           " %7.3f %7.3f %6.3f | %7.5f %7.5f | %6s\n"),
                    name, mean_of(1), mean_of(2), mean_of(3), mean_of(4), mean_of(5), mean_of(6),
                    mean_of(7), mean_of(8), mean_of(9), mean_of(10), mean_of(11), mean_of(12),
                    mean_of(13), mean_of(14),
                    if (all(is.na(measured[, 15]))) "NA" else sprintf("%.3f", mean_of(15))))
        if (name %in% gated) {
            tolerance <- max(margin_spread(measured[, 12], length(gated)), 0.05)
            pass <- isTRUE(abs(mean_of(12) - 1) <= tolerance)
            cat(sprintf(paste0("  %8s   lambda over its df-matched null: %.3f (sd over cohorts",
                               " %.3f), tolerance %.3f  %s\n"),
                        "", mean_of(12), sd(measured[, 12]), tolerance, if (pass) "ok" else "FAIL"))
            ok <- pass && ok
        }
    }
    ok
}

missing_published_theta <- function(replicates) {
    set.seed(seed + 202)
    units <- 6L
    size <- 10
    floor_dp <- 40L
    cohorts <- 12L
    sites <- max(1500L, replicates %/% 70L)
    masks <- c("MCAR 40%", "depth floor", "phenotype-aligned", "allele-linked loss",
               "failed library", "85% masked")
    gated <- c("MCAR 40%", "depth floor", "phenotype-aligned")
    cat(sprintf("\n  theta, %d cohorts x %d sites, each analyzed fully read and masked: unit\n",
                cohorts, sites))
    cat("  truth rbinom(N, p)/N, so the true excess is about 1/N\n")
    cat(sprintf("  %-20s %4s | %7s %8s %8s | %9s %8s %7s | %s\n", "mask", "N", "masked", "theta",
                "full", "paired d", "d / 1/N", "tol", ""))
    ok <- TRUE
    for (mask in masks) {
        for (population in c(100L, 20L)) {
            difference <- numeric(cohorts)
            share <- numeric(cohorts)
            masked_theta <- numeric(cohorts)
            full_theta <- numeric(cohorts)
            tested <- numeric(cohorts)
            for (r in seq_len(cohorts)) {
                p <- runif(sites, 0.15, 0.85)
                unit_truth <- matrix(rbinom(sites * units, population, rep(p, units)) / population,
                                     sites, units)
                depth <- if (mask == "depth floor") {
                    draw_depth(sites, rep(60, units), size, site_shape = 4)
                } else draw_depth(sites, rep(100, units), size)
                retain <- if (mask == "allele-linked loss") 0.4 else 1
                counts <- simulate_cells(depth, 100L, unit_truth, retain = retain)$counts
                observed <- Reduce(`+`, counts)
                read <- switch(mask,
                    "MCAR 40%" = matrix(rbinom(sites * units, 1, 0.6), sites, units) == 1,
                    "depth floor" = observed >= floor_dp,
                    "phenotype-aligned" = matrix(rbinom(sites * units, 1,
                                                        rep(c(0.95, 0.85, 0.72, 0.60, 0.49, 0.35),
                                                            each = sites)),
                                                 sites, units) == 1,
                    "allele-linked loss" = observed >= floor_dp,
                    "failed library" = {
                        dead <- matrix(rbinom(sites * units, 1, 0.8), sites, units) == 1
                        dead[, 4] <- FALSE
                        dead
                    },
                    "85% masked" = matrix(rbinom(sites * units, 1, 0.15), sites, units) == 1)
                read <- read & observed > 0
                masked_counts <- lapply(counts, function(x) {
                    x[!read] <- 0L
                    x[rowSums(read) >= 2, , drop = FALSE]
                })
                full <- association_run(mask_cells(counts, 1L, 1L)$counts, 100, Y_Q,
                                        permute = FALSE)
                masked_run <- association_run(masked_counts, 100, Y_Q, permute = FALSE)
                full_theta[r] <- full$theta
                masked_theta[r] <- masked_run$theta
                difference[r] <- masked_run$theta - full$theta
                share[r] <- mean(!read)
                tested[r] <- masked_run$tested
            }
            judged <- mask %in% gated
            tolerance <- max(margin_spread(difference, 6), 0.05 / population)
            pass <- !judged || isTRUE(abs(mean(difference)) <= tolerance)
            cat(sprintf("  %-20s %4d | %7.3f %8.5f %8.5f | %+9.5f %+8.3f %7.5f | %s\n", mask,
                        population, mean(share), mean(masked_theta), mean(full_theta),
                        mean(difference), mean(difference) * population, tolerance,
                        if (!judged) "reported" else if (pass) "ok" else "FAIL"))
            ok <- pass && ok
            if (mask == "failed library" &&
                (any(is.na(masked_theta)) || min(tested) < 0.5 * sites)) {
                cat("    FAIL: with one pool unread everywhere theta is missing, or fewer than\n")
                cat("    half the sites were tested\n")
                ok <- FALSE
            }
            if (mask == "85% masked" && any(is.na(masked_theta))) {
                cat("    FAIL: theta is missing although some sites were read in two units\n")
                ok <- FALSE
            }
        }
    }
    ok
}

# The values lambda_gc takes on a perfectly calibrated null, by units read and by alleles held.
missing_published_reference <- function(replicates) {
    set.seed(seed + 203)
    cat("\n  lambda_gc of a perfectly calibrated null, so 1 is NOT the value to read it against\n")
    cat("  biallelic, qt(.75, m - 2)^2 / qchisq(.5, 1):")
    for (m in 3:8) cat(sprintf("  m=%d %.3f", m, lambda_expected(m)))
    cat("\n  by alleles held, equal depth 200, simulated over every subset of m of the six units\n")
    for (k in 3:4) {
        truth <- if (k == 3) c(0.60, 0.25, 0.15) else c(0.50, 0.25, 0.15, 0.10)
        cat(sprintf("  %d alleles:", k))
        for (m in 3:6) {
            statistic <- numeric(0)
            for (set in combn(6, m, simplify = FALSE)) {
                drawn <- simulate_arity(1500L, rep(200L, m), 100, truth)
                fit <- fit_multi(drawn$freq, n_eff(100, drawn$depth), drawn$site, Y_Q[set])
                statistic <- c(statistic, site_statistic(fit$t, drawn$site, 1500L))
            }
            cat(sprintf("  m=%d %.2f", m, median(statistic^2, na.rm = TRUE) / qchisq(0.5, 1)))
        }
        cat("\n")
    }
    TRUE
}

section_missing_published <- function(replicates) {
    composition <- missing_published_composition(replicates)
    theta <- missing_published_theta(replicates)
    reference <- missing_published_reference(replicates)
    if (!(composition && theta && reference)) {
        cat("\n  FAIL: a number the run publishes about itself moved with which cells were read\n")
        return(FALSE)
    }
    cat("\n  PASS: lambda_gc sits on the null of its own mix of units and theta ignores which\n")
    cat("  cells were read; the reference lines are what a perfect null reads\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# missing_informative: a cell that goes unread because of the allele it carries
#
# Reads carrying one allele can map worse or not at all -- an indel, a SNP in a divergent stretch,
# a deletion haplotype -- so a pool's depth at such a site falls the more of that allele it carries.
# Alone that is reference bias, which pulls every pool's frequency down by the same factor and
# gives no slope against the phenotype. A depth FLOOR turns it into one: a pool whose mean depth
# sits near the floor clears it only where it lost few reads, which is where it carries little of
# the allele, so the cells that survive are biased low in that pool and not in a deep one. When
# depth lines up with the phenotype the graded bias is a slope, and a null site looks associated.
#
# The generator is that one physical story and nothing else: coverage negative binomial around a
# per-pool mean, the pools' true frequencies spread by F, the ALT-carrying reads kept with
# probability r. Every site is null.
#
# BLOCK 1 screens with the closed-form weighted t, so it judges the phenomenon and not the
# module, over three tables of one draw: every cell with reads (none), step 7's default rule
# (OFF), and the same floor applied to the coverage BEFORE the loss (OFF_N), which no real run can
# do and which says whether the floor or the dependence of depth on the allele moves the rate. The
# gated rows are the controls -- OFF_N never moves, r = 1 never moves even with depth lined up with
# the phenotype, a single shallow pool at one end is never inflated, and a pool that loses half its
# ALT reads with no floor involved is inflated by every rule alike -- and one row that must show
# the effect, so the generator cannot quietly stop producing what the section exists to measure.
# Every other row is reported: where the test breaks is a finding, and a gate on it would make the
# finding a test result. The ranges of F, r and coverage spread are the generator's assumptions,
# not fitted to any library.
#
# BLOCK 2 runs the module on the worst corner, OFF and the mask on the same draw. A site read in
# every unit is the same site under both rules, so the mask does not create the exposure; it
# tests more sites under it, and a rate and a count per raw site answer different questions.
#
# BLOCK 3 says where the excess lives, by the frequency of the allele that loses reads.

informative_screen <- function(sites, mu, size, retain, F, spectrum = c(0.25, 0.75),
                               floor_dp = 20L, y = Y_Q) {
    p <- runif(sites, spectrum[1], spectrum[2])
    truth <- sapply(seq_along(mu), function(j) beta_around(p, F))
    coverage <- draw_depth(sites, mu, size)
    counts <- simulate_cells(coverage, 100L, truth, retain)$counts
    depth <- Reduce(`+`, counts)
    freq <- counts[[2]] / pmax(depth, 1)
    rate <- function(keep) {
        weight <- n_eff(100, depth[keep, , drop = FALSE])
        values <- freq[keep, , drop = FALSE]
        theta <- theta_of(values, weight)
        fit <- weighted_fit(values, 1 / (theta + 1 / weight), y)
        use <- !fit$degenerate & is.finite(fit$t)
        c(mean(2 * pt(-abs(fit$t[use]), length(y) - 2) <= 0.05), sum(use),
          cor(colMeans(1 / (theta + 1 / weight)), y))
    }
    none <- rowSums(depth == 0) == 0
    off <- rowSums(depth < floor_dp | depth == 0) == 0
    off_n <- rowSums(coverage < floor_dp | depth == 0) == 0
    a <- rate(none)
    b <- rate(off)
    c <- rate(off_n)
    list(rate = c(none = a[1], OFF = b[1], OFF_N = c[1]),
         n = c(none = a[2], OFF = b[2], OFF_N = c[2]),
         dpc = b[3], p = p, off = off, none = none, freq = freq, depth = depth)
}

informative_rows <- function() {
    ladder <- round(seq(22, 77, length.out = 6))
    end <- c(rep(60, 5), 22)
    row <- function(arrangement, mu, retain, F, size, note = "") {
        list(arrangement = arrangement, mu = mu, retain = retain, F = F, size = size, note = note)
    }
    rows <- list()
    for (pair in list(c(1, 0.3), c(0.7, 0.3), c(0.4, 0.1), c(0.4, 0.3), c(0.4, 0.5))) {
        rows <- c(rows, list(row("ladder", ladder, pair[1], pair[2], 50),
                             row("one end", end, pair[1], pair[2], 50)))
    }
    c(rows, list(row("ladder", ladder, 0.4, 0.3, 10, "coverage size 10"),
                 row("ladder", ladder, 0.4, 0.3, 300, "coverage size 300"),
                 row("pool bias", rep(60, 6), c(0.95, 0.95, 0.95, 0.95, 0.95, 0.5), 0.05, 10,
                     "pool 6 loses half its ALT reads, no floor involved")))
}

missing_informative_screen <- function(replicates) {
    set.seed(seed + 301)
    sites <- max(60000L, replicates %/% 2L)
    cat(sprintf("  screen: %d raw sites per row, six pools, n_chrom 100, ALT frequency uniform\n",
                sites))
    cat("  on .25-.75, floor 20, closed-form weighted t at alpha .05. ladder: mean depth 22, 33,\n")
    cat("  44, 55, 66, 77 in phenotype order; one end: five pools at 60 and the\n")
    cat("  highest-phenotype pool at 22\n\n")
    cat(sprintf("  %-9s %4s %4s %5s | %7s %7s %7s | %6s %5s | %8s %6s %6s  %s\n", "pools", "r", "F",
                "size", "none", "OFF", "OFF_N", "n OFF", "kept", "OFF-none", "in se", "dpc",
                "verdict"))
    ok <- TRUE
    frontier <- NULL
    for (row in informative_rows()) {
        s <- informative_screen(sites, row$mu, row$size, row$retain, row$F)
        se <- sqrt(0.05 * 0.95 / s$n["OFF"])
        se_n <- sqrt(0.05 * 0.95 / s$n["OFF_N"])
        shift <- s$rate["OFF"] - s$rate["none"]
        moved <- s$rate["OFF_N"] - s$rate["none"]
        control <- length(row$retain) == 1 && row$retain == 1
        bite <- row$arrangement == "ladder" && identical(row$retain, 0.4) && row$F == 0.5
        if (abs(moved) > 4 * se_n) {
            verdict <- "FAIL: the floor on the coverage before the loss moved the rate"
        } else if (control && abs(shift) > 4 * se) {
            verdict <- "FAIL: depth alone moved the rate"
        } else if (row$arrangement == "one end" && shift > 4 * se) {
            verdict <- "FAIL: one shallow pool inflated"
        } else if (row$arrangement == "pool bias" && abs(shift) > 4 * se) {
            verdict <- "FAIL: the floor changed an effect it does not cause"
        } else if (row$arrangement == "ladder" && shift > 4 * se) {
            verdict <- "inflated, reported"
            if (is.null(frontier)) frontier <- sprintf("r %g, F %g", row$retain[1], row$F)
        } else {
            verdict <- if (row$arrangement == "ladder" && row$retain[1] < 1) {
                "not above, reported"
            } else "ok"
        }
        if (bite && !(shift > 4 * se)) {
            verdict <- "FAIL: the effect this row exists to show is gone"
        }
        if (startsWith(verdict, "FAIL")) ok <- FALSE
        cat(sprintf(paste0("  %-9s %4s %4.1f %5g | %7.4f %7.4f %7.4f | %6d %5.2f |",
                           " %+8.4f %6.1f %6.2f  %s %s\n"),
                    row$arrangement,
                    if (length(row$retain) == 1) sprintf("%.1f", row$retain) else "mix", row$F,
                    row$size, s$rate["none"], s$rate["OFF"], s$rate["OFF_N"], s$n["OFF"],
                    s$n["OFF"] / s$n["none"], shift, shift / se, s$dpc, verdict, row$note))
    }
    cat("\n  first ladder row, in the order above, where OFF exceeds the unfloored rate by four\n")
    cat(sprintf("  standard errors: %s\n", if (is.null(frontier)) "none" else frontier))
    ok
}

missing_informative_module <- function(replicates) {
    set.seed(seed + 302)
    cohorts <- 3L
    sites <- max(3000L, replicates %/% 33L)
    mu <- round(seq(22, 77, length.out = 6))
    tally <- list(OFF = c(0, 0), m6 = c(0, 0), m5 = c(0, 0), m4 = c(0, 0))
    kept <- c(OFF = 0, ON = 0)
    published_cor <- numeric(cohorts)
    published_lambda <- numeric(cohorts)
    below_floor <- 0L
    for (r in seq_len(cohorts)) {
        p <- runif(sites, 0.25, 0.75)
        depth <- draw_depth(sites, mu, 50)
        truth <- sapply(1:6, function(j) beta_around(p, 0.3))
        counts <- simulate_cells(depth, 100L, truth, retain = 0.4)$counts
        for (mode in c("OFF", "ON")) {
            masked_table <- mask_cells(counts, 20L, if (mode == "OFF") 6L else 2L)
            run <- association_run(masked_table$counts, 100, Y_Q)
            if (isTRUE(run$skipped)) next
            s <- run$sites
            tested <- !is.na(s$S)
            below_floor <- below_floor + sum(tested & s$perm_p < 1 / factorial(s$m) - 1e-12)
            kept[mode] <- kept[mode] + length(masked_table$kept)
            if (mode == "OFF") {
                tally$OFF <- tally$OFF + c(sum(s$perm_p[tested] <= 0.05 + 1e-12), sum(tested))
            } else {
                for (m in 4:6) {
                    st <- tested & s$m == m
                    key <- paste0("m", m)
                    tally[[key]] <- tally[[key]] + c(sum(s$perm_p[st] <= 0.05 + 1e-12), sum(st))
                }
                published_cor[r] <- run$depth_phenotype_cor
                published_lambda[r] <- run$lambda_gc
            }
        }
    }
    cat(sprintf("\n  the module on the corner (ladder, r 0.4, F 0.3, size 50): %d cohorts x %d\n",
                cohorts, sites))
    cat("  raw sites, enumerated p\n")
    cat(sprintf("    %-13s %8s %9s %8s %8s %9s\n", "table", "tested", "rate .05", "bound", "excess",
                "in se"))
    rows <- list(list("OFF, 6 units", tally$OFF, 6), list("ON, 6 units", tally$m6, 6),
                 list("ON, 5 units", tally$m5, 5), list("ON, 4 units", tally$m4, 4))
    calls <- c(OFF = 0, ON = 0)
    for (row in rows) {
        hits <- row[[2]][1]
        tested <- row[[2]][2]
        bound <- exact_bound(row[[3]], 0.05)
        cat(sprintf("    %-13s %8d %9.4f %8.4f %+8.4f %9.1f\n", row[[1]], tested, hits / tested,
                    bound, hits / tested - bound,
                    (hits / tested - bound) / sqrt(bound * (1 - bound) / tested)))
        mode <- if (startsWith(row[[1]], "OFF")) "OFF" else "ON"
        calls[mode] <- calls[mode] + hits - tested * bound
    }
    cat(sprintf("    false calls above what an exact test attains, per 1000 raw sites: OFF %.2f,\n",
                1000 * calls["OFF"] / (cohorts * sites)))
    cat(sprintf("    ON %.2f; ON kept %.0f%% of the raw sites and OFF %.0f%%\n",
                1000 * calls["ON"] / (cohorts * sites), 100 * kept["ON"] / (cohorts * sites),
                100 * kept["OFF"] / (cohorts * sites)))
    cat(sprintf("    the module published depth_phenotype_cor %.3f and lambda_gc %.2f; the dpc\n",
                mean(published_cor), mean(published_lambda)))
    cat("    column above reads the same on the harmless r = 1 row\n")
    if (below_floor > 0) {
        cat(sprintf("    FAIL: %d tested sites with a p below 1/m!\n", below_floor))
    }
    below_floor == 0
}

missing_informative_bins <- function(replicates) {
    set.seed(seed + 303)
    sites <- max(40000L, replicates %/% 1.5)
    mu <- round(seq(22, 77, length.out = 6))
    s <- informative_screen(sites, mu, 50, 0.4, 0.3, spectrum = c(0.05, 0.95))
    cat("\n  by the frequency of the allele that loses reads (ladder, r 0.4, F 0.3, frequency\n")
    cat(sprintf("  .05-.95, %d raw sites), closed-form rate at .05\n", sites))
    cat(sprintf("    %-12s %8s %8s | %8s %8s | %s\n", "frequency", "none", "n", "OFF", "n",
                "share of OFF's sites"))
    theta <- theta_of(s$freq[s$off, , drop = FALSE], n_eff(100, s$depth[s$off, , drop = FALSE]))
    for (bin in list(c(0.05, 0.25), c(0.25, 0.5), c(0.5, 0.75), c(0.75, 0.95))) {
        here <- s$p >= bin[1] & s$p < bin[2] + 1e-9
        rate <- function(keep) {
            keep <- keep & here
            weight <- n_eff(100, s$depth[keep, , drop = FALSE])
            fit <- weighted_fit(s$freq[keep, , drop = FALSE], 1 / (theta + 1 / weight), Y_Q)
            use <- !fit$degenerate & is.finite(fit$t)
            c(mean(2 * pt(-abs(fit$t[use]), 4) <= 0.05), sum(use))
        }
        a <- rate(s$none)
        b <- rate(s$off)
        cat(sprintf("    %-12s %8.4f %8d | %8.4f %8d | %.2f\n",
                    sprintf("[%.2f, %.2f)", bin[1], bin[2]), a[1], a[2], b[1], b[2],
                    b[2] / sum(s$off)))
    }
    TRUE
}

section_missing_informative <- function(replicates) {
    screen <- missing_informative_screen(replicates)
    module <- missing_informative_module(replicates)
    bins <- missing_informative_bins(replicates)
    if (!(screen && module && bins)) {
        cat("\n  FAIL: a control moved, or the effect the section exists to show is gone\n")
        return(FALSE)
    }
    cat("\n  PASS: the controls hold. The inflated rows are the finding and are not gated: the\n")
    cat("  floor, acting on a depth that depends on the allele, is what moves the rate\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# missing_yield: what keeping a site on its read cells buys where an effect is really there
#
# Reported, never gated: a yield is a measurement, and the size claims it rests on are gated in
# missing_null. The null rate is printed beside every yield so that a gain cannot hide a loss of
# size. A planted site a rule dropped counts as a miss, so a rule that keeps fewer sites cannot
# look better by testing fewer.
#
# BH at six units is arithmetic and not a simulation: the smallest p is 1/720, so BH selects
# nothing unless one site in 36 tested sits at that floor. The section prints how many do and how
# many would be needed.

yield_cohort <- function(setting, sites, slope = 0.14, plant = 0.10) {
    units <- 6L
    floor_dp <- 20L
    planted <- seq_len(sites) <= plant * sites
    base <- runif(sites, 0.3, 0.7)
    truth <- matrix(base, sites, units) + outer(planted * slope, Y_Q - mean(Y_Q), "*")
    truth <- pmin(pmax(truth, 0.01), 0.99)
    if (setting == "allele-linked loss") {
        depth <- draw_depth(sites, round(seq(22, 77, length.out = 6)), 50)
        counts <- simulate_cells(depth, 100L, truth, retain = 0.4)$counts
    } else {
        masked <- c(0.40, 0.30, 0.20, 0.10, 0.05, 0.02)
        mu <- depth_for_masking(sample(masked), floor_dp, 10)
        depth <- draw_depth(sites, mu, 10,
                            site_shape = if (setting == "shared site factor") 4 else Inf)
        counts <- simulate_cells(depth, 100L, truth)$counts
    }
    arms <- list(OFF = c(floor_dp, units), ON = c(floor_dp, 2L))
    if (setting == "allele-linked loss") arms <- c(list(none = c(1L, 1L)), arms)
    out <- list()
    for (arm in names(arms)) {
        masked_table <- mask_cells(counts, arms[[arm]][1], arms[[arm]][2])
        run <- association_run(masked_table$counts, 100, Y_Q)
        on_planted <- planted[masked_table$kept]
        if (isTRUE(run$skipped)) {
            out[[arm]] <- list(kept = length(masked_table$kept), tested = 0, tested_planted = 0,
                               found = 0, false = 0, tested_null = 0, bh = 0, at_floor = 0,
                               by_k = matrix(0, 2, 4))
            next
        }
        s <- run$sites
        tested <- !is.na(s$S)
        out[[arm]] <- list(
            kept = length(masked_table$kept), tested = sum(tested),
            tested_planted = sum(tested & on_planted),
            found = sum(tested & on_planted & s$perm_p <= 0.05),
            false = sum(tested & !on_planted & s$perm_p <= 0.05),
            tested_null = sum(tested & !on_planted),
            bh = sum(!is.na(s$fdr_p) & s$fdr_p <= 0.05),
            at_floor = sum(tested & s$m == 6 & s$perm_p <= 1 / 720 + 1e-12),
            by_k = vapply(2:5, function(k) {
                c(sum(s$m >= k & tested), sum(tested & on_planted & s$m >= k & s$perm_p <= 0.05))
            }, numeric(2)))
    }
    out
}

section_missing_yield <- function(replicates) {
    set.seed(seed + 401)
    cohorts <- 4L
    sites <- max(1000L, replicates %/% 100L)
    planted <- 0.10 * sites
    cat(sprintf("  six units, %d sites x %d cohorts, 10%% of them carrying an effect of 0.14 per\n",
                sites, cohorts))
    cat("  unit of the phenotype, floor 20. independent: 40/30/20/10/5/2% of a pool's cells\n")
    cat("  under the floor, pools drawn per cohort; shared site factor: the same with a gamma\n")
    cat("  depth factor of shape 4 shared by every pool of a site; allele-linked loss: depth\n")
    cat("  ladder 22-77 lined up with the phenotype, the rising allele losing 60% of its reads\n\n")
    cat(sprintf("  %-20s %-4s | %6s %6s | %6s %7s | %9s %8s | %6s %6s %7s\n", "setting", "arm",
                "kept", "tested", "of the", "planted", "per drawn", "null", "BH", "at the",
                "needed"))
    cat(sprintf("  %-20s %-4s | %6s %6s | %6s %7s | %9s %8s | %6s %6s %7s\n", "", "", "", "",
                "planted", "found", "planted", "rate .05", "picked", "floor", "for BH"))
    for (setting in c("independent masking", "shared site factor", "allele-linked loss")) {
        cohort <- replicate(cohorts, yield_cohort(setting, sites), simplify = FALSE)
        for (arm in names(cohort[[1]])) {
            mean_of <- function(field) {
                mean(vapply(cohort, function(one) one[[arm]][[field]], numeric(1)))
            }
            cat(sprintf(paste0("  %-20s %-4s | %6.0f %6.0f | %6.1f %7.1f | %9.3f %8.4f |",
                               " %6.1f %6.1f %7.1f\n"),
                        if (arm == names(cohort[[1]])[1]) setting else "", arm, mean_of("kept"),
                        mean_of("tested"), mean_of("tested_planted"), mean_of("found"),
                        mean_of("found") / planted, mean_of("false") / mean_of("tested_null"),
                        mean_of("bh"), mean_of("at_floor"), ceiling(mean_of("tested") / 36)))
        }
        if (setting == "independent masking") {
            cat("  minSamples on the ON table, read from the K = 2 run: sites with m >= K, and\n")
            cat("  the planted sites among them found at .05\n")
            for (i in 1:4) {
                cat(sprintf("    K = %d: sites %6.0f  planted found %6.1f of %.0f drawn\n", i + 1,
                            mean(vapply(cohort, function(one) one$ON$by_k[1, i], numeric(1))),
                            mean(vapply(cohort, function(one) one$ON$by_k[2, i], numeric(1))),
                            planted))
            }
        }
    }
    cat("\n  Reported, not gated. BH needs one site at the floor, 1/720 at six units, for every\n")
    cat("  36 tested: 'needed' is that count and 'at the floor' what the table holds.\n")
    TRUE
}

# ---------------------------------------------------------------------------------------
# missing_mds: pairwise deletion, and where the ordination puts a pool read at few sites
#
# mds averages each pair of pools over the sites both were read at, so a shallow pool's pairs rest
# on fewer sites than the rest. Its claim is that this costs precision and not accuracy.
#
# BLOCK A, gated: two clades of three by drift, one pool with 85% of its cells under the floor,
# and every pair's corrected distance against the truth -- the mean over EVERY site drawn, kept or
# not, of the squared difference of the true frequencies -- under both rules, over 40 studies.
# Two-sided per pair at a family-wise level near 0.4%. It fails if pairwise deletion is biased by
# which cells were read, which is to say if the correction or the handling of an unread cell
# broke.
#
# BLOCKS B to D are reported. B: how the error of one distance falls with the sites it rests on,
# which is the number a warning on a thin pair would be set from. C: how often, with every pool one
# population, the shallow pool lands farthest from the center of the plotted axes, which is where a
# reader looks for an outlier. D: what allele-linked loss does to the distances and to the plot.
# The sites are independent here, so real data, linked along a genome, are noisier than B says.

missing_mds_rules <- function(counts, floor_dp, pools = 6L) {
    list(none = mask_cells(counts, 2L, 2L), OFF = mask_cells(counts, floor_dp, pools),
         ON = mask_cells(counts, floor_dp, 2L))
}

section_missing_mds <- function(replicates) {
    set.seed(seed + 501)
    ordinate <- module_functions(file.path(MODULES_DIR, "mds", "mds.R"), "ordinate")$ordinate
    floor_dp <- 20L
    size <- 10
    pools <- 6L
    ok <- TRUE

    studies <- 40L
    sites <- max(1000L, replicates %/% 100L)
    masked <- c(0.85, 0.30, 0.30, 0.15, 0.10, 0.05)
    mu <- depth_for_masking(masked, floor_dp, size)
    estimate <- list(OFF = array(NA_real_, c(studies, pools, pools)),
                     ON = array(NA_real_, c(studies, pools, pools)))
    shared <- estimate
    truth_d <- array(NA_real_, c(studies, pools, pools))
    for (r in seq_len(studies)) {
        truth <- population_truth(sites, pools)
        depth <- draw_depth(sites, mu, size)
        counts <- simulate_cells(depth, 100L, truth)$counts
        truth_d[r, , ] <- true_distance(truth)
        rules <- missing_mds_rules(counts, floor_dp)
        for (rule in c("OFF", "ON")) {
            distance <- nei_run(rules[[rule]]$counts)
            estimate[[rule]][r, , ] <- distance$D
            shared[[rule]][r, , ] <- distance$sites
        }
    }
    cat(sprintf("  A. two clades of three by drift (F .10 between, .03 within), %d sites x %d\n",
                sites, studies))
    cat(sprintf("  studies, cells under the floor %s\n",
                paste(sprintf("%.0f%%", 100 * masked), collapse = "/")))
    cat(sprintf("  %-5s | %8s %8s | %8s %6s %8s %6s | %8s %8s | %s\n", "pair", "shared", "shared",
                "OFF", "", "ON", "", "rmse", "rmse", "true D"))
    cat(sprintf("  %-5s | %8s %8s | %8s %6s %8s %6s | %8s %8s |\n", "", "OFF", "ON", "bias", "z",
                "bias", "z", "OFF", "ON"))
    pairs <- which(upper.tri(diag(pools)), arr.ind = TRUE)
    comparisons <- 2 * nrow(pairs)
    worst <- 0
    beyond <- 0L
    for (i in seq_len(nrow(pairs))) {
        a <- pairs[i, 1]
        b <- pairs[i, 2]
        per_rule <- sapply(c("OFF", "ON"), function(rule) {
            error <- estimate[[rule]][, a, b] - truth_d[, a, b]
            c(mean(error), mean(error) / (sd(error) / sqrt(studies)), sqrt(mean(error^2)),
              abs(mean(error)) > margin_spread(error, comparisons, level = 2e-3))
        })
        worst <- max(worst, abs(per_rule[2, ]))
        beyond <- beyond + sum(per_rule[4, ])
        if ((a == 1 && b %in% c(2, 6)) || (a == 2 && b == 3) || (a == 5 && b == 6)) {
            cat(sprintf(paste0("  %d-%d   | %8.0f %8.0f | %+8.4f %6.2f %+8.4f %6.2f |",
                               " %8.4f %8.4f | %.4f\n"),
                        a, b, mean(shared$OFF[, a, b]), mean(shared$ON[, a, b]), per_rule[1, 1],
                        per_rule[2, 1], per_rule[1, 2], per_rule[2, 2], per_rule[3, 1],
                        per_rule[3, 2], mean(truth_d[, a, b])))
        }
    }
    cat(sprintf("  all %d pairs under both rules: largest |z| %.2f; beyond the margin: %d of %d",
                nrow(pairs), worst, beyond, comparisons))
    cat(sprintf("  %s\n", if (beyond == 0) "ok" else "FAIL"))
    if (beyond > 0) ok <- FALSE

    cat("\n  B. pool 1 diverged F .10 from five others and 94% masked, ON: the error of its\n")
    cat("  distance to a deep pool against the sites it rests on\n")
    cat(sprintf("  %6s | %7s %8s %8s %17s %8s %9s\n", "sites", "shared", "mean D", "rmse",
                "rmse*sqrt(shared)", "rmse/D", "refused"))
    mu_thin <- depth_for_masking(c(0.94, rep(0.05, 5)), floor_dp, size)
    for (n_sites in c(60L, 104L, 300L, 1000L, 3000L)) {
        trials <- 100L
        error <- rep(NA_real_, trials)
        rests <- rep(NA_real_, trials)
        true_d <- rep(NA_real_, trials)
        refused <- 0L
        for (r in seq_len(trials)) {
            p <- 0.05 + 0.9 * runif(n_sites)
            truth <- matrix(p, n_sites, pools)
            truth[, 1] <- beta_around(p, 0.10)
            depth <- draw_depth(n_sites, mu_thin, size)
            on <- mask_cells(simulate_cells(depth, 100L, truth)$counts, floor_dp, 2L)
            if (length(on$kept) < 2) {
                refused <- refused + 1L
                next
            }
            distance <- nei_run(on$counts)
            if (any(is.na(distance$D))) {
                refused <- refused + 1L
                next
            }
            true_d[r] <- mean((truth[, 1] - truth[, 2])^2)
            error[r] <- distance$D[1, 2] - true_d[r]
            rests[r] <- distance$sites[1, 2]
        }
        use <- !is.na(error)
        rmse <- sqrt(mean(error[use]^2))
        cat(sprintf("  %6d | %7.1f %8.4f %8.4f %17.4f %8.2f %6d/%d\n", n_sites, mean(rests[use]),
                    mean(true_d[use]), rmse, rmse * sqrt(mean(rests[use])),
                    rmse / mean(true_d[use]), refused, trials))
    }

    cat("\n  C. every pool one population, true distance 0: how often the shallow pool 1 is the\n")
    cat("  pool farthest from the center of the two plotted axes, 1/6 if nothing singles it out\n")
    cat(sprintf("  %-28s | %6s %6s %6s\n", "pool 1 cells under the floor", "none", "OFF", "ON"))
    sites_c <- max(500L, replicates %/% 200L)
    for (thin in c(0, 0.07, 0.34, 0.94)) {
        trials <- 100L
        outermost <- matrix(NA, trials, 3)
        mu_c <- depth_for_masking(c(if (thin == 0) 0.05 else thin, rep(0.05, 5)), floor_dp, size)
        for (r in seq_len(trials)) {
            p <- 0.05 + 0.9 * runif(sites_c)
            depth <- draw_depth(sites_c, mu_c, size)
            counts <- simulate_cells(depth, 100L, matrix(p, sites_c, pools))$counts
            rules <- missing_mds_rules(counts, floor_dp)
            for (k in 1:3) {
                distance <- nei_run(rules[[k]]$counts)
                if (any(is.na(distance$D))) next
                coords <- ordinate(distance$D, 2)$coords
                outermost[r, k] <- which.max(rowSums(sweep(coords, 2, colMeans(coords))^2)) == 1
            }
        }
        cat(sprintf("  %-28s | %6.2f %6.2f %6.2f   (se %.2f)\n",
                    if (thin == 0) "5%, like the rest (control)" else sprintf("%.0f%%", 100 * thin),
                    mean(outermost[, 1], na.rm = TRUE), mean(outermost[, 2], na.rm = TRUE),
                    mean(outermost[, 3], na.rm = TRUE), sqrt(1 / 6 * 5 / 6 / trials)))
    }

    cat("\n  D. allele-linked loss, the ALT allele keeping a share r of its reads in every pool:\n")
    cat("  mean D_hat / D_true\n")
    cat(sprintf("  %-38s | %6s %6s %6s |\n", "", "none", "OFF", "ON"))
    mu_six <- depth_for_masking(c(rep(0.02, 5), 0.34), floor_dp, size)
    for (keep in c(1, 0.7, 0.4)) {
        trials <- 15L
        sites_d <- 2000L
        ratio <- matrix(NA, trials, 3)
        for (r in seq_len(trials)) {
            p <- 0.05 + 0.9 * runif(sites_d)
            truth <- matrix(p, sites_d, pools)
            truth[, 6] <- beta_around(p, 0.10)
            depth <- draw_depth(sites_d, mu_six, size)
            rules <- missing_mds_rules(simulate_cells(depth, 100L, truth, retain = keep)$counts,
                                       floor_dp)
            true_mean <- mean(sapply(1:5, function(j) mean((truth[, 6] - truth[, j])^2)))
            for (k in 1:3) ratio[r, k] <- mean(nei_run(rules[[k]]$counts)$D[6, 1:5]) / true_mean
        }
        cat(sprintf("  %-38s | %6.2f %6.2f %6.2f |\n",
                    sprintf("divergent pool 6, 34%% masked, r %.1f", keep), mean(ratio[, 1]),
                    mean(ratio[, 2]), mean(ratio[, 3])))
    }
    ladder <- depth_for_masking(c(0.60, 0.45, 0.30, 0.15, 0.07, 0.02), floor_dp, size)
    for (keep in c(1, 0.4)) {
        trials <- 15L
        sites_d <- 2000L
        ratio <- matrix(NA, trials, 3)
        rank <- matrix(NA, trials, 3)
        for (r in seq_len(trials)) {
            p <- 0.25 + 0.5 * runif(sites_d)
            truth <- sapply(1:pools, function(j) beta_around(p, 0.10))
            depth <- draw_depth(sites_d, ladder, size)
            rules <- missing_mds_rules(simulate_cells(depth, 100L, truth, retain = keep)$counts,
                                       floor_dp)
            true_d <- true_distance(truth)
            for (k in 1:3) {
                distance <- nei_run(rules[[k]]$counts)
                coords <- ordinate(distance$D, 2)$coords
                rank[r, k] <- cor(ladder, sqrt(rowSums(sweep(coords, 2, colMeans(coords))^2)),
                                  method = "spearman")
                ratio[r, k] <- mean(distance$D[upper.tri(distance$D)]) /
                    mean(true_d[upper.tri(true_d)])
            }
        }
        cat(sprintf(paste0("  %-38s | %6.2f %6.2f %6.2f | Spearman(depth, distance from",
                           " center) %.2f %.2f %.2f\n"),
                    sprintf("star, depth ladder, r %.1f", keep), mean(ratio[, 1]),
                    mean(ratio[, 2]), mean(ratio[, 3]), mean(rank[, 1]), mean(rank[, 2]),
                    mean(rank[, 3])))
    }

    if (!ok) {
        cat("\n  FAIL: pairwise deletion is biased by which cells were read\n")
        return(FALSE)
    }
    cat("\n  PASS: every pair is unbiased under both rules; blocks B to D are reported\n")
    TRUE
}

# ---------------------------------------------------------------------------------------

SECTIONS <- list(n_eff        = section_n_eff,
                 parametric   = section_parametric,
                 permutation  = section_permutation,
                 units        = section_units,
                 weights      = section_weights,
                 dispersion   = section_dispersion,
                 exchangeable = section_exchangeable,
                 breakdown    = section_breakdown,
                 floor        = section_floor,
                 arity        = section_arity,
                 power        = section_power,
                 pools        = section_pools,
                 missing_null        = section_missing_null,
                 missing_published   = section_missing_published,
                 missing_informative = section_missing_informative,
                 missing_yield       = section_missing_yield,
                 missing_mds         = section_missing_mds)

selected <- if (section == "all") {
    names(SECTIONS)
} else if (section == "missing") {
    grep("^missing_", names(SECTIONS), value = TRUE)
} else section
unknown  <- setdiff(selected, names(SECTIONS))
if (length(unknown)) stop("no such section: ", paste(unknown, collapse = ", "))

cat(sprintf("calibrate.R  library %s  seed %d  replicates %d\n\n", lib, seed, replicates))
set.seed(seed)

failed <- character(0)
for (name in selected) {
    cat(sprintf("=== %s ===\n", name))
    if (!SECTIONS[[name]](replicates)) failed <- c(failed, name)
    cat("\n")
}

if (length(failed)) {
    cat(sprintf("FAILED: %s\n", paste(failed, collapse = ", ")))
    quit(status = 1)
}
cat("all sections passed\n")
