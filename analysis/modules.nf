// What the analysis layer can do, and what it says for itself before it runs.
//
// A module is one analysis: it reads what a pipeline run published and writes a result of its
// own. The roster itself is in analysis/lib/modules.nf, which a module reads too; this file is
// what the frame prints before it runs one.

nextflow.enable.dsl=2

include { analysisParams } from '../scripts/0_verify_environment.nf'
include { analysisSetting; renderSetting } from './lib/paths.nf'
include { intermediatesDir; resultsRoot } from './lib/paths.nf'
include { moduleEntry; moduleStore } from './lib/modules.nf'

// The configuration the pipeline recorded beside the results, recomputed from the project as it
// stands now. The analysis layer's own parameters are dropped: they did not exist when the
// results were produced, and every one of them would read as an added setting.
def recordedManifest() {
    def mine = ['analysis.', 'module=']
    return analysisParams(params).findAll { line -> !mine.any { prefix -> line.startsWith(prefix) } }
}

// What the report says about the configuration: the files this invocation was assembled from,
// and where a project's own starts from when it has none.
def configReportLines() {
    def files = workflow.configFiles.collect { path -> "${path}".toString() }
    def lines = ['CONFIGURATION:         read, in order, each winning over the one before it:']
    files.each { path -> lines << "CONFIGURATION:             ${path}".toString() }
    if (!files.any { path -> path.endsWith('/analysis.config') }) {
        lines << 'CONFIGURATION:         this project has no analysis.config, so every setting below is'
        lines << 'CONFIGURATION:         the installation default. To change one, copy'
        lines << "CONFIGURATION:             ${projectDir}/analysis/analysis.config.template".toString()
        lines << 'CONFIGURATION:         beside parameters.config as analysis.config.'
    }
    return lines
}

// What the report says about the module, before anything is checked. The version reported is the
// module's own, not the release's.
def moduleReportLines(String module) {
    def entry = moduleEntry(module)
    def lines = ["MODULE:                ${module} v${entry.version} - ${entry.summary}".toString()]
    lines << (entry.builtin
        ? "MODULE:                shipped with the pipeline; speaks table contract ${entry.contract}".toString()
        : "MODULE:                installed at ${entry.dir}".toString())
    if (!entry.builtin) {
        lines << "MODULE:                speaks table contract ${entry.contract}".toString()
    }
    return lines
}

// What the report says about where this invocation writes.
def outputReportLines(String module) {
    def named = "${analysisSetting('folderName') ?: ''}".trim()
    def lines = ["ANALYSIS OUTPUT:       results folder".toString(),
                 "ANALYSIS OUTPUT:           ${resultsRoot(module)}".toString()]
    lines << (named.isEmpty()
        ? "ANALYSIS OUTPUT:       named after the module. Set analysis.folderName to keep two"
        : "ANALYSIS OUTPUT:       from analysis.folderName = '${named}'. Set it again to keep two")
    lines << "ANALYSIS OUTPUT:       settings of one module side by side; a folder that already holds"
    lines << "ANALYSIS OUTPUT:       an analysis is refused rather than written over."
    lines << "ANALYSIS OUTPUT:       shared intermediates".toString()
    lines << "ANALYSIS OUTPUT:           ${intermediatesDir()}".toString()
    return lines
}

// What the report says about the selection: which runs, and which directories they land in.
def selectionReportLines(List runDefs, List selected, List targets) {
    def lines = ["RUN SELECTION:         analysis.runs = ${renderSetting(analysisSetting('runs'))}".toString()]

    if (!params.multiRun) {
        lines << "RUN SELECTION:         single run - one results directory".toString()
    }
    else {
        def plural = targets.size() == 1 ? 'directory' : 'directories'
        lines << "RUN SELECTION:         ${selected.size()} of ${runDefs.size()} runs, in ${targets.size()} results ${plural}".toString()
        // A run named `all` is legal in the table and is what the keyword spells.
        if (runDefs.any { run -> "${run.runId}" == 'all' }) {
            lines << "RUN SELECTION:         a run in ${params.multiRunFile} is named 'all', which is also the".toString()
            lines << "RUN SELECTION:         keyword for every run. Written bare it is the keyword; write".toString()
            lines << "RUN SELECTION:         ['all'] to mean that run alone.".toString()
        }
    }

    targets.each { target ->
        lines << "RUN SELECTION:             ${target.label}".toString()
        lines << "RUN SELECTION:                 ${target.dir}".toString()
        if (params.multiRun) {
            lines << "RUN SELECTION:                 selected: ${target.selected.join(', ')}".toString()
            def extra = target.members.findAll { member -> !target.selected.contains(member) }
            if (!extra.isEmpty()) {
                lines << "RUN SELECTION:                 also the results of ${extra.join(', ')} - those runs".toString()
                lines << "RUN SELECTION:                 produced the same tables, so there is one directory".toString()
                lines << "RUN SELECTION:                 here and one analysis of it".toString()
            }
        }
    }
    return lines
}
