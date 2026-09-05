# The module's own analysis. The shared library is above this line in the published copy.
#
#     basicstats.R --design design.json --pools pools.json --options options.json
#                  --cpp site_diversity.cpp --depths a.tsv,b.tsv --out published
#
# design.json, pools.json and options.json are written by the frame, from what analysisPlan()
# resolved: the experimental design under the project's own timeVar and series settings, the
# pool sizes and ploidy the pipeline filtered with, and this module's settings. Nothing here
# re-reads the metadata.

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag) {
    hit <- match(flag, args)
    if (is.na(hit) || hit == length(args)) stop("basicstats.R: ", flag, " needs a value")
    args[hit + 1]
}

design <- jsonlite::fromJSON(arg_of("--design"), simplifyVector = FALSE)
pools <- jsonlite::fromJSON(arg_of("--pools"), simplifyVector = FALSE)
OPTS <- jsonlite::fromJSON(arg_of("--options"), simplifyVector = TRUE)
CPP_FILE <- arg_of("--cpp")
out <- arg_of("--out")
depth_files <- strsplit(arg_of("--depths"), ",", fixed = TRUE)[[1]]
# May be empty: a project can legitimately have no histograms, and this degrades rather than
# refusing. Comma-joined by the frame, so an empty string means none rather than one named "".
histogram_files <- Filter(nzchar, strsplit(arg_of("--histograms"), ",", fixed = TRUE)[[1]])

if (length(pools) == 0) {
    stop("basicstats.R: this results directory has no pools. The project's metadata was not ",
         "read, so there is no design to describe and no size to weight by.")
}

# A pool of one chromosome has no diversity to measure and would divide by n_eff - 1 = 0.
single <- Filter(function(p) p$nChrom < 2, pools)
if (length(single) > 0) {
    stop("basicstats.R: ", paste(vapply(single, function(p) p$pool, ""), collapse = ", "),
         " hold one chromosome each. A single haploid genome has no segregating sites, and the ",
         "unbiased correction n_eff/(n_eff - 1) is undefined there. Correct ploidy or ",
         "param_poolSize for those pools.")
}

# The experimental variables, in the order the metadata file gives them.
variables <- vapply(design$variables, function(v) v$name, "")

by_pool <- setNames(pools, vapply(pools, function(p) p$pool, ""))

row_of <- function(entry) {
    figures <- by_pool[[entry$pool]]
    if (is.null(figures)) {
        stop("basicstats.R: the design names a pool '", entry$pool,
             "' that the pool figures do not. Both come from one target and cannot disagree.")
    }
    values <- vapply(variables, function(name) {
        held <- entry$values[[name]]
        if (is.null(held) || !nzchar(held)) NA_character_ else held
    }, "")
    c(list(pool = entry$pool,
           libraries = paste(unlist(entry$libraries), collapse = ";"),
           n_libraries = length(entry$libraries)),
      as.list(values),
      list(pool_size = figures$size,
           ploidy = figures$ploidy,
           n_chrom = figures$nChrom,
           detection_limit = figures$sensitivity))
}

table <- do.call(rbind, lapply(design$pools, function(entry) as.data.frame(
    row_of(entry), stringsAsFactors = FALSE, check.names = FALSE)))

