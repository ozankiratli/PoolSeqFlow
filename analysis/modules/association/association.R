# The module's own analysis. The shared library is above this line in the published copy.
#
#     association.R --design design.json --pools pools.json --options options.json
#                   --cpp allele_frequencies.cpp --depths a.tsv,b.tsv --out published
#
# design.json, pools.json and options.json are written by the frame, from what analysisPlan()
# resolved: the experimental design under the project's own design, timeVar and series settings,
# the pool sizes and ploidy the pipeline filtered with, and this module's settings. Nothing here
# re-reads the metadata.

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag) {
    hit <- match(flag, args)
    if (is.na(hit) || hit == length(args)) stop("association.R: ", flag, " needs a value")
    args[hit + 1]
}

design <- jsonlite::fromJSON(arg_of("--design"), simplifyVector = FALSE)
pools <- jsonlite::fromJSON(arg_of("--pools"), simplifyVector = FALSE)
OPTS <- jsonlite::fromJSON(arg_of("--options"), simplifyVector = TRUE)
CPP_FILE <- arg_of("--cpp")
out <- arg_of("--out")
depth_files <- strsplit(arg_of("--depths"), ",", fixed = TRUE)[[1]]

# The compiled parse, built once per process. sourceCpp caches the build on disk, so a second
# process links rather than compiles; the owner check is what stops one process using a binding
# another one made.
CPP_OWNER <- NA_integer_
compiled_parse <- function() {
    if (!identical(CPP_OWNER, Sys.getpid())) {
        Rcpp::sourceCpp(CPP_FILE)
        CPP_OWNER <<- Sys.getpid()
    }
    allele_frequencies_cpp
}

# The R is the reference and the compiled form is judged against it, never the other way round.
parse_columns <- function(cells) {
    if (isTRUE(OPTS$usecpp)) return(compiled_parse()(cells))
    allele_frequencies(cells)
}

if (isTRUE(OPTS$usecpp)) {
    if (!requireNamespace("Rcpp", quietly = TRUE)) {
        stop("association.R: the compiled path needs Rcpp and it is not installed. Install it, ",
             "or run 'PoolSeqFlow analysis association nocpp' - the R gives the same numbers.")
    }
    invisible(compiled_parse())
}
if (OPTS$workers > 1) {
    if (!requireNamespace("doFuture", quietly = TRUE)) {
        stop("association.R: analysis.modules.association.workers is ", OPTS$workers,
             " and doFuture is not installed. Install it, or set workers to 1.")
    }
    library(doFuture)
    future::plan(future::multisession, workers = OPTS$workers)
}

if (length(pools) == 0) {
    stop("association.R: this results directory has no pools. A phenotype is measured on a ",
         "pool, so there is nothing here to fit.")
}

# options.json is written by main.nf from every setting this module declares. A key missing from
# it is named here rather than left to surface hundreds of lines later as a comparison against
# nothing - `if (NULL > 1)` stops with "argument is of length zero", which says neither which
# setting nor which file. `dispersion` is absent from this list because a null there is its
# documented value and means "estimate it".
for (needed in c("permutations", "fdr", "reportBelow", "reportTop", "binSize", "workers",
                 "usecpp")) {
    if (is.null(OPTS[[needed]])) {
        stop("association.R: options.json carries no '", needed, "'. It is written from ",
             "analysis.modules.association by this module's main.nf, which sends every setting ",
             "the module declares.")
    }
}

# ----------------------------------------------------------------------------------------
# The arithmetic.
#
# Every function below takes the frequencies as one row per ALLELE and the weights as one row
# per SITE, with `site` the index that maps the first onto the second. A site's weights are the
# same for all of its alleles - a weight is how precisely that pool's frequency was measured
# there, which is a property of its depth - so the per-site quantities are computed once and
# read per allele rather than recomputed k times.

