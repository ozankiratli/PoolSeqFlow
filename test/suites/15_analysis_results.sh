#!/bin/bash
# What a module writes: where it lands, what it carries, and completion.
# cost: jvm
# env: analysis
# covers: analysis/lib/nf/results.nf analysis/lib/nf/outputs.nf analysis/complete.nf
# covers: bin/write_citations.py
# covers: analysis.nf
# covers: analysis/lib/nf/report.nf analysis/lib/rmd/
#
# The fixtures and helpers every analysis suite shares are in test/lib/analysis.sh.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 04_pipeline's business, and re-proving it here would
# cost minutes a case.

# ---------------------------------------------------------------------------------------
# Where an analysis is written.
test_results_go_to_a_folder_named_after_the_module() {
    analysis_ready single || return
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "the default folder name should verify"
    assert_file "$ANALYSIS_SB/main/Analysis/Results/verify/0_verify_analysis.txt" \
        "the verification record goes in the folder it cleared"
    assert_dir "$ANALYSIS_SB/main/Analysis/Main" \
        "and the shared intermediates root exists beside Results"
}

# A folder name may be a path, so two settings of one module sit side by side under a name of
# their own rather than being told apart by a timestamp.
test_a_folder_name_may_be_a_path() {
    analysis_ready single || return
    analysis_folder_name "'MDS/SummerPops'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a path should be accepted"
    assert_file "$ANALYSIS_SB/main/Analysis/Results/MDS/SummerPops/0_verify_analysis.txt" \
        "the results folder is the path that was named"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "analysis.folderName = 'MDS/SummerPops'" \
        "and the report says where it came from"
}

# It names a folder under Results, so anything that would climb out of it is refused before
# a task starts rather than resolved into somewhere unexpected.
test_a_folder_name_may_not_leave_the_results_tree() {
    analysis_ready single || return
    analysis_folder_name "'../escape'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "climbing out of Results must stop the run"
    assert_contains "$(analysis_output)" "contains a '..' segment" "naming what is wrong"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/escape/0_verify_analysis.txt" \
        "and nothing is written"
}

# NAMING THE FOLDER IS THE STALENESS MECHANISM. Two settings of one module are told apart by
# the folder each was written to, so one that already holds an analysis is a collision.
test_a_populated_results_folder_is_refused() {
    analysis_ready single || return
    mkdir -p "$ANALYSIS_SB/main/Analysis/Results/verify"
    printf 'an earlier analysis\n' > "$ANALYSIS_SB/main/Analysis/Results/verify/mds_plot.pdf"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 1 "$status" "writing over an analysis must stop the run"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "HOLDS AN ANALYSIS ALREADY - 1 entry" "counting what is there"
    assert_contains "$report" "mds_plot.pdf" "and naming it"
    assert_contains "$report" "analysis.folderName" "with the way out"
}

# The record the verification itself leaves is not an analysis. A module that failed after the
# check leaves the folder holding nothing else, and that retry has to be allowed - otherwise
# the first failure makes the folder name unusable for good.
test_the_verification_record_does_not_count_as_an_analysis() {
    analysis_ready single || return
    run_analysis "$ANALYSIS_SB" verify > /dev/null
    assert_file "$ANALYSIS_SB/main/Analysis/Results/verify/0_verify_analysis.txt" \
        "the first run leaves its record"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a second run into the same folder should be allowed"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "holds no analysis" "and say the folder is free"
}

# One folder per results directory, inside the one the user named - the same rule the pipeline
# uses for Output, where only divergence gets a name.
test_each_results_directory_gets_its_own_folder_under_a_multi_run() {
    analysis_ready multi || return
    analysis_folder_name "'sweep'"
    local status; status=$(run_analysis "$ANALYSIS_SB" verify)
    assert_status 0 "$status" "a multi-run project should verify"
    local report; report=$(analysis_report "$ANALYSIS_SB")
    assert_contains "$report" "Results/sweep/Shared_1" "the shared directory gets its own folder"
    assert_contains "$report" "Results/sweep/strict" "and so does the one that shares nothing"
}

# A module writes everything it produced into the folder the verification cleared, and the
# record that cleared it is still there beside the analysis.
#
# Under the outputPrefix, which is 'Test' in the template: what the module computed is published
# as Test_result.tsv, and the script that computed it keeps its own name, which is the name its
# usage line and the README give it.
test_a_module_publishes_what_it_produced() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder; folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/Test_result.tsv" "the analysis is published under the prefix"
    assert_no_file "$folder/result.tsv" "and not under the name the module wrote"
    assert_file "$folder/result.R" "and the script beside it keeps its own name"
    assert_file "$folder/0_verify_analysis.txt" \
        "the record that cleared the folder travels with the analysis it let run"
    assert_eq "analysis of Output" "$(cat "$folder/Test_result.tsv" 2>/dev/null)" \
        "the file's contents, not a link into a work directory cleanup has removed"
}

# THE PREFIX IS outputPrefix AND NOT THE VCF'S NAME. The template derives vcf.fileName from
# outputPrefix, so in every other project here the two are both 'Test' and a frame that took the
# wrong one would pass. This one names its VCF 'Calls' and its outputs 'Pfx'.
test_a_published_name_starts_with_the_output_prefix_and_not_the_vcf_name() {
    analysis_ready prefixed || return
    if ! grep -q "^        fileName        = 'Calls'" "$ANALYSIS_SB/main/parameters.config" \
       || ! grep -q "^    outputPrefix    = 'Pfx'" "$ANALYSIS_SB/main/parameters.config"; then
        fail_case "the prefixed config did not take; analysis_write_prefixed_config matches no line"
        return
    fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/Pfx_result.tsv" "the analysis is published under outputPrefix"
    assert_no_file "$folder/Calls_result.tsv" "not under the VCF's name"
    assert_no_file "$folder/Test_result.tsv" "nor under the template's"
    assert_contains "$(cat "$folder/README.md" 2>/dev/null)" '`Pfx_writer_report_' \
        "and the README names the report under it as well"
}

# A CONFIG FROM BEFORE outputPrefix PUBLISHES UNDER ITS VCF NAME. A module is its own pipeline and
# reads no nextflow.config, so the default the pipeline takes from there reaches a module through
# frame.config. Without it the module had no prefix, which a string makes 'null': every file was
# published as null_result.tsv while the verification, which does read nextflow.config, reported
# Calls. Found by a review on 2026-10-08; no case had run an analysis on a config without the key.
test_a_config_from_before_the_prefix_publishes_under_its_vcf_name() {
    analysis_ready legacy || return
    if grep -q '^    outputPrefix' "$ANALYSIS_SB/main/parameters.config"; then
        fail_case "the legacy config still carries an outputPrefix line"; return
    fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run; see $ANALYSIS_SB/run.out"
    local folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/Calls_result.tsv" "the analysis is published under the VCF's name"
    assert_no_file "$folder/null_result.tsv" "and not under a prefix the module never got"
}

