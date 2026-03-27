process SortRefAltByFrequency {
    tag { vcf.baseName }

    input:
    file vcf

    output:
    path "*_sort.vcf", emit: sorted_vcf

    script:
    target_folder_vcf = "${params.dir.output.vcf}"
    target_folder_freq = "${params.dir.output.freq}"

    sorted_base = "${vcf.baseName}_sort"
    sorted_vcf = "${sorted_base}.vcf"
    target_sorted_vcf = "${target_folder_vcf}/${sorted_vcf}"

    filterfp_base = "${sorted_base}_fp"
    filterfp_vcf = "${filterfp_base}.vcf"
    target_filterfp_vcf = "${target_folder_vcf}/${filterfp_vcf}"

    filterdq_base = "${filterfp_base}_dq"
    filterdq_vcf = "${filterdq_base}.vcf"
    target_filterdq_vcf = "${target_folder_vcf}/${filterdq_vcf}"

    snp_base = "${filterdq_base}_snp"
    snp_vcf = "${snp_base}.vcf"
    target_snp_vcf = "${target_folder_vcf}/${snp_vcf}"

    indel_base = "${filterdq_base}_indel"
    indel_vcf = "${indel_base}.vcf"
    target_indel_vcf = "${target_folder_vcf}/${indel_vcf}"

    snp_freq_base = "${vcf.baseName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${vcf.baseName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${params.dir.logs}/7_vcf2freq/s1_SortRefAltByFrequency"

    """
    set -e

    echo "SORT ALLELES BY FREQ ${vcf}: Sorting alleles by frequency..."
    if [ -f ${target_snp_freq_tsv} ] || [ -f ${target_indel_freq_tsv} ]; then
        echo "SORT ALLELES BY FREQ ${vcf}: Found at least one of the existing freq files"
        echo "SORT ALLELES BY FREQ ${vcf}: Found: ${target_snp_freq_tsv} ${target_indel_freq_tsv}"
        echo "SORT ALLELES BY FREQ ${vcf}: Creating dummy file..."
        touch ${sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    elif [ -f ${target_snp_vcf} ] || [ -f ${target_indel_vcf} ]; then
        echo "SORT ALLELES BY FREQ ${vcf}: Found at least one of the existing split VCF files"
        echo "SORT ALLELES BY FREQ ${vcf}: Found: ${target_snp_vcf} ${target_indel_vcf}"
        echo "SORT ALLELES BY FREQ ${vcf}: Creating dummy file..."
        touch ${sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    elif [ -f ${target_filterdq_vcf} ]; then
        echo "SORT ALLELES BY FREQ ${vcf}: Found existing depth and quality filtered VCF file"
        echo "SORT ALLELES BY FREQ ${vcf}: Found: ${target_filterdq_vcf}"
        echo "SORT ALLELES BY FREQ ${vcf}: Creating dummy file..."
        touch ${sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    elif [ -f ${target_filterfp_vcf} ]; then
        echo "SORT ALLELES BY FREQ ${vcf}: Found existing false positive filtered VCF file"
        echo "SORT ALLELES BY FREQ ${vcf}: Found: ${target_filterfp_vcf}"
        echo "SORT ALLELES BY FREQ ${vcf}: Creating dummy file..."
        touch ${sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    elif [ -f ${target_sorted_vcf} ]; then
        echo "SORT ALLELES BY FREQ ${vcf}: Found existing allele sorted VCF file"
        echo "SORT ALLELES BY FREQ ${vcf}: Found: ${target_sorted_vcf}"
        echo "SORT ALLELES BY FREQ ${vcf}: Creating symbolic link..."
        ln -s ${target_sorted_vcf} .
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    else
        echo "SORT ALLELES BY FREQ ${vcf}: Sorting alleles by frequency..."
        MajorAlleleToRef.py ${vcf} ${sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: Moving ${sorted_vcf} to ${target_folder_vcf}..."
        mkdir -p ${target_folder_freq}
        mv ${sorted_vcf} ${target_sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: Creating symbolic link..."
        ln -s ${target_sorted_vcf} .
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/7_s1_SortRefAltByFrequency_${vcf.baseName}.log
    cp .command.err ${dir_log}/7_s1_SortRefAltByFrequency_${vcf.baseName}.err
    """
}

