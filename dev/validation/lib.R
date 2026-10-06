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
# orderings, and the phenotype of calibrate.R's section_pools, where this was measured, is evenly
# spaced, so each ordering ties with its own reversal and relabeling cannot go below 2/24 = 0.083;
# but 150 draws taken with replacement reach below 0.05 by luck alone - measured at 0.0155.
# Enumerate whenever the set fits. 2/24 is the floor of moving labels on an evenly spaced
# phenotype only; the module's design_floor is 1/24, the identity being the one ordering sure to
# tie.
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

# ---------------------------------------------------------------------------------------
# Unread cells: generators.
#
# The missing_* sections of calibrate.R, and agree.R, draw tables in which some cells were not
# read, written as step 7 writes them with vcffilter.keepLowDepthAsZero on: zero reads of every
# allele, which the parse turns into depth 0 and no frequency. A cell is one pool's reads at one
# site. The discipline above holds: rbinom, rnbinom, rgamma, rbeta, multinomial_rows and
# arithmetic, and nothing from modules/lib/.
#
# Every table is a list of count matrices, one per allele with REF first, one row per site and one
# column per pool -- the cells of a depth table before they are joined with commas.

# Read depth at every cell, one column per pool: negative binomial with mean mu[pool] * g[site],
# Poisson when size is infinite. g is a gamma factor of mean 1 SHARED by the pools of a site, so
# the same sites are shallow everywhere at once; an infinite site_shape switches it off.
draw_depth <- function(sites, mu, size, site_shape = Inf) {
    g <- if (is.finite(site_shape)) rgamma(sites, shape = site_shape, rate = site_shape) else
        rep(1, sites)
    do.call(cbind, lapply(mu, function(m) {
        if (is.finite(size)) rnbinom(sites, mu = m * g, size = size) else rpois(sites, m * g)
    }))
}

# The mean depth at which a share `masked` of a pool's cells falls below `floor`, depth 0
# included. A cell of a section is named by how much of a pool is masked, which a reader can
# picture, rather than by a mean depth nobody can.
depth_for_masking <- function(masked, floor, size) {
    vapply(masked, function(target) {
        uniroot(function(mu) pnbinom(floor - 1, size = size, mu = mu) - target,
                lower = 0.5, upper = 1e4, tol = 1e-9)$root
    }, numeric(1))
}

# The two-stage draw at every cell of a depth matrix: the chromosomes a pool carried, then the
# reads. `truth` is the true ALT frequency per cell, a matrix or a vector recycled down the
# columns. `retain` is the share of ALT-carrying reads that map, per pool: the ones that do not are
# not in the cell at all, so the observed depth is REF + ALT and FALLS as the pool carries more of
# the allele. That is the whole of the allele-linked loss the informative section measures.
#
# A retain above 1 is not supported: r and 1/r are one experiment with the alleles swapped, and
# rbinom returns NA for a probability above 1 without saying why.
simulate_cells <- function(depth, n_chrom, truth, retain = 1) {
    carried <- matrix(rbinom(length(depth), n_chrom, as.vector(truth)), nrow(depth)) / n_chrom
    alt0 <- matrix(rbinom(length(depth), as.vector(depth), as.vector(carried)), nrow(depth))
    alt <- if (all(retain == 1)) alt0 else {
        kept <- rep(retain, length.out = ncol(depth))[col(depth)]
        matrix(rbinom(length(depth), as.vector(alt0), kept), nrow(depth))
    }
    list(counts = list(ref = depth - alt0, alt = alt), carried = carried, coverage = depth)
}

# The same at k alleles: `truth` is one row of allele probabilities per site. A depth of 0 draws
# nothing, which is what lets it stand for an unread cell.
simulate_alleles <- function(depth, n_chrom, truth) {
    k <- ncol(truth)
    out <- replicate(k, matrix(0L, nrow(depth), ncol(depth)), simplify = FALSE)
    for (pool in seq_len(ncol(depth))) {
        carried <- multinomial_rows(rep.int(n_chrom, nrow(depth)), truth)
        read <- multinomial_rows(depth[, pool], carried / n_chrom)
        for (allele in seq_len(k)) out[[allele]][, pool] <- as.integer(read[, allele])
    }
    out
}