# Collapse each unit's pools onto one weighted value: the weights summed, the frequency their
# weighted mean. Where a unit holds one pool this returns that pool unchanged, so a design with
# no biological replication takes the same path and gets the same answer.
roll_up <- function(freq, weight, site, groups) {
    held <- matrix(0, nrow = nrow(weight), ncol = length(groups),
                   dimnames = list(NULL, names(groups)))
    value <- matrix(0, nrow = nrow(freq), ncol = length(groups),
                    dimnames = list(NULL, names(groups)))
    for (unit in seq_along(groups)) {
        mine <- weight[, groups[[unit]], drop = FALSE]
        held[, unit] <- rowSums(mine)
        value[, unit] <- rowSums(mine[site, , drop = FALSE] *
                                 freq[, groups[[unit]], drop = FALSE]) / held[site, unit]
    }
    value[!is.finite(value)] <- NA_real_
    list(weight = held, freq = value)
}

# The weighted regression of every allele's frequency on the phenotype.
#
# A unit with no reads at a site carries weight 0 there and drops out of every sum without a
# branch; `observed` counts the ones that remain, so the degrees of freedom follow the site
# rather than the table's width.
fit_alleles <- function(freq, weight, site, y) {
    weight[is.na(weight) | weight <= 0] <- 0
    freq[is.na(freq) | weight[site, , drop = FALSE] <= 0] <- 0

    observed <- rowSums(weight > 0)
    total <- rowSums(weight)
    phen <- matrix(y, nrow = nrow(weight), ncol = ncol(weight), byrow = TRUE)
    centered <- phen - rowSums(weight * phen) / total
    sxx <- rowSums(weight * centered * centered)

    wide <- weight[site, , drop = FALSE]
    across <- centered[site, , drop = FALSE]
    middle <- freq - rowSums(wide * freq) / total[site]
    slope <- rowSums(wide * across * middle) / sxx[site]
    spent <- rowSums(wide * (middle - slope * across)^2)
    scatter <- rowSums(wide * middle * middle)

    # RELATIVE, NOT AGAINST ZERO. A perfectly separated site has no residual left, but whether
    # the sum lands on exactly 0 or on 1e-32 is which order the terms canceled in: the corpus's
    # Python reaches 0 and this reaches 1e-32 on the same counts, so a test for zero fires in one
    # and not the other. Anything at the level of the rounding error in `scatter` is a fit with
    # nothing left over, whichever way it fell.
    exhausted <- spent <= 64 * .Machine$double.eps * scatter

    df <- observed - 2
    variance <- spent / df[site]
    error <- sqrt(variance / sxx[site])
    list(b1 = slope, se = error, t = slope / error, variance = variance, exhausted = exhausted,
         sxx = sxx, observed = observed, df = df, weight = total)
}

# The largest |t| over EVERY allele of a site, the reference included: a site's frequencies sum
# to 1, so the reference row carries the negated sum of the others and is where a signal spread
# across several alternates shows up.
#
# An allele that does not vary has a slope of zero over no residual, so its t is 0/0 and takes
# no part in the maximum. A separated one has a slope and no residual, so its t is infinite and
# does take part. A site where no allele has a test in it has no statistic, which is not the
# same as a statistic of zero.
site_statistic <- function(t, site, sites) {
    size <- abs(t)
    size[is.na(t)] <- NA_real_
    order <- order(site, size, na.last = FALSE)
    last <- !duplicated(site[order], fromLast = TRUE)
    out <- rep(NA_real_, sites)
    out[site[order][last]] <- size[order][last]
    out
}

# The excess variance a pooling leaves behind, in units of p(1-p), estimated across sites.
#
# The weights say Var(f) = sigma^2 / n_eff. Uneven contribution to a pool leaves an excess that
# does not shrink with depth, so the truth is Var(f) = p(1-p) * (theta + 1/n_eff). This is theta
# by method of moments: the scatter the units actually show, less the sampling variance the
# weights predict. Clamped at zero.
dispersion_of <- function(freq, weight, site) {
    held <- ncol(freq)
    center <- rowMeans(freq)
    spread <- (rowSums(freq * freq) - held * center * center) / (held - 1)
    scale <- center * (1 - center)
    excess <- (spread - scale * rowMeans(1 / weight)[site]) / scale
    max(0, mean(excess[is.finite(excess)]))
}

