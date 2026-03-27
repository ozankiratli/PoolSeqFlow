process AlignmentReport {
    tag { pair_id }

    input:
    tuple val(pair_id), path(ready_bam)
    tuple val(pair_id), path(ready_bai)

    script:
    report_file = "${pair_id}_alignment_report.txt"
    target_folder = "${params.dir.output.report.align}"
    target_report = "${target_folder}/${report_file}"
    dir_log = "${params.dir.logs}/5_reports/s1_AlignmentReport/${pair_id}"

    """
    set -e
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
        ${params.software.bamtools} stats -in ${ready_bam} >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}

        echo "ALIGNMENT REPORT ${ready_bam}: Moving ${report_file} to ${target_folder}..."
        mkdir -p ${target_folder}
        mv ${report_file} ${target_folder}/
        echo "ALIGNMENT REPORT ${ready_bam}: Creating symbolic link..."
        ln -s ${target_report} .
        echo "ALIGNMENT REPORT ${ready_bam}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/5_GenerateReports_s1_AlignmentReport_${pair_id}.log
    cp .command.err ${dir_log}/5_GenerateReports_s1_AlignmentReport_${pair_id}.err
    """
}

process CoverageReport {
    tag { pair_id }

    input:
    tuple val(pair_id), path(ready_bam)
    tuple val(pair_id), path(ready_bai)

    script:
    report_file = "${pair_id}_coverage_report.txt"
    target_folder = "${params.dir.output.report.coverage}"
    target_report = "${target_folder}/${report_file}"
    dir_log = "${params.dir.logs}/5_reports/s2_CoverageReport/${pair_id}"

    """
    set -e
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
        ${params.software.samtools} coverage ${ready_bam} >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}
        echo "--------------------------------------------------------" >> ${report_file}

        echo "COVERAGE REPORT ${ready_bam}: Moving ${report_file} to ${target_folder}..."
        mkdir -p ${target_folder}
        mv ${report_file} ${target_folder}/
        echo "COVERAGE REPORT ${ready_bam}: Creating symbolic link..."
        ln -s ${target_report} .
        echo "COVERAGE REPORT ${ready_bam}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/5_GenerateReports_s2_CoverageReport_${pair_id}.log
    cp .command.err ${dir_log}/5_GenerateReports_s2_CoverageReport_${pair_id}.err
    """
}

workflow GenerateReports {
    take:
    ready_bams
    ready_bais

    main:
    AlignmentReport(ready_bams, ready_bais)
    CoverageReport(ready_bams, ready_bais)
}