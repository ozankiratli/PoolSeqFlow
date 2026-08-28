process AnnotateVariants {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }
    cpus { run.cores.javaGc }

    input:
    // One tuple, not two inputs: the database marker is a per-run singleton and separate
    // inputs are matched positionally, so with N runs in flight it could be paired with
    // another run's VCF.
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
        # snpEff is given an absolute path for its summary and will NOT create the directory,
        # so it has to exist first. This only ever worked by accident: every other step wrote
        # into the run's own Output tree earlier in the run and made it on the way past. Once a
        # variant can be the first thing to write into its own directory - which is exactly
        # what a Shared_<N> is - the accident stops holding and snpEff exits 255.
        mkdir -p ${report_folder} ${target_folder}

        echo "ANNOTATING VCF ${vcf}: Creating symbolic links for snpEff database"
        ln -s ${run.dir.snpEff}/* .
        # Keep the temp in the task directory rather than system /tmp: it is the same
        # order of magnitude as the call set, so it belongs on the filesystem sized for
        # the run, and `cleanup = true` reaps it. The trap removes it however the task
        # ends - the plain rm below it only ran when everything succeeded, so a bcftools
        # or snpEff failure orphaned a whole-genome VCF, once per retry.
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