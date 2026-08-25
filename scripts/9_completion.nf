// Promotion: moving an artifact from the working volume to permanent storage once nothing
// needs it any more.
//
// Outputs are written to mainDir/Utilized/, which mirrors Output/'s tree exactly, and stay
// there while anything still reads them. When the last step that consumes an artifact has
// succeeded, it moves to storageDir/Output/. Each byte therefore crosses between the two
// volumes exactly once, at the point where it has stopped being working data and become a
// result - instead of being read across the slower volume on every access, which is what
// happened while every dir.* entry resolved to storageDir.
//
// WHY IT ALL LIVES IN ONE FILE. "Was this file really moved, and is the source gone" is the
// question that decides whether a result exists, so it is worth being able to read every
// answer to it in one place. The alternative - a move at the end of each step's own module -
// spreads the same three lines across eight files and makes a missing one invisible.
//
// WHY IT IS WIRED AT SEVERAL POINTS AND NOT ONE TERMINAL NODE. A single node at the end of
// the DAG would hold roughly 2.5-3x the raw data on the fast volume until the run finished,
// which is the opposite of the point. Trimmed reads can go as soon as alignment succeeds;
// alignments as soon as cleaning succeeds. The fast volume is released as the run proceeds.
//
// THREE THINGS THAT CONSTRAIN HOW THIS CAN BE BUILT, all established by probing:
//
//   1. Promotion cannot be driven off a staged input. Six process inputs in this pipeline are
//      pure ordering barriers rather than real reads - the process names an absolute
//      params.* path in its script and never touches the staged copy. For those, "the
//      consumer has the file" is a scheduling fact, not a data-flow one. So promotion is
//      triggered by a completion SIGNAL from the consumer, never by receiving the artifact.
//
//   2. It is the LAST consumer that matters, not the consumer. Test.vcf has two - step 7
//      always, and step 8 whenever annotate is true - with no ordering between them in
//      poolseqflow.nf. So a promotion trigger can be parameter-dependent, and anything that
//      assumes one consumer will delete a file another step is about to read.
//
//   3. Cardinality is fragile. Every singleton artifact here rides a value channel, which is
//      what lets one reference index broadcast against N samples; an operator inserted into
//      such a path turns it into a queue channel and silently reduces N tasks to 1 while the
//      run still reports success. This module therefore attaches as an ADDITIONAL CONSUMER
//      of an existing channel - alongside the real consumer, never in front of it. Nothing
//      upstream changes shape, so there is nothing to flip.
//
// Artifacts with no consumer at all - unpaired reads, trim reports, the FastQC htmls, both
// step 5 reports - are never "an output that becomes an input", so they are written straight
// to storageDir and never enter Utilized. The rule reads the same backwards: something enters
// Utilized exactly when it will be read again.

nextflow.enable.dsl=2

