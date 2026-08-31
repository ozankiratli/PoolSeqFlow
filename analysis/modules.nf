// What the analysis layer can do, and which results an invocation covers.
//
// A module is one analysis: it reads what a pipeline run published and writes a result of its
// own. This file is the only list of them - the wrapper keeps no copy and refuses nothing itself.
//
// Installed modules are read from the store, one directory each, so adding one is adding a
// directory. Nothing here includes a module: a module is its own pipeline and imports what it
// wants from analysis/lib.

nextflow.enable.dsl=2

include { runToken } from '../scripts/variants.nf'
include { analysisParams } from '../scripts/0_verify_environment.nf'

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
    return [ summary : "${parsed.summary}".toString(),
             version : "${parsed.version}".toString(),
             contract: "${parsed.contract}".toString(),
             needs   : parsed.needs ?: [],
             gates   : parsed.gates ?: [],
             builtin : false,
             dir     : "${dir}".toString(),
             entry   : "${dir}/main.nf".toString() ]
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
            "    PoolSeqFlow-analysis <module>\n" +
            "Available here: ${known}")
    }
    if (!moduleRoster().containsKey(asked)) {
        throw new IllegalArgumentException(
            "'${asked}' is not installed.\n" +
            "Available here: ${known}\n" +
            "Modules are installed separately from the pipeline:\n" +
            "    PoolSeqFlow-analysis modules available")
    }
    return asked
}

def moduleEntry(String name) {
    return moduleRoster()[requireModule(name)]
}

// The published files a module can read. `step` is the step that produced the class, and
// therefore whose variant owns the directory it was promoted into; `subdir` is the key under
// dir.output naming that directory.
def artifactClasses() {
    return [
        frequencies: [ step: 7, subdir: 'freq',  pattern: '*_freq.tsv',  label: 'frequency tables' ],
        depths     : [ step: 7, subdir: 'freq',  pattern: '*_depth.tsv', label: 'depth tables' ],
        vcf        : [ step: 6, subdir: 'vcf',   pattern: '*.vcf',       label: 'called VCF' ],
        bams       : [ step: 4, subdir: 'ready', pattern: '*_ready.bam', label: 'ready BAMs' ],
    ]
}

// One of the analysis layer's own settings, from analysis/defaults.config and whatever the
// project put over it.
def analysisSetting(String key) {
    if (!params.containsKey('analysis') || !(params.analysis instanceof Map)) {
        throw new IllegalStateException(
            "the analysis layer's own settings are missing. Modules are run through\n" +
            "    PoolSeqFlow-analysis <module>\n" +
            "which loads analysis/defaults.config from the installation before anything in your\n" +
            "project; started any other way there are no defaults to start from.")
    }
    if (!params.analysis.containsKey(key)) {
        throw new IllegalStateException(
            "analysis.${key} is not set, and analysis/defaults.config in the installation is " +
            "where it comes from. This copy of PoolSeqFlow is incomplete.")
    }
    return params.analysis[key]
}

// Everything the analysis layer writes lives under one root, on the working volume. `complete`
// moves it to permanent storage.
def analysisRoot() {
    return "${params.mainDir}/Analysis".toString()
}

// The derived files modules share. Built on demand, once, and reused by every module that
// needs them.
def intermediatesDir() {
    return "${analysisRoot()}/Main".toString()
}

