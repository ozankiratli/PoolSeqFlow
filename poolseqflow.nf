#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { resolveParameters; runDefinitions } from './scripts/resolve_parameters.nf'
include { variantPlan; childVariants; parentVariant; descendantVariants } from './scripts/variants.nf'
include { gatherToProducer; runToken } from './scripts/variants.nf'
include { sharingReportLines; publishConflictLines; sharedMemberFiles } from './scripts/variants.nf'
include { assertEveryRunProduced } from './scripts/variants.nf'
include { VerifyEnvironment }   from './scripts/0_verify_environment.nf'
include { BuildDictionaries; dictionaryRuns; dictionaryKey } from './scripts/1_build_dictionaries.nf'
include { TrimQcClip; readPairChannel } from './scripts/2_trim_reads.nf'
include { AlignReads }          from './scripts/3_align.nf'
include { SortCleanBams }       from './scripts/4_clean.nf'
include { GenerateReports }     from './scripts/5_reports.nf'
include { VariantCalling }      from './scripts/6_variant_call.nf'
include { VCF2Frequencies }     from './scripts/7_vcf2freq.nf'
include { AnnotateVCF }         from './scripts/8_annotate_variants.nf'
// One alias per attachment point: a workflow cannot be invoked twice.
include { Completion as CompleteAfterClip }  from './scripts/9_completion.nf'
include { Completion as CompleteAfterAlign } from './scripts/9_completion.nf'
include { Completion as CompleteAfterClean } from './scripts/9_completion.nf'
include { Completion as CompleteAfterUse }   from './scripts/9_completion.nf'
include { Completion as CompleteAfterVcf }   from './scripts/9_completion.nf'
include { Citations }           from './scripts/citations.nf'

// Gathers each Logs directory's per-process logs into one file. Must never throw.
def assembleCombinedLogs(List logDirs) {
    try {
        logDirs.collect { dir -> dir.toString() }.unique().each { dir -> assembleCombinedLog(dir) }
    }
    catch (Exception e) {
        System.err.println "PoolSeqFlow: could not assemble the combined logs - ${e.message}"
    }
}

