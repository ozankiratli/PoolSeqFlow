process SortCleanBam {
    tag { pair_id }
    cpus { params.cores.samtools + 1 }

    input:
    tuple val(pair_id), path(input_bam)

    output:
    tuple val(pair_id), path("*_ready.bam"), emit: ready_bam
    tuple val(pair_id), path("*_ready.bam.bai"), emit: ready_bai

    script:
    target_bam = "${pair_id}_ready.bam"
    target_bai = "${pair_id}_ready.bam.bai"
    // Read by BOTH step 5 and step 6, so these stay on the working volume until each of
    // those has finished with them - the first artifact here with more than one consumer.
    // Flat, like Aligned/: the sample is in the file name, not a folder.
    rel_ready = "${params.dir.subpath.ready}"
    target_folder_ready = "${params.dir.utilized}/${rel_ready}"
    target_bam_ready = "${target_folder_ready}/${target_bam}"
    target_bai_ready = "${target_folder_ready}/${target_bai}"
    rgTagsFile = params.rgTagsPath

    dir_log = "${params.dir.logs}/4_clean/${pair_id}"

    """
    set -eo pipefail

    # BOTH files, and on either volume.
    #
    # Both, because the skip branch links the index as well and `ln -s` does not check that
    # its target exists - so testing only the BAM produced a dangling link that still
    # satisfied this process's `*_ready.bam.bai` output glob, and the run carried on with an
    # index that was not there. Reachable whenever indexing was interrupted.
    #
    # Either volume, because these are promoted once steps 5 and 6 have both finished with
    # them. The pair is looked up independently rather than assumed to travel together, so
    # a half-finished promotion is caught here instead of downstream.
    bam_at=\$(find_artifact.sh "${rel_ready}/${target_bam}" "${params.dir.outputs}" "${params.dir.utilized}" || true)
    bai_at=\$(find_artifact.sh "${rel_ready}/${target_bai}" "${params.dir.outputs}" "${params.dir.utilized}" || true)

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

        echo "SORT AND CLEAN BAM ${pair_id}: Preparing RG Tags string..."
        echo "SORT AND CLEAN BAM ${pair_id}: Getting RG Tags from CSV..."
        header=\$(head -n 1 ${rgTagsFile})
        id_col=\$(echo "\$header" | tr ',' '\\n' | grep -n "^ID\$" | cut -d: -f1)
        tags=\$(awk -F ',' '\$'"\$id_col"'=="'${pair_id}'" {print \$0}' ${rgTagsFile})

        echo "SORT AND CLEAN BAM ${pair_id}: Getting RG Tags from CSV..."
        IFS=',' read -ra HEADER <<< "\$header"
        IFS=',' read -ra VALUES <<< "\$tags"
        rg_string="@RG"
        for i in "\${!HEADER[@]}"; do
            if [ -n "\${VALUES[i]}" ]; then
                rg_string="\$rg_string\\t\${HEADER[i]}:\${VALUES[i]}"
            fi
        done
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
        ${params.software.samtools} sort \
            -n \
            -@ ${task.cpus - 1} \
            ${input_bam} | \
        ${params.software.samtools} fixmate \
            -@ \$(( ${params.threads} - 1 )) \
            -m \
            - \
            - | \
        ${params.software.samtools} sort \
            -@ ${task.cpus - 1} \
            - | \
        ${params.software.samtools} markdup \
            -@ ${task.cpus - 1} \
            -r \
            -s \
            - \
            - | \
        ${params.software.samtools} addreplacerg \
            -@ ${task.cpus - 1} \
            -r "\$rg_string" \
            - \
            - | \
        ${params.software.samtools} view \
            -@ ${task.cpus - 1} \
            -F ${params.samtools.filter} \
            -f ${params.samtools.required} \
            -q ${params.samtools.mapq} \
            -b \
            -o ${target_bam} \
            -

        echo "SORT AND CLEAN BAM ${pair_id}: Indexing ${target_bam}..."
        ${params.software.samtools} index ${target_bam}

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