# RUNS THAT DIFFER IN outputPrefix ALONE NEVER SHARE A RESULTS DIRECTORY. With the VCF named in
# parameters.config they share everything through variant calling, and step 7's identity carries
# the prefix, so each run's tables, and the analysis of them, sit under its own name. Without the
# prefix in that identity the two share one directory, where neither planted table is and which
# the frame would refuse as holding two prefixes anyway.
test_runs_that_differ_in_prefix_alone_publish_apart() {
    analysis_ready multiprefix || return
    analysis_plant_results "$ANALYSIS_SB/store/Output/alpha"
    analysis_plant_results "$ANALYSIS_SB/store/Output/beta"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run over both runs; see $ANALYSIS_SB/run.out"
    local results="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$results/alpha/Alpha_result.tsv" "one run's analysis is under its prefix"
    assert_file "$results/beta/Beta_result.tsv" "and the other's under its own"
}

# THE REPORT IS NAMED <prefix>_<module>_report_<yyyyMMdd-HHmmss>.pdf, the time being when the
# analysis was published, in local time. Checked against the clock on either side of the run, so
# a stamp taken from anything but the publish - a fixed string, the date alone, UTC on a machine
# that is not on it - fails here.
test_the_report_is_named_after_the_prefix_the_module_and_the_time() {
    analysis_ready single || return
    have_report_tools || { skip_case "the analysis environment has no pandoc and typst"; return; }
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local before after status
    before=$(date +%Y%m%d-%H%M%S)
    status=$(analysis_run_module writer)
    after=$(date +%Y%m%d-%H%M%S)
    assert_status 0 "$status" "the writer module should run"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer" report name stamp
    local shape='^Test_writer_report_[0-9]{8}-[0-9]{6}\.pdf$'
    report=$(analysis_published_report "$folder" writer)
    if [ -z "$report" ]; then
        fail_case "exactly one Test_writer_report_*.pdf should be published; the folder holds: $(ls -A "$folder" | tr '\n' ' ')"
        return
    fi
    name=$(basename "$report")
    [[ "$name" =~ $shape ]] || fail_case "the report is $name, not prefix, module, report and the time"
    stamp=${name#Test_writer_report_}; stamp=${stamp%.pdf}
    if [[ "$stamp" < "$before" || "$stamp" > "$after" ]]; then
        fail_case "the stamp $stamp is not between $before and $after, the clock either side of the run"
    fi
    assert_contains "$(cat "$folder/README.md" 2>/dev/null)" "\`$name\`" \
        "and the README names the report the folder holds, as it holds it"
}

# A published number is not always a measurement, and a table cell cannot say which it is. The
# README is one mechanism for every module, so no module invents its own way of saying it.
test_a_published_folder_carries_a_readme_linking_every_file_to_the_manual() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local readme; readme=$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/README.md" 2>/dev/null)
    assert_contains "$readme" '`Test_result.tsv`' "the module's own output is listed, as it is published"
    assert_contains "$readme" "PoolSeqFlow-manual.md#output-layout" \
        "linked to the section its manifest named"
    assert_contains "$readme" '`0_verify_analysis.txt`' "and so is what every analysis carries"
    assert_contains "$readme" "PoolSeqFlow-manual.md#citing-the-tools-it-runs" \
        "with the frame's own anchors rendered by the same mechanism"
    # A module is its own pipeline and Nextflow reads no manifest for it, so until 2026-10-08
    # every published folder said it was produced by "PoolSeqFlow unknown".
    assert_contains "$readme" "Produced by PoolSeqFlow $(analysis_release)," \
        "naming the release that produced it"
}

# ONE PDF OF THE WHOLE FOLDER. A module that declares no report of its own gets each table and
# figure it declared, under the file's name, from the same declarations the README uses.
#
# What it must carry is the FILE NAME above each result: a figure that arrives with nothing
# saying which file it came from is the failure this exists to prevent, and it happens on its
# own - a figure sized for looking at pushes the heading onto the page before it.
#
# AND WHAT IS IN THE FILE. Until 2026-10-08 the report opened with a table of every declared file
# name, and every section after it was skipped: the published folder reached the template as the
# literal text `$STAGE`, so no file was ever found. The case asserted the file name, which that
# table always printed, and passed on a report holding nothing. The file's own text is what only
# a rendered section can carry.
test_a_published_folder_carries_one_pdf_of_everything_in_it() {
    analysis_ready single || return
    if ! have_report_tools; then
        skip_case "the analysis environment has no pandoc and typst"; return
    fi
    if ! command -v pdftotext > /dev/null 2>&1; then
        skip_case "no pdftotext to read the report back"; return
    fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer" report
    report=$(analysis_published_report "$folder" writer)
    if [ -z "$report" ]; then
        fail_case "the report should be published beside the analysis; the folder holds: $(ls -A "$folder" | tr '\n' ' ')"
        return
    fi

    # Read back as text, because a PDF that exists and says nothing is the interesting failure.
    local text; text=$(pdf_text "$report")
    assert_contains "$text" "Test_result.tsv" "the module's own output is a section of it, under its published name"
    assert_contains "$text" "analysis of Output" "showing what that file holds"
    assert_contains "$text" "writer" "and it names the module that produced the folder"
    assert_contains "$text" "Produced by PoolSeqFlow $(analysis_release)," \
        "and the release that produced it"
    # The baseline sets no analysis.design.by, which the design reports as a note; the note
    # travels from reportSpec() through the spec to the template.
    assert_contains "$text" "Read these before the numbers" "the design's notes come first"
    assert_contains "$text" "analysis.design.by is not set" "with what they say"
    assert_eq "" "$(pdf_overlapping_words "$report")" "and nothing is printed over anything"

    # The README accounts for it too, or a reader has a file nothing explains.
    assert_contains "$(cat "$folder/README.md" 2>/dev/null)" "\`$(basename "$report")\`" \
        "the README lists the report among what the folder holds"
}

