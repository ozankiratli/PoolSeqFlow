#!/usr/bin/env nextflow

// The analysis layer's entry point, beside poolseqflow.nf and dryrun.nf.
//
// One module per invocation: `--module <name>`, which ./PoolSeqFlow analysis supplies. It reads
// results a pipeline run published and writes an analysis of its own; it never produces, moves
// or removes anything the pipeline made.

nextflow.enable.dsl=2

include { requireModule } from './analysis/lib/nf/modules.nf'
include { recordedManifest; configReportLines } from './analysis/modules.nf'
include { moduleReportLines; outputReportLines; selectionReportLines } from './analysis/modules.nf'
include { intermediatesDir; verificationReportFile } from './analysis/lib/nf/paths.nf'
include { analysisPlan } from './analysis/lib/nf/plan.nf'
include { VerifyAnalysis } from './analysis/0_verify_analysis.nf'

workflow {
    // Before anything else, and before the run table is read.
    def module = requireModule(params.containsKey('module') ? params.module : null)

    // The same call a module makes, so the results this checks are the results it reads.
    def plan = analysisPlan(module)

    VerifyAnalysis(channel.value([
        manifest     : recordedManifest().join('\n'),
        header       : (moduleReportLines(module) + configReportLines() +
                        outputReportLines(module) +
                        selectionReportLines(plan.runs, plan.selected, plan.targets)).join('\n'),
        reportFile   : verificationReportFile(module),
        intermediates: intermediatesDir(),
        targets      : plan.targets ]))
}
