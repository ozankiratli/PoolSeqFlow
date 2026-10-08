# The functions a report is drawn with. report.Rmd sources this before anything is knitted, so the
# frame's own layout and a module's report call the same ones.
#
# Every function that draws prints markdown or a raw typst block, so it is called from a chunk with
# results = "asis".

# The published folder the report describes.
report_folder <- function() {
    folder <- Sys.getenv("POOLSEQFLOW_REPORT_FOLDER")
    if (!nzchar(folder) || !dir.exists(folder)) {
        stop("report: POOLSEQFLOW_REPORT_FOLDER names no folder: '", folder, "'")
    }
    folder
}

# The outputPrefix every file the module computed is published under.
report_prefix <- function() {
    prefix <- Sys.getenv("POOLSEQFLOW_REPORT_PREFIX")
    if (!nzchar(prefix)) stop("report: POOLSEQFLOW_REPORT_PREFIX is not set")
    prefix
}

# The name a file the module wrote is published under, the prefix and an underscore in front. A
# glob gives a glob.
report_name <- function(name) {
    paste0(report_prefix(), "_", name)
}

# A published name with the prefix taken off: the name the module wrote.
report_logical <- function(name) {
    lead <- paste0(report_prefix(), "_")
    ifelse(startsWith(name, lead), substring(name, nchar(lead) + 1), name)
}

# A published table, by the name the module wrote it under, with every column as text, so a
# sequence called 4 stays a name. NULL when the folder does not hold it. The tables are written
# unquoted, so a quote in a cell is a character.
report_read <- function(name) {
    path <- file.path(report_folder(), report_name(name))
    if (!file.exists(path)) return(NULL)
    utils::read.delim(path, check.names = FALSE, colClasses = "character", quote = "",
                      comment.char = "")
}

# The published files a glob of the names the module wrote matches, in name order. The glob is
# matched against the names alone, so a bracket in the folder's own path is a character.
report_files <- function(pattern) {
    sort(list.files(report_folder(), pattern = utils::glob2rx(report_name(pattern)),
                    full.names = TRUE))
}

# Text as markdown that reads exactly as written: every ASCII punctuation mark escaped, so a name
# holding * or @ is not emphasis or a citation.
report_text <- function(x) {
    gsub("([[:punct:]])", "\\\\\\1", as.character(x), perl = TRUE)
}

# Numbers as a table shows them: NA, NaN, Inf and -Inf as themselves. With `decimals`, that many
# places after the point. Without, a whole number is printed whole, a magnitude below 1e-4 or from
# 1e15 in scientific notation, and anything else to `digits` significant digits. Thousands are
# separated.
report_number <- function(x, digits = 3, decimals = NULL) {
    x <- suppressWarnings(as.numeric(x))
    out <- rep("NA", length(x))
    out[is.nan(x)] <- "NaN"
    out[!is.na(x) & x == Inf] <- "Inf"
    out[!is.na(x) & x == -Inf] <- "-Inf"
    ok <- is.finite(x)
    # A value that rounds to zero prints unsigned; formatC writes it as -0.
    if (!is.null(decimals)) x[ok] <- round(x[ok], decimals)
    x[ok & x == 0] <- 0
    if (!is.null(decimals)) {
        out[ok] <- formatC(x[ok], format = "f", digits = decimals, big.mark = ",")
        return(out)
    }
    whole <- ok & x == round(x) & abs(x) < 1e15
    out[whole] <- formatC(x[whole], format = "f", digits = 0, big.mark = ",")
    rest <- ok & !whole
    out[rest] <- vapply(x[rest], function(v) {
        if (abs(v) < 1e-4 || abs(v) >= 1e15) return(formatC(v, format = "e", digits = digits - 1))
        sub("[.]$", "", formatC(signif(v, digits), digits = digits, format = "fg", flag = "#",
                                big.mark = ","))
    }, "")
    out
}

