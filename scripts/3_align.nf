// The roots a skip check searches. Under sharing an artifact this step reads may have
// been produced by a variant with a coarser working root than its own, so the list comes
// from the divergence analysis rather than being spelled out here.
include { searchRoots } from './variants.nf'

process Align {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }
    cpus { run.cores.bwa }

    input:
    // The index arrives in the same tuple as the reads rather than as a second input. Two
    // separate inputs are matched positionally, which was safe only while the index rode a
    // value channel and broadcast to every sample; with N runs in flight there are N indices
    // and positional matching would hand a sample the wrong one.
    tuple val(run), val(pair_id), path(read1), path(read2), path(bwa_index)

    output:
    tuple val(run), val(pair_id), path("*_aligned.bam"), emit: aligned_bam

    script:
    reference = run.reference
    aligned_bam_file = "${pair_id}_aligned.bam"
    // Read again by SortCleanBam, so this is working data: it is written to the working
    // volume and promoted to Output/Aligned/ once cleaning has succeeded for this sample.
    // Unlike Trimmed/, this directory is flat - one BAM per sample, no per-sample folder -
    // so the relative path carries the file name rather than a directory.
    search_roots = searchRoots(run)
    rel_aligned = "${run.dir.subpath.aligned}"
    target_folder = "${run.dir.utilized}/${rel_aligned}"
    target_file = "${target_folder}/${aligned_bam_file}"
    dir_log = "${run.dir.logs}/3_align"

    """
    set -eo pipefail

    # Either volume: still here if cleaning has not finished with it, in permanent storage
    # if it has. Permanent root first, so a residue copy cannot outrank a promoted one. An
    # absent artifact is the ordinary answer on a first run, not an error, so the exit
    # status is discarded and emptiness is what the branch tests.
    aligned_at=\$(find_artifact.sh "${rel_aligned}/${aligned_bam_file}" ${search_roots} || true)

    echo "ALIGNING ${pair_id}: Aligning the reads to the reference..."

    if [ -n "\$aligned_at" ]; then
        echo "ALIGNING ${pair_id}: Found existing BAM file"
        echo "ALIGNING ${pair_id}: Found: \$aligned_at"
        echo "ALIGNING ${pair_id}: Creating symbolic link..."
        ln -s "\$aligned_at" .
        echo "ALIGNING ${pair_id}: COMPLETED"
    else
        echo "ALIGNING ${pair_id}: Aligning reads and converting to BAM..."
        ${run.software.bwa} mem ${run.bwa.options} -t ${task.cpus} ${reference} ${read1} ${read2} | \
        ${run.software.samtools} view -b -@ ${run.cores.samtools} -o ${aligned_bam_file}
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
    reads        // [run, pair_id, clipped1, clipped2]
    bwa_index    // [run, index files] - one per run, not one per sample

    main:
    // One index per run, combined against that run's samples. `combine(by: 0)` is the
    // cartesian product WITHIN a key, which is exactly what the implicit value channel used
    // to do; `join` would be wrong here, because it matches one-to-one and would leave every
    // sample after the first without an index.
    Align(reads.combine(bwa_index, by: 0))

    emit:
    Align.out.aligned_bam
}