// THE ARTIFACT -> GATE TABLE.
//
// Which files a completed step releases, and where they go. Nextflow's own dependency graph
// cannot answer this - all three of its limits here were found by probing, not assumed:
//
//   * it asserts dependencies that are not reads (the six ordering-barrier inputs above),
//   * it misses reads that are never declared (VerifyAll and CheckRGTagsFile take `val` for
//     files and then read them by absolute path into other tasks' work directories), and
//   * it describes one session, while an artifact's lifetime here spans runs - this
//     pipeline resumes by looking at the filesystem, `-resume` is unused, and
//     `cleanup = true` removes the work directories behind it.
//
// So the table is written out, and it grows ONE ROW PER STAGE: each row lands with the
// change that makes it true and is reviewed alongside it. A stage that has no row yet
// returns null and is recorded without moving anything. A stage that is not in the table at
// all is an error rather than a no-op, because a mistyped name would otherwise promote
// nothing, silently, on every run from then on.
//
// `subpath` is relative to both roots - Utilized/ and Output/ differ only in their root,
// which is what makes promotion a move between two spellings of one path.
def promotionRow(String stage, String key) {
    def table = [
        // Step 2's clipped reads are step 3's only input, and nothing after step 3 reads
        // them, so a sample's alignment succeeding releases that sample's reads. The
        // *_val_* reads written into the same directory are deliberately not here:
        // ClipReads deletes them outright, so they never become a result to promote.
        'trimmed reads': [ subpath : "${params.dir.subpath.trimmed}/${key}",
                           patterns: ['*_clipped.fq.gz'] ],

        // The zips FastQC writes beside the trimmed reads. ClipReads unzips them to work
        // out its clipping bounds, so they are working data by the same rule as the reads,
        // small though they are - but their gate is ClipReads finishing rather than
        // alignment, which is why they are a row and an attachment point of their own. The
        // htmls are not here: nothing reads those, so they never enter Utilized at all.
        'fastqc zips'  : [ subpath : "${params.dir.subpath.report.fastqc}/${key}",
                           patterns: ['*_val_1_fastqc.zip', '*_val_2_fastqc.zip'] ],

        // Aligned BAMs, released when cleaning has succeeded for the sample. This
        // directory is flat rather than per-sample, so the key selects the file instead of
        // the folder - which is the reason `subpath` and `patterns` are both resolved
        // against the key rather than only the first.
        'alignments'   : [ subpath : "${params.dir.subpath.aligned}",
                           patterns: ["${key}_aligned.bam"] ],

        // The first artifact with TWO consumers - step 5 reads it for the reports, step 6
        // for calling - so its gate is both of them, assembled at the call site. The index
        // travels with its BAM: nothing here reads the index by name, both step-5 processes
        // just expect it beside the file, so promoting one without the other would leave a
        // BAM that looks complete and is not.
        'ready bams'   : [ subpath : "${params.dir.subpath.ready}",
                           patterns: ["${key}_ready.bam", "${key}_ready.bam.bai"] ],

        // Also two consumers, and here the second is conditional: step 7 always, step 8
        // only when annotate is on. So this gate is parameter-dependent - the one place
        // settled rule 2's "the step that consumes it" is not a single step. No key: one
        // VCF for the whole run, not one per sample.
        'called vcf'   : [ subpath : "${params.dir.subpath.vcf}",
                           patterns: ["${params.vcf.fileName}.vcf"] ],
    ]

    if (!table.containsKey(stage)) {
        throw new IllegalArgumentException(
            "Completion: no promotion row for stage '${stage}'. Either add one to " +
            "promotionRow() in scripts/9_completion.nf, or correct the stage name at " +
            "the call site in poolseqflow.nf.")
    }
    return table[stage]
}

// The move itself. One task per (stage, key); `key` is the sample a per-sample artifact
// belongs to, and is empty for artifacts that belong to the run as a whole.
process PromoteArtifacts {
    tag { key ? "${stage} ${key}" : stage }

    input:
    val stage
    val key

    output:
    val stage, emit: done

    script:
    row = promotionRow(stage, key)
    label = key ? "${stage} ${key}" : stage
    // One writer per log file, as everywhere else in the pipeline: these tasks run
    // concurrently, so a shared file would interleave their output.
    slug = key ? "${stage}_${key}" : stage
    slug = slug.replaceAll(/[^A-Za-z0-9]+/, '_')
    dir_log = "${params.dir.logs}/9_completion/s1_PromoteArtifacts"
    log_file = "${dir_log}/9_Completion_s1_PromoteArtifacts_${slug}_nextflow.log"

    src = row ? "${params.dir.utilized}/${row.subpath}" : ''
    dst = row ? "${params.dir.outputs}/${row.subpath}" : ''
    // Quoted, so that the loops below iterate over the patterns themselves instead of
    // whatever they happen to match in the task directory.
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

        # The source must be GONE, not merely copied. find_artifact.sh reports the first
        # root that has an artifact, and the working volume is searched second, so a copy
        # left behind is harmless now and wrong the moment the promoted one is edited,
        # replaced or reset - it would go on satisfying every later skip check.
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
            # Already promoted by an earlier run is the ordinary case. In neither root is
            # not: the gate reported success, so the artifact has to exist somewhere, and
            # the likeliest cause is a wrong subpath in the table above.
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

        # Only if it is genuinely empty. Anything still in there is worth keeping visible.
        rmdir "${src}" 2>/dev/null || true

        mkdir -p ${dir_log}
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${log_file}
        """
}

// One call per attachment point.
//
// `gate` carries the consuming step's completion - the signal that it finished - and never
// the artifact itself; see constraint 1 above. Its VALUE is the key the row is resolved
// with, so for a per-sample artifact the call site maps the consumer's output down to its
// sample id. Deriving the key from the signal rather than pairing two channels is
// deliberate: two channels would be matched by arrival order, and a promotion aimed at the
// wrong sample would delete a file another task still needs.
workflow Completion {
    take:
    stage
    gate

    main:
    PromoteArtifacts(stage, gate)

    // Unnamed: with a single emit, naming it is what `nextflow lint` objects to.
    emit:
    PromoteArtifacts.out.done
}