# Every rearrangement of the units, as index rows, enumerated whole while it fits.
#
# ENUMERATING IS A CORRECTNESS REQUIREMENT AND NOT AN OPTIMISATION. A sampled p can land below
# the smallest value the design supports, so sampling a set that would fit is a wrong answer and
# not a faster one.
rearrangements <- function(units, budget) {
    every <- function(x) {
        if (length(x) == 1) return(matrix(x, nrow = 1))
        do.call(rbind, lapply(seq_along(x), function(i) cbind(x[i], every(x[-i]))))
    }
    if (units <= 8 && factorial(units) <= budget) {
        return(list(rows = every(seq_len(units)), exhaustive = TRUE))
    }
    list(rows = t(vapply(seq_len(budget), function(i) sample(units), integer(units))),
         exhaustive = FALSE)
}

# The share of rearrangements whose site statistic reaches the observed one.
#
# THE RESIDUALS MOVE, NOT THE LABELS. Units read at different depths are not interchangeable and
# weighting them correctly does not make them so; the residuals about the weighted mean, scaled by
# the root of the weight, are:
#
#     z_i  = (f_i - fbar_w) * sqrt(w_i)          equal variance, so interchangeable
#     f*_i = fbar_w + z_sigma(i) / sqrt(w_i)     put back at THIS unit's precision
#
# WHOLE UNIT COLUMNS MOVE TOGETHER, which keeps a site's frequencies summing to one: a unit's
# residuals sum to zero across its alleles, so a rebuilt unit still sums to one. Moving alleles
# independently would be a different null.
#
# An ENUMERATED null is counted as it stands: the identity is one of the rows being counted. A
# SAMPLED one takes one on the count and one on the total, since the raw share can return zero
# and no permutation p can be zero.
permutation_p <- function(freq, weight, site, sites, y, observed, budget) {
    moves <- rearrangements(ncol(weight), budget)
    root <- sqrt(weight)
    center <- rowSums(weight[site, , drop = FALSE] * freq) / rowSums(weight)[site]
    z <- (freq - center) * root[site, , drop = FALSE]

    # ONE REARRANGEMENT SERVES EVERY SITE, so binning is an allocation strategy and not a change
    # to the null: a bin holds a contiguous run of sites and every bin sees the same
    # rearrangements in the same order.
    ranges <- chunk_ranges(sites, OPTS$binSize)
    tally <- function(range) {
        rows <- which(site >= range[1] & site <= range[2])
        held <- weight[range[1]:range[2], , drop = FALSE]
        index <- site[rows] - range[1] + 1L
        here <- range[2] - range[1] + 1L
        seen <- observed[range[1]:range[2]]
        found <- integer(here)
        for (row in seq_len(nrow(moves$rows))) {
            rebuilt <- center[rows] + z[rows, moves$rows[row, ], drop = FALSE] /
                root[site[rows], , drop = FALSE]
            under <- site_statistic(fit_alleles(rebuilt, held, index, y)$t, index, here)
            found <- found + (!is.na(under) & under >= seen - 1e-12)
        }
        found
    }
    counted <- if (OPTS$workers > 1) {
        foreach::foreach(range = ranges) %dofuture% tally(range)
    } else {
        lapply(ranges, tally)
    }
    reached <- unlist(counted, use.names = FALSE)

    p <- if (moves$exhaustive) reached / nrow(moves$rows) else
        (1 + reached) / (1 + nrow(moves$rows))
    p[is.na(observed)] <- NA_real_
    list(p = p, count = nrow(moves$rows), exhaustive = moves$exhaustive,
         floor = if (moves$exhaustive) 1 / nrow(moves$rows) else 1 / (1 + nrow(moves$rows)))
}

# ----------------------------------------------------------------------------------------
# What the design says to fit.

pool_order <- vapply(design$pools, function(entry) entry$pool, "")
by_pool <- setNames(pools, vapply(pools, function(p) p$pool, ""))

