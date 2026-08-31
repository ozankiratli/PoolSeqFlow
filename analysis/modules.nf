// What the analysis layer can do, and which results an invocation covers.
//
// A module is one analysis: it reads what a pipeline run published and writes a result of its
// own. The roster below is the only list of them - the wrapper keeps no copy and refuses nothing
// itself.

nextflow.enable.dsl=2

include { runToken } from '../scripts/variants.nf'
include { analysisParams } from '../scripts/0_verify_environment.nf'

// Every module this release ships.
//
//   summary  one line, printed when the module is named and in the verification report
//   needs    artifact classes that must be present before it runs; an absent one fails the run
//   gates    assumptions checked before any compute
def moduleRoster() {
    return [
        verify: [
            summary: 'report what the analysis layer can see, and produce nothing',
            needs  : [],
            gates  : [],
        ],
    ]
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
            "Modules in this release: ${known}")
    }
    if (!moduleRoster().containsKey(asked)) {
        throw new IllegalArgumentException(
            "'${asked}' is not a module of this release.\n" +
            "Modules in this release: ${known}")
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
            return [ label   : directoryLabel(variant),
                     dir     : "${variant.dir.outputs}".toString(),
                     members : variant.members.collect { member -> runToken(member) },
                     selected: variant.members.findAll { member -> wanted.contains(member) }
                                              .collect { member -> runToken(member) },
                     classes : classes ]
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

// What the report says about the module, before anything is checked.
def moduleReportLines(String module) {
    return ["MODULE:                ${module} - ${moduleEntry(module).summary}".toString()]
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