# A module that declares a `report` lays out its own results, with the frame's functions and
# under the frame's header, and the declared files are not then listed one by one.
test_a_module_lays_out_its_own_report() {
    analysis_ready single || return
    if ! have_report_tools; then
        skip_case "the analysis environment has no pandoc and typst"; return
    fi
    if ! command -v pdftotext > /dev/null 2>&1; then
        skip_case "no pdftotext to read the report back"; return
    fi
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        "${ANALYSIS_LINKED_MANIFEST/\"needs\"/\"report\": \"report.Rmd\", \"needs\"}" \
        "$ANALYSIS_WRITER_MAIN"
    # report_read() finds the published folder through POOLSEQFLOW_REPORT_FOLDER, which is the
    # half of the $STAGE fix a module's own report depends on.
    cat > "$ANALYSIS_SB/install/analysis/modules/writer/report.Rmd" <<'CHILD'
```{r writer-report, results = "asis"}
held <- report_read("result.tsv")
report_table(data.frame(Column = names(held), check.names = FALSE),
             caption = "WRITERCHILD the columns its result holds")
```
CHILD
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local report; report=$(analysis_published_report "$ANALYSIS_SB/main/Analysis/Results/writer" writer)
    [ -n "$report" ] || { fail_case "the report should be published; see $ANALYSIS_SB/run.out"; return; }
    local text; text=$(pdf_text "$report")
    assert_contains "$text" "WRITERCHILD" "the module's own layout is the report"
    assert_contains "$text" "analysis of Output" "drawn from the folder it published"
    assert_contains "$text" "Produced by PoolSeqFlow $(analysis_release)," "under the frame's header"
    assert_not_contains "$text" "result.tsv" "and the declared files are not listed again"
}

# A CHUNK THAT FAILS STOPS THE REPORT. knitr's knit() writes an R error into the document and
# carries on unless told otherwise, which would publish a report reading "## Error" among the
# results. The analysis is published, the report is not, and the console says why.
test_a_report_chunk_that_fails_publishes_no_report() {
    analysis_ready single || return
    have_report_tools || { skip_case "the analysis environment has no pandoc and typst"; return; }
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        "${ANALYSIS_LINKED_MANIFEST/\"needs\"/\"report\": \"report.Rmd\", \"needs\"}" \
        "$ANALYSIS_WRITER_MAIN"
    cat > "$ANALYSIS_SB/install/analysis/modules/writer/report.Rmd" <<'CHILD'
```{r broken, results = "asis"}
stop("WRITERBROKE this chunk cannot be drawn")
```
CHILD
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the analysis should publish without its report"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/Test_result.tsv" "the analysis itself is there"
    assert_eq "" "$(find "$folder" -name '*.pdf')" "and no report holding an error is"
    local out; out=$(analysis_output)
    assert_contains "$out" "the PDF report could not be built" "saying so on the console"
    assert_contains "$out" "WRITERBROKE" "with the chunk's own error"
}

# The functions a report is drawn with, called directly: no Nextflow, no pandoc.
report_r() {
    local rscript; rscript=$(analysis_rscript)
    "$rscript" --vanilla -e "source('$REPO_ROOT/analysis/lib/rmd/report.R'); $1" 2>&1
}

# A count is printed whole with its thousands separated, anything else to the digits asked for,
# and a missing value as NA - never as a zero or a blank a reader would take for a measurement.
#
# Inf, NaN and the tiny values are what association publishes: a separated allele has t = Inf, and
# design_floor is 1/n!, 1.6e-10 at 13 units. Until 2026-10-08 an Inf stopped the whole report and
# anything below 1e-9 printed as 0.
test_report_numbers_print_the_way_a_table_reads_them() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local out
    out=$(report_r 'cat(report_number(c(124973956, 0.326151016923568, NA, 1e-07, 34)), sep = "|")')
    assert_eq "124,973,956|0.326|NA|1.00e-07|34" "$out" "whole, significant, missing, tiny, whole"
    out=$(report_r 'cat(report_number(c(33.96, 40.70248, NaN), decimals = 1), sep = "|")')
    assert_eq "34.0|40.7|NaN" "$out" "and to a fixed number of places when asked"
    out=$(report_r 'cat(report_number(c(Inf, -Inf, NaN, 1.6059e-10, -1e-10, -2.5)), sep = "|")')
    assert_eq "Inf|-Inf|NaN|1.61e-10|-1.00e-10|-2.50" "$out" \
        "infinite and undefined values as themselves, and a tiny one never as 0"
    # mds' last eigenvalue is zero give or take 1e-18, and its share printed as -0.0%.
    out=$(report_r 'cat(report_number(c(-3.14e-16, -0.04, -0.06), decimals = 1), report_number(-0), sep = "|")')
    assert_eq "0.0|0.0|-0.1|0" "$out" "a value that rounds to zero is printed without a sign"
}

# A table the report knows nothing about is shown as written wherever a number could be a name:
# a column of whole numbers is a count or an identifier, and 01 is a label. Only a column holding
# decimals is reformatted. Until 2026-10-08 pool 01 printed as 1 and the year 2024 as 2,024.
test_a_report_shows_a_name_as_the_file_gives_it() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local out
    out=$(report_r 'f <- report_format(data.frame(pool = c("01", "02", "10"), year = c("2023", "2024", "2024"),
                                                 sites = c("12345", "6", "7"), d = c("0.0123456", "Inf", "1.5"),
                                                 check.names = FALSE, stringsAsFactors = FALSE))
                    cat(unlist(f), sep = "|")')
    assert_eq "01|02|10|2023|2024|2024|12345|6|7|0.01235|Inf|1.500" "$out" \
        "identifiers and counts as written, decimals to four significant digits"
}

# A cell is a typst string, so nothing a sample or sequence is called can be read as markup: a
# `#` would start code, `*` and `_` emphasis, and an unescaped quote would end the string. Asked of
# report_table() itself, which is where a cell is drawn, rather than of the helper it calls.
test_a_report_cell_is_plain_text_whatever_it_holds() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local out
    out=$(report_r 'report_table(data.frame(name = c("Pop_*A*", "say \"x\"", "a\\b", "#import x", NA)))')
    local cell
    for cell in '"Pop_*A*"' '"say \"x\""' '"a\\b"' '"#import x"' '"NA"'; do
        assert_contains "$out" "    $cell," "the cell $cell is a typst string, escaped and otherwise untouched"
    done
}