process FilterPotentialFalsePositives {
    tag { vcf.baseName }

    input:
    path vcf

    output:
    path "*_fp.vcf", emit: filterfp_vcf

    script:
    target_folder_vcf = "${params.dir.output.vcf}"
    target_folder_freq = "${params.dir.output.freq}"

    filterfp_base = "${vcf.baseName}_fp"
    filterfp_vcf = "${filterfp_base}.vcf"
    target_filterfp_vcf = "${target_folder_vcf}/${filterfp_vcf}"

    filterdq_base = "${filterfp_base}_dq"
    filterdq_vcf = "${filterdq_base}.vcf"
    target_filterdq_vcf = "${target_folder_vcf}/${filterdq_vcf}"

    snp_base = "${filterdq_base}_snp"
    snp_vcf = "${snp_base}.vcf"
    target_snp_vcf = "${target_folder_vcf}/${snp_vcf}"

    indel_base = "${filterdq_base}_indel"
    indel_vcf = "${indel_base}.vcf"
    target_indel_vcf = "${target_folder_vcf}/${indel_vcf}"

    snp_freq_base = "${vcf.baseName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${vcf.baseName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"


    sensitivity = params.filterFalsePositives.sensitivity
    threshold = params.filterFalsePositives.sampleThreshold

    dir_log = "${params.dir.logs}/7_vcf2freq/s2_FilterPotentialFalsePositives"

    """
    set -e
    echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Filtering possible false positives..."
    if [ -f ${target_snp_freq_tsv} ] || [ -f ${target_indel_freq_tsv} ]; then
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found at least one of the existing freq files"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found: ${target_snp_freq_tsv} ${target_indel_freq_tsv}"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating dummy file..."
        touch ${filterfp_vcf}
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    elif [ -f ${target_snp_vcf} ] || [ -f ${target_indel_vcf} ]; then
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found at least one of the existing split VCF files"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found: ${target_snp_vcf} ${target_indel_vcf}"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating dummy file..."
        touch ${filterfp_vcf}
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    elif [ -f ${target_filterdq_vcf} ]; then
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found existing depth and quality filtered VCF file"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found: ${target_filterdq_vcf}"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating dummy file..."
        touch ${filterfp_vcf}
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    elif [ -f ${target_filterfp_vcf} ]; then
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found existing false positive filtered VCF file"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Found: ${target_filterfp_vcf}"
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating symbolic link..."
        ln -s ${target_filterfp_vcf} .
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    else
        TMP_FILE=\$(mktemp --suffix=.vcf)
        
        # Following code does the following:
        # 1. Converts multiallelic sites into biallelic sites.
        # 2. Filters out sites with 0 coverage.
        # 3. Filters out low coverage and low allele frequency sites.
        # 4. Replaces '*' with 'X' in the REF and ALT fields, for compatibility with bcftools norm.
        # 5. Normalizes the VCF file.
        # 6. Replaces back 'X' with '*' in the REF and ALT fields.
        # 7. Reorders alleles to match the reference.

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Filtering possible false positives..."
        filterFalsePositives.sh -v ${vcf} -t ${threshold} -s ${sensitivity} -b ${params.software.bcftools} > "\$TMP_FILE"

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Order might change after filtering, reordering alleles again..."
        MajorAlleleToRef.py "\$TMP_FILE" "${filterfp_vcf}"

        rm "\$TMP_FILE"

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Moving ${filterfp_vcf} to ${target_folder_vcf}..."
        mv ${filterfp_vcf} ${target_filterfp_vcf}
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating symbolic link..."
        ln -s ${target_filterfp_vcf} .

        if [ \$? -eq 0 ]; then
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Removing input VCF file: ${vcf}..."
            rm \$(realpath ${vcf})
        fi

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/7_s2_FilterFalsePositives_${vcf.baseName}.log
    cp .command.err ${dir_log}/7_s2_FilterFalsePositives_${vcf.baseName}.err
    """
}