# Every column of a table that holds decimals, printed by report_number(), for a table the report
# knows nothing about. A column of whole numbers is left as written, and so is any column holding a
# value like 01.
report_format <- function(table, digits = 4) {
    for (name in names(table)) {
        values <- table[[name]]
        held <- values[!is.na(values) & nzchar(values) & !(values %in% c("NA", "NaN", "Inf", "-Inf"))]
        if (length(held) == 0 || anyNA(suppressWarnings(as.numeric(held)))) next
        if (!any(grepl(".", held, fixed = TRUE)) || any(grepl("^[-+]?0[0-9]", held))) next
        table[[name]] <- ifelse(is.na(values) | !nzchar(values), values,
                                report_number(values, digits = digits))
    }
    table
}

# The rows of a published table below its header, counted without reading them as a table.
count_rows <- function(path) {
    con <- file(path, "r")
    on.exit(close(con))
    lines <- 0L
    repeat {
        chunk <- readLines(con, n = 100000L, warn = FALSE)
        if (length(chunk) == 0) break
        lines <- lines + length(chunk)
    }
    max(lines - 1L, 0L)
}

# Text as a typst string literal, which typst sets as plain text: no character in it is markup.
typst_string <- function(x) {
    x <- ifelse(is.na(x), "NA", as.character(x))
    x <- gsub("\\", "\\\\", x, fixed = TRUE)
    x <- gsub("\"", "\\\"", x, fixed = TRUE)
    x <- gsub("\n", "\\n", x, fixed = TRUE)
    paste0("\"", x, "\"")
}

# A column is aligned right when every value in it is a number, NA or empty, a column holding
# nothing else included.
numeric_column <- function(values) {
    held <- values[!is.na(values) & nzchar(values) & values != "NA"]
    all(grepl("^[-+\u2265\u2264<>~ ]*[0-9][0-9,.]*(e[-+]?[0-9]+)?%?$", held))
}