# A table cut short says so, with the count it was cut from. `total` defaults to the rows the
# table was given, and R evaluates a default where it is first used; read after the table had
# been cut, it was the cut count, so the line never printed. Found on 2026-10-08 by reading the
# function while giving mds' report a table of its own to cut.
test_a_report_table_cut_short_says_by_how_much() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local out
    out=$(report_r 'report_table(data.frame(n = as.character(1:50)), max_rows = 40, source = "n.tsv")')
    assert_contains "$out" "40 of 50 rows. The whole table is in \`n.tsv\`." \
        "the rows shown, the rows there are, and where the rest of them is"
    assert_not_contains "$out" '"41",' "and the rows past the cut are not drawn"
    out=$(report_r 'report_table(data.frame(n = as.character(1:3)), max_rows = 40, source = "n.tsv")')
    assert_not_contains "$out" " rows." "a table shown whole says nothing about its rows"
}

# A DECLARED TABLE IS READ ONLY AS FAR AS IT IS SHOWN, and the rest are counted. report_declared()
# reads the first max_rows rows and counts the lines past the header with count_rows(), so a
# miscount is a wrong total under a table nothing else checks.
test_a_declared_table_is_counted_and_not_read_whole() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local sb; sb=$(guard_path "$TEST_TMPDIR/report-declared")
    rm -rf "$sb"; mkdir -p "$sb"
    { printf 'n\tnote\n'; seq 1 50 | awk '{ printf "%d\ta \"quoted\" cell\n", $1 }'; } > "$sb/Test_t.tsv"
    local out
    out=$(POOLSEQFLOW_REPORT_FOLDER="$sb" POOLSEQFLOW_REPORT_PREFIX=Test report_r \
        'report_declared(list(list(file = "t.tsv", summary = "fifty rows")), max_rows = 40)')
    assert_contains "$out" "40 of 50 rows. The whole table is in \`Test_t.tsv\`." \
        "forty shown and fifty counted, in the file as it is published"
    assert_contains "$out" '"a \"quoted\" cell"' "and a quote in a cell is a character"
    assert_not_contains "$out" '"41",' "and nothing past the fortieth is drawn"
}

# NAMES AND PATHS ARE READ AS WRITTEN. A report builds in a folder beside the results, so the
# project's own path is part of every path it reads: a bracket in it was a glob character class
# that matched nothing, so every figure went missing with nothing said, and a parenthesis ended a
# figure's path. A quote in a cell opened a quoted string that swallowed the rows after it, a * or
# an @ in a name printed as markdown, and an @ stopped the PDF. A figure taller than the page was
# clipped at its foot. All found by a review on 2026-10-08.
test_names_and_paths_are_read_as_written() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local sb; sb=$(guard_path "$TEST_TMPDIR/report-names")
    local folder="$sb/Project (2026) [pilot]"
    rm -rf "$sb"; mkdir -p "$folder"
    printf 'pool\tnote\nP1\tsays "five"\nP2\tplain\n' > "$folder/Test_t.tsv"
    local out
    out=$(POOLSEQFLOW_REPORT_FOLDER="$folder" POOLSEQFLOW_REPORT_PREFIX=Test report_r '
        draw <- function(name, width, height) {
            grDevices::png(file.path(report_folder(), report_name(name)), width = width,
                           height = height)
            plot(1)
            invisible(grDevices::dev.off())
        }
        draw("tall.png", 600, 1600)
        draw("wide.png", 1600, 600)
        cat(basename(report_files("*.png")), sep = "|"); cat("\n")
        t <- report_read("t.tsv"); cat(nrow(t), t$note[1], sep = "|"); cat("\n")
        cat(report_text("scaf_1*@x"), "\n")
        report_image(report_files("tall.png"), caption = "tall")
        report_image(report_files("wide.png"), caption = "wide")')
    assert_contains "$out" "Test_tall.png|Test_wide.png" "a bracket in the folder's path is a character"
    assert_contains "$out" '2|says "five"' "a quote in a cell is a character, and no row is lost"
    assert_contains "$out" 'scaf\_1\*\@x' "a name's punctuation is escaped for markdown"
    assert_contains "$out" "(<$folder/Test_tall.png>){width=2.81in}" \
        "a tall figure is kept to 7.5 in, its path in angle brackets"
    assert_contains "$out" "(<$folder/Test_wide.png>){width=100%}" "and a wide one fills the width"
}

# A REPORT ASKS FOR A FILE BY THE NAME ITS MODULE WROTE, and reads it under the name it is
# published as: the outputPrefix and an underscore in front. Without a prefix it refuses rather
# than read the names the module wrote, which no published folder holds, and draw a report with
# every section missing - the way every report was blank from v3.0.0 to v3.2.0.
test_a_report_reads_each_file_under_its_published_name() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local sb; sb=$(guard_path "$TEST_TMPDIR/report-prefix")
    rm -rf "$sb"; mkdir -p "$sb"
    printf 'pool\nP1\n' > "$sb/Pfx_mds.tsv"
    printf 'pool\nWRONG\n' > "$sb/mds.tsv"
    : > "$sb/Pfx_depth_chr1.png"
    : > "$sb/depth_chr2.png"
    local out
    out=$(POOLSEQFLOW_REPORT_FOLDER="$sb" POOLSEQFLOW_REPORT_PREFIX=Pfx report_r '
        cat("read:", report_name("mds.tsv"), "|", report_read("mds.tsv")$pool, "\n", sep = "")
        cat("files:", paste(basename(report_files("depth_*.png")), collapse = "|"), "\n", sep = "")
        cat("logical:", paste(report_logical(c("Pfx_depth_chr1.png", "depth_chr2.png", "Pfx")),
                              collapse = "|"), "\n", sep = "")')
    assert_eq "Pfx_mds.tsv|P1" "$(sed -n 's/^read://p' <<< "$out")" \
        "a table is read under the prefix, never the bare name"
    assert_eq "Pfx_depth_chr1.png" "$(sed -n 's/^files://p' <<< "$out")" \
        "a glob matches the published files and only those"
    assert_eq "depth_chr1.png|depth_chr2.png|Pfx" "$(sed -n 's/^logical://p' <<< "$out")" \
        "and the prefix comes off a published name, and off nothing else"
    out=$(POOLSEQFLOW_REPORT_FOLDER="$sb" POOLSEQFLOW_REPORT_PREFIX= report_r 'report_read("mds.tsv")')
    assert_contains "$out" "POOLSEQFLOW_REPORT_PREFIX is not set" "no prefix stops the report"
}