# A Beta draw with mean p and variance F p(1-p): the spread between populations, in the units
# `dispersion` uses above. F of zero leaves every population at p.
beta_around <- function(p, F) {
    if (F <= 0) return(p)
    rbeta(length(p), p * (1 - F) / F, (1 - p) * (1 - F) / F)
}

# What bin/mask_depth.awk does to a table. A cell is READ when its depth is at least `floor` and
# above zero, and every other cell is written as zeros; a site is kept when at least `min_samples`
# of its cells are read. min_samples equal to the number of pools is step 7's default rule, under
# which a kept site has no cell left to rewrite. Returns the masked table of the kept sites, which
# cells of it are read, and the kept rows' indices in the table given.
#
# A second definition of the mask. agree.R holds it to the awk, cell by cell.
mask_cells <- function(counts, floor, min_samples) {
    depth <- Reduce(`+`, counts)
    read <- depth >= floor & depth > 0
    keep <- rowSums(read) >= min_samples
    list(counts = lapply(counts, function(m) {
             m[!read] <- 0L
             m[keep, , drop = FALSE]
         }),
         read = read[keep, , drop = FALSE], kept = which(keep))
}

# Every pattern of read units at once: per_set[m] sites for each of the choose(n, m) patterns of
# m units. Returns the 0/1 read matrix, each site's count of read units, and a label naming its
# pattern.
enumerated_reads <- function(per_set) {
    units <- length(per_set)
    rows <- list()
    for (m in seq_len(units)) {
        if (per_set[m] == 0) next
        for (set in combn(units, m, simplify = FALSE)) {
            pattern <- integer(units)
            pattern[set] <- 1L
            rows[[length(rows) + 1]] <- matrix(pattern, per_set[m], units, byrow = TRUE)
        }
    }
    read <- do.call(rbind, rows)
    list(read = read, size = rowSums(read), id = apply(read, 1, paste, collapse = ""))
}

# Two clades of three populations by drift: each clade F_clade from an ancestral frequency, each
# pool F_pool from its clade. One column of true frequencies per pool.
population_truth <- function(sites, pools = 6L, F_clade = 0.10, F_pool = 0.03) {
    ancestral <- 0.05 + 0.90 * rbeta(sites, 1, 1)
    clade <- sapply(1:2, function(i) beta_around(ancestral, F_clade))
    sapply(seq_len(pools), function(j) beta_around(clade[, if (j <= pools / 2) 1 else 2], F_pool))
}

# The distance the truth puts between two pools: over EVERY site drawn, kept or not, the mean
# squared difference of the true frequencies, which is Nei's minimum distance at two alleles.
true_distance <- function(truth) {
    out <- matrix(0, ncol(truth), ncol(truth))
    for (a in seq_len(ncol(truth))) {
        for (b in seq_len(ncol(truth))) out[a, b] <- mean((truth[, a] - truth[, b])^2)
    }
    out
}

# ---------------------------------------------------------------------------------------
# Unread cells: estimators. These call the library AND the module's own functions, and are what
# the missing_* sections judge.

# The module's own arithmetic, parsed out of its script rather than copied into this file.
# association.R cannot be sourced -- its top level reads argv and needs jsonlite -- so only the
# top-level `name <- function` assignments asked for are evaluated, with the OPTS they read. A name
# the script no longer defines stops the run, so a rename cannot turn a section into a no-op.
module_functions <- function(path, wanted, workers = 1L, bin = 100000L) {
    if (!file.exists(path)) stop("module_functions: no module script at ", path)
    env <- new.env(parent = globalenv())
    env$OPTS <- list(workers = workers, binSize = bin)
    found <- character(0)
    for (e in parse(path)) {
        if (is.call(e) && identical(e[[1]], as.name("<-")) && is.name(e[[2]]) &&
            as.character(e[[2]]) %in% wanted && is.call(e[[3]]) &&
            identical(e[[3]][[1]], as.name("function"))) {
            eval(e, env)
            found <- c(found, as.character(e[[2]]))
        }
    }
    gone <- setdiff(wanted, found)
    if (length(gone)) {
        stop("module_functions: ", path, " no longer defines ", paste(gone, collapse = ", "))
    }
    env
}

