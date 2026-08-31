// What the analysis layer can do, and what it says for itself before it runs.
//
// A module is one analysis: it reads what a pipeline run published and writes a result of its
// own. This file is the only list of them - the wrapper keeps no copy and refuses nothing itself.
//
// Installed modules are read from the store, one directory each, so adding one is adding a
// directory. Nothing here includes a module: a module is its own pipeline and imports what it
// wants from analysis/lib, which is also where the layout and the run selection live.

nextflow.enable.dsl=2

include { analysisParams } from '../scripts/0_verify_environment.nf'
include { analysisSetting; renderSetting } from './lib/paths.nf'
include { intermediatesDir; resultsRoot } from './lib/paths.nf'

// Where installed modules live: inside this release's own installation.
def moduleStore() {
    return "${projectDir}/analysis/modules".toString()
}

// The published-table contract a module declares it speaks. Bumped only when a column's name or
// meaning changes - which has not happened since the project's first commit.
def contractVersion() {
    return 'freq-1'
}

// The modules the frame itself provides. `verify` runs nothing after the checks, which is what
// makes it the way to ask whether a project is ready without spending anything.
def builtinModules() {
    return [
        verify: [
            summary : 'report what the analysis layer can see, and produce nothing',
            version : "${workflow.manifest.version ?: 'unknown'}".toString(),
            contract: contractVersion(),
            needs   : [],
            gates   : [],
            builtin : true,
        ],
    ]
}

// One installed module's manifest, or null when the directory holds nothing usable. A directory
// without a manifest is skipped in silence; a manifest that cannot be read is not.
def readManifest(Object dir) {
    def manifest = file("${dir}/manifest.json")
    if (!manifest.exists()) return null
    def parsed
    try {
        parsed = new groovy.json.JsonSlurper().parseText(manifest.text)
    }
    catch (Exception e) {
        throw new IllegalStateException(
            "${manifest} cannot be read: ${e.message}\n" +
            "A module's manifest is JSON. Reinstall the module, or remove ${dir}.")
    }
    ['name', 'version', 'contract', 'summary'].each { field ->
        if (!parsed.containsKey(field)) {
            throw new IllegalStateException(
                "${manifest} has no '${field}'. A module manifest needs name, version, " +
                "contract and summary.")
        }
    }
    if (parsed.name != "${dir}".tokenize('/').last()) {
        throw new IllegalStateException(
            "${manifest} calls the module '${parsed.name}', but it is installed in a directory " +
            "named '${"${dir}".tokenize('/').last()}'. The two have to agree: the directory is " +
            "how a module is found and the name is how it is asked for.")
    }
    // main.nf is what the wrapper runs second, and the wrapper cannot look for it until this
    // verification has already cleared the results folder.
    def entry = file("${dir}/main.nf")
    if (!entry.exists()) {
        throw new IllegalStateException(
            "${dir} has a manifest but no main.nf. A module is a pipeline of its own and " +
            "main.nf is that pipeline. Install the module again, or remove the directory.")
    }
    return [ summary : "${parsed.summary}".toString(),
             version : "${parsed.version}".toString(),
             contract: "${parsed.contract}".toString(),
             needs   : parsed.needs ?: [],
             gates   : parsed.gates ?: [],
             builtin : false,
             dir     : "${dir}".toString(),
             entry   : "${entry}".toString() ]
}

// Every module available to this invocation: the frame's own, plus whatever is installed.
def moduleRoster() {
    def roster = builtinModules()
    def store = file(moduleStore())
    if (store.exists()) {
        store.listFiles().findAll { entry -> entry.isDirectory() }
            .sort { a, b -> "${a}" <=> "${b}" }
            .each { dir ->
                def found = readManifest(dir)
                if (found != null) roster[dir.name] = found
            }
    }
    return roster
}

def moduleNames() {
    return moduleRoster().keySet().sort()
}

// The named module, or a refusal listing what there is. Called while the DAG is built, so a
// mistyped name costs nothing.
def requireModule(Object name) {
    def asked = name == null ? '' : "${name}".trim()
    def known = moduleNames().join(', ')
    if (asked.isEmpty()) {
        throw new IllegalArgumentException(
            "no module was named. Run one from your project directory:\n" +
            "    PoolSeqFlow analysis <module>\n" +
            "Available here: ${known}")
    }
    if (!moduleRoster().containsKey(asked)) {
        throw new IllegalArgumentException(
            "'${asked}' is not installed.\n" +
            "Available here: ${known}\n" +
            "Modules are installed separately from the pipeline, one directory each, into\n" +
            "    ${moduleStore()}")
    }
    return asked
}

def moduleEntry(String name) {
    return moduleRoster()[requireModule(name)]
}

// The artifact classes the named module cannot run without, from its manifest.
def moduleNeeds(String name) {
    return moduleEntry(name).needs
}

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