# A design note reaches the report ahead of the numbers, under its own heading.
test_a_report_opens_with_the_design_notes() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    local sb; sb=$(guard_path "$TEST_TMPDIR/report-notes")
    rm -rf "$sb"; mkdir -p "$sb/folder"
    printf 'a\tb\n1\t2.5\n' > "$sb/folder/t.tsv"
    analysis_render_report "$sb/folder" "$sb/out" "" md \
        || { fail_case "the report should knit: $(cat "$sb/out/report_knit.log")"; return; }
    local md; md=$(cat "$sb/out/report.md")
    assert_contains "$md" "## Read these before the numbers" "the notes have their heading"
    assert_contains "$md" "- a design note the reader needs first" "and each note is listed"
}

# THE LAYOUT, LOOKED AT. A table that does not fit the page at 10 points is set smaller with its
# headers wrapping, and nothing is printed over anything else. Three shapes that broke on
# 2026-10-08, all found by a review: a design table with three experimental variables, where
# equal shares for the columns of numbers left "Chromosomes" 3.6pt over "Ploidy"; a table too
# wide for 7 points, which was scaled down as one block that could not break across pages, so its
# rows past the first page were drawn over each other at the foot of it; and sixty long pool
# names, which typst's own auto columns squeeze below their width when the table is wider than
# the page, so each name runs into the column after it.
test_a_wide_report_table_prints_nothing_over_anything_else() {
    have_analysis_r || { skip_case "no analysis environment"; return; }
    have_report_tools || { skip_case "the analysis environment has no pandoc and typst"; return; }
    command -v pdftotext > /dev/null 2>&1 || { skip_case "no pdftotext to read the report back"; return; }
    local sb; sb=$(guard_path "$TEST_TMPDIR/report-wide")
    rm -rf "$sb"; mkdir -p "$sb/folder"
    cat > "$sb/child.Rmd" <<'CHILD'
```{r wide, results = "asis"}
pools <- c("Founder1", "Ancestral2", "Naive3", "Selected-Replicate4")
table <- data.frame(Pool = pools, Libraries = paste0(pools, "_L1\n", pools, "_L2"),
                    exp_population = c("Control", "Heat", "Cold", "Heat"),
                    exp_time = c("10", "15", "20", "25"),
                    exp_treatment = c("Control", "Heat", "Cold", "Heat"),
                    "Pool size" = c("50", "60", "70", "80"), Ploidy = "2",
                    Chromosomes = c("100", "120", "140", "160"),
                    "Detection limit" = c("0.00500", "0.00417", "0.00357", "0.00313"),
                    check.names = FALSE)
report_table(table, caption = "The design table that overlapped.")
regime <- "Selection_regime_high_temperature"
long <- data.frame(Pool = sprintf("Population_A_Generation_%d_Replicate_1", 1:90),
                   exp_population = regime, exp_selection_regime = regime,
                   exp_temperature = regime, exp_batch = regime,
                   Segregating = "1,234", "h_sum" = "12.34", "pi per called site" = "0.3262",
                   check.names = FALSE)
report_table(long, caption = "Ninety pools too wide for 7 points, which have to run onto further pages.")
named <- sprintf("Population_%s_Generation_%d_Replicate_%d", rep(c("A", "B", "C", "D"), 15), 10:69,
                 rep(1:3, 20))
sixty <- data.frame(Pool = named, exp_population = rep(c("Control", "Heat", "Cold", "Salt"), 15),
                    exp_time = "10", exp_treatment = rep(c("Control", "Heat"), 30),
                    Chromosomes = "200", "Sites read" = "878", Segregating = "570",
                    "h_sum" = "301.49", "pi per called site" = "0.1869", check.names = FALSE)
report_table(sixty, caption = "Sixty pools named the long way, whose names typst would squeeze.")
```
CHILD
    analysis_render_report "$sb/folder" "$sb/out" "$sb/child.Rmd" \
        || { fail_case "the report should build: $(cat "$sb/out/report_knit.log")"; return; }
    assert_eq "" "$(pdf_overlapping_words "$sb/out/report.pdf")" "no word is printed over another"
    assert_eq "" "$(pdf_missing_words "$sb/out/report.pdf" Chromosomes Ploidy Pool Detection \
                    Segregating Libraries)" \
              "and no header is printed into its neighbor, which fuses the two into one word"
    local text; text=$(pdf_text "$sb/out/report.pdf")
    assert_contains "$text" "Population_A_Generation_90_Replicate_1" \
        "and the ninetieth row is there to read, not smeared at the foot of a page"
}

# A REPORT THAT CANNOT BE BUILT MUST NOT THROW AWAY THE ANALYSIS. Every number in it is already
# a file in the folder, so the report is a convenience; refusing to publish over it would lose
# work that is complete and correct. It must still say why, which is the half that would
# otherwise rot into silence.
test_a_report_that_cannot_be_built_still_publishes_the_analysis() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_LINKED_MANIFEST" "$ANALYSIS_WRITER_MAIN"

    # A pandoc that fails, ahead of the real one, which is what a machine without a working
    # PDF toolchain looks like from inside the task. The pipeline environment carries no pandoc
    # of its own, so this stub is the one the run finds.
    local stub; stub=$(guard_path "$TEST_TMPDIR/no-pandoc")
    rm -rf "$stub"; mkdir -p "$stub"
    printf '#!/bin/sh\necho "no pandoc here" >&2\nexit 1\n' > "$stub/pandoc"
    chmod +x "$stub/pandoc"

    local saved="$PATH" status
    export PATH="$stub:$PATH"
    status=$(analysis_run_module writer)
    export PATH="$saved"
    assert_status 0 "$status" "the analysis should publish without its report"

    local folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/Test_result.tsv" "the analysis itself is there"
    assert_eq "" "$(find "$folder" -name '*.pdf')" "and the report is not"
    # The reason went to stderr until 2026-10-08, which Nextflow never shows for a task that
    # succeeded, so a report that failed to build failed in silence.
    local out; out=$(analysis_output)
    assert_contains "$out" "the PDF report could not be built" "saying so on the console"
    assert_contains "$out" "no pandoc here" "with what the tool itself said"
}

# The anchor is checked against the manual this release ships, while the DAG is built, so a
# manifest promising a section that does not exist stops before any compute.
test_a_module_naming_an_anchor_the_manual_lacks_refuses() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        '{"name":"writer","version":"0.1.0","contract":"freq-1",'"$ANALYSIS_MANIFEST_FLOORS"',
          "summary":"points nowhere", "needs":["frequencies"],
          "outputs":[{"file":"result.tsv","anchor":"how-to-read-a-thing-that-is-not-written"}]}' \
        "$ANALYSIS_WRITER_MAIN"
    local status; status=$(run_analysis "$ANALYSIS_SB" writer)
    assert_status 1 "$status" "a link nobody can follow must stop the run"
    local out; out=$(analysis_output)
    assert_contains "$out" "how-to-read-a-thing-that-is-not-written" "the refusal names the anchor"
    assert_contains "$out" "PoolSeqFlow-manual.md" "and the file it was looked for in"
}

