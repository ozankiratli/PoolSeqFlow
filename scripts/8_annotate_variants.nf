process AnnotateVariants {
    tag { vcf.baseName }
    cpus { params.cores.javaGc }

    input:
    path vcf
    path snpeff_db_verify

    output:
    path "*_annotated.vcf", emit: annotated_vcf

    script:
    annotated_vcf_file = "${vcf.baseName}_annotated.vcf"
    report_folder = "${params.dir.output.reports}"
    report_file = "${report_folder}/snpeff_summary.html"
    target_folder = "${params.dir.output.vcf}"
    target_annotated_vcf = "${target_folder}/${annotated_vcf_file}"

    dir_log = "${params.dir.logs}/8_annotate_variants"

    """
    set -eo pipefail

    export _JAVA_OPTIONS="${params.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

    echo "ANNOTATING VCF ${vcf}: Annotating VCF file..."
    if [ -f ${target_annotated_vcf} ]; then
        echo "ANNOTATING VCF ${vcf}: Found existing annotated VCF file"
        echo "ANNOTATING VCF ${vcf}: Found: ${target_annotated_vcf}"
        echo "ANNOTATING VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_annotated_vcf} .
        echo "ANNOTATING VCF ${vcf}: COMPLETED"
    else
        echo "ANNOTATING VCF ${vcf}: Creating symbolic links for snpEff database"
        ln -s ${params.dir.snpEff}/* .
        # Keep the temp in the task directory rather than system /tmp: it is the same
        # order of magnitude as the call set, so it belongs on the filesystem sized for
        # the run, and `cleanup = true` reaps it. The trap removes it however the task
        # ends - the plain rm below it only ran when everything succeeded, so a bcftools
        # or snpEff failure orphaned a whole-genome VCF, once per retry.
        TMPFILE=\$(mktemp -p . --suffix=.vcf)
        trap 'rm -f "\$TMPFILE"' EXIT
        
        echo "ANNOTATING VCF ${vcf}: Converting multiallelic sites into separate lines..."
        ${params.software.bcftools} norm -m - ${vcf} > \${TMPFILE}
        echo "ANNOTATING VCF ${vcf}: Running snpEff annotation..."
        ${params.software.snpEff} \
            ${params.snpEff.runOptions} \
            -c ${params.snpEff.config} \
            -stats ${report_file} \
            ${params.snpEff.db} \
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
    vcf
    snpeff_db_verify

    main:
    AnnotateVariants(vcf,snpeff_db_verify)

    emit:
    AnnotateVariants.out.annotated_vcf
}