def assembleCombinedLog(String dir) {
    try {
        def logsDir = new File(dir)
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

// Does anything downstream of this step-6 variant annotate?
def annotatedBelow(Map plan, Map producer) {
    return plan.children[8][producer.variantKey].any { child -> child.executes }
}

workflow {
    // In this order: runDefinitions() must copy each run's parameters before resolveParameters()
    // fills the computed ones in. A single run is one definition with runId = null.
    def run_defs = runDefinitions()
    resolveParameters()

    // Where the runs diverge. From here the unit is a VARIANT. No `def`, here or on log_dirs
    // below: the operator closures read them.
    plan = variantPlan(run_defs)

    // Each run writes its logs under its own storageDir.
    log_dirs = (["${params.dir.logs}"] + run_defs.collect { r -> "${r.dir.logs}" })
        .collect { d -> d.toString() }
        .unique()
    workflow.onComplete { assembleCombinedLogs(log_dirs) }

    // The partition report is rendered here: the analysis exists only while the DAG is built.
    VerifyEnvironment(
        channel.value([plan: plan, runs: run_defs]),
        channel.value(tuple(
            sharingReportLines(plan, run_defs),
            publishConflictLines(plan, run_defs),
            sharedMemberFiles(plan))))
    verified = VerifyEnvironment.out

    // Step 1 runs once per distinct dictionary set, gated on every run's step 0 as one signal.
    // A count, not the reports: `combine` spreads a List.
    step0_done = verified.count()
    BuildDictionaries(channel.fromList(dictionaryRuns(run_defs)), step0_done)

    // ...and fanned back out keyed on the dictionary, which is what the two sides share.
    bwa_index = channel.fromList(plan.variants[3].collect { v -> tuple(dictionaryKey(v), v) })
        .combine(BuildDictionaries.out.bwa_index.map { d, idx -> tuple(dictionaryKey(d), idx) }, by: 0)
        .map { _key, variant, idx -> tuple(variant, idx) }
    fai_index = channel.fromList(plan.variants[6].collect { v -> tuple(dictionaryKey(v), v) })
        .combine(BuildDictionaries.out.fai_index.map { d, fai -> tuple(dictionaryKey(d), fai) }, by: 0)
        .map { _key, variant, fai -> tuple(variant, fai) }
    snpeff_db = channel.fromList(plan.variants[8].findAll { v -> v.executes }
                                     .collect { v -> tuple(dictionaryKey(v), v) })
        .combine(BuildDictionaries.out.snpeff_db_verify.map { d, m -> tuple(dictionaryKey(d), m) }, by: 0)
        .map { _key, variant, marker -> tuple(variant, marker) }

    // Globbed per step-2 variant while the DAG is built, which is where N is fixed.
    reads = readPairChannel(plan.variants[2])
    // How many samples the work started with, carried to the step-6 cohort check.
    expected_samples = reads.map { variant, pair_id, _r1, _r2 -> tuple(variant, pair_id) }
        .groupTuple(by: 0)
        .flatMap { variant, pair_ids ->
            descendantVariants(plan, variant, 6).collect { child -> tuple(child, pair_ids.size()) } }

    // The step-0 gate: a shared step waits for every member run, and gating step 2 covers
    // everything after it.
    verified_by_run = verified.map { run, report -> tuple(runToken(run.runId), report) }
    step0_for_reads = channel.fromList(plan.variants[2].collectMany { v ->
                v.members.collect { m -> tuple(runToken(m), groupKey(v.variantKey, v.members.size()), v) } })
        .combine(verified_by_run, by: 0)
        .map { _member, gate, variant, _report -> tuple(gate, variant) }
        .groupTuple(by: 0)
        .map { _gate, variants -> tuple(variants[0], variants.size()) }

    TrimQcClip(reads, step0_for_reads)

    // Expansion, not fan-back: each step enumerates that variant's children in the plan.
    AlignReads(TrimQcClip.out.flatMap { variant, pair_id, read1, read2 ->
        childVariants(plan, variant, 3).collect { child -> tuple(child, pair_id, read1, read2) } },
        bwa_index)
    SortCleanBams(AlignReads.out.flatMap { variant, pair_id, bam ->
        childVariants(plan, variant, 4).collect { child -> tuple(child, pair_id, bam) } })

    // Promotion attachment points, hung alongside each step's real consumer. The signal is the
    // consuming step having finished, keyed by the producing variant.
    CompleteAfterClip('fastqc zips',
        TrimQcClip.out.map { variant, pair_id, _r1, _r2 -> tuple(variant, pair_id) })
    CompleteAfterAlign('trimmed reads',
        gatherToProducer(plan, AlignReads.out.map { variant, pair_id, _bam -> tuple(variant, pair_id) }, 3))
    CompleteAfterClean('alignments',
        gatherToProducer(plan, SortCleanBams.out.ready_bam.map { variant, pair_id, _bam -> tuple(variant, pair_id) }, 4))

    GenerateReports(
        SortCleanBams.out.ready_bam.flatMap { variant, pair_id, bam ->
            childVariants(plan, variant, 5).collect { child -> tuple(child, pair_id, bam) } },
        SortCleanBams.out.ready_bai.flatMap { variant, pair_id, bai ->
            childVariants(plan, variant, 5).collect { child -> tuple(child, pair_id, bai) } })
    VariantCalling(
        SortCleanBams.out.ready_bam.flatMap { variant, pair_id, bam ->
            childVariants(plan, variant, 6).collect { child -> tuple(child, pair_id, bam) } },
        fai_index, expected_samples)

    called_vcf = VariantCalling.out
    VCF2Frequencies(called_vcf.flatMap { variant, vcf ->
        childVariants(plan, variant, 7).collect { child -> tuple(child, vcf) } })
    // `annotate` is part of step 8's identity, so a variant either annotates or does not.
    AnnotateVCF(called_vcf.flatMap { variant, vcf ->
        childVariants(plan, variant, 8).findAll { child -> child.executes }
            .collect { child -> tuple(child, vcf) } }, snpeff_db)

    // The two artifacts with more than one consuming step, so their gate is assembled here.
    // Ready BAMs: step 5 per sample, step 6 for the cohort.
    reports_done = gatherToProducer(plan, GenerateReports.out, 5)
    calling_done = gatherToProducer(plan, called_vcf.map { variant, _vcf -> tuple(variant, '') }, 6)
    CompleteAfterUse('ready bams',
        reports_done.combine(calling_done, by: 0).map { producer, pair_id, _done -> tuple(producer, pair_id) })

    // The called VCF: step 7 always, step 8 only where annotation is on, so both gate shapes can
    // be in flight at once. groupTuple, not collect: the wait is for the tables of this variant.
    freq_done = gatherToProducer(plan,
        VCF2Frequencies.out.groupTuple(by: 0).map { variant, _tsvs -> tuple(variant, '') }, 7)
    annotate_done = gatherToProducer(plan,
        AnnotateVCF.out.map { variant, _vcf -> tuple(variant, '') }, 8)

    // Whether an annotation signal is coming is a property of the producer's children, not of
    // its own `annotate`, which is only its lead member's.
    vcf_released = freq_done.filter { producer, _key -> !annotatedBelow(plan, producer) }
        .mix(freq_done.filter { producer, _key -> annotatedBelow(plan, producer) }
                 .join(annotate_done, by: 0)
                 .map { producer, key, _also -> tuple(producer, key) })
    CompleteAfterVcf('called vcf', vcf_released)

    // Every run in the table must reach the end; nothing else in the pipeline counts runs.
    expected_run_tokens = run_defs.collect { run -> runToken(run.runId) }
    VCF2Frequencies.out
        .flatMap { variant, _tsv -> variant.members.collect { member -> runToken(member) } }
        .unique()
        .collect()
        .subscribe { produced -> assertEveryRunProduced(expected_run_tokens, produced) }

    // What this invocation was built on, recorded beside what it produced. From `params`, not a
    // run: the file describes the invocation and belongs at the base Output/ root.
    citations_run = [ storageDir   : params.storageDir,
                      software     : params.software,
                      dir          : params.dir,
                      annotate     : run_defs.any { r -> r.annotate },
                      citationsData: "${projectDir}/install/citations.json".toString() ]
    Citations(citations_run, VCF2Frequencies.out.collect())
}