# The functions association_run() calls, and nothing it does not.
ASSOCIATION_FUNCTIONS <- c("roll_up", "fit_alleles", "site_statistic", "dispersion_of",
                           "rearrangements", "permutation_p", "spread_of")

# association.R's functions under a modules directory, parsed once per process.
association_module <- local({
    parsed <- list()
    function(modules) {
        path <- file.path(modules, "association", "association.R")
        if (is.null(parsed[[path]])) {
            parsed[[path]] <<- module_functions(path, ASSOCIATION_FUNCTIONS)
        }
        parsed[[path]]
    }
})

# The unit map association_run() takes when pools are grouped: `sizes` pools per unit, named P1,
# P2, ... in column order, as association_run() names the columns.
unit_groups <- function(sizes) {
    ends <- cumsum(sizes)
    starts <- ends - sizes + 1L
    setNames(lapply(seq_along(sizes), function(u) paste0("P", starts[u]:ends[u])),
             paste0("U", seq_along(sizes)))
}

# association.R's main loop over one depth table, in its order: the parse, n_eff per pool, the
# roll-up to units, theta, the two-term weights, the fit, the statistic, the untestable rule, the
# permutation p, BH over the tested sites, and the numbers the module publishes about the run.
# These fifteen lines are the only part of the module restated here; agree.R holds them to the
# shipped script.
#
# `groups` maps unit names to pool names, one pool per unit when NULL. `dispersion` NULL estimates
# theta and a number pins it. permute = FALSE stops before the permutation, which is all lambda_gc
# and theta need.
#
# A table of fewer than two sites is returned unanalyzed with `skipped` set. The module itself
# stops on a one-site table, and a section that masks heavily must report that rather than die.
association_run <- function(counts, n_chrom, y, groups = NULL, budget = 10000L, dispersion = NULL,
                            permute = TRUE, module = association_module(MODULES_DIR)) {
    pools <- ncol(counts[[1]])
    names_p <- paste0("P", seq_len(pools))
    if (is.null(groups)) groups <- setNames(as.list(names_p), names_p)
    sites <- nrow(counts[[1]])
    if (sites < 2) {
        return(list(sites = data.frame(m = integer(0), S = numeric(0), perm_p = numeric(0),
                                       fdr_p = numeric(0), flagged = integer(0)),
                    theta = NA_real_, tested = 0L, selected = 0L, lambda_gc = NA_real_,
                    depth_phenotype_cor = NA_real_, held = NULL, parsed = NULL,
                    exhaustive = NA, count = NA_integer_, floor = NA_real_, skipped = TRUE))
    }
    cells <- lapply(seq_len(pools), function(j) {
        do.call(paste, c(lapply(counts, function(m) m[, j]), sep = ","))
    })
    names(cells) <- names_p
    parsed <- allele_frequencies(cells)
    weight <- vapply(seq_len(pools), function(i) n_eff(n_chrom, parsed$depth[, i]),
                     numeric(sites))
    if (!is.matrix(weight)) weight <- matrix(weight, nrow = sites)
    colnames(weight) <- names_p

    held <- module$roll_up(parsed$freq, weight, parsed$site, groups)
    theta <- if (is.null(dispersion)) {
        module$dispersion_of(held$freq, held$weight, parsed$site)
    } else as.numeric(dispersion)
    if (!is.na(theta)) held$weight <- 1 / (theta + 1 / held$weight)

    fit <- module$fit_alleles(held$freq, held$weight, parsed$site, y)
    observed <- module$site_statistic(fit$t, parsed$site, sites)
    varied <- module$spread_of(held$weight, y)
    untestable <- fit$observed < 3 | !varied
    observed[untestable] <- NA_real_
    tested <- sum(!is.na(observed))

    ran <- permute && tested > 0
    perm <- if (ran) {
        module$permutation_p(held$freq, held$weight, parsed$site, sites, y, observed, budget)
    } else list(p = rep(NA_real_, sites), count = NA_integer_, exhaustive = NA, floor = NA_real_)
    adjusted <- rep(NA_real_, sites)
    if (ran) {
        adjusted[!is.na(observed)] <- p.adjust(perm$p[!is.na(observed)], method = "BH",
                                               n = tested)
    }
    alive <- !is.na(observed)
    spent <- !is.finite(fit$t) | fit$variance <= 0 | fit$exhausted
    flagged <- as.integer(tapply(spent, parsed$site, any))
    flagged[!varied] <- NA_integer_

    list(sites = data.frame(m = fit$observed, S = observed, perm_p = perm$p, fdr_p = adjusted,
                            flagged = flagged),
         theta = theta, tested = tested,
         selected = sum(alive & !is.na(adjusted) & adjusted <= 0.05),
         lambda_gc = if (any(alive)) median(observed[alive]^2) / qchisq(0.5, 1) else NA_real_,
         depth_phenotype_cor = suppressWarnings(cor(colMeans(held$weight, na.rm = TRUE), y,
                                                    use = "pairwise.complete.obs")),
         held = held, parsed = parsed, exhaustive = perm$exhaustive, count = perm$count,
         floor = perm$floor)
}

