process TrimReads {
    tag { pair_id }
    cpus { params.cores.trimTotal }

    input:
    tuple val(pair_id), path(read1), path(read2)
    file verify

    output:
    tuple val(pair_id),
        path("*_val_1.fq.gz"),
        path("*_val_2.fq.gz"), emit: trimmed_fastqs
    tuple val(pair_id),
        path("*_val_1_fastqc.zip"),
        path("*_val_2_fastqc.zip"), emit: fastqc_files

    script:
    target_folder_trimmed = "${params.dir.output.trimmed}/${pair_id}"
    target_folder_unpaired = "${params.dir.output.unpaired}/${pair_id}"
    target_folder_fastqc = "${params.dir.output.report.fastqc}/${pair_id}"
    target_folder_report_trim = "${params.dir.output.report.trim}/${pair_id}"

    clipped1 = "${pair_id}_R1_clipped.fq.gz"
    clipped2 = "${pair_id}_R2_clipped.fq.gz"
    target_file_clipped1 = "${target_folder_trimmed}/${clipped1}"
    target_file_clipped2 = "${target_folder_trimmed}/${clipped2}"

    val1 = "${pair_id}_val_1.fq.gz"
    val2 = "${pair_id}_val_2.fq.gz"
    target_file_val1 = "${target_folder_trimmed}/${val1}"
    target_file_val2 = "${target_folder_trimmed}/${val2}"

    fastqc1 = "${pair_id}_val_1_fastqc.zip"
    fastqc2 = "${pair_id}_val_2_fastqc.zip"
    target_file_fastqc1 = "${target_folder_fastqc}/${fastqc1}"
    target_file_fastqc2 = "${target_folder_fastqc}/${fastqc2}"

    dir_log = "${params.dir.logs}/2_trim_reads/s1_TrimReads/${pair_id}"

    // `cpus` reserves Trim Galore's full footprint, because --cores N actually runs N+4
    // threads (N workers + 2 decompressors + 1 batcher + 1 writer). Map back to the
    // worker count here. --cores 1 is the exception: it bypasses the pool entirely and
    // is genuinely single-threaded, so a 1-core reservation stays 1 worker.
    trim_cores = task.cpus > 4 ? task.cpus - 4 : 1

    """
    set -eo pipefail

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
        ${params.software.trim_galore} ${params.trim_galore.options} \\
            --cores ${trim_cores} --fastqc_args "-t ${task.cpus}" \\
            --basename ${pair_id} ${read1} ${read2}

        echo "TRIMMING READS ${pair_id}: Moving FASTQC reports and zips to ${target_folder_fastqc}"
        mkdir -p ${target_folder_fastqc}
        for f in *.zip *.html; do atomic_mv.sh "\$f" ${target_folder_fastqc}; done

        echo "TRIMMING READS ${pair_id}: Moving trim reports to ${target_folder_report_trim}"
        mkdir -p ${target_folder_report_trim}
        # Trim Galore 2.x writes both .txt and .json reports; keep whichever are present.
        for f in *_trimming_report.*; do atomic_mv.sh "\$f" ${target_folder_report_trim}; done

        echo "TRIMMING READS ${pair_id}: Moving trimmed reads to ${target_folder_trimmed}"
        mkdir -p ${target_folder_trimmed}
        for f in *_val_*; do atomic_mv.sh "\$f" ${target_folder_trimmed}; done

        echo "TRIMMING READS ${pair_id}: Moving unpaired reads to ${target_folder_unpaired}"
        mkdir -p ${target_folder_unpaired}
        for f in *_unpaired_*; do atomic_mv.sh "\$f" ${target_folder_unpaired}; done

        echo "TRIMMING READS ${pair_id}: Creating symbolic links..."
        ln -s ${target_file_val1} .
        ln -s ${target_file_val2} .
        ln -s ${target_file_fastqc1} .
        ln -s ${target_file_fastqc2} .
        echo "TRIMMING READS ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/2_TrimQcClip_s1_TrimReads_${pair_id}_nextflow.log
    """
}

