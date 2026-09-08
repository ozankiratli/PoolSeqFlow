#!/usr/bin/env Rscript
#
# Calibration measurements for the analysis layer, against data simulated from a known truth.
#
#     calibrate.R <library directory> [section] [replicates] [seed]
#
# Sections are named for what they judge; without one, all of them run. Each prints its
# measurements as a table and then a verdict, because these numbers are written up as well as
# checked. Exits 1 if any section fails.
#
# Base R only, like the library it judges.
#
# THE SIMULATION NEVER CALLS THE LIBRARY. Every draw below is rbinom and arithmetic, so a wrong
# library function cannot cancel against itself and report agreement. dev/validation/README.md
# says why that is the whole basis for treating a number here as evidence.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: calibrate.R <library directory> [section] [replicates] [seed]")
lib        <- args[1]
section    <- if (length(args) > 1) args[2] else "all"
replicates <- if (length(args) > 2) as.integer(args[3]) else 200000L
seed       <- if (length(args) > 3) as.integer(args[4]) else 20260907L

sources <- list.files(lib, pattern = "[.]R$", full.names = TRUE)
if (length(sources) == 0) stop("no R sources in ", lib)
for (path in sources) source(path)

# The generators and estimators, shared with external.R so the two cannot drift apart. Found
# beside this script rather than relative to the working directory.
here <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
source(file.path(here, "lib.R"))

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
# The whole set of relabellings is enumerated at six pools, so this is the exact test and not an
# approximation of it. Its granularity is 1/720, which is why the smallest alpha the parametric
# section reports is missing here: no site can attain it, and that is the floor the module prints
# in its own header.
#
# The parametric rate is recomputed on the identical sites, so the two columns differ by the
# method and by nothing else.
#
# THE GATE IS ONE-SIDED. A permutation test over discrete data is conservative: shallow reads of
# a rare allele put the same frequency in several pools, tied relabellings then give tied
# statistics, and every tie counts toward the p-value. Rejecting below alpha is the test being
# safe; rejecting above it is the test being wrong. The ratio is printed either way, because a
# user who asked for 0.01 and got a quarter of it is owed the number.
section_permutation <- function(replicates) {
    pools   <- 6
    n_chrom <- 100
    sites   <- max(2000L, replicates %/% 10L)
    y       <- rnorm(pools)
    labels  <- relabellings(y)

    cat(sprintf("  %d pools, n_chrom %d, %d sites per cell, all %d relabellings\n\n",
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
    cat(sprintf("  %d sites per cell, %d sampled relabellings, alpha %.2f\n\n",
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
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabellings, alpha %.2f\n\n",
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
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabellings, alpha %.2f\n\n",
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
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabellings, alpha %.2f\n\n",
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
    cat(sprintf("  %d poolings per cell, %d sites each, %d relabellings, alpha %.2f\n\n",
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
# design can survive any correction. That is the property the manual leans on.
#
# The residual scheme moves residuals rather than labels, so it has 6! = 720 rearrangements and a
# floor of 1/720 whatever the phenotype's shape. The resolution is real under the model - these
# are enumerated exhaustively here, so what the table shows is exact and not a sampling artefact -
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

    moves <- relabellings(seq_len(pools))
    assignments <- unique(relabellings(y))

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
            centre <- rowSums(held * values) / rowSums(held)
            z <- (values - centre) * root
            over <- integer(length(top))
            for (row in seq_len(nrow(moves))) {
                rebuilt <- centre + z[, moves[row, ], drop = FALSE] / root
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
            centre <- rowSums(weight[drawn$site, ] * drawn$freq) / total[drawn$site]
            z <- (drawn$freq - centre) * root[drawn$site, ]

            over <- integer(sites)
            for (draw in seq_len(draws)) {
                moved <- sample(pools)
                rebuilt <- centre + z[, moved, drop = FALSE] / root[drawn$site, , drop = FALSE]
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
            centre <- rowSums(weight[drawn$site, ] * drawn$freq) / rowSums(weight)[drawn$site]
            z <- (drawn$freq - centre) * root[drawn$site, ]
            over <- integer(sites)
            for (draw in seq_len(draws)) {
                rebuilt <- centre + z[, sample(pools), drop = FALSE] / root[drawn$site, ,
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

    cat(sprintf("  n_chrom %d, %d sites per pooling, %d poolings, %d relabellings, alpha %.2f\n",
                n_chrom, sites, reps, draws, alpha))
    cat(sprintf("  pooling EVEN throughout; power measured at slope %.2f\n\n",
                slope))
    # The smallest p a design of this size can reach by relabelling at all. Reversing the
    # phenotype negates the slope and leaves |t| alone, so the reversal always ties with the
    # observed one and the floor is TWO over the number of orderings, never one.
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
                 pools        = section_pools)

selected <- if (section == "all") names(SECTIONS) else section
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