# The exact m-unit p, by brute force from the specification and NOTHING of the module's
# rearrangement: for the sites read in exactly the units `units`, take their held weights and
# frequencies, rearrange the residuals z = (f - fbar_w) sqrt(w) through every one of the m!
# orders, rebuild each unit at its own precision, refit with lib.R's fit_multi, and count the
# orders whose statistic reaches the observed one under the module's tie rule. `at` indexes the
# sites in the run. Returns one p per site of `at`, with the oracle's own statistic as attribute S.
#
# The held weights and frequencies are the module's -- its roll_up and its theta -- so this checks
# the rearrangement and the fit, and the test suite's Python corpus owns the rest.
oracle_p <- function(run, y, at, units) {
    rows <- which(run$parsed$site %in% at)
    site <- match(run$parsed$site[rows], at)
    freq <- run$held$freq[rows, units, drop = FALSE]
    weight <- run$held$weight[at, units, drop = FALSE]
    root <- sqrt(weight)
    center <- rowSums(weight[site, , drop = FALSE] * freq) / rowSums(weight)[site]
    z <- (freq - center) * root[site, , drop = FALSE]
    seen <- site_statistic(fit_multi(freq, weight, site, y[units])$t, site, length(at))
    reach <- pmin(seen - 1e-12, seen * (1 - 1e-12))
    orders <- relabelings(seq_along(units))
    hits <- integer(length(at))
    for (i in seq_len(nrow(orders))) {
        rebuilt <- center + z[, orders[i, ], drop = FALSE] / root[site, , drop = FALSE]
        under <- site_statistic(fit_multi(rebuilt, weight, site, y[units])$t, site, length(at))
        hits <- hits + (!is.na(under) & under >= reach)
    }
    p <- hits / nrow(orders)
    p[is.na(seen)] <- NA_real_
    attr(p, "S") <- seen
    p
}

# The oracle over every tested site of a run whose read patterns the generator knows: `id` labels
# each site's pattern, as enumerated_reads() does, and `read` is the 0/1 matrix.
oracle_by_set <- function(run, y, id, read) {
    out <- rep(NA_real_, nrow(run$sites))
    stat <- out
    tested <- !is.na(run$sites$S)
    for (pattern in unique(id[tested])) {
        at <- which(id == pattern & tested)
        got <- oracle_p(run, y, at, which(read[at[1], ] == 1L))
        out[at] <- got
        stat[at] <- attr(got, "S")
    }
    attr(out, "S") <- stat
    out
}

