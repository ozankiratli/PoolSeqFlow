# The module's own analysis. The shared library is above this line in the published copy.
#
#     mds.R --design design.json --pools pools.json --options options.json
#           --cpp-frequencies allele_frequencies.cpp --cpp-distance nei_distance.cpp
#           --depths a.tsv,b.tsv --out published
#
# design.json, pools.json and options.json are written by the frame, from what analysisPlan()
# resolved: the experimental design under the project's own design, timeVar and series settings,
# the pool sizes and ploidy the pipeline filtered with, and this module's settings. Nothing here
# re-reads the metadata.

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag) {
    hit <- match(flag, args)
    if (is.na(hit) || hit == length(args)) stop("mds.R: ", flag, " needs a value")
    args[hit + 1]
}

design <- jsonlite::fromJSON(arg_of("--design"), simplifyVector = FALSE)
pools <- jsonlite::fromJSON(arg_of("--pools"), simplifyVector = FALSE)
OPTS <- jsonlite::fromJSON(arg_of("--options"), simplifyVector = TRUE)
CPP_FREQ <- arg_of("--cpp-frequencies")
CPP_DIST <- arg_of("--cpp-distance")
out <- arg_of("--out")
depth_files <- strsplit(arg_of("--depths"), ",", fixed = TRUE)[[1]]

# The two compiled forms, built once per process. sourceCpp caches the build on disk, so a
# second process links rather than compiles; the owner check is what stops one process using a
# binding another one made.
CPP_OWNER <- NA_integer_
compiled <- function() {
    if (!identical(CPP_OWNER, Sys.getpid())) {
        Rcpp::sourceCpp(CPP_FREQ)
        Rcpp::sourceCpp(CPP_DIST)
        CPP_OWNER <<- Sys.getpid()
    }
    list(parse = allele_frequencies_cpp, distance = nei_distance_cpp)
}

# The R is the reference and the compiled forms are judged against it, never the other way round.
parse_columns <- function(cells) {
    if (isTRUE(OPTS$usecpp)) return(compiled()$parse(cells))
    allele_frequencies(cells)
}

distance_of <- function(freq, site, n_eff_site) {
    if (isTRUE(OPTS$usecpp)) return(compiled()$distance(freq, as.integer(site), n_eff_site))
    nei_distance(freq, site, n_eff_site)
}

if (isTRUE(OPTS$usecpp)) {
    if (!requireNamespace("Rcpp", quietly = TRUE)) {
        stop("mds.R: the compiled path needs Rcpp and it is not installed. Install it, or run ",
             "'PoolSeqFlow analysis mds nocpp' - the R gives the same numbers.")
    }
    invisible(compiled())
}
if (OPTS$workers > 1) {
    if (!requireNamespace("doFuture", quietly = TRUE)) {
        stop("mds.R: analysis.modules.mds.workers is ", OPTS$workers, " and doFuture is not ",
             "installed. Install it, or set workers to 1.")
    }
    library(doFuture)
    future::plan(future::multisession, workers = OPTS$workers)
}

# options.json is written by main.nf from every setting this module declares. A key missing from
# it is named here rather than left to surface hundreds of lines later as a comparison against
# nothing. `colorBy` and `shapeBy` are absent from this list because an empty string is the
# documented value of each and means the points carry no such key.
for (needed in c("dimensions", "includeIndels", "binSize", "workers", "usecpp")) {
    if (is.null(OPTS[[needed]])) {
        stop("mds.R: options.json carries no '", needed, "'. It is written from ",
             "analysis.modules.mds by this module's main.nf, which sends every setting the ",
             "module declares.")
    }
}

# ----------------------------------------------------------------------------------------
# What the design says to ordinate.

pool_order <- vapply(design$pools, function(entry) entry$pool, "")
by_pool <- setNames(pools, vapply(pools, function(p) p$pool, ""))
variables <- vapply(design$variables, function(v) v$name, "")

# An ordination of two points is the line between them and says nothing a distance did not.
if (length(pool_order) < 3) {
    stop("mds.R: this results directory holds ", length(pool_order), " pool(s). An ordination ",
         "of fewer than three is the distance between them drawn twice; distance.tsv is what ",
         "such a run has to report and this module does not produce it alone.")
}

n_chrom <- vapply(pool_order, function(name) {
    figures <- by_pool[[name]]
    if (is.null(figures)) {
        stop("mds.R: the design names a pool '", name, "' that the pool figures do not. Both ",
             "come from one target and cannot disagree.")
    }
    as.numeric(figures$nChrom)
}, numeric(1))

