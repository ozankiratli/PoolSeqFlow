// Step 7 turns the called VCF into frequency tables, through four intermediates, each consumed
// and deleted by the next process.
//
// THE SKIP CHECKS LOOK DOWNSTREAM: a process asks whether anything later in the chain already
// exists, and writes a zero-byte placeholder if so.

include { poolSizeArgument } from './metadata.nf'

process SortRefAltByFrequency {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_sort.vcf"), emit: sorted_vcf

    script:
    // Transient: consumed and deleted by the next process, so it never leaves the working volume.
    target_folder_vcf = "${run.dir.utilized}/${run.dir.subpath.vcf}"
    target_folder_freq = "${run.dir.output.freq}"

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

    // From vcf.fileName, NOT vcf.baseName: CalculateFrequencies strips the accumulated suffixes
    // before writing.
    snp_freq_base = "${run.vcf.fileName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${run.vcf.fileName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${run.dir.logs}/7_vcf2freq"

    """
    set -eo pipefail
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
    } >> ${dir_log}/7_s1_SortRefAltByFrequency_${vcf.baseName}_nextflow.log
    # Written as it happens rather than copied at the end: a task killed by a signal leaves what
    # it had reached. stdbuf keeps tee line-buffered, so the last line is not held in a buffer.
    exec > >(stdbuf -oL tee -a ${dir_log}/7_s1_SortRefAltByFrequency_${vcf.baseName}_nextflow.log) 2>&1

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
        mkdir -p ${target_folder_vcf}
        atomic_mv.sh ${sorted_vcf} ${target_sorted_vcf}
        echo "SORT ALLELES BY FREQ ${vcf}: Creating symbolic link..."
        ln -s ${target_sorted_vcf} .
        echo "SORT ALLELES BY FREQ ${vcf}: COMPLETED"
    fi

    """
}

process FilterPotentialFalsePositives {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_fp.vcf"), emit: filterfp_vcf

    script:
    // Transient: consumed and deleted by the next process, so it never leaves the working volume.
    target_folder_vcf = "${run.dir.utilized}/${run.dir.subpath.vcf}"
    target_folder_freq = "${run.dir.output.freq}"

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

    snp_freq_base = "${run.vcf.fileName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${run.vcf.fileName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    sensitivity = run.filterFalsePositives.sensitivity
    threshold = run.filterFalsePositives.sampleThreshold

    // EVERY pool, named, including those taking the global poolSize.
    pool_sizes = poolSizeArgument(run)
    ploidy = run.ploidy

    dir_log = "${run.dir.logs}/7_vcf2freq"

    """
    set -eo pipefail
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
    } >> ${dir_log}/7_s2_FilterFalsePositives_${vcf.baseName}_nextflow.log
    # Written as it happens rather than copied at the end: a task killed by a signal leaves what
    # it had reached. stdbuf keeps tee line-buffered, so the last line is not held in a buffer.
    exec > >(stdbuf -oL tee -a ${dir_log}/7_s2_FilterFalsePositives_${vcf.baseName}_nextflow.log) 2>&1

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
        # In the task directory, not system /tmp, and removed by the trap however the task ends.
        TMP_FILE=\$(mktemp -p . --suffix=.vcf)
        trap 'rm -f "\$TMP_FILE"' EXIT
        

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Filtering possible false positives..."
        filterFalsePositives.sh -v ${vcf} -t ${threshold} -s ${sensitivity} \\
            -p "${pool_sizes}" -d ${ploidy} -b ${run.software.bcftools} > "\$TMP_FILE"

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Order might change after filtering, reordering alleles again..."
        MajorAlleleToRef.py "\$TMP_FILE" "${filterfp_vcf}"

        # In the else branch only: the skip branches above write a zero-byte placeholder on
        # purpose, and a size test would refuse those instead.
        surviving=\$(grep -vc '^#' ${filterfp_vcf} || true)
        if [ "\$surviving" -eq 0 ]; then
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: ERROR: no site survived the cross-sample filter."
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Every called site was removed, so there is"
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: nothing left to publish a frequency for."
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: This run required an allele in ${threshold} of the"
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: samples at a frequency above ${sensitivity}."
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: filterFalsePositives.sampleThreshold and poolSize"
            echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: are what move those. Nothing was published."
            exit 1
        fi

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Moving ${filterfp_vcf} to ${target_folder_vcf}..."
        atomic_mv.sh ${filterfp_vcf} ${target_filterfp_vcf}
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating symbolic link..."
        ln -s ${target_filterfp_vcf} .

        # No status check: `set -eo pipefail` would already have aborted a failed move.
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    fi

    """
}

