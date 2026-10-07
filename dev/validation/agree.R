#!/usr/bin/env Rscript
#
# The harness's estimators against the SHIPPED modules, site by site, on tables with unread cells.
#
#     agree.R <modules directory> <work directory> [seed]
#
# The missing_* sections of calibrate.R call association.R's own functions, parsed out of the
# script, but restate the fifteen lines of its main loop that put them in order: the roll-up,
# theta, the untestable rule, BH over the tested sites. They restate step 7's mask as well. If
# either drifted from what ships, every number those sections print would describe something no
# run computes, and nothing there could tell. So this starts the real association.R and mds.R on
# simulated tables, runs the real bin/mask_depth.awk, and compares. Exits 1 on any disagreement,
# and the missing_* numbers are not to be read until it agrees again.
#
# NOT A SECTION OF calibrate.R. That one is base R and runs under any Rscript; this starts the
# module's own script, which reads its inputs with jsonlite and has to run under the R the module
# really runs under, the analysis environment's. A section that skipped itself without jsonlite
# would be a check that stops checking, so this stops with the reason instead.
#
# Every case carries a VACUITY GUARD: a table that cannot reach what it was built for -- no site
# read in three units, a mask that drops nothing -- fails rather than agrees. Two fired while this
# was being written, a count of 19 against a guard of 20 and a mask case that dropped no site, and
# the cases were rebuilt until they held with margin.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: agree.R <modules directory> <work directory> [seed]")
MODULES_DIR <- normalizePath(args[1])
work <- args[2]
seed <- if (length(args) > 2) as.integer(args[3]) else 20261005L

if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("agree.R: jsonlite is not installed, and the modules read their inputs with it. Run ",
         "this with the Rscript of the analysis environment, PoolSeqFlow-<version>-analysis.")
}
if (!nzchar(Sys.which("awk"))) stop("agree.R: no awk on the PATH, and step 7's mask is awk")

LIBRARIES <- sort(Sys.glob(file.path(MODULES_DIR, "lib", "*", "*.R")))
if (length(LIBRARIES) == 0) stop("agree.R: no R sources under ", MODULES_DIR, "/lib")
for (path in LIBRARIES) source(path)
here <- dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
source(file.path(here, "lib.R"))

dir.create(work, recursive = TRUE, showWarnings = FALSE)
set.seed(seed)

version_of <- function(name) {
    jsonlite::fromJSON(file.path(MODULES_DIR, name, "manifest.json"))$version
}
cat(sprintf("agree.R  %s  jsonlite %s  association %s  mds %s  seed %d\n\n",
            R.version.string, as.character(packageVersion("jsonlite")),
            version_of("association"), version_of("mds"), seed))

failures <- 0L
fail <- function(...) {
    failures <<- failures + 1L
    cat("  DISAGREE: ", sprintf(...), "\n", sep = "")
}
guard <- function(reached, ...) {
    if (!reached) fail("a case no longer reaches what it was built for: %s", sprintf(...))
}

Y <- c(-1.3, -0.8, -0.2, 0.4, 0.9, 1.6)
N_CHROM <- 100L

# ---------------------------------------------------------------------------------------
# What a module run needs: a depth table, the design, the pool figures and the options, in the
# shapes the frame writes them.

write_inputs <- function(tag, counts, alt, groups = NULL, y = Y, variables = FALSE) {
    dir <- file.path(work, tag)
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    pools <- ncol(counts[[1]])
    names_p <- paste0("P", seq_len(pools))
    sites <- nrow(counts[[1]])
    table <- data.frame(CHROM = "chr1", POS = seq_len(sites), REF = "A", ALT = alt,
                        TOTAL_AD = do.call(paste, c(lapply(counts, rowSums), sep = ",")),
                        stringsAsFactors = FALSE)
    for (i in seq_len(pools)) {
        table[[names_p[i]]] <- do.call(paste, c(lapply(counts, function(m) m[, i]), sep = ","))
    }
    write.table(table, file.path(dir, "Sim_snp_depth.tsv"), sep = "\t", quote = FALSE,
                row.names = FALSE)

    if (is.null(groups)) groups <- as.list(seq_len(pools))
    unit_of <- rep(seq_along(groups), lengths(groups))
    design <- list(
        variables = if (variables) list(list(name = "clade", levels = list("A", "B"))) else list(),
        time = NULL, keyColumns = list(),
        roles = list(condition = list(), biological = list(), technical = list()),
        series = list(),
        pools = lapply(seq_len(pools), function(i) {
            list(pool = names_p[i], libraries = list(names_p[i]),
                 values = if (variables) list(clade = if (i <= pools / 2) "A" else "B") else list())
        }),
        units = lapply(seq_along(groups), function(u) {
            list(label = paste0("U", u), key = list(), pools = as.list(names_p[groups[[u]]]),
                 members = as.list(names_p[groups[[u]]]))
        }),
        conditions = list(),
        phenotypes = if (variables) list() else list(list(
            column = "pt_y", kind = "quantitative",
            values = lapply(seq_len(pools), function(i) {
                list(pool = names_p[i], shown = as.character(y[unit_of[i]]), group = NULL,
                     value = y[unit_of[i]])
            }))),
        covariates = list(), warnings = list())
    jsonlite::write_json(design, file.path(dir, "design.json"), auto_unbox = TRUE, null = "null",
                         digits = NA)
    figures <- lapply(names_p, function(pool) {
        list(pool = pool, size = 50, ploidy = 2, nChrom = N_CHROM, sensitivity = 0.01)
    })
    jsonlite::write_json(figures, file.path(dir, "pools.json"), auto_unbox = TRUE, digits = NA)
    dir
}