write.table(table, file.path(out, "design.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE, na = "")

# ----------------------------------------------------------------------------------------
# The published tables.

# Step 7 writes one depth table per variant kind, named <vcf>_snp_depth.tsv and
# <vcf>_indel_depth.tsv. A name neither pattern answers to stops here: guessing which one it
# was would put indels into a diversity estimate that says it excludes them.
kind_of <- function(path) {
    if (grepl("_snp_depth[.]tsv$", path)) return("snp")
    if (grepl("_indel_depth[.]tsv$", path)) return("indel")
    stop("basicstats.R: '", path, "' is a depth table this module cannot classify. Step 7 ",
         "publishes <name>_snp_depth.tsv and <name>_indel_depth.tsv, and every statistic here ",
         "reports the two apart.")
}

FIXED <- c("CHROM", "POS", "REF", "ALT", "TOTAL_AD")
pool_names <- names(by_pool)

read_depths <- function(path) {
    dt <- data.table::fread(path, sep = "\t", header = TRUE, colClasses = "character",
                            data.table = FALSE)
    missing <- setdiff(FIXED, names(dt))
    if (length(missing) > 0) {
        stop("basicstats.R: '", path, "' has no ", paste(missing, collapse = ", "),
             " column. Columns are read by name and never by position.")
    }
    absent <- setdiff(pool_names, names(dt))
    if (length(absent) > 0) {
        stop("basicstats.R: '", path, "' has no column for ", paste(absent, collapse = ", "),
             ". The pools come from the project's metadata and the columns from the VCF the ",
             "pipeline called; a pool missing here means the two describe different runs.")
    }
    extra <- setdiff(names(dt), c(FIXED, pool_names))
    if (length(extra) > 0) {
        stop("basicstats.R: '", path, "' carries ", paste(extra, collapse = ", "),
             ", which the project's metadata names no pool for. Every column has to be a pool ",
             "for a per-pool number to mean anything.")
    }
    dt
}

# Depth and gene diversity for one pool's whole column, in bins.
#
# The bins are handed out to `workers` processes when there is more than one. Sites are
# independent, so the bin size changes only how the work is divided; chunk_ranges() covers
# 1..n in order and the results are put back in that order.
CPP_OWNER <- NULL

# The compiled site_diversity, built once per PROCESS.
#
# A compiled function holds a pointer into the process that built it. A worker is sent a copy
# of it with that pointer nulled, so asking whether the name exists there answers yes and
# calling it dies with "NULL value passed as symbol address". The process id is what actually
# says whether this process built the thing it is holding.
#
# sourceCpp caches the build on disk, so a worker's rebuild is a link rather than a compile.
compiled_site_diversity <- function() {
    if (!identical(CPP_OWNER, Sys.getpid())) {
        Rcpp::sourceCpp(CPP_FILE)
        CPP_OWNER <<- Sys.getpid()
    }
    site_diversity_cpp
}

compute_bin <- function(cells) {
    if (isTRUE(OPTS$usecpp)) return(compiled_site_diversity()(cells))
    site_diversity(cells)
}

column_stats <- function(cells) {
    ranges <- chunk_ranges(length(cells), OPTS$binSize)
    if (OPTS$workers > 1) {
        parts <- foreach::foreach(range = ranges) %dofuture% compute_bin(cells[range[1]:range[2]])
    } else {
        parts <- lapply(ranges, function(range) compute_bin(cells[range[1]:range[2]]))
    }
    list(depth = unlist(lapply(parts, function(part) part$depth), use.names = FALSE),
         h = unlist(lapply(parts, function(part) part$h), use.names = FALSE))
}

if (isTRUE(OPTS$usecpp)) {
    if (!requireNamespace("Rcpp", quietly = TRUE)) {
        stop("basicstats.R: the compiled path needs Rcpp and it is not installed. Install it, ",
             "or run 'PoolSeqFlow analysis basicstats nocpp' - the R gives the same numbers.")
    }
    # Built before any work, so a machine with no compiler stops here rather than partway
    # through a genome. invisible(), or the function object prints itself.
    invisible(compiled_site_diversity())
}
if (OPTS$workers > 1) {
    if (!requireNamespace("doFuture", quietly = TRUE)) {
        stop("basicstats.R: analysis.basicstats.workers is ", OPTS$workers,
             " and doFuture is not installed. Install it, or set workers to 1.")
    }
    library(doFuture)
    future::plan(future::multisession, workers = OPTS$workers)
}

# A site counts as segregating for a pool when an allele that is not that pool's OWN major one
# reaches max(detection limit, minReads / depth). The pool's major and not the cohort's: a pool
# fixed for an allele the cohort calls alternate is not segregating, and reading the majority
# off the REF column would say it is.
is_segregating <- function(cells, depth, limit, min_reads) {
    threshold <- pmax(limit, min_reads / depth)
    counts <- strsplit(cells, ",", fixed = TRUE)
    vapply(seq_along(counts), function(i) {
        values <- suppressWarnings(as.numeric(counts[[i]]))
        if (is.na(depth[i]) || depth[i] <= 0 || anyNA(values)) return(NA)
        p <- values / depth[i]
        any(p[-which.max(values)] >= threshold[i])
    }, logical(1))
}

tables <- lapply(depth_files, read_depths)
kinds <- vapply(depth_files, kind_of, "")

# File order, never sorted: the pipeline writes the chromosomes in the reference's order, and
# sort() would put chr10 before chr2 in every table below.
chrom_levels <- unique(unlist(lapply(tables, function(dt) dt$CHROM), use.names = FALSE))

# Site counts, per chromosome and per kind. A property of the tables, so they carry no pool.
site_rows <- do.call(rbind, lapply(seq_along(tables), function(i) {
    dt <- tables[[i]]
    alleles <- 1 + lengths(strsplit(dt$ALT, ",", fixed = TRUE))
    here <- intersect(chrom_levels, unique(dt$CHROM))
    data.frame(chrom = here, kind = unname(kinds[i]),
               sites = unname(vapply(here, function(c) sum(dt$CHROM == c), 0L)),
               alleles = unname(vapply(here, function(c) sum(alleles[dt$CHROM == c]), 0)),
               stringsAsFactors = FALSE)
}))
write.table(site_rows, file.path(out, "sites.tsv"), sep = "\t", quote = FALSE,
            row.names = FALSE)

# Everything below is over the SNP table alone, which is what the module's gates state: an
# indel's read counts are a different measurement and pooling the two would report a diversity
# neither is.
snp <- tables[kinds == "snp"]
if (length(snp) != 1) {
    stop("basicstats.R: this results directory holds ", length(snp), " SNP depth tables and ",
         "every statistic below is defined over exactly one.")
}
snp <- snp[[1]]

depth_rows <- list()
diversity_rows <- list()
for (name in pool_names) {
    figures <- by_pool[[name]]
    stats <- column_stats(snp[[name]])
    segregating <- is_segregating(snp[[name]], stats$depth, figures$sensitivity, OPTS$minReads)

    for (chrom in intersect(chrom_levels, unique(snp$CHROM))) {
        here <- snp$CHROM == chrom
        depth_rows[[length(depth_rows) + 1]] <- data.frame(
            pool = name, chrom = chrom, sites = sum(here),
            depth_mean = mean(stats$depth[here], na.rm = TRUE),
            depth_median = median(stats$depth[here], na.rm = TRUE),
            depth_harmonic = harmonic_mean(stats$depth[here]),
            stringsAsFactors = FALSE)
    }

    size <- n_eff(figures$nChrom, stats$depth)
    corrected <- stats$h * size / (size - 1)
    harmonic_depth <- harmonic_mean(stats$depth)
    diversity_rows[[length(diversity_rows) + 1]] <- data.frame(
        pool = name, n_chrom = figures$nChrom,
        sites = length(stats$depth),
        segregating = sum(segregating, na.rm = TRUE),
        depth_harmonic = harmonic_depth,
        n_eff_harmonic = pool_n_eff(figures$nChrom, harmonic_depth),
        h_sum = sum(corrected, na.rm = TRUE),
        pi_per_called_site = sum(corrected, na.rm = TRUE) / sum(!is.na(corrected)),
        stringsAsFactors = FALSE)
}

write.table(do.call(rbind, depth_rows), file.path(out, "depth.tsv"), sep = "\t",
            quote = FALSE, row.names = FALSE)
write.table(do.call(rbind, diversity_rows), file.path(out, "diversity.tsv"), sep = "\t",
            quote = FALSE, row.names = FALSE)

# ----------------------------------------------------------------------------------------
# Effective sample size at two levels and from two sources.
#
# The two sources are not one quantity measured twice and the table says so per row. A
# histogram counts every position the library covered, before the depth ceiling and without a
# mapping or base quality minimum; the called sites are what survived the whole filter chain,
# every one of them carrying at least vcffilter.minDP reads in every sample. The called figure
# is always the larger.
#
# There is no library-level row from the called sites, and there cannot be: the published
# tables have one column per RG_Sample, so a merged pool's libraries are already summed in
# them and nothing separates them again.

# `depth<TAB>positions`, as samtools stats reports coverage. No header.
read_histogram <- function(path) {
    hist <- utils::read.table(path, sep = "\t", header = FALSE,
                              col.names = c("depth", "positions"))
    list(depth = harmonic_mean(hist$depth, hist$positions), positions = sum(hist$positions))
}

by_library <- list()
for (path in histogram_files) {
    by_library[[sub("_depth_histogram[.]tsv$", "", basename(path))]] <- read_histogram(path)
}

neff_rows <- list()
missing <- character(0)
for (entry in design$pools) {
    figures <- by_pool[[entry$pool]]
    libraries <- unlist(entry$libraries)
    held <- libraries[libraries %in% names(by_library)]

    for (name in held) {
        one <- by_library[[name]]
        neff_rows[[length(neff_rows) + 1]] <- data.frame(
            level = "library", id = name, pool = entry$pool, source = "histogram",
            positions = one$positions, depth_harmonic = one$depth,
            n_chrom = figures$nChrom, n_eff = pool_n_eff(figures$nChrom, one$depth),
            estimate = "exact", stringsAsFactors = FALSE)
    }

    if (length(held) < length(libraries)) {
        missing <- c(missing, entry$pool)
    } else {
        # A merged pool's depth at a position is its libraries' depths added, and the harmonic
        # mean of a sum is not recoverable from the histograms of its parts. The sum of the
        # parts' harmonic means is a LOWER bound on it - exact when the libraries cover
        # positions in proportion to one another, and conservative otherwise. The manual says
        # what that means for a number read off this row.
        summed <- sum(vapply(held, function(name) by_library[[name]]$depth, 0))
        neff_rows[[length(neff_rows) + 1]] <- data.frame(
            level = "pool", id = entry$pool, pool = entry$pool, source = "histogram",
            positions = min(vapply(held, function(name) by_library[[name]]$positions, 0)),
            depth_harmonic = summed, n_chrom = figures$nChrom,
            n_eff = pool_n_eff(figures$nChrom, summed),
            estimate = if (length(held) > 1) "lower_bound" else "exact",
            stringsAsFactors = FALSE)
    }
}

# The called-site figures, which diversity.tsv already carries, repeated here so one table
# holds every effective size a reader might compare.
for (row in diversity_rows) {
    neff_rows[[length(neff_rows) + 1]] <- data.frame(
        level = "pool", id = row$pool, pool = row$pool, source = "called",
        positions = row$sites, depth_harmonic = row$depth_harmonic,
        n_chrom = row$n_chrom, n_eff = row$n_eff_harmonic,
        estimate = "exact", stringsAsFactors = FALSE)
}

write.table(do.call(rbind, neff_rows), file.path(out, "neff.tsv"), sep = "\t",
            quote = FALSE, row.names = FALSE)

if (length(missing) > 0) {
    cat("basicstats: no depth histogram for ", paste(unique(missing), collapse = ", "),
        " - those pools have no genome-wide effective size, and none is guessed from the ",
        "libraries that did have one\n", sep = "")
}

# ----------------------------------------------------------------------------------------
# Depth along a sequence, for the sequences you named and no others.
#
# Nothing is drawn until a name is given. A genome has more sequences than anyone wants plots
# for, and which of them is worth looking at is the user's question rather than a default this
# could guess; when none are named the candidates are listed with their site counts so a name
# can be copied into the setting.
#
# It is depth at the CALLED sites, not coverage: the x axis is a called position and the gaps
# between them are sites the pipeline did not call, not sites with no reads.

named <- as.character(unlist(OPTS$chromosomes))
available <- intersect(chrom_levels, unique(snp$CHROM))

if (length(named) == 0) {
    cat("basicstats: no depth plot was drawn. Name the sequences you want in ",
        "analysis.basicstats.chromosomes:\n", sep = "")
    for (chrom in available) {
        cat("basicstats:     ", chrom, " (", sum(snp$CHROM == chrom), " called SNP sites)\n",
            sep = "")
    }
} else {
    unknown <- setdiff(named, available)
    if (length(unknown) > 0) {
        stop("basicstats.R: analysis.basicstats.chromosomes names ",
             paste(unknown, collapse = ", "), ", which the depth table has no called site on. ",
             "It has: ", paste(available, collapse = ", "), ". A sequence with no surviving ",
             "variant is invisible here and cannot be told from one your reference does not ",
             "have, so this is refused rather than drawn empty.")
    }
    if (!requireNamespace("ggplot2", quietly = TRUE)) {
        stop("basicstats.R: analysis.basicstats.chromosomes asks for a plot and ggplot2 is not ",
             "installed. Install it, or set chromosomes to an empty list.")
    }

    for (chrom in named) {
        here <- snp$CHROM == chrom
        frame <- do.call(rbind, lapply(pool_names, function(name) data.frame(
            pool = name,
            position = as.numeric(snp$POS[here]),
            depth = column_stats(snp[[name]][here])$depth,
            stringsAsFactors = FALSE)))
        # The pools keep the table's own order rather than R's alphabetical one, so the facets
        # read in the order every other file here uses.
        frame$pool <- factor(frame$pool, levels = pool_names)

        figure <- ggplot2::ggplot(frame, ggplot2::aes(x = position, y = depth)) +
            ggplot2::geom_point(size = 0.4, alpha = 0.6) +
            ggplot2::facet_wrap(~ pool, ncol = 1, scales = "fixed") +
            ggplot2::labs(
                title = paste0("Depth at called SNP sites: ", chrom),
                subtitle = "Each point is one called site. Gaps are sites with no call, not sites with no reads.",
                x = paste0("Position on ", chrom), y = "Reads supporting any allele") +
            ggplot2::theme_bw(base_size = 9)

        # The name is sanitised: a sequence may be called anything, and a published file name
        # has to survive being one.
        safe <- gsub("[^A-Za-z0-9._-]", "_", chrom)
        ggplot2::ggsave(file.path(out, paste0("depth_", safe, ".png")), figure,
                        width = 7, height = 1.4 * length(pool_names) + 1, dpi = 150)
        cat("basicstats: drew depth_", safe, ".png over ", sum(here), " called sites\n", sep = "")
    }
}

cat("basicstats: ", nrow(table), " pools, ",
    length(variables), " experimental variable", if (length(variables) == 1) "" else "s",
    "\n", sep = "")
cat("basicstats: ", nrow(snp), " SNP sites, ",
    sum(site_rows$sites) - nrow(snp), " indel sites, over ",
    length(chrom_levels), " sequence", if (length(chrom_levels) == 1) "" else "s", "\n", sep = "")
cat("basicstats: diversity computed by the ",
    if (isTRUE(OPTS$usecpp)) "compiled" else "vectorised R",
    " path, in bins of ", OPTS$binSize, " sites over ",
    OPTS$workers, if (OPTS$workers == 1) " worker" else " workers", "\n", sep = "")