# A module published separately has no section in this manual to point at, so it gives a full
# url instead - which is the half of F0c that a first-party-only design would have missed.
test_a_module_may_link_out_of_the_manual_entirely() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        '{"name":"writer","version":"0.1.0","contract":"freq-1",'"$ANALYSIS_MANIFEST_FLOORS"',
          "summary":"published elsewhere", "needs":["frequencies"],
          "outputs":[{"file":"result.tsv","summary":"the analysis",
                      "url":"https://example.org/writer/#results"}]}' \
        "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "a url needs no heading in this manual"
    assert_contains "$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/README.md" 2>/dev/null)" \
        "https://example.org/writer/#results" "and is rendered as given"
}

# Declaring an output is a promise about what the folder will hold. Checked in the STAGE, like
# the script check beside it, so a module that breaks it publishes nothing.
test_a_module_that_does_not_publish_what_it_declared_publishes_nothing() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer \
        '{"name":"writer","version":"0.1.0","contract":"freq-1",'"$ANALYSIS_MANIFEST_FLOORS"',
          "summary":"promises a table", "needs":["frequencies"],
          "outputs":[{"file":"frequencies.tsv","summary":"never produced","anchor":"output-layout"}]}' \
        "$ANALYSIS_WRITER_MAIN"
    local status; status=$(analysis_run_module writer)
    assert_status 1 "$status" "an undelivered output must fail the publish"
    assert_contains "$(analysis_output)" "declares it publishes 'frequencies.tsv', here 'Test_frequencies.tsv'" \
        "naming what was promised, and the name it would have been published under"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/writer/Test_result.tsv" \
        "and nothing is published, so the folder stays as the verification left it"
}

# THE HALF THAT WILL REGRESS. A module that fails must leave the folder as the verification
# left it, or its own name is unusable for good: refuse-if-populated cannot tell a crash from
# a collision.
test_a_module_that_fails_publishes_nothing() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module breaker "$ANALYSIS_BREAKER_MANIFEST" "$ANALYSIS_BREAKER_MAIN"

    local status; status=$(analysis_run_module breaker)
    assert_status 1 "$status" "the breaker module should fail"

    local folder held
    folder="$ANALYSIS_SB/main/Analysis/Results/breaker"
    held=$(ls -A "$folder" 2>/dev/null | sort | tr '\n' ' ')
    assert_eq "0_verify_analysis.txt " "$held" \
        "a failed module leaves the folder holding nothing but the verification record"

    status=$(run_analysis "$ANALYSIS_SB" breaker)
    assert_status 0 "$status" "so the retry is not refused"
    assert_contains "$(analysis_report "$ANALYSIS_SB")" "holds no analysis" \
        "and the folder still reads as ready to be written"
}

# A published analysis is self-describing: the result, the script that made it, the record
# that cleared the folder, and what it was all produced with. Written into the STAGE, so the
# citations arrive in the same rename and a folder is never half-described.
test_a_published_analysis_carries_its_citations() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local folder; folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/CITATIONS.md" "the citation list is published with the analysis"
    assert_file "$folder/references.bib" "and the BibTeX beside it"

    local md; md=$(cat "$folder/CITATIONS.md" 2>/dev/null)
    assert_contains "$md" "PoolSeqFlow" "citing the pipeline itself"
    # The release, read for the module's own run, which has no workflow manifest to ask.
    assert_contains "$(cat "$folder/references.bib" 2>/dev/null)" \
        "Version $(analysis_release) used" "at the release that ran"
    assert_contains "$md" "Nextflow" "and Nextflow"
    assert_contains "$md" "R" "and R, which every module runs on"
    # The pipeline's own tools are in citations/citations.json and an analysis invokes none of
    # them. Citing BWA for a run that never aligned anything would be a false claim.
    assert_not_contains "$md" "BWA" "but not a tool the analysis never ran"
    assert_not_contains "$md" "SnpEff" "nor another"
}

# A module is published separately, so the frame cannot hold a list of citations for modules
# that do not exist yet. Each carries its own, and they are merged for the run that used it.
test_a_module_adds_its_own_citations() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_WRITER_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    cat > "$ANALYSIS_SB/install/analysis/modules/writer/citations.json" <<'JSON'
{
  "vegan": {
    "name": "vegan",
    "type": "misc",
    "key": "oksanen2024vegan",
    "authors": "Oksanen, Jari and others",
    "title": "vegan: Community Ecology Package",
    "url": "https://CRAN.R-project.org/package=vegan",
    "r_package": "vegan"
  }
}
JSON

    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should still run"
    local md; md=$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/CITATIONS.md" 2>/dev/null)
    assert_contains "$md" "vegan" "the module's own citation is in the list"
    assert_contains "$md" "PoolSeqFlow" "beside the frame's"
    assert_contains "$(cat "$ANALYSIS_SB/main/Analysis/Results/writer/references.bib" 2>/dev/null)" \
        "oksanen2024vegan" "and its BibTeX key is in references.bib"
}

# THE REPRODUCIBILITY GUARANTEE, enforced rather than documented. README rule 15 has always
# said a result ships the script that made it; nothing checked, so a module could simply not
# and no one would know until someone tried to regenerate the result.
test_a_module_that_emits_no_script_publishes_nothing() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module mute "$ANALYSIS_MUTE_MANIFEST" "$ANALYSIS_MUTE_MAIN"

    local status; status=$(analysis_run_module mute)
    assert_status 1 "$status" "publishing without a script must fail the run"

    local out; out=$(analysis_output)
    assert_contains "$out" "carries no script" "saying what is missing"
    assert_contains "$out" "result.tsv" "and listing what it did produce"
    assert_contains "$out" "*.R" "and which extensions count"

    # The same guarantee the breaker case makes: a refusal here must not consume the folder
    # name, or the module could never be published under it again.
    local folder held
    folder="$ANALYSIS_SB/main/Analysis/Results/mute"
    held=$(ls -A "$folder" 2>/dev/null | sort | tr '\n' ' ')
    assert_eq "0_verify_analysis.txt " "$held" \
        "and the folder still holds nothing but the verification record"
    assert_no_file "$folder/Test_result.tsv" "the result itself is not published"
}