chosen <- OPTS$phenotypes
if (is.null(chosen) || length(chosen) == 0) {
    stop("association.R: analysis.modules.association.phenotypes names no column. This project ",
         "declares ", length(design$phenotypes), "; naming one is how a published folder says ",
         "which it used instead of holding several answers under one name.")
}
declared <- vapply(design$phenotypes, function(p) p$column, "")
unknown <- setdiff(chosen, declared)
if (length(unknown) > 0) {
    stop("association.R: no phenotype called ", paste(unknown, collapse = ", "),
         ". This project declares ", paste(declared, collapse = ", "), ".")
}

# One row per unit, in design order, so a unit's pools index the published columns rather than
# being re-derived from the metadata.
unit_labels <- vapply(design$units, function(u) u$label, "")
unit_pools <- lapply(design$units, function(u) unlist(u$pools))
names(unit_pools) <- unit_labels

if (length(design$units) < 3) {
    stop("association.R: this design holds ", length(design$units), " independent unit(s). A ",
         "slope and its standard error need three, and degrees of freedom come from units and ",
         "never from pools - see analysis.design.technicalRep if two pools here are one ",
         "material measured twice.")
}

# A phenotype is measured on a pool; the fit is on units. Every pool of a unit must therefore
# agree, which is the same refusal checkTargetDesign() applies to an experimental column.
phenotype_by_unit <- function(entry) {
    value <- setNames(vapply(entry$values, function(v) as.numeric(v$value), numeric(1)),
                      vapply(entry$values, function(v) v$pool, ""))
    vapply(unit_pools, function(members) {
        held <- unique(value[members])
        if (length(held) > 1) {
            stop("association.R: the pools of one unit carry ", length(held), " values of ",
                 entry$column, " (", paste(sort(held), collapse = ", "), "). The fit is on ",
                 "units and a unit takes one value, so either this phenotype is a trait of the ",
                 "unit and the metadata disagrees about it, or it was measured repeatedly on ",
                 "the same material - which is a mixed model and not something this release ",
                 "fits. Restricting to one time level with ",
                 "analysis.modules.association.timepoint is the way to fit a design like that ",
                 "here.")
        }
        held
    }, numeric(1))
}

# ----------------------------------------------------------------------------------------
# The tables.

# Step 7 writes one depth table per variant kind, named <vcf>_snp_depth.tsv and
# <vcf>_indel_depth.tsv. A name neither pattern answers to stops here: a site key carries the
# kind, and guessing it would let a SNP and an indel at one position share a row.
kind_of <- function(path) {
    if (grepl("_snp_depth[.]tsv$", path)) return("snp")
    if (grepl("_indel_depth[.]tsv$", path)) return("indel")
    stop("association.R: cannot tell what kind of variant ", basename(path), " holds. Step 7 ",
         "names its depth tables <vcf>_snp_depth.tsv and <vcf>_indel_depth.tsv.")
}

# The five fixed columns are named, never counted: sample column order was not deterministic
# before v2.1.1, so a pool is found by its header and nothing else.
FIXED <- c("CHROM", "POS", "REF", "ALT", "TOTAL_AD")

read_depth_table <- function(path) {
    table <- read.delim(path, colClasses = "character", check.names = FALSE)
    absent <- setdiff(FIXED, names(table))
    if (length(absent) > 0) {
        stop("association.R: ", basename(path), " has no ", paste(absent, collapse = ", "),
             " column. That is not a depth table as step 7 publishes one.")
    }
    missing_pools <- setdiff(pool_order, names(table))
    if (length(missing_pools) > 0) {
        stop("association.R: ", basename(path), " has no column for ",
             paste(missing_pools, collapse = ", "), ". The design and the table come from one ",
             "target and cannot disagree about which pools it holds.")
    }
    table
}

# The largest weighted leverage at a site, over units. It costs one pass and it is the
# diagnostic that says whether one unit is carrying the slope by itself, which at six of them
# is the question a reader has.
top_leverage <- function(weight, y) {
    total <- rowSums(weight)
    phen <- matrix(y, nrow = nrow(weight), ncol = ncol(weight), byrow = TRUE)
    centered <- phen - rowSums(weight * phen) / total
    sxx <- rowSums(weight * centered * centered)
    held <- weight * (1 / total + centered * centered / sxx)
    do.call(pmax, c(lapply(seq_len(ncol(held)), function(j) held[, j]), list(na.rm = TRUE)))
}