# n_eff is 1 for a pool of one chromosome at every depth, so the unbiased correction divides by
# zero at every site and the whole matrix would come back empty. A single haploid genome is one
# gene copy: it carries no within-pool diversity for the correction to remove.
alone <- pool_order[n_chrom <= 1]
if (length(alone) > 0) {
    stop("mds.R: ", paste(alone, collapse = ", "), " holds one chromosome - a single haploid ",
         "genome, from ploidy times pool size. The sampling correction needs a pool that can ",
         "differ from itself, so there is no corrected distance to that pool from anything.")
}

# One row per unit, in design order, so a pool's unit is a label on its point rather than
# something re-derived from the metadata. The ordination places POOLS: two pools of one unit
# landing apart is what a reader looks at an ordination to see, and collapsing them first would
# remove exactly that.
unit_of <- setNames(rep(NA_character_, length(pool_order)), pool_order)
for (unit in design$units) {
    for (member in unlist(unit$pools)) unit_of[[member]] <- unit$label
}

# The value of one experimental variable for every pool, in design order.
variable_of <- function(name) {
    vapply(design$pools, function(entry) {
        held <- entry$values[[name]]
        if (is.null(held) || !nzchar(held)) NA_character_ else held
    }, "")
}

# The experimental variable a plot key is set to, refused by name when the project has no such
# column. An empty setting is no key.
aesthetic <- function(setting) {
    held <- if (is.null(OPTS[[setting]])) "" else as.character(OPTS[[setting]])
    if (nzchar(held) && !(held %in% variables)) {
        stop("mds.R: analysis.modules.mds.", setting, " names '", held, "', which is not an ",
             "experimental variable of this project. It declares ",
             if (length(variables) == 0) "none" else paste(variables, collapse = ", "), ".")
    }
    held
}

color_by <- aesthetic("colorBy")
shape_by <- aesthetic("shapeBy")

# R's plotting symbols: ggplot2's own six first, then the rest of pch in order.
#
# ggplot2's discrete shape scale stops at six and returns NA beyond, which drops those pools from
# the plot with a warning a Nextflow task swallows. Naming the symbols is what carries a seventh
# level and past it, and the first six are ggplot2's own, so a plot of six or fewer is the one it
# would have drawn anyway. Nothing is chosen for color: its default scale takes any number of
# levels, and which colors a reader needs is a property of the experiment.
SHAPE_VALUES <- c(16, 17, 15, 3, 7, 8, setdiff(0:25, c(16, 17, 15, 3, 7, 8)))

shape_levels <- 0
if (nzchar(shape_by)) {
    shape_levels <- length(unique(variable_of(shape_by)))
    if (shape_levels > length(SHAPE_VALUES)) {
        stop("mds.R: analysis.modules.mds.shapeBy names '", shape_by, "', which has ",
             shape_levels, " levels, and R has ", length(SHAPE_VALUES), " plotting symbols in ",
             "all. Use colorBy for this variable, which is not limited that way.")
    }
}

# ----------------------------------------------------------------------------------------
# The ordination.
#
# The distances themselves are the shared library's: nei_distance() accumulates them, and
# add_distance() and mean_distance() fold the bins into one matrix. What follows is what this
# module makes of that matrix.

# Classical multidimensional scaling from a matrix of SQUARED distances.
#
# The squared distances are double centred into a Gram matrix and that is decomposed, which is
# what cmdscale does internally with the distances it is given. Taking that step here rather than
# calling cmdscale keeps the corrected distances out of a square root: they are already squared
# distances, and the small negative entries an unbiased estimator produces have no root.
#
# Returns the coordinates on the leading `dimensions` axes and every eigenvalue.
ordinate <- function(squared, dimensions) {
    n <- nrow(squared)
    if (n < 2) stop("ordinate: an ordination needs at least two pools")
    centring <- diag(n) - 1 / n
    gram <- -0.5 * (centring %*% squared %*% centring)
    # eigen(symmetric = TRUE) reads one triangle; the halves differ in the last bits after the
    # multiplications above.
    gram <- (gram + t(gram)) / 2

    spectrum <- eigen(gram, symmetric = TRUE)
    keep <- seq_len(min(dimensions, n - 1))
    coords <- spectrum$vectors[, keep, drop = FALSE] *
              rep(sqrt(pmax(spectrum$values[keep], 0)), each = n)

    # An eigenvector is a direction, not a sign, so the same data can plot mirrored on two
    # machines. Each axis is turned so that its largest coordinate is positive, ties going to
    # the pool that comes first.
    for (j in seq_len(ncol(coords))) {
        lead <- which.max(abs(coords[, j]))
        if (coords[lead, j] < 0) coords[, j] <- -coords[, j]
    }

    list(coords = coords, values = spectrum$values)
}

