process Align {
    tag { pair_id }

    input:
    tuple val(pair_id), path(read1), path(read2)
    path bwa_index

    output:
    tuple val(pair_id), path("*_aligned.bam"), emit: aligned_bam

    script:
    reference = params.reference
    aligned_bam_file = "${pair_id}_aligned.bam"
    target_folder = "${params.dir.output.aligned}"
    target_file = "${target_folder}/${aligned_bam_file}"
    dir_log = "${params.dir.logs}/3_align/${pair_id}"

    """
    set -e

    echo "ALIGNING ${pair_id}: Aligning the reads to the reference..."
    
    # Check if file already exists in output directory
    if [ -f "${target_file}" ]; then
        echo "ALIGNING ${pair_id}: Found existing BAM file"
        echo "ALIGNING ${pair_id}: Found: ${target_file}"
        echo "ALIGNING ${pair_id}: Creating symbolic link..."
        ln -s "${target_file}" .
        echo "ALIGNING ${pair_id}: COMPLETED"
    else
        echo "ALIGNING ${pair_id}: Aligning reads and converting to BAM..."
        ${params.software.bwa} mem ${params.bwa.options} ${reference} ${read1} ${read2} | \
        ${params.software.samtools} view -b -@ ${params.samtools.threads} -o ${aligned_bam_file}
        echo "ALIGNING ${pair_id}: Moving ${aligned_bam_file} to ${target_folder}"
        mkdir -p ${target_folder}
        mv ${aligned_bam_file} ${target_folder}
        echo "ALIGNING ${pair_id}: Creating symbolic link..."
        ln -s ${target_file} .
        echo "ALIGNING ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/3_AlignReads_Align_${pair_id}.log
    cp .command.err ${dir_log}/3_AlignReads_Align_${pair_id}.err
    """
}

workflow AlignReads {
    take:
    reads
    bwa_index

    main:
    Align(reads, bwa_index)

    emit:
    aligned_bam = Align.out.aligned_bam
}