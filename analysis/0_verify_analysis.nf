// The analysis layer's step 0: everything checked before a module is allowed to compute.
//
// Three checks. The identity check compares the project as it stands with the record the
// pipeline wrote beside the results; the directory check counts what each selected results
// directory holds; the folder check reports what is already where this invocation would write.
// The report assembles all three and fails the run on any of them.
//
// The module and the run selection are settled while the DAG is built and arrive here already
// rendered, so a mistyped module or run name never reaches a task.

nextflow.enable.dsl=2

include { verificationRecordName } from './lib/paths.nf'

// Where the analysis layer keeps its own record, under mainDir.
def analysisLogDir() {
    return "${params.mainDir}/Analysis/Logs/0_verify_analysis".toString()
}

// A results directory's name as a file name. One task per directory writes its own stage
// report, and they are collected into one process.
def targetSlug(Map target) {
    return "${target.label}".replaceAll(/[^A-Za-z0-9]+/, '_')
}

// The results a module reads were produced under a configuration, and that configuration is
// recorded beside them. This compares the two and refuses a project that has moved on.
process CheckProjectIdentity {
    input:
    // Rendered while the DAG is built, where `params` is fully resolved.
    val manifest

    output:
    path 'analysis_identity.txt', emit: report

    script:
    root        = "${params.storageDir}/Output"
    version     = "${root}/.poolseqflow_version"
    stored      = "${root}/.poolseqflow_params"
    storedTable = "${root}/.multirun.csv"
    readable    = "${root}/run_parameters.txt"
    liveTable   = params.multiRun ? "${params.multiRunPath}" : ''
    release     = workflow.manifest.version ?: 'unknown'
    dir_log     = analysisLogDir()
    """
    REPORTFILE="analysis_identity.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    cat <<'CURRENT_PARAMS' > current_params.txt
${manifest}
CURRENT_PARAMS

    STATUS="PASS"

    # The version, first and on its own: nothing below it means anything if the results came
    # from another release.
    if [ ! -f "${version}" ]; then
        log_message "RESULTS IDENTITY:      No results recorded in"
        log_message "RESULTS IDENTITY:          ${root}"
        log_message "RESULTS IDENTITY:      The analysis layer reads what a pipeline run published, and this"
        log_message "RESULTS IDENTITY:      project has none - .poolseqflow_version is written there by the"
        log_message "RESULTS IDENTITY:      first run and is not there."
        log_message "RESULTS IDENTITY:"
        log_message "RESULTS IDENTITY:      Run the pipeline first:  PoolSeqFlow run"
        STATUS="FAIL"
    elif [ "\$(cut -f1 < "${version}")" != "${release}" ]; then
        log_message "RESULTS IDENTITY:      These results were produced by PoolSeqFlow \$(cut -f1 < "${version}"),"
        log_message "RESULTS IDENTITY:      and this analysis layer is ${release}."
        log_message "RESULTS IDENTITY:"
        log_message "RESULTS IDENTITY:      What a table holds and what its columns mean belong to the release"
        log_message "RESULTS IDENTITY:      that wrote it, so a module of one release reading another's results"
        log_message "RESULTS IDENTITY:      has no way to know what it is reading."
        log_message "RESULTS IDENTITY:"
        log_message "RESULTS IDENTITY:      Install the analysis layer of the release that made them, or produce"
        log_message "RESULTS IDENTITY:      the results again under this one:  PoolSeqFlow reset"
        STATUS="FAIL"
    else
        log_message "RESULTS IDENTITY:      PoolSeqFlow ${release}, results recorded \$(cut -f2 < "${version}")"
    fi

    # The multi-run table, as written. Which runs share a results directory is decided by it, and
    # that is the mapping the selection above was resolved through.
    if [ "\$STATUS" = "PASS" ] && [ -n "${liveTable}" ]; then
        sed -e 's/\\r\$//' -e 's/[[:space:]]*\$//' -e '/^\$/d' "${liveTable}" > current_table.csv
        if [ ! -f "${storedTable}" ]; then
            log_message "RESULTS IDENTITY:      ${params.multiRunFile} was not recorded beside the results."
            log_message "RESULTS IDENTITY:      .multirun.csv is written by the first run of a multi-run project,"
            log_message "RESULTS IDENTITY:      so these results were produced as a single run and the table is new."
            STATUS="FAIL"
        elif diff -q "${storedTable}" current_table.csv > /dev/null 2>&1; then
            log_message "RESULTS IDENTITY:      ${params.multiRunFile} unchanged since the results were produced"
        else
            log_message "RESULTS IDENTITY:      ${params.multiRunFile} has CHANGED since the results were produced:"
            log_message ""
            while IFS= read -r line; do
                case "\$line" in
                    '<'*) printf '  was  %s\\n' "\${line#< }" | tee -a \$REPORTFILE ;;
                    '>'*) printf '  now  %s\\n' "\${line#> }" | tee -a \$REPORTFILE ;;
                esac
            done < <(diff "${storedTable}" current_table.csv | grep -E '^[<>]')
            log_message ""
            log_message "RESULTS IDENTITY:      Which runs share a results directory is decided by that table, so"
            log_message "RESULTS IDENTITY:      an edit can move a run to a directory holding somebody else's"
            log_message "RESULTS IDENTITY:      results. Restore it, or produce the results again:"
            log_message "RESULTS IDENTITY:          PoolSeqFlow reset"
            STATUS="FAIL"
        fi
    fi

    # parameters.config, by resolved value rather than as written. Paths and resources are not
    # compared: the same manifest the pipeline recorded leaves them out.
    if [ "\$STATUS" = "PASS" ] && [ ! -f "${stored}" ]; then
        log_message "RESULTS IDENTITY:      No parameter record beside the results."
        log_message "RESULTS IDENTITY:      .poolseqflow_params is written by the first run and is not there, so"
        log_message "RESULTS IDENTITY:      there is nothing to check these results against."
        STATUS="FAIL"
    elif [ "\$STATUS" = "PASS" ] && diff -q "${stored}" current_params.txt > /dev/null 2>&1; then
        log_message "RESULTS IDENTITY:      parameters.config unchanged since the results were produced"
    elif [ "\$STATUS" = "PASS" ]; then
        classify_manifest.sh "${stored}" current_params.txt > param_diff.txt
        log_message "RESULTS IDENTITY:      parameters.config has CHANGED since the results were produced:"
        log_message ""
        while IFS=\$'\\t' read -r kind key was now; do
            case "\$kind" in
                CHANGED) printf '  %s\\n      was  %s\\n      now  %s\\n' "\$key" "\$was" "\$now" | tee -a \$REPORTFILE ;;
                ADDED)   printf '  added    %s = %s\\n' "\$key" "\$now" | tee -a \$REPORTFILE ;;
                REMOVED) printf '  removed  %s (was %s)\\n' "\$key" "\$was" | tee -a \$REPORTFILE ;;
            esac
        done < param_diff.txt
        log_message ""
        log_message "RESULTS IDENTITY:      A module reads these settings and the tables together - pool sizes,"
        log_message "RESULTS IDENTITY:      ploidy and the filter thresholds all decide what a frequency means."
        log_message "RESULTS IDENTITY:      The values above are not the ones that produced the tables."
        log_message "RESULTS IDENTITY:"
        log_message "RESULTS IDENTITY:      What produced them is recorded in"
        log_message "RESULTS IDENTITY:          ${readable}"
        log_message "RESULTS IDENTITY:      Restore those values, or produce the results again:"
        log_message "RESULTS IDENTITY:          PoolSeqFlow reset"
        STATUS="FAIL"
    fi

    log_message "RESULTS IDENTITY:      STATUS=\$STATUS"

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/0_VerifyAnalysis_s1_CheckProjectIdentity_nextflow.log
    """
}