# The module as the frame publishes it: every library's R above the module's own.
assemble <- function(dir, module) {
    script <- file.path(dir, paste0(module, ".R"))
    writeLines(c(unlist(lapply(LIBRARIES, readLines)),
                 readLines(file.path(MODULES_DIR, module, paste0(module, ".R")))), script)
    script
}

run_module <- function(dir, module, options, extra, refusal = NULL) {
    jsonlite::write_json(options, file.path(dir, "options.json"), auto_unbox = TRUE,
                         null = "null", digits = NA)
    script <- assemble(dir, module)
    started <- Sys.time()
    status <- system2(file.path(R.home("bin"), "Rscript"),
                      c("--vanilla", script, "--design", file.path(dir, "design.json"),
                        "--pools", file.path(dir, "pools.json"),
                        "--options", file.path(dir, "options.json"), extra,
                        "--depths", file.path(dir, "Sim_snp_depth.tsv"), "--out", dir),
                      stdout = file.path(dir, "out.txt"), stderr = file.path(dir, "out.txt"))
    cat(sprintf("   %s exit %d in %.1f s\n", module, status,
                as.numeric(Sys.time() - started, units = "secs")))
    said <- paste(readLines(file.path(dir, "out.txt")), collapse = "\n")
    if (!is.null(refusal)) {
        if (status == 0 || !grepl(refusal, said)) {
            fail("%s: expected a refusal naming '%s', got exit %d", module, refusal, status)
        }
        return(invisible(NULL))
    }
    if (status != 0) stop(said)
}

association_options <- function(dispersion) {
    list(phenotypes = list("pt_y"), permutations = 5000, dispersion = dispersion, fdr = "BH",
         reportBelow = 1, reportTop = 100000, chromosomes = list(), binSize = 100000,
         workers = 1, usecpp = FALSE)
}
source_of <- function(library) file.path(MODULES_DIR, "lib", library, paste0(library, ".cpp"))

# Equal to a relative tolerance, NA where the other is NA and nowhere else.
close_to <- function(a, b, tolerance) {
    both <- !is.na(a) & !is.na(b)
    identical(is.na(a), is.na(b)) &&
        all(abs(a[both] - b[both]) <= tolerance * pmax(1, abs(b[both])) | a[both] == b[both])
}