n_chrom <- vapply(pool_order, function(name) {
    figures <- by_pool[[name]]
    if (is.null(figures)) {
        stop("association.R: the design names a pool '", name, "' that the pool figures do ",
             "not. Both come from one target and cannot disagree.")
    }
    as.numeric(figures$nChrom)
}, numeric(1))

budget <- if (is.null(OPTS$permutations)) 1000L else as.integer(OPTS$permutations)
wanted <- if (is.null(OPTS$chromosomes)) character(0) else as.character(OPTS$chromosomes)
method <- if (is.null(OPTS$fdr)) "BH" else as.character(OPTS$fdr)

site_rows <- list()
allele_rows <- list()
report <- list()

for (entry in design$phenotypes[declared %in% chosen]) {
    y <- phenotype_by_unit(entry)

    for (path in depth_files) {
        kind <- kind_of(path)
        table <- read_depth_table(path)
        if (length(wanted) > 0) table <- table[table$CHROM %in% wanted, , drop = FALSE]
        if (nrow(table) == 0) next

        parsed <- parse_columns(as.list(table[pool_order]))
        # Named: a unit holds the NAMES of its pools and indexes the columns with them.
        weight <- vapply(seq_along(pool_order),
                         function(i) n_eff(n_chrom[i], parsed$depth[, i]),
                         numeric(nrow(parsed$depth)))
        colnames(weight) <- pool_order

        held <- roll_up(parsed$freq, weight, parsed$site, unit_pools)
        sites <- nrow(held$weight)

        # What the fit and the permutation both weight by. The absolute scale of a weight cancels
        # out of t exactly, so only the RATIO between units is ever a claim - and `theta` is what
        # corrects that ratio where uneven pooling made it wrong. Setting
        # analysis.modules.association.dispersion to 0 recovers the plain n_eff weights.
        theta <- if (is.null(OPTS$dispersion)) dispersion_of(held$freq, held$weight, parsed$site)
                 else as.numeric(OPTS$dispersion)
        held$weight <- 1 / (theta + 1 / held$weight)

        fit <- fit_alleles(held$freq, held$weight, parsed$site, y)
        observed <- site_statistic(fit$t, parsed$site, sites)
        shuffled <- permutation_p(held$freq, held$weight, parsed$site, sites, y,
                                  observed, budget)

        tested <- sum(!is.na(observed))
        adjusted <- rep(NA_real_, sites)
        adjusted[!is.na(observed)] <- p.adjust(shuffled$p[!is.na(observed)],
                                               method = method, n = tested)

        # A site is flagged when any of its alleles ran out of residual. Where that happens t
        # and its parametric p are not comparable between implementations - two alleles of one
        # separated biallelic site are algebraically one test, and whether each lands on exactly
        # zero or on 1e-18 decides between t = Inf and t = 8e15.
        spent <- !is.finite(fit$t) | fit$variance <= 0 | fit$exhausted
        flagged <- as.integer(tapply(spent, parsed$site, any))

        site_rows[[length(site_rows) + 1]] <- data.frame(
            phenotype = entry$column, kind = kind,
            chrom = table$CHROM, pos = as.integer(table$POS),
            k = parsed$alleles, n_observed = fit$observed, n_units = length(unit_pools),
            S = observed, perm_p = shuffled$p, fdr_p = adjusted,
            mean_weight = rowMeans(held$weight), max_leverage = top_leverage(held$weight, y),
            zero_variance = flagged,
            stringsAsFactors = FALSE, check.names = FALSE)

        alleles <- unlist(lapply(strsplit(paste(table$REF, table$ALT, sep = ","), ",",
                                          fixed = TRUE), identity), use.names = FALSE)
        allele_rows[[length(allele_rows) + 1]] <- data.frame(
            phenotype = entry$column, kind = kind,
            chrom = table$CHROM[parsed$site], pos = as.integer(table$POS)[parsed$site],
            allele = alleles,
            b1 = fit$b1, se = fit$se, t = fit$t,
            p = 2 * pt(-abs(fit$t), fit$df[parsed$site]),
            stringsAsFactors = FALSE, check.names = FALSE)

        # `design_floor` is what the design supports by rearrangement alone and `floor` what this
        # run could reach. They differ only when the set was too large to enumerate.
        # THE SMALLEST P THIS DESIGN CAN REACH BY REARRANGEMENT AT ALL. Reversing the phenotype
        # negates every slope and leaves |t| alone, so the reversal always ties with the observed
        # arrangement and the floor is TWO over the count, never one.
        limit <- 2 / factorial(length(unit_pools))
        if (limit > 0.05) {
            message("association.R: ", length(unit_pools), " units allow ",
                    factorial(length(unit_pools)), " rearrangements, so the smallest p any site ",
                    "can reach is ", signif(limit, 3), ". Nothing here can be significant at ",
                    "0.05 and the table is a RANKING of effect sizes, not a test. More units is ",
                    "the only thing that changes it.")
        }

        alive <- !is.na(observed)
        picked <- alive & !is.na(adjusted) & adjusted <= 0.05
        report[[length(report) + 1]] <- data.frame(
            phenotype = entry$column, kind = kind, sites = sites, tested = tested,
            units = length(unit_pools), permutations = shuffled$count,
            exhaustive = shuffled$exhaustive, floor = shuffled$floor, design_floor = limit,
            dispersion = theta,
            depth_phenotype_cor = suppressWarnings(cor(colMeans(held$weight), y)),
            lambda_gc = if (any(alive)) {
                median(observed[alive]^2, na.rm = TRUE) / qchisq(0.5, 1)
            } else NA_real_,
            # The allele counts of the sites selected, against the allele counts of all of them.
            # Published as a pair: the two are only meaningful beside each other.
            arity_mean = mean(parsed$alleles[alive]),
            arity_selected = if (any(picked)) mean(parsed$alleles[picked]) else NA_real_,
            selected = sum(picked),
            stringsAsFactors = FALSE)
    }
}