# A table, as typst draws it: the header repeated on every page the table runs onto, a cell
# holding a newline set on two lines, and no cell broken anywhere else.
#
# Typst measures every cell and every header once and keeps the first layout that fits the text
# width: each column as wide as what is in it, at 10, 9, 8 or 7 points; then each column at least
# as wide as its widest cell and the widest part of its header, with the space left over shared in
# proportion to what each column lacks of its full width and the headers wrapping after an
# underscore, a dot or a space, at 10 down to 5 points; then that at 4 points. Every one of them
# breaks across pages.
#
# `align` is one letter per column, "l" or "r"; without it a column of numbers is aligned right and
# anything else left. `groups` is one label per column, and a run of equal labels is printed once
# above the columns it spans; "" spans nothing. `size` fixes the text size in points, with the
# headers on one line. A table longer than `max_rows` shows its first rows. `total` is how many
# rows the table has when it was read cut short, and the table says how many `source` holds.
report_table <- function(table, caption = NULL, align = NULL, groups = NULL, size = NULL,
                         max_rows = Inf, source = NULL, total = nrow(table)) {
    stopifnot(is.data.frame(table))
    # Evaluated here: its default counts the rows before the cut below.
    force(total)
    if (ncol(table) == 0) {
        cat("\n*Nothing to show", if (!is.null(caption)) paste0(": ", caption), ".*\n\n", sep = "")
        return(invisible())
    }
    if (nrow(table) > max_rows) table <- utils::head(table, max_rows)
    if (is.null(align)) align <- vapply(table, function(col) if (numeric_column(col)) "r" else "l", "")
    alignment <- ifelse(align == "r", "right", "left")

    n <- ncol(table)
    as_array <- function(items) paste0("(", paste(c(items, ""), collapse = ", "), ")")
    values <- lapply(table, function(col) typst_string(ifelse(is.na(col), "NA", as.character(col))))
    labels <- names(table)
    # A header's parts: where it may wrap, after an underscore or a dot, or at a space.
    parts <- lapply(labels, function(label) {
        pieces <- strsplit(gsub("([_.])", "\\1\001", label), "\001| ", perl = TRUE)[[1]]
        pieces[nzchar(pieces)]
    })

    # The header rows, and the rule under each group label.
    names_row <- paste(sprintf("strong(if wrapped { soft.at(%d) } else { whole.at(%d) })",
                               seq_len(n) - 1, seq_len(n) - 1), collapse = ", ")
    header_rows <- 1
    if (is.null(groups)) {
        header <- paste0("table.header(", names_row, ")")
    } else {
        stopifnot(length(groups) == ncol(table))
        runs <- rle(groups)
        starts <- cumsum(c(0, utils::head(runs$lengths, -1)))
        spans <- character(0)
        rules <- character(0)
        # A label is broken between words to about the width of the columns under it, counted in
        # characters.
        chars <- vapply(seq_along(table), function(j) {
            max(nchar(names(table)[j]), nchar(as.character(table[[j]])), na.rm = TRUE) + 2
        }, 0)
        for (i in seq_along(runs$lengths)) {
            if (!nzchar(runs$values[i])) {
                spans <- c(spans, rep("[]", runs$lengths[i]))
                next
            }
            room <- sum(chars[starts[i] + seq_len(runs$lengths[i])])
            label <- paste(strwrap(runs$values[i], width = max(room, 1)), collapse = "\n")
            spans <- c(spans, sprintf("table.cell(colspan: %d, align: center, strong(%s))",
                                      runs$lengths[i], typst_string(label)))
            rules <- c(rules, sprintf("table.hline(y: 1, start: %d, end: %d, stroke: 0.4pt)",
                                      starts[i], starts[i] + runs$lengths[i]))
        }
        header <- paste0("table.header(", paste(c(spans, rules), collapse = ", "), ", ",
                         names_row, ")")
        header_rows <- 2
    }

    # The cells a row to a line, and the same cells a column to an array for measuring.
    rows <- if (nrow(table) > 0) paste0("    ", do.call(paste, c(values, sep = ", ")), ",")
            else character(0)
    data <- c(
        "  let flat = (",
        rows,
        "  )",
        sprintf("  let cells = range(%d).map(j => range(%d).map(i => flat.at(i * %d + j)))",
                n, nrow(table), n),
        sprintf("  let whole = %s", as_array(typst_string(labels))),
        sprintf("  let soft = %s", as_array(typst_string(gsub("([_.])", "\\1\u200b", labels)))),
        sprintf("  let parts = %s", as_array(vapply(parts, function(p) as_array(typst_string(p)), ""))))
    make <- c(
        "  let make(s, columns, wrapped) = text(size: s, table(",
        "    columns: columns,",
        sprintf("    align: %s,", as_array(alignment)),
        "    stroke: none,",
        "    inset: (x: 5pt, y: 3.5pt),",
        sprintf("    fill: (_, y) => if y >= %d and calc.odd(y - %d) { luma(245) },",
                header_rows, header_rows),
        "    table.hline(),",
        paste0("    ", header, ","),
        "    table.hline(stroke: 0.5pt),",
        "    ..flat,",
        "    table.hline(),",
        "  ))")
    # Widths are measured at 10 points and scale with the text; each column also carries its
    # 5pt inset on either side.
    shown <- if (!is.null(size)) sprintf("  let shown = make(%spt, %d, false)", size, n) else c(
        "  let width(x, bold) = measure(text(size: 10pt, if bold { strong(x) } else { x })).width",
        "  let widest(xs, bold) = xs.fold(0pt, (m, x) => calc.max(m, width(x, bold)))",
        sprintf("  let least = range(%d).map(j => calc.max(widest(cells.at(j), false), widest(parts.at(j), true)))", n),
        sprintf("  let most = range(%d).map(j => calc.max(widest(cells.at(j), false), width(whole.at(j), true)))", n),
        "  let at(ws, s) = ws.map(w => w * (s / 10pt) + 10pt)",
        "  let fits(ws, s) = at(ws, s).sum() <= region.width",
        "  let natural = (10pt, 9pt, 8pt, 7pt).find(s => fits(most, s))",
        sprintf("  let shown = if natural != none { make(natural, %d, false) } else {", n),
        "    let found = (10pt, 9pt, 8pt, 7pt, 6pt, 5pt).find(s => fits(least, s))",
        "    let s = if found != none { found } else { 4pt }",
        "    let low = at(least, s)",
        "    let lacking = at(most, s).zip(low).map(((h, l)) => h - l)",
        "    let spare = calc.max(0pt, region.width - low.sum())",
        "    let total = lacking.sum()",
        "    let widths = low.zip(lacking).map(((l, d)) =>",
        "      if total > 0pt { l + calc.min(d, spare * (d / total)) } else { l })",
        "    make(s, widths, true)",
        "  }")
    placed <- if (is.null(caption)) "  shown"
              else paste0("  figure(kind: table, caption: ", typst_string(caption), ", shown)")
    cat("\n\n```{=typst}\n#layout(region => {\n", paste(c(data, make, shown, placed), collapse = "\n"),
        "\n})\n```\n\n", sep = "")
    if (total > nrow(table)) {
        cat(nrow(table), " of ", total, " rows",
            if (!is.null(source)) paste0(". The whole table is in `", source, "`"), ".\n\n", sep = "")
    }
    invisible()
}

