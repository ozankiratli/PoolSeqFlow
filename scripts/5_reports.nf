process AlignmentReport {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }

    input:
    tuple val(run), val(pair_id), path(ready_bam), path(ready_bai)

    // Declared so that finishing is observable. Until 3.0 neither report process declared
    // any output at all, which made this step invisible to the graph: it could not be
    // waited on, and Nextflow tracked nothing it produced. The ready BAMs are read by this
    // step AND by variant calling, so promoting them needs to know when BOTH are done -
    // and that is impossible for a step that never says it finished.
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

workflow GenerateReports {
    take:
    ready_bams
    ready_bais

    main:
    // Join on the run AND the sample so each BAM is matched with its own index. Passing the
    // two channels separately would pair them by emission order, not by sample; keying on
    // the sample alone would pair one run's BAM with another run's index, because two runs
    // over the same data have samples of the same name.
    ready_data = ready_bams.join(ready_bais, by: [0, 1])
    AlignmentReport(ready_data)
    CoverageReport(ready_data)

    // Both reports for a sample, joined back to one signal per (run, sample). A caller that
    // needs "step 5 has finished with this BAM" means both of them, not whichever landed
    // first.
    emit:
    AlignmentReport.out.report
        .join(CoverageReport.out.report, by: [0, 1])
        .map { run, pair_id, _align, _coverage -> tuple(run, pair_id) }
}