# What share of the scatter each axis carries, under both denominators in use.
#
# Negative eigenvalues are what a distance matrix no flat space holds exactly produces. Summing
# them signed can put the leading axes above 100%; summing their absolute values cannot. Both
# are reported and the eigenvalue table carries the signs.
axis_shares <- function(values) {
    list(signed = values / sum(values),
         absolute = values / sum(abs(values)))
}

# ----------------------------------------------------------------------------------------
# The tables.

# Step 7 writes one depth table per variant kind, named <vcf>_snp_depth.tsv and
# <vcf>_indel_depth.tsv. A name neither pattern answers to stops here.
kind_of <- function(path) {
    if (grepl("_snp_depth[.]tsv$", path)) return("snp")
    if (grepl("_indel_depth[.]tsv$", path)) return("indel")
    stop("mds.R: cannot tell what kind of variant ", basename(path), " holds. Step 7 names its ",
         "depth tables <vcf>_snp_depth.tsv and <vcf>_indel_depth.tsv.")
}

# The five fixed columns are named, never counted: sample column order was not deterministic
# before v2.1.1, so a pool is found by its header and nothing else.
FIXED <- c("CHROM", "POS", "REF", "ALT", "TOTAL_AD")

read_depth_table <- function(path) {
    table <- read.delim(path, colClasses = "character", check.names = FALSE)
    absent <- setdiff(FIXED, names(table))
    if (length(absent) > 0) {
        stop("mds.R: ", basename(path), " has no ", paste(absent, collapse = ", "),
             " column. That is not a depth table as step 7 publishes one.")
    }
    missing_pools <- setdiff(pool_order, names(table))
    if (length(missing_pools) > 0) {
        stop("mds.R: ", basename(path), " has no column for ",
             paste(missing_pools, collapse = ", "), ". The design and the table come from one ",
             "target and cannot disagree about which pools it holds.")
    }
    table
}

# One bin's contribution: the cells parsed, each pool's effective size at each site, and the
# pairwise sums over them.
#
# The effective sizes are filled column by column rather than by vapply, which returns a vector
# and not a one-row matrix when a bin holds a single site.
accumulate <- function(cells) {
    parsed <- parse_columns(cells)
    sizes <- matrix(NA_real_, nrow(parsed$depth), length(pool_order))
    for (i in seq_along(pool_order)) sizes[, i] <- n_eff(n_chrom[i], parsed$depth[, i])
    distance_of(parsed$freq, parsed$site, sizes)
}

wanted <- if (is.null(OPTS$chromosomes)) character(0) else as.character(OPTS$chromosomes)

# Indels are a different kind of difference between two pools and are counted apart everywhere
# else in this frame, so the default reads the SNP tables alone.
if (!isTRUE(OPTS$includeIndels)) {
    depth_files <- depth_files[vapply(depth_files, kind_of, "") == "snp"]
}
if (length(depth_files) == 0) {
    stop("mds.R: no SNP depth table to read. Set analysis.modules.mds.includeIndels to true if ",
         "this target holds indels alone.")
}

accumulated <- NULL
read_sites <- 0L
for (path in depth_files) {
    table <- read_depth_table(path)
    if (length(wanted) > 0) table <- table[table$CHROM %in% wanted, , drop = FALSE]
    if (nrow(table) == 0) next
    read_sites <- read_sites + nrow(table)

    # Binned so the allele matrix of a whole genome is never held: a bin's frequencies are
    # accumulated into the pairwise sums and dropped before the next is parsed.
    bins <- lapply(chunk_ranges(nrow(table), OPTS$binSize),
                   function(range) as.list(table[seq.int(range[1], range[2]), pool_order,
                                                 drop = FALSE]))
    if (OPTS$workers > 1) {
        parts <- foreach::foreach(cells = bins) %dofuture% accumulate(cells)
        for (part in parts) accumulated <- add_distance(accumulated, part)
    } else {
        for (cells in bins) accumulated <- add_distance(accumulated, accumulate(cells))
    }
    rm(table, bins)
}

if (is.null(accumulated)) {
    stop("mds.R: none of the depth tables held a site",
         if (length(wanted) > 0) paste0(" on ", paste(wanted, collapse = ", ")) else "",
         ". There is nothing to place.")
}