# Every intermediate says which results it came from. Analysis/Main outlives any one analysis,
# so nothing else in the layout would notice a pipeline re-run underneath it.
test_an_intermediate_records_the_results_it_came_from() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the writer module should run"

    local main; main=$(analysis_main_dir)
    assert_file "$main/matrix.tsv" "the intermediate is on the working volume"
    assert_file "$main/matrix.tsv.provenance" "with its provenance record beside it"

    local record; record=$(cat "$main/matrix.tsv.provenance" 2>/dev/null)
    assert_contains "$record" ".poolseqflow_params" "the record names the parameter manifest"
    assert_contains "$record" ".poolseqflow_version" "and the version record"
    assert_contains "$record" ".multirun.csv" "and the run table, absent or not"
}

# Derived once, reused by every module after it. That is what Analysis/Main is for, and the
# reuse is skip-by-existence across separate Nextflow runs.
test_an_intermediate_is_derived_once() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive it"
    assert_contains "$(analysis_output)" "WRITER derived" "the first run derives the intermediate"

    analysis_folder_name "'second'"
    status=$(analysis_run_module writer)
    assert_status 0 "$status" "the second run should reuse it"
    local out; out=$(analysis_output)
    assert_contains "$out" "WRITER reused" "the second run reuses it"
    assert_contains "$out" "on the working volume" "and finds it without touching storage"
}

# THE ONE THE VERIFICATION CANNOT CATCH. Re-running the pipeline under the settings it already
# recorded leaves the identity check passing, and every intermediate derived from the results
# it replaced is stale. The record beside the intermediate is the only thing that sees it.
test_an_intermediate_derived_from_other_results_refuses() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive the intermediate"

    # Field 2 is the date the results were recorded, which the identity check prints and does
    # not compare - so this is a re-run the verification has no quarrel with.
    local version release
    version="$ANALYSIS_SB/store/Output/.poolseqflow_version"
    release=$(cut -f1 < "$version")
    printf '%s\t%s\n' "$release" "1999-01-01" > "$version"

    analysis_folder_name "'after_rerun'"
    status=$(run_analysis "$ANALYSIS_SB" writer)
    assert_status 0 "$status" "the verification still passes, which is the point"

    status=$(run_module "$ANALYSIS_SB" writer)
    assert_status 1 "$status" "the module refuses on the stale intermediate"
    local out; out=$(analysis_output)
    assert_contains "$out" "matrix.tsv is STALE" "and names the file"
    assert_contains "$out" ".poolseqflow_version" "and the record that moved"
}

# What is IN the record is the contract: a later run compares against it byte for byte. The
# frame version is the half the results digests cannot see - .poolseqflow_version records the
# PIPELINE release that produced the results, not the code that derived from them.
test_an_intermediate_records_the_frame_that_derived_it() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should derive the intermediate"

    local record declared
    record=$(cat "$(analysis_main_dir)/matrix.tsv.provenance" 2>/dev/null)
    declared=$(grep -vE '^\s*(#|$)' "$REPO_ROOT/analysis/frame.version" | head -1 | tr -d ' ')
    assert_contains "$record" "frame " "the record names the frame that derived it"
    assert_contains "$record" "$declared" "with the version frame.config declares"
    assert_not_contains "$record" "unknown" "and never a placeholder"
    assert_contains "$record" ".poolseqflow_version" "beside the pipeline's own records"
}

# THE RISKY TRANSFER. Named files, one at a time, out of a directory that holds other things -
# a wholesale copy is how a neighbor comes back with them.
#
# It COPIES: permanent storage keeps its copy, so a cycle costs one transfer instead of two and
# the next `complete` has something to discard rather than something to send again.
test_an_intermediate_comes_back_from_permanent_storage() {
    analysis_writer_ready || return
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the first run should derive the intermediate"

    analysis_archive_main
    local archived; archived="$ANALYSIS_SB/store/Analysis/Main/Output"
    printf 'somebody else put this here\n' > "$archived/bystander.txt"
    assert_file "$archived/matrix.tsv" "the intermediate is in permanent storage to start with"

    analysis_folder_name "'from_storage'"
    status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should run against the archived intermediate"

    local main out
    main=$(analysis_main_dir)
    out=$(analysis_output)
    assert_contains "$out" "copied back from permanent storage" "the copy back is reported"
    assert_contains "$out" "WRITER reused" "and the intermediate is reused, not derived again"
    assert_file "$main/matrix.tsv" "it is on the working volume now"
    assert_file "$main/matrix.tsv.provenance" "and its record came with it"
    assert_file "$archived/matrix.tsv" "and permanent storage still has it - this is a copy"
    assert_file "$archived/matrix.tsv.provenance" "record included"
    assert_file "$archived/bystander.txt" \
        "and nothing else in permanent storage was carried off with them"

    # AND NO STAGING DIRECTORY SURVIVES IT. The stage the copy lands in belongs to the
    # transfer, not to Analysis/Main; left behind it would be read as an intermediate by the
    # next `find` that walks Main.
    #
    # Asserted here rather than in a case of its own, which repeated this whole setup for one
    # line and had nothing in it proving the copy back had happened at all - so the count was
    # over a directory that need never have existed. The assertions above are that proof.
    local leftovers
    leftovers=$(find "$main" -maxdepth 1 -name '.restore.*' 2>/dev/null | wc -l)
    assert_eq "0" "$leftovers" "no staging directory survives the copy"
}

test_complete_moves_the_analyses_and_the_intermediates() {
    analysis_completable || return
    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "complete should move what the writer produced"

    local store; store=$(analysis_archived)
    assert_file "$store/Results/writer/Test_result.tsv" "the analysis is in permanent storage"
    assert_file "$store/Results/writer/0_verify_analysis.txt" "with the record that cleared it"
    assert_file "$store/Main/Output/matrix.tsv" "and so is the intermediate"
    assert_file "$store/Main/Output/matrix.tsv.provenance" "with its provenance record"
    assert_no_file "$ANALYSIS_SB/main/Analysis/Results/writer" "the working copies are gone"
    assert_no_file "$(analysis_main_dir)/matrix.tsv" ""
}

# THE RISK, IN THE OTHER DIRECTION. RestoreIntermediates already proves a move back does not
# carry off a neighbor; this is the same guarantee on the way out.
test_complete_leaves_permanent_storage_alone() {
    analysis_completable || return
    local store; store=$(analysis_archived)
    mkdir -p "$store/Main/Output" "$store/Results/somebody_else"
    printf 'not mine\n' > "$store/Main/Output/bystander.txt"
    printf 'not mine\n' > "$store/Results/somebody_else/report.tsv"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "complete should run with other things already in storage"
    assert_eq "not mine" "$(cat "$store/Main/Output/bystander.txt" 2>/dev/null)" \
        "a file already beside the intermediates is untouched"
    assert_eq "not mine" "$(cat "$store/Results/somebody_else/report.tsv" 2>/dev/null)" \
        "and so is somebody else's results folder"
    assert_file "$store/Main/Output/matrix.tsv" "while what was asked for did move"
}