// What one results directory holds, class by class. A class the module declared it needs and
// that is not there fails the run; the rest are counted and reported.
process CheckResultsDirectory {
    tag { target.label }

    input:
    val target

    output:
    tuple val(target), path("analysis_results_${targetSlug(target)}.txt"), emit: report

    script:
    // One call per artifact class, rendered here so the shell loops over the classes rather than
    // over what their patterns match in the task directory.
    checks = target.classes.collect { _name, spec ->
        "check_class '${spec.label}' '${spec.dir}' '${spec.pattern}' '${spec.required}'"
    }.join('\n    ')
    dir_log = analysisLogDir()
    slug = targetSlug(target)
    """
    REPORTFILE="analysis_results_${slug}.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    STATUS="PASS"

    check_class() {
        label="\$1"
        dir="\$2"
        pattern="\$3"
        required="\$4"

        found=0
        if [ -d "\$dir" ]; then
            for f in "\$dir"/\$pattern; do
                if [ -e "\$f" ]; then found=\$(( found + 1 )); fi
            done
        fi

        if [ "\$found" -gt 0 ]; then
            printf 'RESULTS CHECK:             %-18s %s\\n' "\$label" "\$found" | tee -a \$REPORTFILE
        elif [ "\$required" = "true" ]; then
            printf 'RESULTS CHECK:             %-18s MISSING\\n' "\$label" | tee -a \$REPORTFILE
            log_message "RESULTS CHECK:                 nothing matching \$pattern in"
            log_message "RESULTS CHECK:                 \$dir"
            log_message "RESULTS CHECK:                 and this module reads them."
            STATUS="FAIL"
        else
            printf 'RESULTS CHECK:             %-18s none\\n' "\$label" | tee -a \$REPORTFILE
        fi
    }

    log_message "RESULTS CHECK:         ${target.label}"
    ${checks}
    log_message "RESULTS CHECK:         STATUS=\$STATUS"

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/0_VerifyAnalysis_s2_CheckResultsDirectory_${slug}_nextflow.log
    """
}

