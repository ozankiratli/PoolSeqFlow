// Promotion: moving an artifact from the working volume to permanent storage once nothing needs
// it any more.

nextflow.enable.dsl=2

// Which files a completed step releases, and where they go.
//
// A stage with no row yet moves nothing; a stage MISSING from the table is an error. `subpath` is
// relative to both roots, which is what makes promotion a move between two spellings of one path.
def promotionRow(Map run, String stage, String key) {
    def table = [
        // Released when the sample's alignment succeeds. No *_val_* reads: ClipReads deletes
        // them outright.
        'trimmed reads': [ subpath : "${run.dir.subpath.trimmed}/${key}",
                           patterns: ['*_clipped.fq.gz'] ],

        // A row of their own: gated on ClipReads, not alignment. No htmls; nothing reads those.
        'fastqc zips'  : [ subpath : "${run.dir.subpath.report.fastqc}/${key}",
                           patterns: ['*_val_1_fastqc.zip', '*_val_2_fastqc.zip'] ],

        // A flat directory, so the key selects the FILE rather than the folder.
        'alignments'   : [ subpath : "${run.dir.subpath.aligned}",
                           patterns: ["${key}_aligned.bam"] ],

        // Two consumers, steps 5 and 6, so the gate is assembled at the call site. The index
        // travels with its BAM: promoting one alone leaves a BAM that looks complete.
        'ready bams'   : [ subpath : "${run.dir.subpath.ready}",
                           patterns: ["${key}_ready.bam", "${key}_ready.bam.bai"] ],

        // Two consumers again, the second conditional: step 7 always, step 8 only when annotate
        // is on. No key - one VCF for the whole run.
        'called vcf'   : [ subpath : "${run.dir.subpath.vcf}",
                           patterns: ["${run.vcf.fileName}.vcf"] ],
    ]

    if (!table.containsKey(stage)) {
        throw new IllegalArgumentException(
            "Completion: no promotion row for stage '${stage}'. Either add one to " +
            "promotionRow() in scripts/9_completion.nf, or correct the stage name at " +
            "the call site in poolseqflow.nf.")
    }
    return table[stage]
}

// What a promotion task calls itself, in its tag and in its log: the runs the artifact belongs
// to, not the variant's lead member.
def promotionLabel(Map run, String stage, String key) {
    def what = key ? "${stage} ${key}" : stage
    def who = (run.members ?: [run.runId]).findAll { member -> member != null }.join('+')
    return who ? "${who}:${what}" : "${what}"
}

// The move itself. One task per (producing variant, stage, key), never one per member: the
// members of a variant share one artifact, so a task each would move the same file N times.
// `key` is the sample, and is empty for an artifact belonging to the cohort.
process PromoteArtifacts {
    tag { promotionLabel(run, stage, key) }

    input:
    // Separate: a literal at the call site, so it rides a value channel. The run travels WITH
    // the key.
    val stage
    tuple val(run), val(key)

    output:
    tuple val(run), val(stage), emit: done

    script:
    row = promotionRow(run, stage, key)
    label = promotionLabel(run, stage, key)
    // One writer per log file: these tasks run concurrently. The run is not in the slug;
    // dir.logs is already per run.
    slug = key ? "${stage}_${key}" : stage
    slug = slug.replaceAll(/[^A-Za-z0-9]+/, '_')
    dir_log = "${run.dir.logs}/9_completion"
    log_file = "${dir_log}/9_Completion_s1_PromoteArtifacts_${slug}_nextflow.log"

    src = row ? "${run.dir.utilized}/${row.subpath}" : ''
    dst = row ? "${run.dir.outputs}/${row.subpath}" : ''
    // Quoted, so the loops below iterate over the patterns rather than over what they match in
    // the task directory.
    patterns = row ? row.patterns.collect { p -> "'${p}'" }.join(' ') : ''

    if (row == null)
        """
        echo "PROMOTING ${label}: finished; nothing is promoted for this stage yet"

        mkdir -p ${dir_log}
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${log_file}
        """
    else
        """
        set -eo pipefail

        echo "PROMOTING ${label}: ${src}"
        echo "PROMOTING ${label}:   -> ${dst}"

        moved=0
        if [ -d "${src}" ]; then
            mkdir -p "${dst}"
            for pattern in ${patterns}; do
                for f in "${src}"/\$pattern; do
                    if [ -e "\$f" ]; then
                        atomic_mv.sh "\$f" "${dst}/"
                        moved=\$(( moved + 1 ))
                    fi
                done
            done
        fi

        # The source must be GONE, not merely copied.
        left=0
        for pattern in ${patterns}; do
            for f in "${src}"/\$pattern; do
                if [ -e "\$f" ]; then
                    echo "PROMOTING ${label}: still present after promotion: \$f" >&2
                    left=\$(( left + 1 ))
                fi
            done
        done
        if [ "\$left" -ne 0 ]; then
            echo "PROMOTING ${label}: ERROR: \$left file(s) remain under ${src}." >&2
            exit 1
        fi

        if [ "\$moved" -eq 0 ]; then
            # Already promoted by an earlier run is ordinary; in NEITHER root is not.
            present=0
            for pattern in ${patterns}; do
                for f in "${dst}"/\$pattern; do
                    if [ -e "\$f" ]; then present=\$(( present + 1 )); fi
                done
            done
            if [ "\$present" -eq 0 ]; then
                echo "PROMOTING ${label}: ERROR: nothing matching ${patterns} in either" >&2
                echo "PROMOTING ${label}: ${src}" >&2
                echo "PROMOTING ${label}: or ${dst}, but the step that consumes it succeeded." >&2
                exit 1
            fi
            echo "PROMOTING ${label}: already in permanent storage; nothing to move"
        else
            echo "PROMOTING ${label}: moved \$moved file(s)"
        fi

        # Only if it is genuinely empty.
        rmdir "${src}" 2>/dev/null || true

        mkdir -p ${dir_log}
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${log_file}
        """
}

// One call per attachment point. `gate` carries the consuming step's completion signal, never the
// artifact, and its value is the key the row is resolved with.
workflow Completion {
    take:
    stage
    gate     // [producing variant, key]

    main:
    PromoteArtifacts(stage, gate)

    // Unnamed: with a single emit, naming it is what `nextflow lint` objects to.
    emit:
    PromoteArtifacts.out.done
}