# The rearrangement the module REJECTED, kept as a comparator: unread units zeroed and one
# rearrangement of all n units, so a read unit is handed an unread unit's zero residual. It
# reports p below 1/m!, and a section measures it beside the module so that its floor and oracle
# gates are seen to be able to fail. The module's own fit and statistic, so only the rearrangement
# differs.
rejected_p <- function(run, y, module = association_module(MODULES_DIR)) {
    site <- run$parsed$site
    weight <- run$held$weight
    freq <- run$held$freq
    weight[is.na(weight) | weight <= 0] <- 0
    freq[is.na(freq) | weight[site, , drop = FALSE] <= 0] <- 0
    root <- sqrt(weight)
    center <- rowSums(weight[site, , drop = FALSE] * freq) / rowSums(weight)[site]
    z <- (freq - center) * root[site, , drop = FALSE]
    sites <- nrow(run$sites)
    seen <- run$sites$S
    reach <- pmin(seen - 1e-12, seen * (1 - 1e-12))
    moves <- relabelings(seq_len(ncol(weight)))
    hits <- integer(sites)
    for (i in seq_len(nrow(moves))) {
        rebuilt <- center + z[, moves[i, ], drop = FALSE] / root[site, , drop = FALSE]
        under <- module$site_statistic(module$fit_alleles(rebuilt, weight, site, y)$t, site,
                                       sites)
        hits <- hits + (!is.na(under) & under >= reach)
    }
    p <- hits / nrow(moves)
    p[is.na(seen)] <- NA_real_
    p
}

# Nei's corrected distance as mds.R accumulates it, over one table: the library's parse, n_eff,
# nei_distance and mean_distance. Returns the per-pair mean, the raw form beside it, and the sites
# each pair rests on.
nei_run <- function(counts, n_chrom = 100) {
    pools <- ncol(counts[[1]])
    cells <- lapply(seq_len(pools), function(j) {
        do.call(paste, c(lapply(counts, function(m) m[, j]), sep = ","))
    })
    names(cells) <- paste0("P", seq_len(pools))
    parsed <- allele_frequencies(cells)
    sizes <- vapply(seq_len(pools), function(i) n_eff(n_chrom, parsed$depth[, i]),
                    numeric(nrow(parsed$depth)))
    got <- nei_distance(parsed$freq, parsed$site, sizes)
    list(D = mean_distance(got$corrected, got$sites), raw = mean_distance(got$raw, got$sites),
         sites = got$sites)
}

# ---------------------------------------------------------------------------------------
# What a rate may be compared with, and how far from it counts as a difference.

# The largest rate an EXACT test of m units can attain at alpha: its p lies on the grid k/m!, so
# the rate is floor(alpha m!)/m!. 0 at three units, 1/24 at four, alpha from five up.
exact_bound <- function(m, alpha) floor(factorial(m) * alpha + 1e-9) / factorial(m)

# The null value of lambda_gc, median(S^2) / qchisq(.5, 1), over tested sites read in the units
# `m`, one entry per site. S is a t on m - 2 degrees of freedom, so S^2 is F(1, m - 2) and the
# median is that of the mixture; one m gives qt(.75, m - 2)^2 / qchisq(.5, 1). 1.21 at six units.
lambda_expected <- function(m) {
    uniroot(function(x) mean(pf(x, 1, m - 2)) - 0.5, c(1e-8, 1e5), tol = 1e-12)$root /
        qchisq(0.5, 1)
}

# How far above `bound` a rate may sit before it counts as above it, for ENUMERATED p-values. The
# sites are independent given their read pattern, so the binomial error over all of them is exact,
# and the spread across cohorts is taken as well in case something was shared after all. Four
# standard errors of the larger: over 400,000 simulated nulls this alarmed 2e-5 per comparison,
# and 6e-4 when the cohorts carried twice the binomial variance.
margin_exact <- function(rates, sites, bound, z = 4) {
    z * max(sqrt(bound * (1 - bound) / sites), sd(rates) / sqrt(length(rates)))
}

# The same for rates whose sites SHARE something -- one set of sampled rearrangements, one theta
# per cohort -- where no binomial error applies and only the spread across cohorts is honest. A t
# quantile at `level` shared by the section's `comparisons`: four standard errors of a spread from
# six cohorts alarms 0.7% of the time, and the quantile needs eight cohorts or more to leave any
# power (6.1 at eight, 4.9 at twelve).
margin_spread <- function(rates, comparisons, level = 1e-3) {
    qt(1 - level / comparisons, length(rates) - 1) * sd(rates) / sqrt(length(rates))
}
