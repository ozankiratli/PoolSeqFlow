process AnnotateVariants {
    tag { vcf.baseName }

    input:
    path vcf
    path snpeff_db_verify

    output:
    path "*_annotated.vcf", emit: annotated_vcf

    script:
    gff = params.gff
    reference = params.reference
    annotated_vcf_file = "${vcf.baseName}_annotated.vcf"
    report_folder = "${params.dir.output.reports}"
    report_file = "${report_folder}/snpeff_summary.html"
    target_folder = "${params.dir.output.vcf}"
    target_annotated_vcf = "${target_folder}/${annotated_vcf_file}"

    dir_log = "${params.dir.logs}/8_annotate_variants"

    """
    set -e

    export _JAVA_OPTIONS="${params.java.options}"

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
        TMPFILE=\$(mktemp --suffix=.vcf)
        
        echo "ANNOTATING VCF ${vcf}: Converting multiallelic sites into separate lines..."
        ${params.software.bcftools} norm -m - ${vcf} > \${TMPFILE}
        echo "ANNOTATING VCF ${vcf}: Running snpEff annotation..."
        ${params.software.snpEff} \
            ${params.snpEff.runOptions} \
            -stats ${report_file} \
            ${params.snpEff.db} \
            \${TMPFILE} \
            > ${annotated_vcf_file}

        rm \${TMPFILE}

        echo "ANNOTATING VCF ${vcf}: Moving ${annotated_vcf_file} to ${target_folder}"
        mkdir -p ${target_folder}
        mv ${annotated_vcf_file} ${target_folder}/
        echo "ANNOTATING VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_annotated_vcf} .
        echo "ANNOTATING VCF ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/8_AnnotateVariants_${vcf.baseName}.log
    cp .command.err ${dir_log}/8_AnnotateVariants_${vcf.baseName}.err
    """
}

workflow AnnotateVCF {
    take:
    vcf
    snpeff_db_verify

    main:
    AnnotateVariants(vcf,snpeff_db_verify)

    emit:
    annotated_vcf = AnnotateVariants.out.annotated_vcf
}