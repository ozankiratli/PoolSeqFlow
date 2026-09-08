# The generators and estimators the validation scripts share.
#
# `calibrate.R` measures calibration and power against a known truth; `external.R` compares the
# same statistic against an independently written tool. They must fit and permute identically or
# neither result says anything about the other, so both source this and neither defines its own.
#
# Base R only. NOTHING HERE THAT GENERATES DATA MAY CALL THE LIBRARY UNDER TEST - every draw is
# rbinom and arithmetic, so a wrong `n_eff` cannot cancel against itself. The estimators below
# may and do; they are what is on trial.

# The variance of a sample variance, from the sample's own fourth moment. Reported per cell so a
# disagreement is read in standard errors rather than in percent: the same 1% gap is decisive at
# one grid point and meaningless at another.
moments <- function(x) {
    centered  <- x - mean(x)
    variance <- mean(centered^2)
    list(variance = variance,
         se       = sqrt((mean(centered^4) - variance^2) / length(x)))
}

# ---------------------------------------------------------------------------------------
# Generators.

# One cohort of null sites: every pool at one site is drawn from the SAME true frequency, so
# nothing anywhere is associated with anything. Returns the integer counts the depth table would
# hold. The weights are not computed here - they belong to the estimator, which is what is on
# trial.
simulate_null <- function(sites, pools, n_chrom, depth, p) {
    carried <- rbinom(sites * pools, n_chrom, p)
    alt     <- rbinom(sites * pools, depth, carried / n_chrom)
    list(freq  = matrix(alt / depth, nrow = sites),
         depth = matrix(depth, nrow = sites, ncol = pools))
}

# The same, with the pools grouped into units that each carry their own true frequency. A unit's
# pools therefore agree with each other beyond what depth alone explains, which is what makes them
# one independent observation rather than several.
#
# `dispersion` is the between-unit variance as a fraction of p(1-p): 0 leaves every unit at the
# same truth, and the Beta below has mean p and variance dispersion*p(1-p) exactly.
simulate_clustered <- function(sites, units, per_unit, n_chrom, depth, p, dispersion) {
    truth <- if (dispersion <= 0) {
        matrix(p, nrow = sites, ncol = units)
    } else {
        spread <- (1 - dispersion) / dispersion
        matrix(rbeta(sites * units, p * spread, (1 - p) * spread), nrow = sites)
    }
    freq <- matrix(0, nrow = sites, ncol = units * per_unit)
    for (unit in seq_len(units)) {
        for (pool in seq_len(per_unit)) {
            carried <- rbinom(sites, n_chrom, truth[, unit])
            freq[, (unit - 1L) * per_unit + pool] <-
                rbinom(sites, depth, carried / n_chrom) / depth
        }
    }
    list(freq = freq, depth = matrix(depth, nrow = sites, ncol = units * per_unit))
}

# The same, with the individuals contributing unevenly to the pool. `n_eff` assumes every
# chromosome in a pool is equally likely to be read; DNA that was quantified badly is not.
#
# Each pool draws its own contribution vector ONCE - the mixture is physical and does not change
# between sites - from a Dirichlet of the given concentration. An infinite concentration is the
# even pool `n_eff` assumes; concentration 1 is uniform on the simplex, which leaves a pool
# carrying about twice the variance of its nominal size.
simulate_skewed <- function(sites, depths, n_ind, ploidy, p, concentration) {
    freq <- matrix(0, nrow = sites, ncol = length(depths))
    for (pool in seq_along(depths)) {
        share <- if (is.finite(concentration)) {
            drawn <- rgamma(n_ind, shape = concentration, rate = 1)
            drawn / sum(drawn)
        } else {
            rep(1 / n_ind, n_ind)
        }
        carried      <- matrix(rbinom(sites * n_ind, ploidy, p), nrow = sites)
        truth        <- as.vector(carried %*% share) / ploidy
        freq[, pool] <- rbinom(sites, depths[pool], truth) / depths[pool]
    }
    list(freq  = freq,
         depth = matrix(depths, nrow = sites, ncol = length(depths), byrow = TRUE))
}

