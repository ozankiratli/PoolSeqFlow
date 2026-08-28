#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { resolveParameters; runDefinitions } from './scripts/resolve_parameters.nf'
include { variantPlan; childVariants; parentVariant; descendantVariants } from './scripts/variants.nf'
include { gatherToProducer; runToken } from './scripts/variants.nf'
include { sharingReportLines; publishConflictLines } from './scripts/variants.nf'
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
//
// One combined log per Logs directory, not one for the invocation. Under multiRun each run
// has its own, and the shared work has the project's - so the combined log sits beside the
// per-process logs it summarises rather than mixing three runs into one file under whichever
// root happened to be the base. For a single run there is exactly one directory and this is
// what it always was.
// NOTHING IN HERE MAY THROW. When an onComplete handler fails, Nextflow reports
// "Failed to invoke `workflow.onComplete` event handler" INSTEAD of the error that actually
// stopped the run - so a fault in the logging replaces the diagnosis with a line about
// logging. It cost the multi-run dictionary conflict its entire message: a GString reaching a
// String parameter here turned a precise explanation into a pointer at this file.
//
// The per-directory function has its own try/catch as well. This one covers the list handling
// around it, which is where that failure was.
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

// Does anything downstream of this step-6 variant annotate? A function rather than a closure
// assigned to a local, because the strict parser is unhappy invoking those.
def annotatedBelow(Map plan, Map producer) {
    return plan.children[8][producer.variantKey].any { child -> child.executes }
}

