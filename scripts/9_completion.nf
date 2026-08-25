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

// The scaffold. It reports what reached it and moves nothing.
//
// Deliberately inert at this stage. The risk in this refactor is not the moving, which is a
// rename; it is the wiring, which can change the shape of the graph without changing its
// result. Landing the attachment points first - with task counts asserted against the same
// fixture - separates "the graph still has the shape we think" from "the moves are correct",
// so that when something does change we know which of the two caused it.
process RecordCompletion {
    input:
    val stage
    val token

    output:
    val stage, emit: done

    script:
    dir_log = "${params.dir.logs}/9_completion/s1_RecordCompletion"
    """
    echo "COMPLETION:            stage ${stage} finished; promotion is not yet enabled"
    echo "COMPLETION:            utilized  ${params.dir.utilized}"
    echo "COMPLETION:            outputs   ${params.dir.outputs}"

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/9_Completion_s1_RecordCompletion_nextflow.log
    """
}

// One call per attachment point. `trigger` is the consuming step's own output - the signal
// that it finished - and is never the artifact itself; see constraint 1 above.
workflow Completion {
    take:
    stage
    trigger

    main:
    RecordCompletion(stage, trigger)

    // Unnamed: with a single emit, naming it is what `nextflow lint` objects to.
    emit:
    RecordCompletion.out.done
}