# A site that really is associated: the pool's true frequency moves with its phenotype, and the
# same two samplings then stand between that and the table.
simulate_effect <- function(sites, depths, n_chrom, base, slope, y) {
    truth <- base + slope * (y - mean(y))
    freq <- matrix(0, nrow = sites, ncol = length(depths))
    for (pool in seq_along(depths)) {
        carried <- rbinom(sites, n_chrom, truth[pool])
        freq[, pool] <- rbinom(sites, depths[pool], carried / n_chrom) / depths[pool]
    }
    list(freq = freq, depth = matrix(depths, nrow = sites, ncol = length(depths), byrow = TRUE))
}

# Multinomial counts by stick-breaking, so it vectorizes over sites where rmultinom does not.
# `prob` is one row of allele probabilities per site and `size` one count per site.
multinomial_rows <- function(size, prob) {
    out <- matrix(0, nrow = nrow(prob), ncol = ncol(prob))
    left <- size
    remaining <- rep(1, nrow(prob))
    for (allele in seq_len(ncol(prob) - 1)) {
        share <- prob[, allele] / remaining
        share[!is.finite(share)] <- 0
        out[, allele] <- rbinom(nrow(prob), left, pmin(pmax(share, 0), 1))
        left <- left - out[, allele]
        remaining <- remaining - prob[, allele]
    }
    out[, ncol(prob)] <- left
    out
}

# Null sites of a given arity: the same two samplings as before with a multinomial at each stage,
# so the k frequencies of a pool sum to one exactly and every pool is drawn from one truth.
# Returned in the module's own layout - one row per ALLELE, one row of weights per SITE.
simulate_arity <- function(sites, depths, n_chrom, truth) {
    alleles <- length(truth)
    site <- rep.int(seq_len(sites), rep.int(alleles, sites))
    freq <- matrix(0, nrow = sites * alleles, ncol = length(depths))
    for (pool in seq_along(depths)) {
        carried <- multinomial_rows(rep.int(n_chrom, sites),
                                    matrix(truth, nrow = sites, ncol = alleles, byrow = TRUE))
        read <- multinomial_rows(rep.int(depths[pool], sites), carried / n_chrom)
        freq[, pool] <- as.vector(t(read)) / depths[pool]
    }
    list(freq = freq, site = site,
         depth = matrix(depths, nrow = sites, ncol = length(depths), byrow = TRUE))
}

# The triallelic site the multiallelic decision exists for: BOTH alternates rise with the
# phenotype and the reference falls by the sum of them, so the reference row carries twice the
# signal of either alternate and neither alternate alone is impressive. An implementation that
# minimises over the alternates cannot see what one that maximises over every allele can.
# The other triallelic shape, and the two cannot be reduced the same way. Here the two alternates
# move in OPPOSITE directions and the reference does not move at all, so collapsing the alternates
# together destroys the signal outright while reading either one alone finds it. On `split` the
# collapse is what works and reading one alternate is weak. A genome holds both.
simulate_opposed <- function(sites, depths, n_chrom, slope, y) {
    moved <- slope * (y - mean(y))
    site <- rep.int(seq_len(sites), rep.int(3L, sites))
    freq <- matrix(0, nrow = sites * 3L, ncol = length(depths))
    for (pool in seq_along(depths)) {
        truth <- c(0.50, 0.25 + moved[pool], 0.25 - moved[pool])
        carried <- multinomial_rows(rep.int(n_chrom, sites),
                                    matrix(truth, nrow = sites, ncol = 3L, byrow = TRUE))
        read <- multinomial_rows(rep.int(depths[pool], sites), carried / n_chrom)
        freq[, pool] <- as.vector(t(read)) / depths[pool]
    }
    list(freq = freq, site = site,
         depth = matrix(depths, nrow = sites, ncol = length(depths), byrow = TRUE))
}

simulate_split <- function(sites, depths, n_chrom, slope, y) {
    moved <- slope * (y - mean(y))
    site <- rep.int(seq_len(sites), rep.int(3L, sites))
    freq <- matrix(0, nrow = sites * 3L, ncol = length(depths))
    for (pool in seq_along(depths)) {
        truth <- c(0.50 - 2 * moved[pool], 0.25 + moved[pool], 0.25 + moved[pool])
        carried <- multinomial_rows(rep.int(n_chrom, sites),
                                    matrix(truth, nrow = sites, ncol = 3L, byrow = TRUE))
        read <- multinomial_rows(rep.int(depths[pool], sites), carried / n_chrom)
        freq[, pool] <- as.vector(t(read)) / depths[pool]
    }
    list(freq = freq, site = site,
         depth = matrix(depths, nrow = sites, ncol = length(depths), byrow = TRUE))
}

