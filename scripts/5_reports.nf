// One sample's effective depth ceiling, from its metadata row or the run's own setting.
include { sampleCapMaxDepth } from './metadata.nf'

process AlignmentReport {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }

    input:
    tuple val(run), val(pair_id), path(ready_bam), path(ready_bai)

    // A completion signal, not data any later step reads.
    output:
    tuple val(run), val(pair_id), path("*_alignment_report.txt"), emit: report

    script:
    report_file = "${pair_id}_alignment_report.txt"
    target_folder = "${run.dir.output.report.align}"
    target_report = "${target_folder}/${report_file}"
    dir_log = "${run.dir.logs}/5_reports"

    """
    set -eo pipefail
    if [ -f ${target_report} ]; then
        echo "ALIGNMENT REPORT ${ready_bam}: Found existing alignment report file"
        echo "ALIGNMENT REPORT ${ready_bam}: Found: ${target_report}"
        echo "ALIGNMENT REPORT ${ready_bam}: Marking step as completed!"
        echo "ALIGNMENT REPORT ${ready_bam}: Creating symbolic link..."
        ln -s ${target_report} .
        echo "ALIGNMENT REPORT ${ready_bam}: COMPLETED"
    else
        echo "ALIGNMENT REPORT ${ready_bam}: Generating alignment report..."
        echo "--------------------------------------------------------" > ${report_file}
        echo "Alignment Report For: ${pair_id}" >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}
        ${run.software.bamtools} stats -in ${ready_bam} >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}

        echo "ALIGNMENT REPORT ${ready_bam}: Moving ${report_file} to ${target_folder}..."
        mkdir -p ${target_folder}
        atomic_mv.sh ${report_file} ${target_report}
        echo "ALIGNMENT REPORT ${ready_bam}: Creating symbolic link..."
        ln -s ${target_report} .
        echo "ALIGNMENT REPORT ${ready_bam}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/5_GenerateReports_s1_AlignmentReport_${pair_id}_nextflow.log
    """
}

process CoverageReport {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }

    input:
    tuple val(run), val(pair_id), path(ready_bam), path(ready_bai)

    // See AlignmentReport above.
    output:
    tuple val(run), val(pair_id), path("*_coverage_report.txt"), emit: report

    script:
    report_file = "${pair_id}_coverage_report.txt"
    target_folder = "${run.dir.output.report.coverage}"
    target_report = "${target_folder}/${report_file}"
    dir_log = "${run.dir.logs}/5_reports"

    """
    set -eo pipefail
    if [ -f ${target_report} ]; then
        echo "COVERAGE REPORT ${ready_bam}: Found existing coverage report file"
        echo "COVERAGE REPORT ${ready_bam}: Found: ${target_report}"
        echo "COVERAGE REPORT ${ready_bam}: Marking step as completed!"
        echo "COVERAGE REPORT ${ready_bam}: Creating symbolic link..."
        ln -s ${target_report} .
        echo "COVERAGE REPORT ${ready_bam}: COMPLETED"
    else
        echo "COVERAGE REPORT ${ready_bam}: Generating alignment report..."
        echo "--------------------------------------------------------" > ${report_file}
        echo "Coverage Report For: ${pair_id}" >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}
        ${run.software.samtools} coverage ${ready_bam} >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}

        echo "COVERAGE REPORT ${ready_bam}: Moving ${report_file} to ${target_folder}..."
        mkdir -p ${target_folder}
        atomic_mv.sh ${report_file} ${target_report}
        echo "COVERAGE REPORT ${ready_bam}: Creating symbolic link..."
        ln -s ${target_report} .
        echo "COVERAGE REPORT ${ready_bam}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/5_GenerateReports_s2_CoverageReport_${pair_id}_nextflow.log
    """
}

