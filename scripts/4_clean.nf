process SortCleanBam {
    tag { pair_id }

    input:
    tuple val(pair_id), path(input_bam)

    output:
    tuple val(pair_id), path("*_ready.bam"), emit: ready_bam
    tuple val(pair_id), path("*_ready.bam.bai"), emit: ready_bai

    script:
    target_bam = "${pair_id}_ready.bam"
    target_bai = "${pair_id}_ready.bam.bai"
    target_folder_ready = "${params.dir.output.ready}"
    target_bam_ready = "${target_folder_ready}/${target_bam}"
    target_bai_ready = "${target_folder_ready}/${target_bai}"
    rgTagsFile = params.rgTagsPath

    dir_log = "${params.dir.logs}/4_clean/${pair_id}"

    """
    set -e

    echo "SORT AND CLEAN BAM ${pair_id}: Sorting and Cleaning BAM file..."
    if [ -f ${target_bam_ready} ]; then
        echo "SORT AND CLEAN BAM ${pair_id}: Found existing BAM file"
        echo "SORT AND CLEAN BAM ${pair_id}: Found: ${target_bam_ready}"
        echo "SORT AND CLEAN BAM ${pair_id}: Marking step as completed!"
        echo "SORT AND CLEAN BAM ${pair_id}: Creating symbolic links..."
        ln -s ${target_bam_ready} .
        ln -s ${target_bai_ready} .
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
            -@ ${params.samtools.threads} \
            ${input_bam} | \
        ${params.software.samtools} fixmate \
            -@ \$(( ${params.threads} - 1 )) \
            -m \
            - \
            - | \
        ${params.software.samtools} sort \
            -@ ${params.samtools.threads} \
            - | \
        ${params.software.samtools} markdup \
            -@ ${params.samtools.threads} \
            -r \
            -s \
            - \
            - | \
        ${params.software.samtools} addreplacerg \
            -@ ${params.samtools.threads} \
            -r "\$rg_string" \
            - \
            - | \
        ${params.software.samtools} view \
            -@ ${params.samtools.threads} \
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
        mv ${target_bam} ${target_bam_ready}
        mv ${target_bai} ${target_bai_ready}
        echo "SORT AND CLEAN BAM ${pair_id}: Creating symbolic links..."
        ln -s ${target_bam_ready} .
        ln -s ${target_bai_ready} .
        echo "SORT AND CLEAN BAM ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/4_SortCleanBam_${pair_id}.log
    cp .command.err ${dir_log}/4_SortCleanBam_${pair_id}.err
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