process DepthAndQualityFilter {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_dq.vcf"), emit: filterdq_vcf

    script:
    // Transient: consumed and deleted by the next process, so it never leaves the working volume.
    target_folder_vcf = "${run.dir.utilized}/${run.dir.subpath.vcf}"
    target_folder_freq = "${run.dir.output.freq}"

    // Depth-filtered intermediate, kept in the task directory. Named _dp so the process's own
    // "*_dq.vcf" output glob cannot pick it up.
    filterdp_vcf = "${vcf.baseName}_dp.vcf"

    // bcftools excludes the whole SITE when the expression holds for any one sample, so this
    // is an intersection across samples: every published site has every sample at or above
    // minDP. The zero term is redundant whenever minDP is 1 or more.
    depth_exclude = run.vcffilter.dropZeroDepth
        ? "FMT/DP<${run.vcffilter.minDP} || FMT/DP==0"
        : "FMT/DP<${run.vcffilter.minDP}"

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

    snp_freq_base = "${run.vcf.fileName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${run.vcf.fileName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${run.dir.logs}/7_vcf2freq"

    """
    set -eo pipefail
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
    } >> ${dir_log}/7_s3_DepthAndQualityFilter_${vcf.baseName}_nextflow.log
    # Written as it happens rather than copied at the end: a task killed by a signal leaves what
    # it had reached. stdbuf keeps tee line-buffered, so the last line is not held in a buffer.
    exec > >(stdbuf -oL tee -a ${dir_log}/7_s3_DepthAndQualityFilter_${vcf.baseName}_nextflow.log) 2>&1

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
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Depth Filtering VCF, excluding ${depth_exclude}"
        ${run.software.bcftools} view -e "${depth_exclude}" -Ov -o ${filterdp_vcf} ${vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Quality Filtering VCF..."
        ${run.software.vcftools} --vcf ${filterdp_vcf} \
            --minQ ${run.vcffilter.minQUAL} \
            --recode --recode-INFO-all \
            --out ${filterdq_base}

        # In the else branch only: the skip branches above write a zero-byte placeholder on
        # purpose, and a size test would refuse those instead.
        surviving=\$(grep -vc '^#' ${filterdq_recode_vcf} || true)
        if [ "\$surviving" -eq 0 ]; then
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: ERROR: no site survived the depth and quality filter."
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Both are applied to the whole SITE: one sample under"
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: the depth removes it for every sample, so the"
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: shallowest library sets the threshold for the cohort."
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: This run used minDP ${run.vcffilter.minDP}, minQUAL ${run.vcffilter.minQUAL},"
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: dropZeroDepth ${run.vcffilter.dropZeroDepth}. Check the weakest sample in"
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Output/Reports/Coverage before raising any of them."
            echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Nothing was published, so this costs nothing already made."
            exit 1
        fi

        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Renaming ${filterdq_recode_vcf} as ${filterdq_vcf} and moving to ${target_folder_vcf}"
        atomic_mv.sh ${filterdq_recode_vcf} ${target_filterdq_vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_filterdq_vcf} .

        # No status check: `set -eo pipefail` would already have aborted a failed move.
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})

        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: COMPLETED"
    fi

    """
}

