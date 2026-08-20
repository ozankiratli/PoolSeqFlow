#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { VerifyEnvironment }   from './scripts/0_verify_environment.nf'
include { BuildDictionaries }   from './scripts/1_build_dictionaries.nf'
include { TrimQcClip }          from './scripts/2_trim_reads.nf'
include { AlignReads }          from './scripts/3_align.nf'
include { SortCleanBams }       from './scripts/4_clean.nf'
include { GenerateReports }     from './scripts/5_reports.nf'
include { VariantCalling }      from './scripts/6_variant_call.nf'
include { VCF2Frequencies }     from './scripts/7_vcf2freq.nf'
include { AnnotateVCF }         from './scripts/8_annotate_variants.nf'

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

    VerifyEnvironment()
    BuildDictionaries(VerifyEnvironment.out)
    
    TrimQcClip(VerifyEnvironment.out)
    AlignReads(TrimQcClip.out, BuildDictionaries.out.bwa_index)  
    SortCleanBams(AlignReads.out)
    
    GenerateReports(SortCleanBams.out.ready_bam,SortCleanBams.out.ready_bai)
    VariantCalling(SortCleanBams.out.ready_bam, BuildDictionaries.out.fai_index)
    VCF2Frequencies(VariantCalling.out)
    if (params.annotate) {
        AnnotateVCF(VariantCalling.out, BuildDictionaries.out.snpeff_db_verify)
    }
}
