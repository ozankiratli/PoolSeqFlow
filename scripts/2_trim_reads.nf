process TrimReads {
    tag { pair_id }

    input:
    tuple val(pair_id), path(read1), path(read2)
    file verify

    output:
    tuple val(pair_id), 
        path("*_R1_val_1.fq.gz"), 
        path("*_R2_val_2.fq.gz"), emit: trimmed_fastqs
    tuple val(pair_id),
        path("*_R1_*.zip"),
        path("*_R2_*.zip"), emit: fastqc_files

    script:
    target_folder_trimmed = "${params.dir.output.trimmed}/${pair_id}"
    target_folder_unpaired = "${params.dir.output.unpaired}/${pair_id}"
    target_folder_fastqc = "${params.dir.output.report.fastqc}/${pair_id}"
    target_folder_report_trim = "${params.dir.output.report.trim}/${pair_id}"

    clipped1 = "${pair_id}_R1_clipped.fq.gz"
    clipped2 = "${pair_id}_R2_clipped.fq.gz"
    target_file_clipped1 = "${target_folder_trimmed}/${clipped1}"
    target_file_clipped2 = "${target_folder_trimmed}/${clipped2}"

    val1 = "${pair_id}_R1_val_1.fq.gz"
    val2 = "${pair_id}_R2_val_2.fq.gz"
    target_file_val1 = "${target_folder_trimmed}/${val1}"
    target_file_val2 = "${target_folder_trimmed}/${val2}"

    fastqc1 = "${pair_id}_R1_val_1_fastqc.zip"
    fastqc2 = "${pair_id}_R2_val_2_fastqc.zip"
    target_file_fastqc1 = "${target_folder_fastqc}/${fastqc1}"
    target_file_fastqc2 = "${target_folder_fastqc}/${fastqc2}"

    dir_log = "${params.dir.logs}/2_trim_reads/s1_TrimReads/${pair_id}"

    """
    set -e

    export _JAVA_OPTIONS="${params.java.options}"

    echo "TRIMMING READS ${pair_id}: Trimming the reads..."
    if [ -f ${target_file_clipped1} ] && [ -f ${target_file_clipped2} ]; then
        echo "TRIMMING READS ${pair_id}: Found existing clipped files"
        echo "TRIMMING READS ${pair_id}: Found: ${target_file_clipped1} ${target_file_clipped2}"
        echo "TRIMMING READS ${pair_id}: Creating dummy files..."
        touch ${val1}
        touch ${val2}
        touch ${fastqc1}
        touch ${fastqc2}
        echo "TRIMMING READS ${pair_id}: COMPLETED"
    elif [ -f ${target_file_fastqc1} ] && [ -f ${target_file_fastqc2} ] && [ -f ${target_file_val1} ] && [ -f ${target_file_val2} ]; then
        echo "TRIMMING READS ${pair_id}: Found existing trimmed files and FASTQC zip files"
        echo "TRIMMING READS ${pair_id}: Found: ${target_file_clipped1} ${target_file_clipped2}"
        echo "TRIMMING READS ${pair_id}: Creating symbolic links..."
        ln -s ${target_file_val1} .
        ln -s ${target_file_val2} .
        ln -s ${target_file_fastqc1} .
        ln -s ${target_file_fastqc2} .
        echo "TRIMMING READS ${pair_id}: COMPLETED"
    else
        echo "TRIMMING READS ${pair_id}: Trimming paired reads..."
        ${params.software.trim_galore} ${params.trim_galore.options} ${read1} ${read2}

        echo "TRIMMING READS ${pair_id}: Moving FASTQC reports and zips to ${target_folder_fastqc}"
        mkdir -p ${target_folder_fastqc}
        mv *.zip ${target_folder_fastqc}
        mv *.html ${target_folder_fastqc}

        echo "TRIMMING READS ${pair_id}: Moving trim reports to ${target_folder_report_trim}"
        mkdir -p ${target_folder_report_trim}
        mv *_trimming_report.txt ${target_folder_report_trim}

        echo "TRIMMING READS ${pair_id}: Moving trimmed reads to ${target_folder_trimmed}"
        mkdir -p ${target_folder_trimmed}
        mv *_val_* ${target_folder_trimmed}

        echo "TRIMMING READS ${pair_id}: Moving unpaired reads to ${target_folder_unpaired}"
        mkdir -p ${target_folder_unpaired}
        mv *_unpaired_* ${target_folder_unpaired}

        echo "TRIMMING READS ${pair_id}: Creating symbolic links..."
        ln -s ${target_file_val1} .
        ln -s ${target_file_val2} .
        ln -s ${target_file_fastqc1} .
        ln -s ${target_file_fastqc2} .
        echo "TRIMMING READS ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/2_TrimQcClip_s1_TrimReads_${pair_id}.log
    cp .command.err ${dir_log}/2_TrimQcClip_s1_TrimReads_${pair_id}.err
    """
}