# The module's tables against association_run() over the same counts. S is compared only where no
# allele exhausted its residual: two builds of R disagree about an exhausted site, as the module's
# own cases note, and zero_variance is compared everywhere instead.
compare_association <- function(label, dir, mine) {
    got <- read.delim(file.path(dir, "association.tsv"))
    run <- read.delim(file.path(dir, "permutations.tsv"))
    own <- mine$sites
    cat(sprintf("%s: %d sites, the module tested %d, the estimator %d\n", label, nrow(got),
                sum(!is.na(got$S)), mine$tested))
    if (!isTRUE(run$exhaustive) || run$permutations != factorial(got$n_units[1])) {
        fail("%s: the module sampled", label)
    }
    if (!identical(as.integer(got$n_observed), as.integer(own$m))) {
        fail("%s: n_observed differs", label)
    }
    if (!identical(as.integer(got$zero_variance), as.integer(own$flagged))) {
        fail("%s: zero_variance differs", label)
    }
    for (column in c("S", "perm_p", "fdr_p")) {
        if (!identical(is.na(got[[column]]), is.na(own[[column]]))) {
            fail("%s: %s is NA at different sites", label, column)
        }
    }
    clean <- is.na(got$zero_variance) | got$zero_variance == 0
    finite <- clean & is.finite(got$S) & is.finite(own$S)
    if (!close_to(got$S[finite], own$S[finite], 1e-9)) fail("%s: S differs", label)
    both <- clean & !is.na(got$perm_p) & !is.na(own$perm_p)
    gap_p <- max(abs(got$perm_p[both] - own$perm_p[both]), 0)
    gap_q <- max(abs(got$fdr_p[both] - own$fdr_p[both]), 0)
    if (gap_p > 1e-12) fail("%s: perm_p differs by %.2e", label, gap_p)
    if (gap_q > 1e-12) fail("%s: fdr_p differs by %.2e", label, gap_q)
    if (!close_to(run$dispersion, mine$theta, 1e-9)) {
        fail("%s: dispersion %.10g against %.10g", label, run$dispersion, mine$theta)
    }
    if (!close_to(run$lambda_gc, mine$lambda_gc, 1e-9)) fail("%s: lambda_gc differs", label)
    if (!close_to(run$depth_phenotype_cor, mine$depth_phenotype_cor, 1e-9)) {
        fail("%s: depth_phenotype_cor differs", label)
    }
    read_in <- table(got$n_observed)
    cat(sprintf("   n_observed, NA patterns and zero_variance identical; perm_p within %.1e and\n",
                gap_p))
    cat("   fdr_p")
    cat(sprintf(" within %.1e on the %d sites not flagged; units read %s\n", gap_q, sum(clean),
                paste(names(read_in), read_in, sep = ":", collapse = " ")))
    invisible(got)
}

# ---------------------------------------------------------------------------------------
cat("1. the induced orders, over every subset of 3 to 7 units\n")
# The identity the module's per-site rearrangement rests on: the order a subset M of the units
# takes inside every one of the n! rearrangements of all of them meets each of M's m! orders
# exactly n!/m! times. Pure counting, and the reason an enumerated p over all n units is the exact
# test over the m units a site was read in.
checked <- 0L
for (n in 3:7) {
    moves <- relabelings(seq_len(n))
    for (size in seq_len(n)) {
        for (subset in combn(n, size, simplify = FALSE)) {
            inside <- matrix(moves %in% subset, nrow = nrow(moves))
            induced <- matrix(t(moves)[t(inside)], ncol = size, byrow = TRUE)
            met <- table(as.vector(induced %*% (n + 1)^(seq_len(size) - 1)))
            if (length(met) != factorial(size) || any(met != factorial(n) / factorial(size))) {
                fail("n = %d, M = %s: the induced orders are not uniform", n,
                     paste(subset, collapse = ","))
            }
            checked <- checked + 1L
        }
    }
}
cat(sprintf("   %d subsets, each order of M met exactly n!/m! times\n\n", checked))

masked_depths <- depth_for_masking(c(0.9, 0.6, 0.4, 0.25, 0.12, 0.05), 20L, 4)

cat("2. association.R, two alleles: every read pattern, sites read in one or two units, and\n")
cat("   sites whose ALT no read cell holds\n")
counts <- simulate_cells(draw_depth(1000L, masked_depths, 4), N_CHROM,
                         matrix(runif(1000, 0.15, 0.85), 1000, 6))$counts
masked_table <- mask_cells(counts, 20L, 1L)
phantoms <- 30L
from <- sample(which(rowSums(masked_table$read) >= 3), phantoms)
ref <- rbind(masked_table$counts[[1]], masked_table$counts[[1]][from, ])
alt <- rbind(masked_table$counts[[2]], matrix(0L, phantoms, 6))
dir <- write_inputs("biallelic", list(ref, alt), rep("G", nrow(alt)))
for (dispersion in list(NULL, 0)) {
    run_module(dir, "association", association_options(dispersion),
               c("--cpp", source_of("allele_frequencies")))
    how <- if (is.null(dispersion)) "estimated" else "pinned at 0"
    got <- compare_association(
        sprintf("   biallelic, dispersion %s", how), dir,
        association_run(list(ref, alt), N_CHROM, Y, budget = 5000L, dispersion = dispersion))
}
tested_by_m <- table(factor(got$n_observed[!is.na(got$S)], levels = 3:6))
guard(all(tested_by_m >= 10), "tested sites per m %s", paste(tested_by_m, collapse = "/"))
guard(sum(got$n_observed <= 2) >= 10, "%d sites read in two units or fewer",
      sum(got$n_observed <= 2))
