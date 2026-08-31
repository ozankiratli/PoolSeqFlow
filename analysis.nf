#!/usr/bin/env nextflow

// The analysis layer's entry point, beside poolseqflow.nf and dryrun.nf.
//
// One module per invocation: `--module <name>`, which ./PoolSeqFlow-analysis supplies. It reads
// results a pipeline run published and writes an analysis of its own; it never produces, moves
// or removes anything the pipeline made.

nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from './scripts/resolve_parameters.nf'
include { variantPlan } from './scripts/variants.nf'
include { requireModule; selectedRuns; resultsTargets } from './analysis/modules.nf'
include { recordedManifest; configReportLines } from './analysis/modules.nf'
include { moduleReportLines; outputReportLines; selectionReportLines } from './analysis/modules.nf'
include { intermediatesDir; verificationReportFile } from './analysis/modules.nf'
include { VerifyAnalysis } from './analysis/0_verify_analysis.nf'

workflow {
    // Before anything else, and before the run table is read: a mistyped module name should cost
    // nothing.
    def module = requireModule(params.containsKey('module') ? params.module : null)

    // In this order, as poolseqflow.nf calls them: runDefinitions() must copy each run's
    // parameters before resolveParameters() fills the computed ones in.
    def run_defs = runDefinitions()
    resolveParameters()

    // The pipeline's own partition of the runs, which is what decides the results directory
    // each one wrote to.
    def plan = variantPlan(run_defs)

    def selected = selectedRuns(run_defs)
    def targets  = resultsTargets(plan, selected, module)

    VerifyAnalysis(channel.value([
        manifest     : recordedManifest().join('\n'),
        header       : (moduleReportLines(module) + configReportLines() +
                        outputReportLines(module) +
                        selectionReportLines(run_defs, selected, targets)).join('\n'),
        reportFile   : verificationReportFile(module),
        intermediates: intermediatesDir(),
        targets      : targets ]))
}
