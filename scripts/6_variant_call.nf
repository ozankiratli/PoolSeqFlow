process VariantCall {
    tag { "calling_variants" }

    input:
    path ready_bams
    path fai_index

    output:
    path "${params.vcf.fileName}.vcf", emit: vcf_file

    script:
    reference = params.reference
    vcf_file = "${params.vcf.fileName}.vcf"
    target_vcf_folder = "${params.dir.output.vcf}"
    target_vcf_file = "${target_vcf_folder}/${vcf_file}"
    dir_log = "${params.dir.logs}/6_variant_call"

    """
    set -e
    echo "VARIANT CALL ${vcf_file}: Variant calling started..."
    if [ -f ${target_vcf_file} ]; then
        echo "VARIANT CALL ${vcf_file}: Found existing VCF file" 
        echo "VARIANT CALL ${vcf_file}: Found: ${target_vcf_file}"
        echo "VARIANT CALL ${vcf_file}: Creating symbolic link..."
        ln -s ${target_vcf_file} .
        echo "VARIANT CALL ${vcf_file}: COMPLETED"
    else
        echo "VARIANT CALL ${vcf_file}: Creating VCF file..."
        ${params.software.bcftools} mpileup ${params.bcftools.mpileupOptions} \
        -f ${reference} ${ready_bams} | \
        ${params.software.bcftools} call ${params.bcftools.callOptions} \
        -o ${vcf_file}

        echo "VARIANT CALL ${vcf_file}: Fixing minor header issue..."
        sed -i 's/##INFO=<ID=MQ,Number=1,Type=Integer/##INFO=<ID=MQ,Number=1,Type=Float/' ${vcf_file}
        echo "VARIANT CALL ${vcf_file}: Type of MQ changed from Integer to Float..."

        echo "VARIANT CALL ${vcf_file}: Moving ${vcf_file} to ${target_vcf_folder}..."
        mkdir -p ${params.dir.output.vcf}
        mv ${vcf_file} ${target_vcf_file}
        echo "VARIANT CALL ${vcf_file}: Creating symbolic link..."
        ln -s ${target_vcf_file} .
        echo "VARIANT CALL ${vcf_file}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/6_VariantCall_${params.vcf.fileName}.log
    cp .command.err ${dir_log}/6_VariantCall_${params.vcf.fileName}.err
    """
}

workflow VariantCalling {
    take:
    out_ready_bams
    fai_index

    main:
    ready_bams = out_ready_bams
            .map { id, bam -> return bam }
            .collect()

    VariantCall(ready_bams,fai_index)

    emit:
    vcf = VariantCall.out.vcf_file
}