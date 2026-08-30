process AnnotateVariants {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }
    cpus { run.cores.javaGc }

    input:
    // One tuple, not two inputs: the marker is matched to the VCF by run.
    tuple val(run), path(vcf), path(snpeff_db_verify)

    output:
    tuple val(run), path("*_annotated.vcf"), emit: annotated_vcf

    script:
    annotated_vcf_file = "${vcf.baseName}_annotated.vcf"
    report_folder = "${run.dir.output.reports}"
    report_file = "${report_folder}/snpeff_summary.html"
    target_folder = "${run.dir.output.vcf}"
    target_annotated_vcf = "${target_folder}/${annotated_vcf_file}"

    dir_log = "${run.dir.logs}/8_annotate_variants"

    """
    set -eo pipefail

    export _JAVA_OPTIONS="${run.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

    echo "ANNOTATING VCF ${vcf}: Annotating VCF file..."
    if [ -f ${target_annotated_vcf} ]; then
        echo "ANNOTATING VCF ${vcf}: Found existing annotated VCF file"
        echo "ANNOTATING VCF ${vcf}: Found: ${target_annotated_vcf}"
        echo "ANNOTATING VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_annotated_vcf} .
        echo "ANNOTATING VCF ${vcf}: COMPLETED"
    else
        # snpEff is given an absolute path for its summary and exits 255 rather than creating the
        # directory, so it has to exist first.
        mkdir -p ${report_folder} ${target_folder}

        echo "ANNOTATING VCF ${vcf}: Creating symbolic links for snpEff database"
        ln -s ${run.dir.snpEff}/* .
        # In the task directory, not system /tmp, and removed by the trap however the task ends.
        TMPFILE=\$(mktemp -p . --suffix=.vcf)
        trap 'rm -f "\$TMPFILE"' EXIT
        
        echo "ANNOTATING VCF ${vcf}: Converting multiallelic sites into separate lines..."
        ${run.software.bcftools} norm -m - ${vcf} > \${TMPFILE}
        echo "ANNOTATING VCF ${vcf}: Running snpEff annotation..."
        ${run.software.snpEff} \
            ${run.snpEff.runOptions} \
            -c ${run.snpEff.config} \
            -stats ${report_file} \
            ${run.snpEff.db} \
            \${TMPFILE} \
            > ${annotated_vcf_file}

        echo "ANNOTATING VCF ${vcf}: Moving ${annotated_vcf_file} to ${target_folder}"
        mkdir -p ${target_folder}
        atomic_mv.sh ${annotated_vcf_file} ${target_annotated_vcf}
        echo "ANNOTATING VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_annotated_vcf} .
        echo "ANNOTATING VCF ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/8_AnnotateVariants_${vcf.baseName}_nextflow.log
    """
}

workflow AnnotateVCF {
    take:
    vcf                 // [run, called vcf] - only the runs that annotate
    snpeff_db_verify    // [run, database marker]

    main:
    AnnotateVariants(vcf.join(snpeff_db_verify, by: 0))

    emit:
    AnnotateVariants.out.annotated_vcf
}