sites_table <- do.call(rbind, site_rows)
alleles_table <- do.call(rbind, allele_rows)

write.table(sites_table, file.path(out, "association.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE, na = "NA")

# The allele table is a SELECTION and the site table is not. What selected it is printed in the
# published header, so a filtered table cannot be read as the whole one.
below <- if (is.null(OPTS$reportBelow)) 0.05 else as.numeric(OPTS$reportBelow)
top <- if (is.null(OPTS$reportTop)) 1000L else as.integer(OPTS$reportTop)

key <- paste(sites_table$phenotype, sites_table$kind, sites_table$chrom, sites_table$pos)
ranked <- order(sites_table$perm_p, na.last = NA)
keep <- unique(c(key[!is.na(sites_table$perm_p) & sites_table$perm_p <= below],
                 key[head(ranked, top)]))
selected <- paste(alleles_table$phenotype, alleles_table$kind,
                  alleles_table$chrom, alleles_table$pos) %in% keep

write.table(alleles_table[selected, , drop = FALSE],
            file.path(out, "association_alleles.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE, na = "NA")

write.table(do.call(rbind, report), file.path(out, "permutations.tsv"), sep = "\t",
            quote = FALSE, row.names = FALSE, na = "NA")

# ----------------------------------------------------------------------------------------
# The phenotype as it was read, and the figures.

# The cell as written beside the number the fit used, and for a categorical scale which level
# became 1. A reversed case/control coding has no more of a check than dd/MM against MM/dd does:
# printing the resolved answer is the only place a reader catches either.
phenotype_rows <- function(entry) {
    shown <- setNames(vapply(entry$values, function(v) as.character(v$shown), ""),
                      vapply(entry$values, function(v) v$pool, ""))
    read <- setNames(vapply(entry$values, function(v) as.numeric(v$value), numeric(1)),
                     vapply(entry$values, function(v) v$pool, ""))
    fitted <- phenotype_by_unit(entry)
    do.call(rbind, lapply(seq_along(unit_pools), function(i) data.frame(
        phenotype = entry$column, kind = entry$kind, unit = names(unit_pools)[i],
        pool = unit_pools[[i]], shown = shown[unit_pools[[i]]], value = read[unit_pools[[i]]],
        fitted = fitted[[i]],
        coded_one = if (is.null(entry$levels)) NA_character_
                    else as.character(unlist(entry$levels)[2]),
        stringsAsFactors = FALSE, row.names = NULL)))
}

write.table(do.call(rbind, lapply(design$phenotypes[declared %in% chosen], phenotype_rows)),
            file.path(out, "phenotype.tsv"), sep = "\t", quote = FALSE, row.names = FALSE,
            na = "NA")

# Figures degrade rather than refuse: every number they show is in the tables beside them.
drawable <- requireNamespace("ggplot2", quietly = TRUE)
if (!drawable) {
    message("association.R: ggplot2 is not installed, so no figures were drawn. Every number ",
            "they would have shown is in association.tsv and permutations.tsv.")
}

if (drawable && any(!is.na(sites_table$perm_p))) {
    frame <- do.call(rbind, lapply(split(sites_table, sites_table$phenotype), function(part) {
        seen <- sort(part$perm_p[!is.na(part$perm_p)])
        if (length(seen) == 0) return(NULL)
        data.frame(phenotype = part$phenotype[1],
                   expected = -log10(ppoints(length(seen))),
                   observed = -log10(seen), stringsAsFactors = FALSE)
    }))
    figure <- ggplot2::ggplot(frame, ggplot2::aes(x = expected, y = observed)) +
        ggplot2::geom_abline(slope = 1, intercept = 0, color = "gray60") +
        ggplot2::geom_point(size = 0.5, alpha = 0.6) +
        ggplot2::facet_wrap(~ phenotype, ncol = 1) +
        ggplot2::labs(title = "Permutation p-values against the uniform they should follow",
                      subtitle = paste0("A permutation p is discrete, so the points sit on a ",
                                        "ladder; the ceiling is the design's own floor."),
                      x = "Expected -log10(p)", y = "Observed -log10(p)") +
        ggplot2::theme_bw(base_size = 9)
    ggplot2::ggsave(file.path(out, "qq.png"), figure, width = 6,
                    height = 2.6 * length(unique(frame$phenotype)) + 0.6, dpi = 150)
}

# Nothing is plotted along a sequence until one is named in the module's `chromosomes` setting.
for (chrom in wanted) {
    here <- drawable & sites_table$chrom == chrom & !is.na(sites_table$perm_p)
    if (!any(here)) next
    figure <- ggplot2::ggplot(sites_table[here, , drop = FALSE],
                              ggplot2::aes(x = pos, y = -log10(perm_p))) +
        ggplot2::geom_point(size = 0.5, alpha = 0.6) +
        ggplot2::facet_wrap(~ phenotype, ncol = 1) +
        ggplot2::labs(title = paste0("Association along ", chrom),
                      subtitle = paste0("One point per called site. The permutation p cannot go ",
                                        "below the design's floor, so a flat ceiling here is ",
                                        "the design and not the data."),
                      x = paste0("Position on ", chrom), y = "-log10(permutation p)") +
        ggplot2::theme_bw(base_size = 9)
    # A sequence may be called anything and a published file name has to survive being one.
    safe <- gsub("[^A-Za-z0-9._-]", "_", chrom)
    ggplot2::ggsave(file.path(out, paste0("manhattan_", safe, ".png")), figure, width = 7,
                    height = 2.6 * length(chosen) + 0.6, dpi = 150)
}

cat("association: ", length(unit_pools), " units over ", length(pool_order), " pools, ",
    nrow(sites_table), " site rows, ", sum(!is.na(sites_table$perm_p)), " tested\n", sep = "")
cat("association: parsed by the ", if (isTRUE(OPTS$usecpp)) "compiled" else "vectorized R",
    " path, in bins of ", OPTS$binSize, " sites over ", OPTS$workers,
    if (OPTS$workers == 1) " worker" else " workers", "\n", sep = "")