process DepthAndQualityFilter {
    tag { vcf.baseName }

    input:
    path vcf

    output:
    path "*_dq.vcf", emit: filterdq_vcf

    script:
    target_folder_vcf = "${params.dir.output.vcf}"
    target_folder_freq = "${params.dir.output.freq}"

    filterdq_base = "${vcf.baseName}_dq"
    filterdq_vcf = "${filterdq_base}.vcf"
    filterdq_recode_vcf = "${filterdq_base}.recode.vcf"
    target_filterdq_vcf = "${target_folder_vcf}/${filterdq_vcf}"

    snp_base = "${filterdq_base}_snp"
    snp_vcf = "${snp_base}.vcf"
    target_snp_vcf = "${target_folder_vcf}/${snp_vcf}"

    indel_base = "${filterdq_base}_indel"
    indel_vcf = "${indel_base}.vcf"
    target_indel_vcf = "${target_folder_vcf}/${indel_vcf}"

    snp_freq_base = "${vcf.baseName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${vcf.baseName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${params.dir.logs}/7_vcf2freq/s3_DepthAndQualityFilter"

    """
    set -e
    echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Filtering VCF for depth and quality ${vcf.baseName}..."
    if [ -f ${target_snp_freq_tsv} ] || [ -f ${target_indel_freq_tsv} ]; then
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Found at least one of the existing freq files"
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Found: ${target_snp_freq_tsv} ${target_indel_freq_tsv}"
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Creating dummy file..."
        touch ${filterdq_vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: COMPLETED"
    elif [ -f ${target_snp_vcf} ] || [ -f ${target_indel_vcf} ]; then
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Found at least one of the existing split VCF files"
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Found: ${target_snp_vcf} ${target_indel_vcf}"
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Creating dummy file..."
        touch ${filterdq_vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: COMPLETED"
    elif [ -f ${target_filterdq_vcf} ]; then
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Found existing depth and quality filtered VCF file"
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Found: ${target_filterdq_vcf}"
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_filterdq_vcf} .
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: COMPLETED"
    else
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Processing SNPs..."
        ${params.software.vcftools} --vcf ${vcf} \
            --minDP ${params.vcftools.minDP} \
            --minQ ${params.vcftools.minQUAL} \
            --recode --recode-INFO-all \
            --out ${filterdq_base}

        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Renaming ${filterdq_recode_vcf} as ${filterdq_vcf} and moving to ${target_folder_vcf}"
        mv ${filterdq_recode_vcf} ${target_filterdq_vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_filterdq_vcf} .

        if [ \$? -eq 0 ]; then
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Removing input VCF file: ${vcf}..."
            rm \$(realpath ${vcf})
        fi

        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/7_s3_DepthAndQualityFilter_${vcf.baseName}.log
    cp .command.err ${dir_log}/7_s3_DepthAndQualityFilter_${vcf.baseName}.err
    """
}

process SplitSNPsAndINDELs {
    tag { vcf.baseName }

    input:
    file vcf

    output:
    path "*_snp.vcf", emit: snp_vcf
    path "*_indel.vcf", emit: indel_vcf

    script:
    target_folder_vcf = "${params.dir.output.vcf}"
    target_folder_freq = "${params.dir.output.freq}"

    snp_base = "${vcf.baseName}_snp"
    snp_vcf = "${snp_base}.vcf"
    snp_recode_vcf = "${snp_base}.recode.vcf"
    target_snp_vcf = "${target_folder_vcf}/${snp_vcf}"
   
    indel_base = "${vcf.baseName}_indel"
    indel_vcf = "${indel_base}.vcf"
    indel_recode_vcf = "${indel_base}.recode.vcf"
    target_indel_vcf = "${target_folder_vcf}/${indel_vcf}"
    
    snp_freq_base = "${vcf.baseName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${vcf.baseName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${params.dir.logs}/7_vcf2freq/s4_SplitSNPsAndINDELs"

    """
    set -e
    echo "SPLIT SNPS AND INDELS ${vcf}: Splitting ${vcf.baseName} to SNP and INDEL VCFs..."
    if [ -f ${target_snp_freq_tsv} ] || [ -f ${target_indel_freq_tsv} ]; then
        echo "SPLIT SNPS AND INDELS ${vcf}: Found both of the freq files"
        echo "SPLIT SNPS AND INDELS ${vcf}: Found: ${target_snp_freq_tsv} ${target_indel_freq_tsv}"
        echo "SPLIT SNPS AND INDELS ${vcf}: Creating dummy files..."
        touch ${snp_vcf}
        touch ${indel_vcf}
        echo "SPLIT SNPS AND INDELS ${vcf}: COMPLETED"
    elif [ -f ${target_snp_vcf} ] && [ -f ${target_indel_vcf} ]; then
        echo "SPLIT SNPS AND INDELS ${vcf}: Found both of the split VCF files"
        echo "SPLIT SNPS AND INDELS ${vcf}: Found: ${target_snp_vcf} ${target_indel_vcf}"
        echo "SPLIT SNPS AND INDELS ${vcf}: Creating symbolic links..."
        ln -s ${target_snp_vcf} .
        ln -s ${target_indel_vcf} .
        echo "SPLIT SNPS AND INDELS ${vcf}: COMPLETED"
    else 
        if [ -f ${target_snp_vcf} ]; then
            echo "SPLIT SNPS AND INDELS ${vcf}: Found existing SNP VCF file:"
            echo "SPLIT SNPS AND INDELS ${vcf}: Found: ${target_snp_vcf}"
            echo "SPLIT SNPS AND INDELS ${vcf}: Creating symbolic link..."
            ln -s ${target_snp_vcf} .
        else
            echo "SPLIT SNPS AND INDELS ${vcf}: Processing SNPs..."
            ${params.software.vcftools} --vcf ${vcf} \
            --remove-indels \
            --recode --recode-INFO-all \
            --out ${snp_base}

            echo "SPLIT SNPS AND INDELS ${vcf}: Renaming ${snp_recode_vcf} as ${snp_vcf} and moving to ${target_folder_vcf}"
            mv ${snp_recode_vcf} ${target_snp_vcf}
            echo "SPLIT SNPS AND INDELS ${vcf}: Creating symbolic link for SNP..."
            ln -s ${target_snp_vcf} .
        fi 

        if [ -f ${target_indel_vcf} ]; then
            echo "SPLIT SNPS AND INDELS ${vcf}: Found existing INDEL VCF file:"
            echo "SPLIT SNPS AND INDELS ${vcf}: Found: ${target_indel_vcf}"
            echo "SPLIT SNPS AND INDELS ${vcf}: Creating symbolic link..."
            ln -s ${target_indel_vcf} .
            echo "SPLIT SNPS AND INDELS ${vcf}: COMPLETED"
        else
            echo "SPLIT SNPS AND INDELS ${vcf}: Processing INDELS..."
            ${params.software.vcftools} --vcf ${vcf} \
            --keep-only-indels \
            --recode --recode-INFO-all \
            --out ${indel_base}

            echo "SPLIT SNPS AND INDELS ${vcf}: Renaming ${snp_recode_vcf} as ${snp_vcf} and moving to ${target_folder_vcf}"
            mv ${indel_recode_vcf} ${target_indel_vcf}
            echo "SPLIT SNPS AND INDELS ${vcf}: Creating symbolic link..."
            ln -s ${target_indel_vcf} .
            echo "SPLIT SNPS AND INDELS ${vcf}: COMPLETED"
        fi
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/7_s4_SplitSNPsAndINDELs_${vcf.baseName}.log
    cp .command.err ${dir_log}/7_s4_SplitSNPsAndINDELs_${vcf.baseName}.err
    """
}