# ---------------------------------------------------------------------------------------
# Estimators. These MAY call the library, and are what the measurements judge.

# The weighted simple regression of each site's frequency on the phenotype, vectorized over
# sites: one row of the matrices is one site, one column is one pool.
#
# `spent` is the weighted residual sum of squares and `total` the weighted sum of squares about
# the mean. A site where the two are equal to the last bit has no residual left for a standard
# error to come from, so t is Inf or NaN by arithmetic rather than by evidence; the caller drops
# those rather than reading them.
weighted_fit <- function(freq, wt, y) {
    pools <- ncol(freq)
    phen  <- matrix(y, nrow = nrow(freq), ncol = pools, byrow = TRUE)
    scale <- rowSums(wt)
    yc    <- phen - rowSums(wt * phen) / scale
    fc    <- freq - rowSums(wt * freq) / scale
    sxx   <- rowSums(wt * yc * yc)
    slope <- rowSums(wt * yc * fc) / sxx
    spent <- rowSums(wt * (fc - slope * yc)^2)
    list(t          = slope / sqrt(spent / (pools - 2) / sxx),
         degenerate = spent <= .Machine$double.eps * rowSums(wt * fc * fc))
}

# The allele-level fit, weights held per site and read per allele.
fit_multi <- function(freq, weight, site, y) {
    phen <- matrix(y, nrow = nrow(weight), ncol = ncol(weight), byrow = TRUE)
    total <- rowSums(weight)
    centered <- phen - rowSums(weight * phen) / total
    sxx <- rowSums(weight * centered * centered)
    wide <- weight[site, , drop = FALSE]
    across <- centered[site, , drop = FALSE]
    middle <- freq - rowSums(wide * freq) / total[site]
    slope <- rowSums(wide * across * middle) / sxx[site]
    spent <- rowSums(wide * (middle - slope * across)^2)
    scatter <- rowSums(wide * middle * middle)
    list(t = slope / sqrt(spent / (ncol(weight) - 2) / sxx[site]),
         degenerate = spent <= 64 * .Machine$double.eps * scatter)
}

# The largest |t| over every allele of a site. An allele that does not vary has a slope of zero
# over no residual, so its t is 0/0 and takes no part; a separated one is infinite and does. NA
# sorts first, so a site whose alleles all lack a test keeps NA rather than picking one up.
site_statistic <- function(t, site, sites) {
    size <- abs(t)
    size[is.na(t)] <- NA_real_
    order <- order(site, size, na.last = FALSE)
    last <- !duplicated(site[order], fromLast = TRUE)
    out <- rep(NA_real_, sites)
    out[site[order][last]] <- size[order][last]
    out
}

# The p-value from a SAMPLED permutation null: one added to both the count and the total.
#
# Dividing the raw count by the number of draws returns 0 for a statistic no draw reached, and no
# permutation p can be 0 - the observed labeling is always one of the labelings. Measured on
# data satisfying every assumption of the model, the raw form rejects at 0.0569 where it was asked
# for 0.05, at 300 draws. An enumerated null needs no such correction: the observed labeling is
# already in the set being counted.
#
# AND SAMPLING A SET SMALL ENOUGH TO ENUMERATE BREAKS THE FLOOR. At four pools there are 24
# orderings and a floor of 2/24 = 0.083, but 150 draws taken with replacement reach below 0.05 by
# luck alone - measured at 0.0155. Enumerate whenever the set fits.
sampled_p <- function(reached, draws) (1 + reached) / (1 + draws)

# Every relabeling of a phenotype of this length, as one row each. 720 at six pools, which is
# the whole null the permutation p is read off.
relabelings <- function(x) {
    if (length(x) == 1) return(matrix(x, nrow = 1))
    do.call(rbind, lapply(seq_along(x),
                          function(i) cbind(x[i], relabelings(x[-i]))))
}