guard(sum(is.na(got$S) & got$n_observed >= 3) >= 25, "%d sites with no varying allele",
      sum(is.na(got$S) & got$n_observed >= 3))

cat("\n3. a failed library: pool 4 unread at every site, the others masked at random\n")
sites <- 600L
counts <- simulate_cells(matrix(120L, sites, 6), N_CHROM,
                         matrix(runif(sites, 0.15, 0.85), sites, 6))$counts
read <- matrix(rbinom(sites * 6, 1, 0.8), sites, 6) == 1
read[, 4] <- FALSE
failed_library <- lapply(counts, function(m) {
    m[!read] <- 0L
    m[rowSums(read) >= 2, , drop = FALSE]
})
dir <- write_inputs("failed_library", failed_library, rep("G", nrow(failed_library[[1]])))
run_module(dir, "association", association_options(NULL),
           c("--cpp", source_of("allele_frequencies")))
got <- compare_association("   failed library", dir,
                           association_run(failed_library, N_CHROM, Y, budget = 5000L))
guard(!is.na(read.delim(file.path(dir, "permutations.tsv"))$dispersion) && sum(!is.na(got$S)) > 100,
      "theta missing or nothing tested")

cat("\n4. three alleles\n")
sites <- 250L
depth <- draw_depth(sites, masked_depths, 4)
shares <- matrix(rgamma(sites * 3, 1.2), sites, 3)
shares <- shares / rowSums(shares)
masked_table <- mask_cells(simulate_alleles(depth, N_CHROM, shares), 20L, 1L)
dir <- write_inputs("triallelic", masked_table$counts, rep("G,T", nrow(masked_table$counts[[1]])))
run_module(dir, "association", association_options(0), c("--cpp", source_of("allele_frequencies")))
compare_association("   three alleles, dispersion pinned at 0", dir,
                    association_run(masked_table$counts, N_CHROM, Y, budget = 5000L,
                                    dispersion = 0))

cat("\n5. technical replicates: twelve pools in six units of two lanes of one pool\n")
sites <- 400L
carried <- matrix(rbinom(sites * 6, N_CHROM, 0.5), sites, 6) / N_CHROM
depth <- draw_depth(sites, rep(masked_depths, each = 2), 4)
alt <- matrix(rbinom(length(depth), as.vector(depth), as.vector(carried[, rep(1:6, each = 2)])),
              sites)
masked_table <- mask_cells(list(depth - alt, alt), 20L, 1L)
dir <- write_inputs("lanes", masked_table$counts, rep("G", nrow(masked_table$counts[[1]])),
                    groups = lapply(1:6, function(u) c(2 * u - 1, 2 * u)))
run_module(dir, "association", association_options(NULL),
           c("--cpp", source_of("allele_frequencies")))
compare_association("   12 pools in 6 units of 2", dir,
                    association_run(masked_table$counts, N_CHROM, Y,
                                    groups = unit_groups(rep(2, 6)), budget = 5000L))
lanes_read <- masked_table$read[, seq(1, 12, by = 2)] + masked_table$read[, seq(2, 12, by = 2)]
guard(sum(lanes_read == 1) >= 100, "%d unit cells read through one lane of two",
      sum(lanes_read == 1))

cat("\n6. mds.R: its tables against nei_distance called as the harness calls it\n")
ordinate <- module_functions(file.path(MODULES_DIR, "mds", "mds.R"), "ordinate")$ordinate
mds_depths <- depth_for_masking(c(0.85, 0.30, 0.30, 0.15, 0.10, 0.05), 20L, 10)
counts <- simulate_cells(draw_depth(1000L, mds_depths, 10), N_CHROM,
                         population_truth(1000L))$counts
masked_table <- mask_cells(counts, 20L, 1L)
dir <- write_inputs("mds", masked_table$counts, rep("G", nrow(masked_table$counts[[1]])),
                    variables = TRUE)
mds_options <- list(dimensions = 2, colorBy = "", shapeBy = "", includeIndels = FALSE,
                    chromosomes = list(), binSize = 100000, workers = 1, usecpp = FALSE)
mds_sources <- c("--cpp-frequencies", source_of("allele_frequencies"),
                 "--cpp-distance", source_of("nei_distance"))