// Where this invocation's results go, and whether anything is there already. A folder that
// holds an analysis fails the stage.
//
// The verification record is excluded from the count: a module that failed after this stage
// leaves the folder holding nothing else, and that retry has to be allowed.
process CheckResultsFolder {
    tag { target.label }

    input:
    val target

    output:
    tuple val(target), path("analysis_folder_${targetSlug(target)}.txt"), emit: report

    script:
    dir_log = analysisLogDir()
    slug = targetSlug(target)
    keep = verificationRecordName()
    """
    REPORTFILE="analysis_folder_${slug}.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    STATUS="PASS"

    log_message "RESULTS FOLDER:        ${target.label}"
    log_message "RESULTS FOLDER:            ${target.results}"

    if [ ! -d "${target.results}" ]; then
        log_message "RESULTS FOLDER:            new - nothing is there yet"
    else
        HELD=\$(find "${target.results}" -mindepth 1 -maxdepth 1 ! -name '${keep}' | wc -l)
        if [ "\$HELD" -eq 0 ]; then
            log_message "RESULTS FOLDER:            holds no analysis - ready to be written"
        else
            if [ "\$HELD" -eq 1 ]; then WHAT="entry"; else WHAT="entries"; fi
            log_message "RESULTS FOLDER:            HOLDS AN ANALYSIS ALREADY - \$HELD \$WHAT"
            find "${target.results}" -mindepth 1 -maxdepth 1 ! -name '${keep}' \
                | sed 's|.*/|                                   |' | head -10 | tee -a \$REPORTFILE
            log_message "RESULTS FOLDER:"
            log_message "RESULTS FOLDER:            The folder you name is how two settings of one module are"
            log_message "RESULTS FOLDER:            told apart, so this is a collision rather than something to"
            log_message "RESULTS FOLDER:            write over. Name another with analysis.folderName, or move"
            log_message "RESULTS FOLDER:            this one out of the way."
            STATUS="FAIL"
        fi
    fi

    log_message "RESULTS FOLDER:        STATUS=\$STATUS"

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/0_VerifyAnalysis_s3_CheckResultsFolder_${slug}_nextflow.log
    """
}

// Every stage's verdict in one report, and the run's own fate. Fails on any FAIL, so a module
// that reaches its own work has had every assumption it declared checked.
process VerifyAnalysisReport {
    errorStrategy 'finish'

    input:
    tuple val(header), val(report_file), val(intermediates)
    path identity_log
    path folder_logs
    path results_logs

    output:
    path '0_verify_analysis.txt'

    script:
    dir_log = analysisLogDir()
    """
    REPORTFILE="0_verify_analysis.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    # The report has to leave the task directory, which `cleanup = true` empties on success.
    # Called on both paths, and before the `exit 1`, so a failed verification is archived too.
    archive_logs() {
        mkdir -p "\$(dirname ${report_file})" ${intermediates}
        atomic_mv.sh \$REPORTFILE ${report_file}
        ln -s ${report_file} .
        mkdir -p ${dir_log}
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${dir_log}/0_VerifyAnalysis_VerifyAnalysisReport_nextflow.log
    }

    log_message "===================== ANALYSIS VERIFICATION REPORT ====================="
    log_message "Date: \$(date)"
    log_message "======================================================================="
    log_message ""

    cat <<'HEADER' | tee -a \$REPORTFILE
${header}
HEADER
    log_message ""

    cat ${identity_log} | tee -a \$REPORTFILE
    log_message ""
    cat ${folder_logs} | tee -a \$REPORTFILE
    log_message ""
    cat ${results_logs} | tee -a \$REPORTFILE
    log_message ""
    log_message "======================================================================="

    # `|| true` is load-bearing: grep exits 1 when it counts none, and the task runs under -e.
    CHECKFAIL=\$(grep -c "STATUS=FAIL" \$REPORTFILE || true)
    if [ "\$CHECKFAIL" -gt 0 ]; then
        log_message "Analysis verification failed with \$CHECKFAIL issue(s)."
        log_message ""
        log_message "ANALYSIS VERIFICATION: FAILED"

        archive_logs
        exit 1
    fi

    log_message "All verification checks passed successfully."
    log_message ""
    log_message "ANALYSIS VERIFICATION: SUCCESS"

    archive_logs
    """
}

workflow VerifyAnalysis {
    take:
    // The module, the selection and the manifest in ONE value channel, settled while the DAG was
    // built; flatMap expands the targets into one check task each.
    context

    main:
    CheckProjectIdentity(context.map { ctx -> ctx.manifest })
    CheckResultsFolder(context.flatMap { ctx -> ctx.targets })
    CheckResultsDirectory(context.flatMap { ctx -> ctx.targets })

    VerifyAnalysisReport(
        context.map { ctx -> tuple(ctx.header, ctx.reportFile, ctx.intermediates) },
        CheckProjectIdentity.out.report,
        // Sorted, so the report reads the same way twice over the same project.
        CheckResultsFolder.out.report.map { _target, report -> report }
            .toSortedList { a, b -> a.name <=> b.name },
        CheckResultsDirectory.out.report.map { _target, report -> report }
            .toSortedList { a, b -> a.name <=> b.name })

    emit:
    VerifyAnalysisReport.out
}