# Permuting a quantity that IS exchangeable, instead of the labels.
#
# Pools read at different depths carry different precision. Weighted least squares handles that
# for estimation, but a permutation test needs the observations to be interchangeable, and unequal
# variances are not made equal by weighting them correctly. Under the null the residuals about the
# weighted mean have variance proportional to 1/w, and z = e * sqrt(w) does not:
#
#     z_i  = (f_i - fbar_w) * sqrt(w_i)          equal variance, so interchangeable
#     f*_i = fbar_w + z_sigma(i) / sqrt(w_i)     put back at THIS pool's precision
#
# One permutation sigma serves every site in a draw, as the label scheme does, so the correlation
# between sites survives into the null and a genome-wide maximum still means something.
residual_p <- function(freq, weight, y, draws) {
    root <- sqrt(weight)
    center <- rowSums(weight * freq) / rowSums(weight)
    z <- (freq - center) * root

    fit <- weighted_fit(freq, weight, y)
    keep <- !fit$degenerate
    seen <- abs(fit$t[keep])
    held <- weight[keep, , drop = FALSE]
    over <- integer(length(seen))
    for (draw in seq_len(draws)) {
        moved <- sample(ncol(freq))
        rebuilt <- center[keep] + z[keep, moved, drop = FALSE] / root[keep, , drop = FALSE]
        under <- abs(weighted_fit(rebuilt, held, y)$t)
        under[!is.finite(under)] <- Inf
        over <- over + (under >= seen)
    }
    out <- rep(NA_real_, nrow(freq))
    out[keep] <- sampled_p(over, draws)
    out
}

residual_permutation <- function(freq, weight, y, draws, alpha) {
    mean(residual_p(freq, weight, y, draws) <= alpha, na.rm = TRUE)
}

# The same over a table holding several alleles per site, where the statistic is the largest |t|
# the site offers. WHOLE POOL COLUMNS MOVE TOGETHER, which preserves the sum-to-one constraint
# exactly: a pool's residuals sum to zero across its alleles, so a rebuilt pool's frequencies
# still sum to one. Permuting alleles independently would not, and would be a different null.
residual_p_multi <- function(freq, weight, site, sites, y, draws) {
    root <- sqrt(weight)
    center <- rowSums(weight[site, , drop = FALSE] * freq) / rowSums(weight)[site]
    z <- (freq - center) * root[site, , drop = FALSE]

    observed <- site_statistic(fit_multi(freq, weight, site, y)$t, site, sites)
    over <- integer(sites)
    for (draw in seq_len(draws)) {
        rebuilt <- center + z[, sample(ncol(freq)), drop = FALSE] / root[site, , drop = FALSE]
        under <- site_statistic(fit_multi(rebuilt, weight, site, y)$t, site, sites)
        over <- over + (!is.na(under) & under >= observed)
    }
    out <- sampled_p(over, draws)
    out[is.na(observed)] <- NA_real_
    out
}

# The excess dispersion a pooling leaves behind, estimated from the data by method of moments: the
# scatter a site actually shows, less the sampling variance the weights predict, in units of
# p(1-p). Clamped at zero because a negative excess is noise and not a pool more precise than its
# own sampling.
#
# This is what makes the standardised residuals exchangeable when the pooling was uneven, and it
# is a diagnostic worth printing in its own right: it says what the weights had to absorb.
theta_of <- function(freq, weight) {
    center <- rowMeans(freq)
    spread <- apply(freq, 1, var)
    scale <- center * (1 - center)
    excess <- (spread - scale * rowMeans(1 / weight)) / scale
    max(0, mean(excess[is.finite(excess)]))
}

# The excess a Dirichlet of this concentration actually produces, from the moments rather than
# from the simulation: a pool's skew factor is k = n_ind * E[sum c^2], the model assumes k = 1,
# and the variance it fails to account for is p(1-p)(k - 1)/n_chrom. So theta_of has something to
# be judged against.
theta_true <- function(concentration, n_ind, n_chrom) {
    if (!is.finite(concentration)) return(0)
    ((n_ind * (concentration + 1) / (n_ind * concentration + 1)) - 1) / n_chrom
}