process ClipReads {
    tag { pair_id }
    errorStrategy 'retry'
    maxRetries 3

    input:
    tuple val(pair_id), path(trimmed_read1), path(trimmed_read2), path(zip1), path(zip2)

    output:
    tuple val(pair_id),
        path("*_R1_clipped.fq.gz"),
        path("*_R2_clipped.fq.gz"), emit: clipped_fastqs

    script:
    target_folder_trimmed = "${params.dir.output.trimmed}/${pair_id}"
    target_folder_fastqc = "${params.dir.output.report.fastqc}/${pair_id}"

    clipped1 = "${pair_id}_R1_clipped.fq.gz"
    clipped2 = "${pair_id}_R2_clipped.fq.gz"
    target_file_clipped1 = "${target_folder_trimmed}/${clipped1}"
    target_file_clipped2 = "${target_folder_trimmed}/${clipped2}"

    at_gc_upper_limit = 1 + params.cutadapt.at_gc_error
    at_gc_lower_limit = 1 - params.cutadapt.at_gc_error

    dir_log = "${params.dir.logs}/2_trim_reads/${pair_id}"

    """
    set -e

    # Set Java options
    export _JAVA_OPTIONS="${params.java.options}"

    echo "CLIPPING READS ${pair_id}: Clipping the reads..."
    if [ -f ${target_file_clipped1} ] && [ -f ${target_file_clipped2} ]; then
        echo "CLIPPING READS ${pair_id}: Found existing clipped files"
        echo "CLIPPING READS ${pair_id}: Found ${target_file_clipped1} ${target_file_clipped2}"
        echo "CLIPPING READS ${pair_id}: Creating symbolic links..."
        ln -s ${target_file_clipped1} .
        ln -s ${target_file_clipped2} .
        echo "CLIPPING READS ${pair_id}: COMPLETED"
    else
        echo "CLIPPING READS ${pair_id}: Extracting FastQC data" 
        unzip -o ${zip1}
        unzip -o ${zip2}

        fqcDir1=\$(echo ${zip1} | sed 's/.zip//')
        fqcDir2=\$(echo ${zip2} | sed 's/.zip//')

        Data1=\$fqcDir1/fastqc_data.txt
        Data2=\$fqcDir2/fastqc_data.txt

        echo "CLIPPING READS ${pair_id}: Calculating clipping parameters..."
        Max1=\$(sed -n '/>>Per base sequence content/,/>>END_MODULE/p' \$Data1 | head -n -1 | tail -n +2 | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} 'NR==1 {for (i=1; i<=NF; i++) {if (\$i == "A") a_col=i; if (\$i == "T") t_col=i; if (\$i == "G") g_col=i; if (\$i == "C") c_col=i}} NR>1 {at_ratio=\$(a_col)/\$(t_col); gc_ratio=\$(g_col)/\$(c_col); print \$1, at_ratio, gc_ratio}' | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} '\$2 >= lower && \$2 <= upper && \$3 >= lower && \$3 <= upper {print \$1}' | sed 's/-/ /g' | tr '\n' ' ' | awk '{print \$NF}')
        Min1=\$(sed -n '/>>Per base sequence content/,/>>END_MODULE/p' \$Data1 | head -n -1 | tail -n +2 | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} 'NR==1 {for (i=1; i<=NF; i++) {if (\$i == "A") a_col=i; if (\$i == "T") t_col=i; if (\$i == "G") g_col=i; if (\$i == "C") c_col=i}} NR>1 {at_ratio=\$(a_col)/\$(t_col); gc_ratio=\$(g_col)/\$(c_col); print \$1, at_ratio, gc_ratio}' | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} '\$2 >= lower && \$2 <= upper && \$3 >= lower && \$3 <= upper {print \$1}' | sed 's/-/ /g' | tr '\n' ' ' | awk '{print \$1}')
        Max2=\$(sed -n '/>>Per base sequence content/,/>>END_MODULE/p' \$Data2 | head -n -1 | tail -n +2 | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} 'NR==1 {for (i=1; i<=NF; i++) {if (\$i == "A") a_col=i; if (\$i == "T") t_col=i; if (\$i == "G") g_col=i; if (\$i == "C") c_col=i}} NR>1 {at_ratio=\$(a_col)/\$(t_col); gc_ratio=\$(g_col)/\$(c_col); print \$1, at_ratio, gc_ratio}' | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} '\$2 >= lower && \$2 <= upper && \$3 >= lower && \$3 <= upper {print \$1}' | sed 's/-/ /g' | tr '\n' ' ' | awk '{print \$NF}')
        Min2=\$(sed -n '/>>Per base sequence content/,/>>END_MODULE/p' \$Data2 | head -n -1 | tail -n +2 | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} 'NR==1 {for (i=1; i<=NF; i++) {if (\$i == "A") a_col=i; if (\$i == "T") t_col=i; if (\$i == "G") g_col=i; if (\$i == "C") c_col=i}} NR>1 {at_ratio=\$(a_col)/\$(t_col); gc_ratio=\$(g_col)/\$(c_col); print \$1, at_ratio, gc_ratio}' | awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} '\$2 >= lower && \$2 <= upper && \$3 >= lower && \$3 <= upper {print \$1}' | sed 's/-/ /g' | tr '\n' ' ' | awk '{print \$1}')

        Clip5=\$(echo \$Min1 \$Min2 | tr ' ' '\n' | sort -n | tail -1)
        rL1=\$(( \$Max1 - \$Clip5 ))
        rL2=\$(( \$Max2 - \$Clip5 ))
        readLengthLimit=\$(echo \$rL1 \$rL2 | tr ' ' '\n' | sort -n | tail -1)

        echo "CLIPPING READS ${pair_id}: Clipping reads..." 
        ${params.software.cutadapt} ${params.cutadapt.options} -u \$Clip5 -U \$Clip5 -l \$readLengthLimit \
            -o ${pair_id}_R1_clipped.fq.gz -p ${pair_id}_R2_clipped.fq.gz ${trimmed_read1} ${trimmed_read2}

        echo "CLIPPING READS ${pair_id}: QC on clipped reads..." 
        ${params.software.fastqc} ${params.fastqc.options} ${pair_id}_R1_clipped.fq.gz ${pair_id}_R2_clipped.fq.gz

        echo "CLIPPING READS ${pair_id}: Cleaning up..." 
        rm -r \$fqcDir1 \$fqcDir2

        echo "CLIPPING READS ${pair_id}: Moving clipped reads to ${target_folder_trimmed}" 
        mkdir -p ${target_folder_trimmed}
        mv *_clipped.fq.gz ${target_folder_trimmed}

        echo "CLIPPING READS ${pair_id}: Moving FASTQC reports and zip files to ${target_folder_fastqc}" 
        mkdir -p ${target_folder_fastqc}
        mv *_clipped_fastqc.zip ${target_folder_fastqc}
        mv *_clipped_fastqc.html ${target_folder_fastqc}

        echo "CLIPPING READS ${pair_id}: Creating symbolic links..."
        ln -s ${target_file_clipped1} .
        ln -s ${target_file_clipped2} .

        echo "CLIPPING READS ${pair_id}: Removing trimmed reads..."
        rm \$(realpath ${trimmed_read1})
        rm \$(realpath ${trimmed_read2})
        echo "CLIPPING READS ${pair_id}: COMPLETED"
    fi
    echo "Clipping completed for ${pair_id}!"

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/2_TrimQcClip_s2_ClipReads_${pair_id}.log
    cp .command.err ${dir_log}/2_TrimQcClip_s2_ClipReads_${pair_id}.err
    """
}

workflow TrimQcClip{
    take:
    verify

    main:
    rawFiles = Channel.fromFilePairs("${params.reads}", checkIfExists: true)
        .map { id, files -> tuple(id, files[0], files[1]) }

    TrimReads(rawFiles,verify)
    trimmed_and_qc = TrimReads.out.trimmed_fastqs.join(TrimReads.out.fastqc_files)
    ClipReads(trimmed_and_qc)

    emit:
    clipped_fastqs = ClipReads.out.clipped_fastqs
}