// The roots a skip check searches, from the divergence analysis.
include { searchRoots } from './variants.nf'
// The read group line, assembled from the parsed metadata.
include { rgTagString } from './metadata.nf'

process SortCleanBam {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }
    cpus { run.cores.samtools + 1 }

    input:
    tuple val(run), val(pair_id), path(input_bam)

    output:
    tuple val(run), val(pair_id), path("*_ready.bam"), emit: ready_bam
    tuple val(run), val(pair_id), path("*_ready.bam.bai"), emit: ready_bai

    script:
    target_bam = "${pair_id}_ready.bam"
    target_bai = "${pair_id}_ready.bam.bai"
    // Read by BOTH step 5 and step 6, so these stay on the working volume until each has
    // finished. Flat, like Aligned/: the sample is in the file name, not a folder.
    search_roots = searchRoots(run)
    rel_ready = "${run.dir.subpath.ready}"
    target_folder_ready = "${run.dir.utilized}/${rel_ready}"
    target_bam_ready = "${target_folder_ready}/${target_bam}"
    target_bai_ready = "${target_folder_ready}/${target_bai}"
    // Rendered while the DAG is built; the shell below never sees the CSV.
    rg_string = rgTagString(run, "${pair_id}".toString())

    dir_log = "${run.dir.logs}/4_clean"

    """
    set -eo pipefail

    # BOTH files, on either volume, looked up independently. The skip branch links the index too
    # and `ln -s` does not check its target exists, so testing only the BAM leaves a dangling
    # link that still satisfies the `*_ready.bam.bai` output glob.
    bam_at=\$(find_artifact.sh "${rel_ready}/${target_bam}" ${search_roots} || true)
    bai_at=\$(find_artifact.sh "${rel_ready}/${target_bai}" ${search_roots} || true)

    echo "SORT AND CLEAN BAM ${pair_id}: Sorting and Cleaning BAM file..."
    if [ -n "\$bam_at" ] && [ -n "\$bai_at" ]; then
        echo "SORT AND CLEAN BAM ${pair_id}: Found existing BAM file and index"
        echo "SORT AND CLEAN BAM ${pair_id}: Found: \$bam_at"
        echo "SORT AND CLEAN BAM ${pair_id}: Found: \$bai_at"
        echo "SORT AND CLEAN BAM ${pair_id}: Marking step as completed!"
        echo "SORT AND CLEAN BAM ${pair_id}: Creating symbolic links..."
        ln -s "\$bam_at" .
        ln -s "\$bai_at" .
        echo "SORT AND CLEAN BAM ${pair_id}: COMPLETED"
    else
        echo "SORT AND CLEAN BAM ${pair_id}: Processing BAM file..."

        rg_string="${rg_string}"
        echo "SORT AND CLEAN BAM ${pair_id}: RG Tags string is: \$rg_string"

        echo "SORT AND CLEAN BAM ${pair_id}: Pipeline to clean BAM:"
        echo "SORT AND CLEAN BAM ${pair_id}: 1. Sort by name (required for fixmate)"
        echo "SORT AND CLEAN BAM ${pair_id}: 2. Fix mate information and add mate score tags"
        echo "SORT AND CLEAN BAM ${pair_id}: 3. Sort by coordinate (required for markdup)"
        echo "SORT AND CLEAN BAM ${pair_id}: 4. Mark and remove duplicates"
        echo "SORT AND CLEAN BAM ${pair_id}: 5. Add read groups"
        echo "SORT AND CLEAN BAM ${pair_id}: 6. Filter out problematic reads"
        echo "SORT AND CLEAN BAM ${pair_id}: 7. Index final BAM"

        echo "SORT AND CLEAN BAM ${pair_id}: Sorting and cleaning ${input_bam} with samtools"
        ${run.software.samtools} sort \
            -n \
            -@ ${task.cpus - 1} \
            ${input_bam} | \
        ${run.software.samtools} fixmate \
            -@ \$(( ${run.threads} - 1 )) \
            -m \
            - \
            - | \
        ${run.software.samtools} sort \
            -@ ${task.cpus - 1} \
            - | \
        ${run.software.samtools} markdup \
            -@ ${task.cpus - 1} \
            -r \
            -s \
            - \
            - | \
        ${run.software.samtools} addreplacerg \
            -@ ${task.cpus - 1} \
            -r "\$rg_string" \
            - \
            - | \
        ${run.software.samtools} view \
            -@ ${task.cpus - 1} \
            -F ${run.samtools.filter} \
            -f ${run.samtools.required} \
            -q ${run.samtools.mapq} \
            -b \
            -o ${target_bam} \
            -

        echo "SORT AND CLEAN BAM ${pair_id}: Indexing ${target_bam}..."
        ${run.software.samtools} index ${target_bam}

        echo "SORT AND CLEAN BAM ${pair_id}: Moving ${target_bam} and ${target_bai} to ${target_folder_ready}..."
        mkdir -p ${target_folder_ready}
        atomic_mv.sh ${target_bam} ${target_bam_ready}
        atomic_mv.sh ${target_bai} ${target_bai_ready}
        echo "SORT AND CLEAN BAM ${pair_id}: Creating symbolic links..."
        ln -s ${target_bam_ready} .
        ln -s ${target_bai_ready} .
        echo "SORT AND CLEAN BAM ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/4_SortCleanBam_${pair_id}_nextflow.log
    """
}

workflow SortCleanBams {
    take:
    aligned_bam

    main:
    ready_data = SortCleanBam(aligned_bam)

    emit:
    ready_bam = ready_data.ready_bam
    ready_bai = ready_data.ready_bai
}