// The per-position depth histogram, and from it this sample's ceiling for step 6. Runs on every
// sample of every run, whatever capBAM.maxDepth is set to.
process DepthProfile {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }

    input:
    tuple val(run), val(pair_id), path(ready_bam), path(ready_bai)

    // The BAM and its index pass straight through; step 6 reads them.
    output:
    tuple val(run), val(pair_id), path(ready_bam), path(ready_bai),
          path("${pair_id}_depth_cap.txt"), emit: profile

    script:
    setting = sampleCapMaxDepth(run, pair_id)
    histogram_file = "${pair_id}_depth_histogram.tsv"
    decision_file = "${pair_id}_depth_cap.txt"
    report_file = "${pair_id}_depth_report.txt"
    target_folder = "${run.dir.output.report.depth}"
    dir_log = "${run.dir.logs}/5_reports"
    // The histogram's top bin. samtools' own default is 1000.
    hist_max = 100000

    """
    set -eo pipefail
    if [ -f ${target_folder}/${decision_file} ]; then
        echo "DEPTH PROFILE ${ready_bam}: Found existing depth profile"
        echo "DEPTH PROFILE ${ready_bam}: Found: ${target_folder}/${decision_file}"
        echo "DEPTH PROFILE ${ready_bam}: Creating symbolic links..."
        ln -s ${target_folder}/${decision_file} .
        echo "DEPTH PROFILE ${ready_bam}: COMPLETED"
    else
        echo "DEPTH PROFILE ${ready_bam}: Measuring the depth histogram..."
        ${run.software.samtools} stats -c 1,${hist_max},1 ${ready_bam} > stats.txt

        # The open top bin holds every position deeper than the ceiling. A non-empty one means
        # the histogram is truncated.
        open_bin=\$(awk -F'\\t' '\$1 == "COV" && \$2 ~ /</ { print \$4 }' stats.txt)
        if [ -n "\$open_bin" ] && [ "\$open_bin" -gt 0 ]; then
            echo "DEPTH PROFILE ${ready_bam}: ERROR: \$open_bin position(s) deeper than ${hist_max}," >&2
            echo "DEPTH PROFILE ${ready_bam}: so the depth histogram is truncated and a ceiling read" >&2
            echo "DEPTH PROFILE ${ready_bam}: from it would be chosen from a partial picture. Raise the" >&2
            echo "DEPTH PROFILE ${ready_bam}: histogram ceiling in scripts/5_reports.nf." >&2
            exit 1
        fi

        awk -F'\\t' '\$1 == "COV" && \$2 !~ /</ { print \$3 "\\t" \$4 }' stats.txt > ${histogram_file}

        if [ "${setting}" = "-1" ]; then
            echo "DEPTH PROFILE ${ready_bam}: Choosing a ceiling from the histogram..."
            depth_cutoff.py ${histogram_file} > decision.txt
            cap=\$(sed -n 1p decision.txt)
            reason=\$(sed -n 2p decision.txt)
        elif [ "${setting}" = "0" ]; then
            cap=0
            reason="capping is switched off for this sample (capBAM.maxDepth = 0)"
        else
            cap=${setting}
            reason="capped at the depth this sample was given (capBAM.maxDepth = ${setting})"
        fi

        printf '%s\\n' "\$cap" > ${decision_file}
        {
            echo "--------------------------------------------------------"
            echo "Depth Profile For: ${pair_id}"
            echo "--------------------------------------------------------"
            echo "capBAM.maxDepth setting : ${setting}"
            echo "ceiling applied         : \$( [ "\$cap" = "0" ] && echo "none - this sample is not capped" || echo "\$cap" )"
            echo "why                     : \$reason"
            echo "histogram               : ${histogram_file}"
            echo "--------------------------------------------------------"
        } > ${report_file}

        echo "DEPTH PROFILE ${ready_bam}: \$reason"
        echo "DEPTH PROFILE ${ready_bam}: Moving reports to ${target_folder}..."
        mkdir -p ${target_folder}
        atomic_mv.sh ${histogram_file} ${target_folder}/${histogram_file}
        atomic_mv.sh ${report_file} ${target_folder}/${report_file}
        atomic_mv.sh ${decision_file} ${target_folder}/${decision_file}
        echo "DEPTH PROFILE ${ready_bam}: Creating symbolic links..."
        ln -s ${target_folder}/${decision_file} .
        echo "DEPTH PROFILE ${ready_bam}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/5_GenerateReports_s3_DepthProfile_${pair_id}_nextflow.log
    """
}

workflow GenerateReports {
    take:
    ready_bams
    ready_bais

    main:
    // On the run AND the sample: on the sample alone, one run's BAM would pair with another
    // run's index.
    ready_data = ready_bams.join(ready_bais, by: [0, 1])
    AlignmentReport(ready_data)
    CoverageReport(ready_data)
    DepthProfile(ready_data)

    // All three reports for a sample, joined back to one item per (run, sample), carrying the
    // BAM, its index and the chosen ceiling.
    emit:
    DepthProfile.out.profile
        .join(AlignmentReport.out.report, by: [0, 1])
        .join(CoverageReport.out.report, by: [0, 1])
        .map { run, pair_id, bam, bai, cap, _align, _coverage -> tuple(run, pair_id, bam, bai, cap) }
}