// What this invocation's results folder is called. Empty means the module's own name, so
// `mds` writes to Results/mds until you say otherwise.
def resultsFolderName(String module) {
    def name = "${analysisSetting('folderName') ?: ''}".trim()
    if (name.isEmpty()) return module
    checkFolderName(name)
    return name
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def folderNameRefusal(String name, String why) {
    return new IllegalArgumentException(
        "analysis.folderName is '${name}', which ${why}.\n" +
        "It names a folder under Analysis/Results and may be a path, as 'MDS/SummerPops' is. " +
        "Use letters, digits, dot, dash, underscore and '/'.")
}

// A folder name may be a path - 'MDS/SummerPops'. It may not leave Results/.
def checkFolderName(String name) {
    if (name.startsWith('/')) throw folderNameRefusal(name, 'is an absolute path')
    def segments = name.tokenize('/')
    if (segments.isEmpty()) throw folderNameRefusal(name, 'names nothing')
    segments.each { segment ->
        if (segment == '.' || segment == '..') {
            throw folderNameRefusal(name, "contains a '${segment}' segment")
        }
        if (!(segment ==~ /[A-Za-z0-9._-]+/)) {
            throw folderNameRefusal(name, "has a part that cannot be a folder name: '${segment}'")
        }
    }
}

// This invocation's results folder, holding one analysis.
def resultsRoot(String module) {
    return "${analysisRoot()}/Results/${resultsFolderName(module)}".toString()
}

// Where one results directory's analysis goes inside it. A single run has no name anywhere, so
// its analysis sits in the folder directly; runs are told apart by the directory they produced.
def targetResultsDir(String module, String label) {
    if (!params.multiRun) return resultsRoot(module)
    return "${resultsRoot(module)}/${label}".toString()
}

// The verification record, written beside the results it cleared. One per invocation, however
// many results directories it covers.
def verificationReportFile(String module) {
    return "${resultsRoot(module)}/0_verify_analysis.txt".toString()
}

// A setting as it should read back to the user who wrote it.
def renderSetting(Object value) {
    if (value instanceof List) return "[${value.collect { v -> "'${v}'" }.join(', ')}]"
    return "'${value}'"
}

// The runs this invocation covers, from analysis.runs.
//
// `all` is a keyword and a list is always run names, so a run named all is still reachable by
// writing ['all'].
def selectedRuns(List runDefs) {
    def wanted = analysisSetting('runs')
    def asList = (wanted instanceof List)

    if (!asList && "${wanted}" == 'all') return runDefs

    if (!params.multiRun) {
        throw new IllegalArgumentException(
            "analysis.runs is ${renderSetting(wanted)}, but this project is a single run:\n" +
            "parameters.config has multiRun = false, so no run has a name to select. Leave\n" +
            "analysis.runs at 'all', which is the one results directory this project has.")
    }

    def names = (asList ? wanted.collect { n -> "${n}".toString() } : ["${wanted}".toString()]).unique()
    if (names.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.runs is an empty list, so it selects nothing. Name the runs to analyse, " +
            "or set it to 'all'.")
    }

    def known = runDefs.collect { run -> "${run.runId}".toString() }
    def unknown = names.findAll { n -> !known.contains(n) }
    if (!unknown.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.runs names ${unknown.size() == 1 ? 'a run' : 'runs'} that ${params.multiRunFile} " +
            "does not: ${unknown.join(', ')}\n" +
            "The runs in that table are: ${known.join(', ')}")
    }
    return runDefs.findAll { run -> names.contains("${run.runId}".toString()) }
}

// The variant at `step` whose members cover these runs. Runs sharing a directory at one step
// share one ancestor at every earlier step, so there is exactly one.
def ancestorAt(Map plan, List members, int step) {
    def found = plan.variants[step].find { cand -> cand.members.containsAll(members) }
    if (found == null) {
        throw new IllegalStateException(
            "no step ${step} variant covers ${members.collect { m -> runToken(m) }.join(', ')}. " +
            "The plan and the run table disagree about which runs share work.")
    }
    return found
}

// What a results directory is called. A single run's has no name, as the pipeline leaves it.
def directoryLabel(Map variant) {
    if (variant.runId == null) return 'Output'
    return "${variant.dir.outputs}".tokenize('/').last()
}

// One entry per results directory the selected runs produced, and where each artifact class sits
// inside it. Two runs whose tables are the same file share a directory and are covered once.
def resultsTargets(Map plan, List selected, String module) {
    def wanted = selected.collect { run -> run.runId }
    def needs = moduleEntry(module).needs
    return plan.variants[7]
        .findAll { variant -> variant.members.any { member -> wanted.contains(member) } }
        .sort { a, b -> "${a.dir.outputs}" <=> "${b.dir.outputs}" }
        .collect { variant ->
            def classes = artifactClasses().collectEntries { name, spec ->
                def owner = ancestorAt(plan, variant.members, spec.step)
                [ name, [ label   : spec.label,
                          pattern : spec.pattern,
                          dir     : "${owner.dir.output[spec.subdir]}".toString(),
                          required: needs.contains(name) ] ]
            }
            def label = directoryLabel(variant)
            return [ label   : label,
                     dir     : "${variant.dir.outputs}".toString(),
                     members : variant.members.collect { member -> runToken(member) },
                     selected: variant.members.findAll { member -> wanted.contains(member) }
                                              .collect { member -> runToken(member) },
                     classes : classes,
                     results : targetResultsDir(module, label) ]
        }
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