process CalculateFrequencies {
    tag { vcf.baseName }

    input:
    path vcf

    output:
    path "${vcf.baseName.replace('_sort_fp_dq', '')}_freq.tsv", emit: frequencies

    script:
    target_folder_freq = "${params.dir.output.freq}"
    freq_base = "${vcf.baseName.replace('_sort_fp_dq', '')}"
    freq_file = "${freq_base}_freq.tsv"
    target_freq_file = "${params.dir.output.freq}/${freq_file}"
    dir_log = "${params.dir.logs}/7_vcf2freq/s5_CalculateFrequencies"

    """
    set -e

    echo "CALCULATE FREQUENCIES ${vcf}: Calculating Frequencies"
    if [ -f ${target_freq_file} ]; then
        echo "CALCULATE FREQUENCIES ${vcf}: Found existing frequency file."
        echo "CALCULATE FREQUENCIES ${vcf}: Found: ${target_freq_file}"
        echo "CALCULATE FREQUENCIES ${vcf}: Creating symbolic link..."
        ln -s ${freq_file} .
        echo "CALCULATE FREQUENCIES ${vcf}: COMPLETED"
    else
        echo "CALCULATE FREQUENCIES ${vcf}: Calculating frequencies for ${freq_file}..."
        createDepthFile.sh -v ${vcf} -b ${params.software.bcftools} | depth2freq.awk > ${freq_file}
        
        echo "CALCULATE FREQUENCIES ${vcf}: Moving ${freq_file} to ${target_folder_freq}..."
        mkdir -p ${target_folder_freq}
        mv ${freq_file} ${target_freq_file}
        echo "CALCULATE FREQUENCIES ${vcf}: Creating symbolic link..."
        ln -s ${target_freq_file} .
        
        if [ \$? -eq 0 ]; then
            echo "CALCULATE FREQUENCIES ${vcf}: Removing input VCF file: ${vcf}..."
            rm \$(realpath ${vcf})
        fi
        echo "CALCULATE FREQUENCIES ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/7_s5_CalculateFrequencies_${vcf.baseName}.log
    cp .command.err ${dir_log}/7_s5_CalculateFrequencies_${vcf.baseName}.err
    """
}

workflow VCF2Frequencies {
    take:
    vcf

    main:
    SortRefAltByFrequency(vcf)
    FilterPotentialFalsePositives(SortRefAltByFrequency.out.sorted_vcf)
    DepthAndQualityFilter(FilterPotentialFalsePositives.out.filterfp_vcf)

    prepared_vcfs = SplitSNPsAndINDELs(DepthAndQualityFilter.out.filterdq_vcf)
    all_vcfs = prepared_vcfs.snp_vcf
        .mix(prepared_vcfs.indel_vcf)
    
    CalculateFrequencies(all_vcfs)

    emit:
    frequencies = CalculateFrequencies.out.frequencies
}