# A PNG's width and height in pixels, from its header; NULL for any other file.
png_size <- function(path) {
    head <- readBin(path, "raw", n = 24L)
    if (length(head) < 24L || !identical(head[2:4], charToRaw("PNG"))) return(NULL)
    number <- function(bytes) sum(as.numeric(bytes) * 256^(3:0))
    c(number(head[17:20]), number(head[21:24]))
}

# A figure already on disk, scaled to `width` of the text width, and a PNG at the full width kept
# to 7.5 in tall so a caption fits under it. The template's 1 in margins on letter paper leave a
# text block 6.5 in wide and 9 in tall. The path is in angle brackets, so a parenthesis in it is a
# character.
report_image <- function(path, caption = NULL, width = "100%") {
    size <- png_size(path)
    if (identical(width, "100%") && !is.null(size) && 7.5 * size[1] / size[2] < 6.5) {
        width <- sprintf("%.2fin", 7.5 * size[1] / size[2])
    }
    cat("\n\n![", if (is.null(caption)) "" else caption, "](<", path, ">){width=", width, "}\n\n",
        sep = "")
    invisible()
}

# A ggplot drawn into report_figures/ beside the report and placed like report_image(). `width`
# and `height` are the size it is drawn at, in inches.
report_plot <- function(plot, name, width = 7, height = 4, caption = NULL) {
    dir.create("report_figures", showWarnings = FALSE)
    path <- file.path("report_figures", paste0(name, ".png"))
    ggplot2::ggsave(path, plot, width = width, height = height, dpi = 200)
    report_image(path, caption)
}

# Items split into as few groups of at most `most` as hold them all, in the order given, the sizes
# differing by at most one: 25 pools make tables of 7, 6, 6 and 6 columns.
report_columns <- function(items, most = 8) {
    groups <- max(1, ceiling(length(items) / most))
    sizes <- length(items) %/% groups + (seq_len(groups) <= length(items) %% groups)
    split(items, rep(seq_len(groups), sizes))
}

# One color per pool, in the order given: the Okabe-Ito palette for up to eight pools, and evenly
# spaced hues past that.
report_palette <- function(pools) {
    okabe_ito <- c("#E69F00", "#56B4E9", "#009E73", "#0072B2", "#D55E00", "#CC79A7",
                   "#F0E442", "#000000")
    colors <- if (length(pools) <= length(okabe_ito)) okabe_ito[seq_along(pools)]
              else grDevices::hcl.colors(length(pools), "Dark 3")
    stats::setNames(colors, pools)
}

# Each declared .tsv table and .png figure under its own file name, which is the whole report of a
# module that declares no report of its own. A table is read only as far as the rows it shows.
report_declared <- function(outputs, max_rows = 40) {
    for (output in outputs) {
        for (path in report_files(output$file)) {
            name <- basename(path)
            if (grepl("[.]tsv$", name)) {
                cat("\n\n## ", report_text(name), "\n\n", sep = "")
                table <- utils::read.delim(path, check.names = FALSE, colClasses = "character",
                                           nrows = max_rows, quote = "", comment.char = "")
                report_table(report_format(table), caption = output$summary, source = name,
                             total = count_rows(path))
            } else if (grepl("[.]png$", name)) {
                cat("\n\n## ", report_text(name), "\n\n", sep = "")
                report_image(path, caption = output$summary)
            }
        }
    }
    invisible()
}
