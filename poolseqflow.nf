#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { resolveParameters; runDefinitions } from './scripts/resolve_parameters.nf'
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

    runs = channel.fromList(run_defs)

    // FROM HERE ON EVERY CHANNEL CARRIES ITS RUN as element 0, and nothing is matched
    // positionally. That is the whole shape of this stage: with one run there was exactly one
    // of each singleton and Nextflow's implicit value channels broadcast them for free, so
    // "the reference index" and "the sample" could be two separate process inputs. With N
    // runs there are N of each, positional matching pairs whichever arrived first, and the
    // result is a run analysed against another run's reference - which no later check could
    // detect. So per-run singletons are combined onto their run's samples by key
    // (`combine(by: 0)`), and two per-sample channels are joined on the run AND the sample
    // (`join(by: [0, 1])`).
    VerifyEnvironment(runs)
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

    // ...and fanned back out, so that from here on every channel is per run again. Keyed on
    // the dictionary rather than on the run, because that is what the two sides share.
    runs_by_dictionary = runs.map { run -> tuple(dictionaryKey(run), run) }
    bwa_index = runs_by_dictionary
        .combine(BuildDictionaries.out.bwa_index.map { d, idx -> tuple(dictionaryKey(d), idx) }, by: 0)
        .map { _key, run, idx -> tuple(run, idx) }
    fai_index = runs_by_dictionary
        .combine(BuildDictionaries.out.fai_index.map { d, fai -> tuple(dictionaryKey(d), fai) }, by: 0)
        .map { _key, run, fai -> tuple(run, fai) }
    snpeff_db = runs_by_dictionary
        .combine(BuildDictionaries.out.snpeff_db_verify.map { d, m -> tuple(dictionaryKey(d), m) }, by: 0)
        .map { _key, run, marker -> tuple(run, marker) }
        .filter { run, _marker -> run.annotate }

    // The reads are globbed per run while the DAG is built, which is also where N is fixed.
    reads = readPairChannel(run_defs)
    // How many samples each run started with, taken from that same channel rather than
    // counted separately - so it cannot drift from what step 2 actually ran. Step 6 checks
    // its cohort against it; see the gather point in scripts/6_variant_call.nf.
    expected_samples = reads.map { run, pair_id, _r1, _r2 -> tuple(run, pair_id) }
        .groupTuple(by: 0)
        .map { run, pair_ids -> tuple(run, pair_ids.size()) }

    TrimQcClip(reads, verified)
    AlignReads(TrimQcClip.out, bwa_index)
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
    CompleteAfterClip('fastqc zips', TrimQcClip.out.map { run, pair_id, _r1, _r2 -> tuple(run, pair_id) })
    CompleteAfterAlign('trimmed reads', AlignReads.out.map { run, pair_id, _bam -> tuple(run, pair_id) })
    CompleteAfterClean('alignments', SortCleanBams.out.ready_bam.map { run, pair_id, _bam -> tuple(run, pair_id) })

    GenerateReports(SortCleanBams.out.ready_bam, SortCleanBams.out.ready_bai)
    VariantCalling(SortCleanBams.out.ready_bam, fai_index, expected_samples)

    called_vcf = VariantCalling.out
    VCF2Frequencies(called_vcf)
    // `annotate` is a per-run parameter, so this is a filter on the runs rather than a branch
    // in the script. Under multiRun one run may annotate while another does not, which the
    // `if (params.annotate)` this replaces could not express - it read the base config and
    // decided for everybody.
    AnnotateVCF(called_vcf.filter { run, _vcf -> run.annotate }, snpeff_db)

    // The two artifacts with more than one consumer. Everything above is released by a
    // single step finishing; these two need every reader to be done, so the gate is
    // assembled here rather than being one step's output.
    //
    // Ready BAMs: step 5 per sample, step 6 for the cohort. `combine(by: 0)` waits for THIS
    // run's calling to finish and then re-emits each of its samples' own signals, so the
    // result is still one task per sample - the sample identity comes from step 5's side,
    // and calling contributes only its completion. Keyed on the run, so one run's calling
    // cannot release another run's BAMs.
    CompleteAfterUse('ready bams',
        GenerateReports.out.combine(called_vcf, by: 0).map { run, pair_id, _vcf -> tuple(run, pair_id) })

    // The called VCF: step 7 always, step 8 only when annotation is on - so the gate is
    // built differently depending on a parameter, which is the case settled rule 2 does not
    // cover. And `annotate` is now a per-run parameter, so the two shapes are no longer
    // alternatives for the whole invocation: both can be in flight at once, one run each.
    //
    // groupTuple, not collect: the wait has to be for every task OF THIS RUN, and collect()
    // would wait for every task of every run and then release them all together - correct,
    // but it would hold the last run's working files until the slowest run had finished.
    freq_done = VCF2Frequencies.out.groupTuple(by: 0).map { run, _tsvs -> tuple(run, '') }
    annotate_done = AnnotateVCF.out.map { run, _vcf -> tuple(run, '') }

    vcf_released = freq_done.filter { run, _key -> !run.annotate }
        .mix(freq_done.filter { run, _key -> run.annotate }
                 .join(annotate_done, by: 0)
                 .map { run, key, _also -> tuple(run, key) })
    CompleteAfterVcf('called vcf', vcf_released)
}
