process Align {
    tag { pair_id }
    cpus { params.cores.bwa }

    input:
    tuple val(pair_id), path(read1), path(read2)
    path bwa_index

    output:
    tuple val(pair_id), path("*_aligned.bam"), emit: aligned_bam

    script:
    reference = params.reference
    aligned_bam_file = "${pair_id}_aligned.bam"
    // Read again by SortCleanBam, so this is working data: it is written to the working
    // volume and promoted to Output/Aligned/ once cleaning has succeeded for this sample.
    // Unlike Trimmed/, this directory is flat - one BAM per sample, no per-sample folder -
    // so the relative path carries the file name rather than a directory.
    rel_aligned = "${params.dir.subpath.aligned}"
    target_folder = "${params.dir.utilized}/${rel_aligned}"
    target_file = "${target_folder}/${aligned_bam_file}"
    dir_log = "${params.dir.logs}/3_align/${pair_id}"

    """
    set -eo pipefail

    # Either volume: still here if cleaning has not finished with it, in permanent storage
    # if it has. Permanent root first, so a residue copy cannot outrank a promoted one. An
    # absent artifact is the ordinary answer on a first run, not an error, so the exit
    # status is discarded and emptiness is what the branch tests.
    aligned_at=\$(find_artifact.sh "${rel_aligned}/${aligned_bam_file}" "${params.dir.outputs}" "${params.dir.utilized}" || true)

    echo "ALIGNING ${pair_id}: Aligning the reads to the reference..."

    if [ -n "\$aligned_at" ]; then
        echo "ALIGNING ${pair_id}: Found existing BAM file"
        echo "ALIGNING ${pair_id}: Found: \$aligned_at"
        echo "ALIGNING ${pair_id}: Creating symbolic link..."
        ln -s "\$aligned_at" .
        echo "ALIGNING ${pair_id}: COMPLETED"
    else
        echo "ALIGNING ${pair_id}: Aligning reads and converting to BAM..."
        ${params.software.bwa} mem ${params.bwa.options} -t ${task.cpus} ${reference} ${read1} ${read2} | \
        ${params.software.samtools} view -b -@ ${params.cores.samtools} -o ${aligned_bam_file}
        echo "ALIGNING ${pair_id}: Moving ${aligned_bam_file} to ${target_folder}"
        mkdir -p ${target_folder}
        atomic_mv.sh ${aligned_bam_file} ${target_file}
        echo "ALIGNING ${pair_id}: Creating symbolic link..."
        ln -s ${target_file} .
        echo "ALIGNING ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/3_AlignReads_Align_${pair_id}_nextflow.log
    """
}

workflow AlignReads {
    take:
    reads
    bwa_index

    main:
    Align(reads, bwa_index)

    emit:
    Align.out.aligned_bam
}