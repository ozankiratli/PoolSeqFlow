// Step 7 turns the called VCF into frequency tables, through four intermediates.
//
// WHERE EACH FILE LIVES. Only Test.vcf coming in and the *_freq.tsv tables going out are
// results. Everything between them - _sort, _sort_fp, _sort_fp_dq and the two split VCFs -
// is consumed and deleted by the next process in the chain, so those never leave the
// working volume and never need a two-root lookup: there is only ever one place they can
// be. The frequency tables have no consumer at all and are written straight to permanent
// storage. Test.vcf itself is promoted, but by step 6, not here.
//
// THE SKIP CHECKS LOOK DOWNSTREAM, not at their own output. A process here asks "has
// anything later in the chain already been produced?" and if so writes a zero-byte
// placeholder for its own output rather than redoing work whose result has already been
// superseded. That is why SortRefAltByFrequency has five branches: it can be satisfied by
// any of four later artifacts. Those later artifacts are all either transient or terminal,
// which is what keeps every one of these checks single-rooted.

process SortRefAltByFrequency {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_sort.vcf"), emit: sorted_vcf

    script:
    // Transient - see the header: consumed and deleted by the next process, so it stays
    // on the working volume for its whole life.
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

    // The frequency-table names come from params.vcf.fileName, not from vcf.baseName. Every
    // other name in this file accumulates suffixes as the VCF moves down the chain
    // (Test -> _sort -> _fp -> _dq), but CalculateFrequencies strips them all back off before
    // writing, so the tables are always Test_snp_freq.tsv / Test_indel_freq.tsv. Building
    // these guards from vcf.baseName gave each process a different, suffixed name that no
    // step ever writes - so on a rerun of a finished project the guards never matched, the
    // vcftools passes ran again, and the split VCFs reappeared in Output/VCF after
    // CalculateFrequencies had already consumed them.
    snp_freq_base = "${run.vcf.fileName}_snp_freq"
    snp_freq_tsv = "${snp_freq_base}.tsv"
    target_snp_freq_tsv = "${target_folder_freq}/${snp_freq_tsv}"

    indel_freq_base = "${run.vcf.fileName}_indel_freq"
    indel_freq_tsv = "${indel_freq_base}.tsv"
    target_indel_freq_tsv = "${target_folder_freq}/${indel_freq_tsv}"

    dir_log = "${run.dir.logs}/7_vcf2freq/s1_SortRefAltByFrequency"

    """
    set -eo pipefail

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

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/7_s1_SortRefAltByFrequency_${vcf.baseName}_nextflow.log
    """
}

process FilterPotentialFalsePositives {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_fp.vcf"), emit: filterfp_vcf

    script:
    // Transient - see the header: consumed and deleted by the next process, so it stays
    // on the working volume for its whole life.
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

    dir_log = "${run.dir.logs}/7_vcf2freq/s2_FilterPotentialFalsePositives"

    """
    set -eo pipefail
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
        # In the task directory, not system /tmp, and removed by the trap however the
        # task ends. The plain rm further down only ran on the success path.
        TMP_FILE=\$(mktemp -p . --suffix=.vcf)
        trap 'rm -f "\$TMP_FILE"' EXIT
        
        # Following code does the following:
        # 1. Converts multiallelic sites into biallelic sites.
        # 2. Filters out sites with 0 coverage.
        # 3. Filters out low coverage and low allele frequency sites.
        # 4. Replaces '*' with 'X' in the REF and ALT fields, for compatibility with bcftools norm.
        # 5. Normalizes the VCF file.
        # 6. Replaces back 'X' with '*' in the REF and ALT fields.
        # 7. Reorders alleles to match the reference.

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Filtering possible false positives..."
        filterFalsePositives.sh -v ${vcf} -t ${threshold} -s ${sensitivity} -b ${run.software.bcftools} > "\$TMP_FILE"

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Order might change after filtering, reordering alleles again..."
        MajorAlleleToRef.py "\$TMP_FILE" "${filterfp_vcf}"

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Moving ${filterfp_vcf} to ${target_folder_vcf}..."
        atomic_mv.sh ${filterfp_vcf} ${target_filterfp_vcf}
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Creating symbolic link..."
        ln -s ${target_filterfp_vcf} .

        # No status check here. `set -eo pipefail` has already aborted the task if the
        # move above failed, so reaching this line means the replacement is in place.
        # This was guarded by `[ \$? -eq 0 ]`, which read the exit status of the `ln -s`
        # on the line above rather than of the move it was written to check.
        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})

        echo "FILTER POTENTIAL FALSE POSITIVES ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/7_s2_FilterFalsePositives_${vcf.baseName}_nextflow.log
    """
}