corrected <- mean_distance(accumulated$corrected, accumulated$sites)
raw <- mean_distance(accumulated$raw, accumulated$sites)

empty <- which(accumulated$sites == 0 & row(accumulated$sites) != col(accumulated$sites),
               arr.ind = TRUE)
if (nrow(empty) > 0) {
    stop("mds.R: ", pool_order[empty[1, 1]], " and ", pool_order[empty[1, 2]], " share no site ",
         "either was read at, so there is no distance between them and no ordination that holds ",
         "both. distance.tsv would show which pairs those are; check the depth filters.")
}

# ----------------------------------------------------------------------------------------
# What it publishes.

placed <- ordinate(corrected, OPTS$dimensions)
shares <- axis_shares(placed$values)
axes <- paste0("dim", seq_len(ncol(placed$coords)))

values_of <- function(entry) {
    vapply(variables, function(name) {
        held <- entry$values[[name]]
        if (is.null(held) || !nzchar(held)) NA_character_ else held
    }, "")
}

coordinates <- as.data.frame(placed$coords, stringsAsFactors = FALSE)
names(coordinates) <- axes
mds_table <- cbind(
    data.frame(pool = pool_order, unit = unname(unit_of[pool_order]),
               stringsAsFactors = FALSE),
    as.data.frame(do.call(rbind, lapply(design$pools, values_of)),
                  stringsAsFactors = FALSE),
    coordinates)
write.table(mds_table, file.path(out, "mds.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE, na = "")

pairs <- which(upper.tri(corrected), arr.ind = TRUE)
distance_table <- data.frame(
    pool_a = pool_order[pairs[, 1]], pool_b = pool_order[pairs[, 2]],
    sites = accumulated$sites[pairs],
    distance = corrected[pairs], raw = raw[pairs],
    correction = raw[pairs] - corrected[pairs],
    stringsAsFactors = FALSE)
write.table(distance_table[order(distance_table$pool_a, distance_table$pool_b), ],
            file.path(out, "distance.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE, na = "")

eigen_table <- data.frame(
    axis = seq_along(placed$values), eigenvalue = placed$values,
    share = shares$signed, share_absolute = shares$absolute,
    cumulative = cumsum(shares$signed), cumulative_absolute = cumsum(shares$absolute),
    plotted = as.integer(seq_along(placed$values) <= ncol(placed$coords)),
    stringsAsFactors = FALSE)
write.table(eigen_table, file.path(out, "eigenvalues.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE, na = "")

# ----------------------------------------------------------------------------------------
# The plot.

if (ncol(placed$coords) >= 2) {
    frame <- data.frame(x = placed$coords[, 1], y = placed$coords[, 2],
                        pool = pool_order, stringsAsFactors = FALSE)
    if (nzchar(color_by)) frame$color_group <- variable_of(color_by)
    if (nzchar(shape_by)) frame$shape_group <- variable_of(shape_by)

    label <- function(axis) {
        sprintf("axis %d  (%.1f%% of |eigenvalues|)", axis, 100 * shares$absolute[axis])
    }
    mapping <- if (nzchar(color_by) && nzchar(shape_by)) {
        ggplot2::aes(color = color_group, shape = shape_group)
    } else if (nzchar(color_by)) {
        ggplot2::aes(color = color_group)
    } else if (nzchar(shape_by)) {
        ggplot2::aes(shape = shape_group)
    } else {
        ggplot2::aes()
    }
    figure <- ggplot2::ggplot(frame, ggplot2::aes(x = x, y = y)) +
        ggplot2::geom_point(mapping, size = 3) +
        ggplot2::geom_text(ggplot2::aes(label = pool), vjust = -1, size = 3) +
        ggplot2::coord_fixed() +
        ggplot2::labs(x = label(1), y = label(2),
                      title = "Nei's minimum distance, classical MDS") +
        ggplot2::theme_bw()
    # An empty legend title is a label ggplot2 warns about rather than ignores, so a key is
    # named only when there is one.
    if (nzchar(color_by)) figure <- figure + ggplot2::labs(color = color_by)
    if (nzchar(shape_by)) {
        figure <- figure + ggplot2::labs(shape = shape_by) +
            ggplot2::scale_shape_manual(values = SHAPE_VALUES[seq_len(shape_levels)])
    }
    ggplot2::ggsave(file.path(out, "mds.png"), figure, width = 7, height = 6, dpi = 150)
}