# Logs and Session describe invocations rather than results - Session is overwritten by the
# next one and Logs is appended to by every one - so neither belongs in permanent storage.
test_complete_leaves_the_working_records_behind() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null
    local out; out=$(analysis_output)
    assert_dir "$ANALYSIS_SB/main/Analysis/Logs" "Logs stays on the working volume"
    assert_no_file "$(analysis_archived)/Logs" "and does not appear in permanent storage"
    assert_contains "$out" "Logs, Session and work stay" "and the run says so"
}

# Two different analyses under one name is what folderName exists to prevent, so a name
# already taken stops the whole command - not just that one item.
test_complete_refuses_a_name_already_in_permanent_storage() {
    analysis_completable || return
    local store; store=$(analysis_archived)
    mkdir -p "$store/Results/writer"
    printf 'an older analysis\n' > "$store/Results/writer/result.tsv"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 1 "$status" "a collision should stop the command"
    local out; out=$(analysis_output)
    assert_contains "$out" "already in permanent storage" "naming what collided"
    assert_contains "$out" "Results/writer" "and which one"
    assert_eq "an older analysis" "$(cat "$store/Results/writer/result.tsv" 2>/dev/null)" \
        "the copy in storage is untouched"
    assert_file "$ANALYSIS_SB/main/Analysis/Results/writer/Test_result.tsv" \
        "and NOTHING moved - not the colliding folder"
    assert_file "$(analysis_main_dir)/matrix.tsv" "and not the intermediate either"
}

# A failed verification leaves a folder holding its record and nothing else, and the manual
# promises that retry is allowed. Archiving it would take the name into storage and the
# two-root refusal would then block the retry for good.
test_complete_leaves_a_folder_holding_only_a_failed_record() {
    analysis_ready single || return
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_WRITER_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    run_analysis "$ANALYSIS_SB" writer > /dev/null

    local folder; folder="$ANALYSIS_SB/main/Analysis/Results/writer"
    assert_file "$folder/0_verify_analysis.txt" "the verification record is there to start with"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "complete should run"
    assert_contains "$(analysis_output)" "left behind" "and say it passed the folder over"
    assert_file "$folder/0_verify_analysis.txt" "the record stays on the working volume"
    assert_no_file "$(analysis_archived)/Results/writer" \
        "and the name is not consumed in permanent storage"
}

# Interrupted, it has to be safe to run again; and with nothing left to move it must not
# invent an error.
test_complete_run_twice_moves_nothing_the_second_time() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null
    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "a second run should succeed"
    local out; out=$(analysis_output)
    assert_contains "$out" "0 item(s) moved" "having found nothing to move"
    assert_file "$(analysis_archived)/Main/Output/matrix.tsv" "and disturbed nothing"
}

# END TO END, and the reason the relative path is the same under both volumes: a module run
# after `complete` finds its intermediate in storage and brings it back.
test_a_module_reaches_an_intermediate_that_complete_archived() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module should run against the archived intermediate"
    local out; out=$(analysis_output)
    assert_contains "$out" "copied back from permanent storage" "restoring it"
    assert_contains "$out" "WRITER reused" "rather than deriving it again"
}

# THE LOOP THAT WAS NEVER TESTED, and the one that failed: complete -> run -> complete. The
# second complete used to refuse, because every intermediate the run copied back collided with
# the copy that was still in storage and every collision was a refusal.
test_complete_after_a_resume_discards_the_working_intermediate() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    local status; status=$(analysis_run_module writer)
    assert_status 0 "$status" "the module runs against the archived intermediate"
    assert_file "$(analysis_main_dir)/matrix.tsv" "which puts a working copy back"

    status=$(run_complete "$ANALYSIS_SB")
    assert_status 0 "$status" "the second complete should succeed, not refuse"

    local out store
    out=$(analysis_output)
    store=$(analysis_archived)
    assert_contains "$out" "discarded - permanent storage has it" "saying what it discarded"
    assert_contains "$out" "Main/Output/matrix.tsv" "and naming it"
    assert_no_file "$(analysis_main_dir)/matrix.tsv" "the working copy is gone"
    assert_no_file "$(analysis_main_dir)/matrix.tsv.provenance" "and so is its record"
    assert_file "$store/Main/Output/matrix.tsv" "the archived copy is untouched"
    assert_file "$store/Results/after_complete/Test_result.tsv" "and the new analysis did move"
}

# The discard is licensed by the provenance records agreeing. When they do not, the two copies
# came from different results and only the user can say which one to keep.
test_complete_refuses_an_intermediate_whose_records_disagree() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    analysis_run_module writer > /dev/null

    local main store
    main=$(analysis_main_dir)
    store=$(analysis_archived)
    printf 'derived from something else\n' > "$main/matrix.tsv.provenance"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 1 "$status" "a disagreement should stop the command"
    local out; out=$(analysis_output)
    assert_contains "$out" "do not agree" "naming the disagreement"
    assert_contains "$out" "Main/Output/matrix.tsv" "and which intermediate"
    assert_contains "$out" "Nothing was moved and nothing was discarded" "and doing nothing"
    assert_file "$main/matrix.tsv" "the working copy is left for the user to judge"
    assert_file "$store/Main/Output/matrix.tsv" "and so is the archived one"
    assert_no_file "$store/Results/after_complete" "and the analysis did not move either"
}

# A working copy with no record beside it cannot license its own discard. publishIntermediate
# writes the record first, so this state means something removed it by hand.
test_complete_refuses_an_intermediate_with_no_record_beside_it() {
    analysis_completable || return
    run_complete "$ANALYSIS_SB" > /dev/null

    analysis_folder_name "'after_complete'"
    analysis_run_module writer > /dev/null
    rm -f "$(analysis_main_dir)/matrix.tsv.provenance"

    local status; status=$(run_complete "$ANALYSIS_SB")
    assert_status 1 "$status" "a missing record should stop the command"
    local out; out=$(analysis_output)
    assert_contains "$out" "no provenance record" "saying which side is missing one"
    assert_file "$(analysis_main_dir)/matrix.tsv" "and nothing is discarded"
}