process DepthAndQualityFilter {
    tag { run.runId ? "${run.runId}:${vcf.baseName}" : vcf.baseName }

    input:
    tuple val(run), path(vcf)

    output:
    tuple val(run), path("*_dq.vcf"), emit: filterdq_vcf

    script:
    // Transient - see the header: consumed and deleted by the next process, so it stays
    // on the working volume for its whole life.
    target_folder_vcf = "${run.dir.utilized}/${run.dir.subpath.vcf}"
    target_folder_freq = "${run.dir.output.freq}"

    // Depth-filtered intermediate. Stays in the task directory and is never moved to
    // permanent storage - only the quality-filtered result is kept. Named _dp so it
    // cannot be picked up by the process's own "*_dq.vcf" output glob.
    filterdp_vcf = "${vcf.baseName}_dp.vcf"

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

    dir_log = "${run.dir.logs}/7_vcf2freq/s3_DepthAndQualityFilter"

    """
    set -eo pipefail
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
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Depth Filtering VCF..."
        ${run.software.bcftools} view -e "FMT/DP<${run.vcffilter.minDP}" -Ov -o ${filterdp_vcf} ${vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Quality Filtering VCF..."
        ${run.software.vcftools} --vcf ${filterdp_vcf} \
            --minQ ${run.vcffilter.minQUAL} \
            --recode --recode-INFO-all \
            --out ${filterdq_base}

        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Renaming ${filterdq_recode_vcf} as ${filterdq_vcf} and moving to ${target_folder_vcf}"
        atomic_mv.sh ${filterdq_recode_vcf} ${target_filterdq_vcf}
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Creating symbolic link..."
        ln -s ${target_filterdq_vcf} .

        # No status check here. `set -eo pipefail` has already aborted the task if the
        # move above failed, so reaching this line means the replacement is in place.
        # This was guarded by `[ \$? -eq 0 ]`, which read the exit status of the `ln -s`
        # on the line above rather than of the move it was written to check.
        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})

        echo "DEPTH AND QUALITY FILTER VCF ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/7_s3_DepthAndQualityFilter_${vcf.baseName}_nextflow.log
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
    // Transient - see the header: consumed and deleted by the next process, so it stays
    // on the working volume for its whole life.
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

    dir_log = "${run.dir.logs}/7_vcf2freq/s4_SplitSNPsAndINDELs"

    """
    set -eo pipefail
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

        # Removed here and not a line earlier: this process is the one place in the chain
        # that reads its input TWICE - once to pull out the SNPs, once for the INDELs - so
        # it can only go after both passes. That is why the deletion was missing from this
        # process alone while its three siblings had it, and why _sort_fp_dq.vcf was left
        # sitting in Output/VCF beside the real results on every run since 1.0.
        echo "SPLIT SNPS AND INDELS ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/7_s4_SplitSNPsAndINDELs_${vcf.baseName}_nextflow.log
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
    dir_log = "${run.dir.logs}/7_vcf2freq/s5_CalculateFrequencies"

    """
    set -eo pipefail

    echo "CALCULATE FREQUENCIES ${vcf}: Calculating Frequencies"
    if [ -f ${target_freq_file} ]; then
        echo "CALCULATE FREQUENCIES ${vcf}: Found existing frequency file."
        echo "CALCULATE FREQUENCIES ${vcf}: Found: ${target_freq_file}"
        echo "CALCULATE FREQUENCIES ${vcf}: Creating symbolic link..."
        ln -s ${target_freq_file} .
        echo "CALCULATE FREQUENCIES ${vcf}: COMPLETED"
    else
        echo "CALCULATE FREQUENCIES ${vcf}: Calculating frequencies for ${freq_file}..."
        createDepthFile.sh -v ${vcf} -b ${run.software.bcftools} | depth2freq.awk > ${freq_file}
        
        echo "CALCULATE FREQUENCIES ${vcf}: Moving ${freq_file} to ${target_folder_freq}..."
        mkdir -p ${target_folder_freq}
        atomic_mv.sh ${freq_file} ${target_freq_file}
        echo "CALCULATE FREQUENCIES ${vcf}: Creating symbolic link..."
        ln -s ${target_freq_file} .

        # No status check here. `set -eo pipefail` has already aborted the task if the
        # move above failed, so reaching this line means the replacement is in place.
        # This was guarded by `[ \$? -eq 0 ]`, which read the exit status of the `ln -s`
        # on the line above rather than of the move it was written to check.
        echo "CALCULATE FREQUENCIES ${vcf}: Removing input VCF file: ${vcf}..."
        rm \$(realpath ${vcf})
        echo "CALCULATE FREQUENCIES ${vcf}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/7_s5_CalculateFrequencies_${vcf.baseName}_nextflow.log
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
    // Both halves carry their own run, so mixing them keeps each frequency table attached to
    // the run that produced it - two tasks per run rather than two per invocation.
    all_vcfs = prepared_vcfs.snp_vcf
        .mix(prepared_vcfs.indel_vcf)

    CalculateFrequencies(all_vcfs)

    emit:
    CalculateFrequencies.out.frequencies
}