process ClipReads {
    tag { pair_id }
    cpus { params.cores.cutadapt }
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
    set -eo pipefail

    # FastQC is a JVM program; give it the cores this task reserved.
    export _JAVA_OPTIONS="${params.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

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
        ${params.software.unzip} -o ${zip1}
        ${params.software.unzip} -o ${zip2}

        fqcDir1=\$(echo ${zip1} | sed 's/.zip//')
        fqcDir2=\$(echo ${zip2} | sed 's/.zip//')

        Data1=\$fqcDir1/fastqc_data.txt
        Data2=\$fqcDir2/fastqc_data.txt

        echo "CLIPPING READS ${pair_id}: Calculating clipping parameters..."

        # Print the first and last cycle whose A/T and G/C ratios are both within
        # tolerance. Cycles where T or C is zero are skipped: dividing by them aborts
        # awk mid-pipeline, which plain `set -e` does not catch, leaving the bounds
        # silently derived from a truncated table.
        clip_range() {
            sed -n '/>>Per base sequence content/,/>>END_MODULE/p' "\$1" |
            head -n -1 | tail -n +2 |
            awk -v upper=${at_gc_upper_limit} -v lower=${at_gc_lower_limit} '
                NR == 1 {
                    for (i = 1; i <= NF; i++) {
                        if (\$i == "A") a = i
                        if (\$i == "T") t = i
                        if (\$i == "G") g = i
                        if (\$i == "C") c = i
                    }
                    if (!a || !t || !g || !c) { bad_header = 1; exit 3 }
                    next
                }
                {
                    if (\$(t) + 0 == 0 || \$(c) + 0 == 0) next
                    at = \$(a) / \$(t)
                    gc = \$(g) / \$(c)
                    if (at >= lower && at <= upper && gc >= lower && gc <= upper) {
                        n = split(\$1, part, "-")
                        if (first == "") first = part[1]
                        last = (n > 1) ? part[2] : part[1]
                    }
                }
                END {
                    # `exit 3` above still runs END, so re-assert it here or the
                    # status below would overwrite the header diagnostic.
                    if (bad_header) exit 3
                    if (first == "") exit 4
                    print first, last
                }
            '
        }

        clip_range_failed() {
            echo "CLIPPING READS ${pair_id}: ERROR: no usable clip range in \$1" >&2
            echo "CLIPPING READS ${pair_id}: exit 3 = unexpected FastQC header; 4 = no cycle within at_gc_error (${params.cutadapt.at_gc_error})" >&2
            exit 1
        }

        range1=\$(clip_range "\$Data1") || clip_range_failed "\$Data1"
        range2=\$(clip_range "\$Data2") || clip_range_failed "\$Data2"

        Min1=\${range1%% *}; Max1=\${range1##* }
        Min2=\${range2%% *}; Max2=\${range2##* }

        for bound in "\$Min1" "\$Max1" "\$Min2" "\$Max2"; do
            case "\$bound" in
                ''|*[!0-9]*)
                    echo "CLIPPING READS ${pair_id}: ERROR: non-numeric clip bound '\$bound'" >&2
                    exit 1 ;;
            esac
        done

        # Clip the 5' end by the larger of the two lower bounds, then truncate to the
        # larger of the two usable spans. Unchanged from the original calculation.
        Clip5=\$Min1
        if [ "\$Min2" -gt "\$Clip5" ]; then Clip5=\$Min2; fi
        rL1=\$(( Max1 - Clip5 ))
        rL2=\$(( Max2 - Clip5 ))
        readLengthLimit=\$rL1
        if [ "\$rL2" -gt "\$readLengthLimit" ]; then readLengthLimit=\$rL2; fi

        if [ "\$readLengthLimit" -le 0 ]; then
            echo "CLIPPING READS ${pair_id}: ERROR: read length limit \$readLengthLimit is not positive (Clip5=\$Clip5 Max1=\$Max1 Max2=\$Max2)" >&2
            exit 1
        fi

        echo "CLIPPING READS ${pair_id}: usable cycles R1 \$Min1-\$Max1, R2 \$Min2-\$Max2"
        echo "CLIPPING READS ${pair_id}: 5' clip=\$Clip5, read length limit=\$readLengthLimit"

        echo "CLIPPING READS ${pair_id}: Clipping reads..." 
        ${params.software.cutadapt} ${params.cutadapt.options} --cores ${task.cpus} -u \$Clip5 -U \$Clip5 -l \$readLengthLimit \
            -o ${pair_id}_R1_clipped.fq.gz -p ${pair_id}_R2_clipped.fq.gz ${trimmed_read1} ${trimmed_read2}

        echo "CLIPPING READS ${pair_id}: QC on clipped reads..." 
        ${params.software.fastqc} ${params.fastqc.options} -t ${task.cpus} ${pair_id}_R1_clipped.fq.gz ${pair_id}_R2_clipped.fq.gz

        echo "CLIPPING READS ${pair_id}: Cleaning up..." 
        rm -r \$fqcDir1 \$fqcDir2

        echo "CLIPPING READS ${pair_id}: Moving clipped reads to ${target_folder_trimmed}" 
        mkdir -p ${target_folder_trimmed}
        for f in *_clipped.fq.gz; do atomic_mv.sh "\$f" ${target_folder_trimmed}; done

        echo "CLIPPING READS ${pair_id}: Moving FASTQC reports and zip files to ${target_folder_fastqc}" 
        mkdir -p ${target_folder_fastqc}
        for f in *_clipped_fastqc.zip *_clipped_fastqc.html; do atomic_mv.sh "\$f" ${target_folder_fastqc}; done

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
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/2_TrimQcClip_s2_ClipReads_${pair_id}_nextflow.log
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