process SplitSNPsAndINDELs {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_snp.vcf"), emit: snp_vcf
    tuple val(run), path("*_indel.vcf"), emit: indel_vcf

    script:
    // Transient: consumed and deleted by the next process, so it never leaves the working volume.
    target_folder_vcf = "${run.dir.utilized}/${run.dir.subpath.vcf}"
    target_folder_freq = "${run.dir.output.freq}"

    snp_base = "${vcf.baseName}_snp"
    snp_vcf = "${snp_base}.vcf"
    snp_recode_vcf = "${snp_base}.recode.vcf"
    target_snp_vcf = "${target_folder_vcf}/${snp_vcf}"
   
    indel_base = "${vcf.baseName}_indel"
    indel_vcf = "${indel_base}.vcf"
    indel_recode_vcf = "${indel_base}.recode.vcf"
    target_indel_vcf = "${target_folder_vcf}/${indel_vcf}"
    
    snp_freq_base = "${run.vcf.fileName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${run.vcf.fileName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${run.dir.logs}/7_vcf2freq"

    """
    set -eo pipefail
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
    } >> ${dir_log}/7_s4_SplitSNPsAndINDELs_${vcf.baseName}_nextflow.log
    # Written as it happens rather than copied at the end: a task killed by a signal leaves what
    # it had reached. stdbuf keeps tee line-buffered, so the last line is not held in a buffer.
    exec > >(stdbuf -oL tee -a ${dir_log}/7_s4_SplitSNPsAndINDELs_${vcf.baseName}_nextflow.log) 2>&1
    echo "SPLIT SNPS AND INDELS ${vcf}: Splitting ${vcf.baseName} to SNP and INDEL VCFs..."
    # AND, where the three processes above use OR: this one has TWO outputs, and calculating a
    # missing table needs a real split VCF, not the dummy this branch emits.
    if [ -f ${target_snp_freq_tsv} ] && [ -f ${target_indel_freq_tsv} ]; then
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
            ${run.software.vcftools} --vcf ${vcf} \
            --remove-indels \
            --recode --recode-INFO-all \
            --out ${snp_base}

            echo "SPLIT SNPS AND INDELS ${vcf}: Renaming ${snp_recode_vcf} as ${snp_vcf} and moving to ${target_folder_vcf}"
            atomic_mv.sh ${snp_recode_vcf} ${target_snp_vcf}
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
            ${run.software.vcftools} --vcf ${vcf} \
            --keep-only-indels \
            --recode --recode-INFO-all \
            --out ${indel_base}

            echo "SPLIT SNPS AND INDELS ${vcf}: Renaming ${indel_recode_vcf} as ${indel_vcf} and moving to ${target_folder_vcf}"
            atomic_mv.sh ${indel_recode_vcf} ${target_indel_vcf}
            echo "SPLIT SNPS AND INDELS ${vcf}: Creating symbolic link..."
            ln -s ${target_indel_vcf} .
            echo "SPLIT SNPS AND INDELS ${vcf}: COMPLETED"
        fi

        # After both passes, not a line earlier: this process is the one place in the chain that
        # reads its input twice, once for the SNPs and once for the INDELs.
        echo "SPLIT SNPS AND INDELS ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})
    fi

    """
}

process CalculateFrequencies {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("${vcf.baseName.replace('_sort_fp_dq', '')}_freq.tsv"), emit: frequencies

    script:
    target_folder_freq = "${run.dir.output.freq}"
    freq_base = "${vcf.baseName.replace('_sort_fp_dq', '')}"
    freq_file = "${freq_base}_freq.tsv"
    target_freq_file = "${run.dir.output.freq}/${freq_file}"
    // The read counts the frequencies are computed from. Published by absolute path, like step
    // 5's reports: nothing in this pipeline consumes it.
    depth_file = "${freq_base}_depth.tsv"
    target_depth_file = "${run.dir.output.freq}/${depth_file}"
    dir_log = "${run.dir.logs}/7_vcf2freq"

    """
    set -eo pipefail
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
    } >> ${dir_log}/7_s5_CalculateFrequencies_${vcf.baseName}_nextflow.log
    # Written as it happens rather than copied at the end: a task killed by a signal leaves what
    # it had reached. stdbuf keeps tee line-buffered, so the last line is not held in a buffer.
    exec > >(stdbuf -oL tee -a ${dir_log}/7_s5_CalculateFrequencies_${vcf.baseName}_nextflow.log) 2>&1

    echo "CALCULATE FREQUENCIES ${vcf}: Calculating Frequencies"
    if [ -f ${target_freq_file} ] && [ -f ${target_depth_file} ]; then
        echo "CALCULATE FREQUENCIES ${vcf}: Found existing frequency file."
        echo "CALCULATE FREQUENCIES ${vcf}: Found: ${target_freq_file}"
        echo "CALCULATE FREQUENCIES ${vcf}: Creating symbolic link..."
        ln -s ${target_freq_file} .
        echo "CALCULATE FREQUENCIES ${vcf}: COMPLETED"
    else
        echo "CALCULATE FREQUENCIES ${vcf}: Calculating frequencies for ${freq_file}..."
        createDepthFile.sh -v ${vcf} -b ${run.software.bcftools} > ${depth_file}
        depth2freq.awk < ${depth_file} > ${freq_file}

        echo "CALCULATE FREQUENCIES ${vcf}: Moving ${freq_file} to ${target_folder_freq}..."
        mkdir -p ${target_folder_freq}
        atomic_mv.sh ${depth_file} ${target_depth_file}
        atomic_mv.sh ${freq_file} ${target_freq_file}
        echo "CALCULATE FREQUENCIES ${vcf}: Creating symbolic link..."
        ln -s ${target_freq_file} .

        # No status check: `set -eo pipefail` would already have aborted a failed move.
        echo "CALCULATE FREQUENCIES ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})
        echo "CALCULATE FREQUENCIES ${vcf}: COMPLETED"
    fi

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
    // Both halves carry their own run, so this is two tasks per run, not two per invocation.
    all_vcfs = prepared_vcfs.snp_vcf
        .mix(prepared_vcfs.indel_vcf)

    CalculateFrequencies(all_vcfs)

    emit:
    CalculateFrequencies.out.frequencies
}