run_module(dir, "mds", mds_options, mds_sources)
mine <- nei_run(masked_table$counts)
names_p <- paste0("P", 1:6)
published <- read.delim(file.path(dir, "distance.tsv"))
at <- cbind(match(published$pool_a, names_p), match(published$pool_b, names_p))
if (!identical(as.numeric(published$sites), as.numeric(mine$sites[at]))) {
    fail("mds: shared-site counts differ")
}
if (!close_to(published$distance, mine$D[at], 1e-9)) fail("mds: corrected distance differs")
if (!close_to(published$raw, mine$raw[at], 1e-9)) fail("mds: raw distance differs")
plotted <- as.matrix(read.delim(file.path(dir, "mds.tsv"))[, c("dim1", "dim2")])
gap <- max(abs(plotted - ordinate(mine$D, 2)$coords))
if (gap > 1e-9) fail("mds: coordinates differ")
cat(sprintf("   %d pairs on %d to %d shared sites; distances and coordinates agree, largest gap\n",
            nrow(published), min(published$sites), max(published$sites)))
cat(sprintf("   %.1e\n", gap))
guard(min(published$sites) < 0.2 * max(published$sites),
      "the pairs rest on similar numbers of sites")
dead <- lapply(masked_table$counts, function(m) {
    m[, 3] <- 0L
    m
})
dir <- write_inputs("mds_dead", dead, rep("G", nrow(dead[[1]])), variables = TRUE)
run_module(dir, "mds", mds_options, mds_sources, refusal = "share no site")
cat("   a pool unread everywhere: the module stops, naming the pair\n")

cat("\n7. the harness's mask against bin/mask_depth.awk\n")
sites <- 400L
counts <- simulate_cells(draw_depth(sites, masked_depths, 10), N_CHROM,
                         matrix(runif(sites, 0.1, 0.9), sites, 6))$counts
ref <- counts[[1]]
alt <- counts[[2]]
lines <- c("##fileformat=VCFv4.2",
           paste(c("#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO", "FORMAT",
                   paste0("P", 1:6)), collapse = "\t"))
for (i in seq_len(sites)) {
    info <- sprintf("AD=%d,%d;DP=%d;DP4=1,1,1,1", sum(ref[i, ]), sum(alt[i, ]),
                    sum(ref[i, ] + alt[i, ]))
    cells <- sprintf("./.:%d:%d,%d", ref[i, ] + alt[i, ], ref[i, ], alt[i, ])
    lines <- c(lines, paste(c("chr1", i, ".", "A", "G", ".", ".", info, "GT:DP:AD", cells),
                            collapse = "\t"))
}
vcf <- file.path(work, "mask_in.vcf")
writeLines(lines, vcf)
awk <- file.path(dirname(MODULES_DIR), "bin", "mask_depth.awk")
for (min_samples in c(2L, 4L)) {
    out <- system2("awk", c("-f", awk, "-v", "minDP=20",
                            "-v", sprintf("minSamples=%d", min_samples), vcf), stdout = TRUE)
    body <- out[!grepl("^#", out)]
    mine <- mask_cells(counts, 20L, min_samples)
    if (length(body) != length(mine$kept)) {
        fail("mask at minSamples %d: the awk kept %d sites, the harness %d", min_samples,
             length(body), length(mine$kept))
    } else {
        fields <- strsplit(body, "\t")
        awk_cells <- do.call(rbind, lapply(fields, function(f) sub("^[^:]*:[^:]*:", "", f[10:15])))
        harness_cells <- matrix(paste(mine$counts[[1]], mine$counts[[2]], sep = ","),
                                nrow(mine$counts[[1]]))
        if (!identical(unname(awk_cells), unname(harness_cells))) {
            fail("mask at minSamples %d: the cells differ", min_samples)
        }
        if (!identical(as.integer(vapply(fields, `[`, "", 2)), mine$kept)) {
            fail("mask at minSamples %d: the kept sites differ", min_samples)
        }
    }
    guard(mean(!mine$read) > 0.05 && length(mine$kept) < sites && length(mine$kept) > 0,
          "minSamples %d: masked share %.2f, kept %d of %d", min_samples, mean(!mine$read),
          length(mine$kept), sites)
    cat(sprintf("   minSamples %d: the awk kept %d of %d sites, %.0f%% of their cells masked,\n",
                min_samples, length(body), sites, 100 * mean(!mine$read)))
    cat("   and every cell identical\n")
}

if (failures > 0) {
    cat(sprintf("\nFAILED: %d disagreement(s). The estimators in lib.R are not what the modules\n",
                failures))
    cat("compute, and no missing_* number of calibrate.R is to be read until they agree.\n")
    quit(status = 1)
}
cat("\nall agree\n")
