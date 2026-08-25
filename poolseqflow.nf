#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { resolveParameters }   from './scripts/resolve_parameters.nf'
include { VerifyEnvironment }   from './scripts/0_verify_environment.nf'
include { BuildDictionaries }   from './scripts/1_build_dictionaries.nf'
include { TrimQcClip }          from './scripts/2_trim_reads.nf'
include { AlignReads }          from './scripts/3_align.nf'
include { SortCleanBams }       from './scripts/4_clean.nf'
include { GenerateReports }     from './scripts/5_reports.nf'
include { VariantCalling }      from './scripts/6_variant_call.nf'
include { VCF2Frequencies }     from './scripts/7_vcf2freq.nf'
include { AnnotateVCF }         from './scripts/8_annotate_variants.nf'
// One alias per attachment point. A workflow cannot be invoked twice - Nextflow answers
// "Process 'X' has been already used" - and aliasing is the supported way round it whenever
// the number of call sites is known while the script is being read, which is the case here:
// the DAG's shape is fixed, and only multi-run's N comes from data.
include { Completion as CompleteAfterClip }  from './scripts/9_completion.nf'
include { Completion as CompleteAfterAlign } from './scripts/9_completion.nf'
include { Completion as CompleteAfterClean } from './scripts/9_completion.nf'
include { Completion as CompleteAfterUse }   from './scripts/9_completion.nf'
include { Completion as CompleteAfterVcf }   from './scripts/9_completion.nf'

// Each task appends its own log to Logs/<step>/*_nextflow.log. One writer per file, so
// tasks never contend - but a run ends up scattered across dozens of files. By the time
// this runs there are no writers left, so gathering it into one file is safe here in a
// way it would not be while tasks are still going.
//
// Only the current run is collected: every block in a per-process log carries the session
// id that wrote it, so blocks from earlier runs in the same file are skipped. This file is
// overwritten each run; the full history stays in the per-process logs.
def assembleCombinedLog() {
    try {
        def logsDir = new File("${params.dir.logs}")
        if (!logsDir.isDirectory()) return

        def marker = "session=${workflow.sessionId}"
        def parts = []
        logsDir.eachFileRecurse { f ->
            if (f.isFile() && f.name.endsWith('_nextflow.log')) parts << f
        }
        parts.sort { a, b -> a.path <=> b.path }

        def out = new StringBuilder()
        out << "===================== PoolSeqFlow combined log =====================\n"
        out << "run       : ${workflow.runName}\n"
        out << "session   : ${workflow.sessionId}\n"
        out << "started   : ${workflow.start}\n"
        out << "completed : ${workflow.complete}\n"
        out << "duration  : ${workflow.duration}\n"
        out << "status    : ${workflow.success ? 'SUCCESS' : 'FAILED'}\n"
        out << "command   : ${workflow.commandLine}\n"
        out << "===================================================================\n"

        parts.each { f ->
            def keep = []
            def inRun = false
            f.eachLine { line ->
                if (line.startsWith('===== run=')) inRun = line.contains(marker)
                else if (inRun) keep << line
            }
            if (keep.any { line -> line.trim() }) {
                out << "\n########## ${f.name - '_nextflow.log'} ##########\n"
                out << keep.join('\n') << "\n"
            }
        }

        new File(logsDir, 'poolseqflow_last_run.log').text = out.toString()
    }
    catch (Exception e) {
        System.err.println "PoolSeqFlow: could not assemble the combined log - ${e.message}"
    }
}

workflow {
    workflow.onComplete { assembleCombinedLog() }

    // First, before any process script is evaluated and before the change-guard manifest is
    // built: it fills in every parameter that is computed from another one.
    resolveParameters()

    VerifyEnvironment()
    BuildDictionaries(VerifyEnvironment.out)
    
    TrimQcClip(VerifyEnvironment.out)
    AlignReads(TrimQcClip.out, BuildDictionaries.out.bwa_index)
    SortCleanBams(AlignReads.out)

    // Promotion attachment points. Each hangs off a step's output ALONGSIDE that output's
    // real consumer rather than in front of it: nothing upstream changes shape, so no value
    // channel can be turned into a queue channel and quietly reduce N tasks to 1.
    //
    // The signal is the consuming step having finished, not the artifact itself - several
    // processes here take an input purely for ordering and read an absolute path instead, so
    // holding the file proves nothing about who is done with it. What is passed is the
    // sample id carried by that signal, which is also the key the promotion table needs; see
    // scripts/9_completion.nf for why it is derived from the signal rather than zipped
    // alongside it.
    CompleteAfterClip('fastqc zips', TrimQcClip.out.map { pair_id, _r1, _r2 -> pair_id })
    CompleteAfterAlign('trimmed reads', AlignReads.out.map { pair_id, _bam -> pair_id })
    CompleteAfterClean('alignments', SortCleanBams.out.ready_bam.map { pair_id, _bam -> pair_id })

    GenerateReports(SortCleanBams.out.ready_bam,SortCleanBams.out.ready_bai)
    VariantCalling(SortCleanBams.out.ready_bam, BuildDictionaries.out.fai_index)
    VCF2Frequencies(VariantCalling.out)
    if (params.annotate) {
        AnnotateVCF(VariantCalling.out, BuildDictionaries.out.snpeff_db_verify)
    }

    // The two artifacts with more than one consumer. Everything above is released by a
    // single step finishing; these two need every reader to be done, so the gate is
    // assembled here rather than being one step's output.
    //
    // Ready BAMs: step 5 per sample, step 6 for the cohort. `combine` waits for calling to
    // finish and then re-emits each sample's own signal, so the result is still one task
    // per sample - the sample identity comes from step 5's side, and calling contributes
    // only its completion.
    CompleteAfterUse('ready bams',
        GenerateReports.out.combine(VariantCalling.out).map { pair_id, _vcf -> pair_id })

    // The called VCF: step 7 always, step 8 only when annotation is on - so the gate is
    // built differently depending on a parameter, which is the case settled rule 2 does not
    // cover. `collect` turns "every task of that step" into a single signal, and `combine`
    // then waits for both.
    //
    // ONE closure parameter, not one per step. `combine` FLATTENS: what arrives is a single
    // list holding everything both steps produced, not a tuple of two lists. Naming two
    // parameters here looked right and failed at runtime with "Invalid method invocation
    // `call` with arguments: [...] (java.util.LinkedList)". Nothing reads the contents -
    // only the arrival matters - so it maps straight to the key, which is empty because
    // this artifact belongs to the run rather than to any one sample.
    if (params.annotate) {
        vcf_released = VCF2Frequencies.out.collect()
            .combine(AnnotateVCF.out.collect())
            .map { _done -> '' }
    } else {
        vcf_released = VCF2Frequencies.out.collect().map { _done -> '' }
    }
    CompleteAfterVcf('called vcf', vcf_released)
}