workflow {
    // THE RUNS THIS INVOCATION WILL EXECUTE, and the two calls have to be in this order.
    //
    // runDefinitions() takes each run's copy of the parameters while "absent" still means
    // "the user did not set this". resolveParameters() destroys that distinction by filling
    // the computed values in, and `fill` will not overwrite - so a run that changes an input
    // to a derivation would silently keep the base run's derived value. Reversing these two
    // lines produces wrong numbers, not an error.
    //
    // For a single run this is one definition with runId = null: no suffix anywhere, and
    // every path exactly what it was before multi-run existed (settled rule 3).
    def run_defs = runDefinitions()
    resolveParameters()

    // WHERE THE RUNS DIVERGE, and therefore what the DAG below is shaped like.
    //
    // Worked out once, here, before a single task is submitted. From this line on the unit that
    // flows through the pipeline is a VARIANT - a parameter set one or more runs share at a
    // given step - and a run is a path from the root of that tree to a leaf. A process still
    // takes `tuple val(x), ...` and still reads `x.dir.*`; only what `x` means has changed.
    //
    // While sharing is off (scripts/variants.nf, `sharingEnabled`) every run is its own variant
    // at every step, so each of those trees is a straight line and this whole file describes
    // exactly the DAG it described before. That is deliberate: it makes the rewiring provable
    // by running the old and new code over one fixture and showing that nothing moved.
    //
    // Deliberately declared without `def`, like log_dirs below: the operator closures further
    // down read it, and a `def` local of the workflow body is not something a closure resolved
    // against the script binding can see.
    plan = variantPlan(run_defs)

    // Registered here rather than at the top of the workflow because it needs the runs: each
    // one writes its logs under its own storageDir, and params.dir.logs names only the base.
    //
    // TWO THINGS ABOUT THIS SHAPE, both learned by getting them wrong.
    //
    // The list is built HERE and not inside the handler. A `def` local of the workflow body is
    // not visible to the onComplete closure when it eventually runs - the closure resolves the
    // name against the script binding, finds nothing, and dies on
    // "Cannot get property 'dir' on null object". `log_dirs` is deliberately declared without
    // `def` so that it IS a binding variable, which is what the closure can see.
    //
    // And the handler does nothing but call one guarded function, because when an onComplete
    // handler throws, Nextflow reports "Failed to invoke `workflow.onComplete` event handler"
    // INSTEAD of the error that actually stopped the run. Anything evaluated in the handler's
    // argument list is outside that function's own try/catch, which is exactly how this one
    // hid a multi-run configuration error behind a message about logging.
    log_dirs = (["${params.dir.logs}"] + run_defs.collect { r -> "${r.dir.logs}" })
        .collect { d -> d.toString() }
        .unique()
    workflow.onComplete { assembleCombinedLogs(log_dirs) }

    // EVERY CHANNEL CARRIES ITS OWN WORK ITEM as element 0, and nothing is matched
    // positionally. With one run there was exactly one of each singleton and Nextflow's
    // implicit value channels broadcast them for free, so "the reference index" and "the
    // sample" could be two separate process inputs. With N of each, positional matching pairs
    // whichever arrived first, and the result is one analysis run against another's reference -
    // which no later check could detect. So singletons are combined onto their own samples by
    // key (`combine(by: 0)`), and two per-sample channels are joined on the work item AND the
    // sample (`join(by: [0, 1])`).
    //
    // STEP 0 FOLLOWS THE SAME SHAPE AS THE REST. Each of its stages is keyed to what it
    // validates - a reference file, a data directory, a results directory, a step-6 variant -
    // rather than run once per run, which produced N identical reports for one file. Only
    // VerifyAll is per run: it assembles that run's own report and is the gate its work waits
    // on. So runs still appear exactly twice, at the step-2 gate below and at publication.
    //
    // What step 0 says about the partition, and the one disagreement a group cannot absorb,
    // are rendered here because the analysis exists only while the DAG is being built. The
    // plan itself goes in too, because two of the stages are keyed by it.
    VerifyEnvironment(
        channel.value([plan: plan, runs: run_defs]),
        channel.value(tuple(
            sharingReportLines(plan, run_defs),
            publishConflictLines(plan, run_defs))))
    verified = VerifyEnvironment.out

    // Step 1 runs once per DISTINCT DICTIONARY SET, not once per run. Its artifacts live on
    // mainDir and are shared by settled rule 4, so two runs naming the same reference resolve
    // to the same output paths - see dictionaryKey() in scripts/1_build_dictionaries.nf.
    //
    // The gate is every run's step 0 having passed, as one signal. Dictionaries are shared,
    // so no single run owns the decision to build one, and `count` only emits once the
    // channel has closed - which is exactly "all of them are done".
    //
    // A COUNT AND NOT THE REPORTS THEMSELVES. `combine` treats a channel item that is a List
    // as a tuple and spreads it, so combining a collect()ed list of N reports produces an
    // N+1 element tuple rather than a pair, and every closure downstream is called with the
    // wrong arity. A scalar cannot be spread. Nothing reads the gate's value in any case.
    step0_done = verified.count()
    BuildDictionaries(channel.fromList(dictionaryRuns(run_defs)), step0_done)

    // ...and fanned back out to whichever step reads each index, keyed on the dictionary
    // rather than on the work item, because that is what the two sides share. Each index goes
    // to the variants of the step that actually consumes it - the FASTA index to step 3, the
    // .fai to step 6, the snpEff database to step 8 - which is also why step 1 exposes three
    // identities rather than one: two runs differing only in `gffFile` must not redo alignment.
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

    // The reads are globbed per step-2 variant while the DAG is built, which is also where N
    // is fixed. Per variant and not per run because `reads` is part of step 2's identity, so
    // every member of a variant globs the same files by construction.
    reads = readPairChannel(plan.variants[2])
    // How many samples the work started with, taken from that same channel rather than counted
    // separately - so it cannot drift from what step 2 actually ran. Carried straight to the
    // step-6 variants that will check their cohorts against it, which is an expansion like any
    // other; it just skips the intermediate steps rather than being re-derived at each.
    expected_samples = reads.map { variant, pair_id, _r1, _r2 -> tuple(variant, pair_id) }
        .groupTuple(by: 0)
        .flatMap { variant, pair_ids ->
            descendantVariants(plan, variant, 6).collect { child -> tuple(child, pair_ids.size()) } }

    // THE STEP-0 GATE, AND IT IS THE ONLY ONE THE PIPELINE NEEDS.
    //
    // A shared step must wait for EVERY run that shares it, not just the one whose parameters
    // it carries: VerifyAll is `errorStrategy 'finish'`, which lets already-submitted tasks
    // complete, so a step gated on one member's report could finish and promote while another
    // member's CheckRunParameters was still deciding to fail.
    //
    // Gating step 2 covers every step after it, because a variant's members are always a
    // subset of its parent's - so a step-2 variant that waited for all of its members has
    // already waited for all of every variant descended from it.
    //
    // groupKey carries the member count with the key, so each variant is released as its own
    // members report rather than when the whole channel closes; with sharing off that is one
    // report per variant and the wait is exactly the per-run wait it replaces.
    verified_by_run = verified.map { run, report -> tuple(runToken(run.runId), report) }
    step0_for_reads = channel.fromList(plan.variants[2].collectMany { v ->
                v.members.collect { m -> tuple(runToken(m), groupKey(v.variantKey, v.members.size()), v) } })
        .combine(verified_by_run, by: 0)
        .map { _member, gate, variant, _report -> tuple(gate, variant) }
        .groupTuple(by: 0)
        .map { _gate, variants -> tuple(variants[0], variants.size()) }

    TrimQcClip(reads, step0_for_reads)

    // EXPANSION, NOT FAN-BACK. Each step derives its work items from the previous step's by
    // enumerating that variant's children in the plan, so the arity is decided before anything
    // runs. The joins these replace matched keys and dropped the ones that did not match,
    // silently and with the run still reporting success.
    AlignReads(TrimQcClip.out.flatMap { variant, pair_id, read1, read2 ->
        childVariants(plan, variant, 3).collect { child -> tuple(child, pair_id, read1, read2) } },
        bwa_index)
    SortCleanBams(AlignReads.out.flatMap { variant, pair_id, bam ->
        childVariants(plan, variant, 4).collect { child -> tuple(child, pair_id, bam) } })

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
    //
    // AND THE GATE IS KEYED BY THE PRODUCING VARIANT, not by the consuming one. Once a producer
    // is shared its consumers may not be - two runs can share step 2 and diverge at step 3, so
    // two step-3 work items read one set of trimmed reads - and releasing on the first of them
    // to finish would delete a file the second still needs. gatherToProducer() maps each
    // consumer's completion back to the variant that produced what it read and waits for all
    // of them; see scripts/variants.nf for why that count is arithmetic rather than a runtime
    // reference count.
    //
    // The FastQC zips are the one artifact produced and consumed inside a single step, so
    // producer and consumer are the same variant and there is nothing to gather.
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
    // `annotate` is part of step 8's identity, so a variant either annotates or does not -
    // never half. Under multiRun one run may annotate while another does not, which the
    // `if (params.annotate)` this replaces could not express: it read the base config and
    // decided for everybody.
    AnnotateVCF(called_vcf.flatMap { variant, vcf ->
        childVariants(plan, variant, 8).findAll { child -> child.executes }
            .collect { child -> tuple(child, vcf) } }, snpeff_db)

    // The two artifacts with more than one CONSUMING STEP. Everything above is released by a
    // single step finishing; these two need every reader to be done, so the gate is assembled
    // here rather than being one step's output.
    //
    // Ready BAMs: step 5 per sample, step 6 for the cohort. Both are gathered onto their
    // step-4 producer first, which collapses calling to one signal per producer however many
    // step-6 variants read it. `combine(by: 0)` then waits for that and re-emits each of the
    // producer's samples' own signals, so the result is still one task per sample - the sample
    // identity comes from step 5's side and calling contributes only its completion.
    reports_done = gatherToProducer(plan, GenerateReports.out, 5)
    calling_done = gatherToProducer(plan, called_vcf.map { variant, _vcf -> tuple(variant, '') }, 6)
    CompleteAfterUse('ready bams',
        reports_done.combine(calling_done, by: 0).map { producer, pair_id, _done -> tuple(producer, pair_id) })

    // The called VCF: step 7 always, step 8 only where annotation is on - so the gate is built
    // differently depending on a parameter, which is the case settled rule 2 does not cover.
    // Both shapes can be in flight at once, since a step-6 variant may feed an annotating
    // branch and a non-annotating one at the same time.
    //
    // groupTuple, not collect: the wait has to be for the tables OF THIS VARIANT, and collect()
    // would wait for every task of every variant and release them together - correct, but it
    // would hold the last one's working files until the slowest had finished.
    freq_done = gatherToProducer(plan,
        VCF2Frequencies.out.groupTuple(by: 0).map { variant, _tsvs -> tuple(variant, '') }, 7)
    annotate_done = gatherToProducer(plan,
        AnnotateVCF.out.map { variant, _vcf -> tuple(variant, '') }, 8)

    // Whether an annotation signal is ever coming is a property of the producer's children,
    // not of the producer's own `annotate`: the variant carries its lead member's parameters,
    // and `annotate` is not part of step 6's identity, so the lead cannot answer for the rest.
    vcf_released = freq_done.filter { producer, _key -> !annotatedBelow(plan, producer) }
        .mix(freq_done.filter { producer, _key -> annotatedBelow(plan, producer) }
                 .join(annotate_done, by: 0)
                 .map { producer, key, _also -> tuple(producer, key) })
    CompleteAfterVcf('called vcf', vcf_released)

    // Every run in the table must reach the end. See assertEveryRunProduced() in
    // scripts/variants.nf for why nothing else in the pipeline would notice if one did not.
    //
    // A binding variable, not a `def` local: the closure runs after this body has returned, and
    // resolves its names against the script binding - the same trap that once replaced a
    // multi-run configuration error with a message about logging.
    expected_run_tokens = run_defs.collect { run -> runToken(run.runId) }
    VCF2Frequencies.out
        .flatMap { variant, _tsv -> variant.members.collect { member -> runToken(member) } }
        .unique()
        .collect()
        .subscribe { produced -> assertEveryRunProduced(expected_run_tokens, produced) }
}
