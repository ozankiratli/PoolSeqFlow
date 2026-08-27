// The roots a skip check searches. Under sharing an artifact this step reads may have
// been produced by a variant with a coarser working root than its own, so the list comes
// from the divergence analysis rather than being spelled out here.
include { searchRoots } from './variants.nf'

// The (variant, sample) read channel.
//
// Takes the variant LIST rather than a channel because channel.fromFilePairs is a factory: it
// globs the filesystem while the DAG is being built and fixes N there, so it has to be handed
// a concrete parameter set. Reproducing its sample-id derivation by hand is exactly what step
// 0's CheckRGTagsFile must agree with, and having two implementations of that rule is how they
// come to disagree - so the factory is called once per variant instead.
//
// One glob per step-2 variant and not per run: `reads` is part of step 2's identity, so every
// member of a variant globs the same files by construction.
def readPairChannel(List variants) {
    def per = variants.collect { variant ->
        channel.fromFilePairs("${variant.reads}", checkIfExists: true)
            .map { id, files -> tuple(variant, id, files[0], files[1]) }
    }
    return per.size() == 1 ? per[0] : per.inject { a, b -> a.mix(b) }
}

process TrimReads {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }
    cpus { run.cores.trimTotal }

    input:
    // `verify` is step 0's completion for THIS run and nothing more - the script body never
    // names it. `val`, not `file`: it was staged and never read, and under multiRun every run
    // publishes a report of the same name.
    tuple val(run), val(pair_id), path(read1), path(read2), val(verify)

    output:
    tuple val(run), val(pair_id),
        path("*_val_1.fq.gz"),
        path("*_val_2.fq.gz"), emit: trimmed_fastqs
    tuple val(run), val(pair_id),
        path("*_val_1_fastqc.zip"),
        path("*_val_2_fastqc.zip"), emit: fastqc_files

    script:
    // The reads this step produces are read again - by ClipReads, then by step 3 - so they
    // are working data and stay on the working volume until alignment has finished with
    // them. Utilized/ and Output/ take the same relative path, which is what lets the skip
    // checks below ask find_artifact.sh which volume actually holds a file.
    search_roots = searchRoots(run)
    rel_trimmed = "${run.dir.subpath.trimmed}/${pair_id}"
    target_folder_trimmed = "${run.dir.utilized}/${rel_trimmed}"
    // The FastQC zips are read again too - ClipReads unzips them to work out the clipping
    // bounds - so they are working data by the same rule, small though they are. They are
    // promoted when ClipReads succeeds, which is a different gate from the reads above and
    // therefore a separate attachment point. The htmls that FastQC writes beside them have
    // no consumer at all, so those go straight to permanent storage and the two are split
    // across the roots here rather than moved together.
    rel_fastqc = "${run.dir.subpath.report.fastqc}/${pair_id}"
    target_folder_fastqc_work = "${run.dir.utilized}/${rel_fastqc}"
    // The rest is never read again - unpaired reads, the trim reports, the FastQC htmls -
    // so it goes straight to permanent storage and never enters Utilized.
    target_folder_unpaired = "${run.dir.output.unpaired}/${pair_id}"
    target_folder_fastqc = "${run.dir.output.report.fastqc}/${pair_id}"
    target_folder_report_trim = "${run.dir.output.report.trim}/${pair_id}"

    clipped1 = "${pair_id}_R1_clipped.fq.gz"
    clipped2 = "${pair_id}_R2_clipped.fq.gz"

    val1 = "${pair_id}_val_1.fq.gz"
    val2 = "${pair_id}_val_2.fq.gz"
    target_file_val1 = "${target_folder_trimmed}/${val1}"
    target_file_val2 = "${target_folder_trimmed}/${val2}"

    fastqc1 = "${pair_id}_val_1_fastqc.zip"
    fastqc2 = "${pair_id}_val_2_fastqc.zip"
    target_file_fastqc1 = "${target_folder_fastqc_work}/${fastqc1}"
    target_file_fastqc2 = "${target_folder_fastqc_work}/${fastqc2}"

    dir_log = "${run.dir.logs}/2_trim_reads/s1_TrimReads/${pair_id}"

    // `cpus` reserves Trim Galore's full footprint, because --cores N actually runs N+4
    // threads (N workers + 2 decompressors + 1 batcher + 1 writer). Map back to the
    // worker count here. --cores 1 is the exception: it bypasses the pool entirely and
    // is genuinely single-threaded, so a 1-core reservation stays 1 worker.
    trim_cores = task.cpus > 4 ? task.cpus - 4 : 1

    """
    set -eo pipefail

    # The clipped reads are the artifact that can be on either volume: still under
    # Utilized/ if alignment has not finished with them, in Output/ if it has. Asking one
    # directory would re-trim a sample whose reads an earlier run already promoted. The
    # roots are given permanent-first, so a residue copy cannot outrank a finished one.
    #
    # An absent artifact is find_artifact.sh's ordinary answer, not an error, so its exit
    # status is discarded here and emptiness is what the branch tests.
    clipped1_at=\$(find_artifact.sh "${rel_trimmed}/${clipped1}" ${search_roots} || true)
    clipped2_at=\$(find_artifact.sh "${rel_trimmed}/${clipped2}" ${search_roots} || true)
    fastqc1_at=\$(find_artifact.sh "${rel_fastqc}/${fastqc1}" ${search_roots} || true)
    fastqc2_at=\$(find_artifact.sh "${rel_fastqc}/${fastqc2}" ${search_roots} || true)

    echo "TRIMMING READS ${pair_id}: Trimming the reads..."
    if [ -n "\$clipped1_at" ] && [ -n "\$clipped2_at" ]; then
        echo "TRIMMING READS ${pair_id}: Found existing clipped files"
        echo "TRIMMING READS ${pair_id}: Found: \$clipped1_at \$clipped2_at"
        echo "TRIMMING READS ${pair_id}: Creating dummy files..."
        touch ${val1}
        touch ${val2}
        touch ${fastqc1}
        touch ${fastqc2}
        echo "TRIMMING READS ${pair_id}: COMPLETED"
    elif [ -n "\$fastqc1_at" ] && [ -n "\$fastqc2_at" ] && [ -f ${target_file_val1} ] && [ -f ${target_file_val2} ]; then
        # The *_val_* reads are looked for in one place on purpose: ClipReads deletes them
        # rather than promoting them, so the working volume is the only place they can ever
        # be. The zips it consumes are promoted, so those take both roots.
        echo "TRIMMING READS ${pair_id}: Found existing trimmed files and FASTQC zip files"
        echo "TRIMMING READS ${pair_id}: Found: ${target_file_val1} ${target_file_val2}"
        echo "TRIMMING READS ${pair_id}: Found: \$fastqc1_at \$fastqc2_at"
        echo "TRIMMING READS ${pair_id}: Creating symbolic links..."
        ln -s ${target_file_val1} .
        ln -s ${target_file_val2} .
        ln -s "\$fastqc1_at" .
        ln -s "\$fastqc2_at" .
        echo "TRIMMING READS ${pair_id}: COMPLETED"
    else
        echo "TRIMMING READS ${pair_id}: Trimming paired reads..."
        ${run.software.trim_galore} ${run.trim_galore.options} \\
            --cores ${trim_cores} --fastqc_args "-t ${task.cpus}" \\
            --basename ${pair_id} ${read1} ${read2}

        # Split by whether anything reads it again. The zips are ClipReads' input, so they
        # go to the working volume and are promoted once it has succeeded; the htmls are
        # for you to look at and go straight to permanent storage. They end up in the same
        # directory either way - Utilized/ mirrors Output/ - just not at the same time.
        echo "TRIMMING READS ${pair_id}: Moving FASTQC zips to ${target_folder_fastqc_work}"
        mkdir -p ${target_folder_fastqc_work}
        for f in *.zip; do atomic_mv.sh "\$f" ${target_folder_fastqc_work}/; done

        echo "TRIMMING READS ${pair_id}: Moving FASTQC reports to ${target_folder_fastqc}"
        mkdir -p ${target_folder_fastqc}
        for f in *.html; do atomic_mv.sh "\$f" ${target_folder_fastqc}/; done

        echo "TRIMMING READS ${pair_id}: Moving trim reports to ${target_folder_report_trim}"
        mkdir -p ${target_folder_report_trim}
        # Trim Galore 2.x writes both .txt and .json reports; keep whichever are present.
        for f in *_trimming_report.*; do atomic_mv.sh "\$f" ${target_folder_report_trim}/; done

        echo "TRIMMING READS ${pair_id}: Moving trimmed reads to ${target_folder_trimmed}"
        mkdir -p ${target_folder_trimmed}
        for f in *_val_*; do atomic_mv.sh "\$f" ${target_folder_trimmed}/; done

        echo "TRIMMING READS ${pair_id}: Moving unpaired reads to ${target_folder_unpaired}"
        mkdir -p ${target_folder_unpaired}
        for f in *_unpaired_*; do atomic_mv.sh "\$f" ${target_folder_unpaired}/; done

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
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }
    cpus { run.cores.cutadapt }
    errorStrategy 'retry'
    maxRetries 3

    input:
    tuple val(run), val(pair_id), path(trimmed_read1), path(trimmed_read2), path(zip1), path(zip2)

    output:
    tuple val(run), val(pair_id),
        path("*_R1_clipped.fq.gz"),
        path("*_R2_clipped.fq.gz"), emit: clipped_fastqs

    script:
    // Step 3 reads these, so they stay on the working volume and are promoted once
    // alignment has succeeded for this sample. See TrimReads above.
    search_roots = searchRoots(run)
    rel_trimmed = "${run.dir.subpath.trimmed}/${pair_id}"
    target_folder_trimmed = "${run.dir.utilized}/${rel_trimmed}"
    // The clipped FastQC zips and htmls this process produces have no consumer, so they go
    // straight to permanent storage. The *_val_* zips it CONSUMES are the other case: they
    // are on the working volume, staged in above, and promoted into this same directory
    // once this process succeeds.
    target_folder_fastqc = "${run.dir.output.report.fastqc}/${pair_id}"

    clipped1 = "${pair_id}_R1_clipped.fq.gz"
    clipped2 = "${pair_id}_R2_clipped.fq.gz"
    target_file_clipped1 = "${target_folder_trimmed}/${clipped1}"
    target_file_clipped2 = "${target_folder_trimmed}/${clipped2}"

    at_gc_upper_limit = 1 + run.cutadapt.at_gc_error
    at_gc_lower_limit = 1 - run.cutadapt.at_gc_error

    dir_log = "${run.dir.logs}/2_trim_reads/${pair_id}"

    """
    set -eo pipefail

    # FastQC is a JVM program; give it the cores this task reserved.
    export _JAVA_OPTIONS="${run.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

    # Either volume, for the same reason as TrimReads: promotion may already have moved
    # these to permanent storage. The link goes to wherever they actually are, not to
    # where this process would have written them.
    clipped1_at=\$(find_artifact.sh "${rel_trimmed}/${clipped1}" ${search_roots} || true)
    clipped2_at=\$(find_artifact.sh "${rel_trimmed}/${clipped2}" ${search_roots} || true)

    echo "CLIPPING READS ${pair_id}: Clipping the reads..."
    if [ -n "\$clipped1_at" ] && [ -n "\$clipped2_at" ]; then
        echo "CLIPPING READS ${pair_id}: Found existing clipped files"
        echo "CLIPPING READS ${pair_id}: Found \$clipped1_at \$clipped2_at"
        echo "CLIPPING READS ${pair_id}: Creating symbolic links..."
        ln -s "\$clipped1_at" .
        ln -s "\$clipped2_at" .
        echo "CLIPPING READS ${pair_id}: COMPLETED"
    else
        echo "CLIPPING READS ${pair_id}: Extracting FastQC data" 
        ${run.software.unzip} -o ${zip1}
        ${run.software.unzip} -o ${zip2}

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
            echo "CLIPPING READS ${pair_id}: exit 3 = unexpected FastQC header; 4 = no cycle within at_gc_error (${run.cutadapt.at_gc_error})" >&2
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

        # cutadapt applies -m (minimum length) AFTER -l (truncate to length), so a minimum
        # above the read length limit computed just above discards every pair - and cutadapt
        # still exits 0. That leaves empty clipped FASTQs which the existence-based skip
        # checks would then treat as a finished step for good.
        #
        # The value is read out of cutadapt.options rather than taken from
        # params.cutadapt.min_length, because that options line is user-edited and may carry
        # a literal instead. No -m at all - the default - means nothing to check.
        clip_min_length() {
            set -- ${run.cutadapt.options}
            while [ \$# -gt 0 ]; do
                case "\$1" in
                    -m|--minimum-length) printf '%s' "\${2-}"; return 0 ;;
                    --minimum-length=*)  printf '%s' "\${1#--minimum-length=}"; return 0 ;;
                    -m?*)                printf '%s' "\${1#-m}"; return 0 ;;
                esac
                shift
            done
        }

        minLength=\$(clip_min_length)
        if [ -n "\$minLength" ]; then
            # The paired form is "R1:R2". cutadapt's default --pair-filter=any drops the
            # pair when either mate is too short, so the larger of the two is what binds.
            minR1=\${minLength%%:*}
            minR2=\${minLength#*:}
            if [ "\$minR2" = "\$minLength" ]; then minR2=\$minR1; fi

            minValid=yes
            for bound in "\$minR1" "\$minR2"; do
                case "\$bound" in
                    ''|*[!0-9]*) minValid=no ;;
                esac
            done

            if [ "\$minValid" = no ]; then
                # Deliberately a warning, not an error: this check exists to catch one
                # specific trap, not to validate cutadapt's option grammar. An option string
                # it cannot parse must not be able to block an otherwise valid run.
                echo "CLIPPING READS ${pair_id}: WARNING: could not read a numeric minimum length from cutadapt.options; skipping the read length limit check" >&2
            else
                minBinding=\$minR1
                if [ "\$minR2" -gt "\$minBinding" ]; then minBinding=\$minR2; fi
                if [ "\$minBinding" -gt "\$readLengthLimit" ]; then
                    echo "CLIPPING READS ${pair_id}: ERROR: these settings would discard every read." >&2
                    echo "CLIPPING READS ${pair_id}: cutadapt.options sets a minimum length of \$minBinding, but the read length limit computed from this sample's FastQC report is \$readLengthLimit." >&2
                    echo "CLIPPING READS ${pair_id}: cutadapt truncates to \$readLengthLimit first and only then drops reads shorter than \$minBinding, so nothing would survive." >&2
                    echo "CLIPPING READS ${pair_id}: lower cutadapt.min_length to \$readLengthLimit or less, or comment the -m line in cutadapt.options back out." >&2
                    exit 1
                fi
            fi
        fi

        echo "CLIPPING READS ${pair_id}: Clipping reads..."
        ${run.software.cutadapt} ${run.cutadapt.options} --cores ${task.cpus} -u \$Clip5 -U \$Clip5 -l \$readLengthLimit \
            -o ${pair_id}_R1_clipped.fq.gz -p ${pair_id}_R2_clipped.fq.gz ${trimmed_read1} ${trimmed_read2}

        echo "CLIPPING READS ${pair_id}: QC on clipped reads..." 
        ${run.software.fastqc} ${run.fastqc.options} -t ${task.cpus} ${pair_id}_R1_clipped.fq.gz ${pair_id}_R2_clipped.fq.gz

        echo "CLIPPING READS ${pair_id}: Cleaning up..." 
        rm -r \$fqcDir1 \$fqcDir2

        echo "CLIPPING READS ${pair_id}: Moving clipped reads to ${target_folder_trimmed}" 
        mkdir -p ${target_folder_trimmed}
        for f in *_clipped.fq.gz; do atomic_mv.sh "\$f" ${target_folder_trimmed}/; done

        echo "CLIPPING READS ${pair_id}: Moving FASTQC reports and zip files to ${target_folder_fastqc}" 
        mkdir -p ${target_folder_fastqc}
        for f in *_clipped_fastqc.zip *_clipped_fastqc.html; do atomic_mv.sh "\$f" ${target_folder_fastqc}/; done

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
    reads     // [run, pair_id, read1, read2], from readPairChannel()
    verify    // [run, step 0 completion for that run]

    main:
    // combine, not join, and by the run rather than positionally. Step 0 emits ONE report
    // per run against N samples, so this is the broadcast a value channel used to do
    // implicitly - written out, because with N runs in flight there is no longer a single
    // value to broadcast.
    TrimReads(reads.combine(verify, by: 0))

    // by: [0,1] - the run AND the sample. Joining on the sample alone would pair one run's
    // reads with another run's zips whenever both trim a sample of the same name, which is
    // the ordinary case: multi-run's whole point is the same data under different settings.
    trimmed_and_qc = TrimReads.out.trimmed_fastqs.join(TrimReads.out.fastqc_files, by: [0, 1])
    ClipReads(trimmed_and_qc)

    emit:
    ClipReads.out.clipped_fastqs
}