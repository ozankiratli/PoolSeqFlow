// The analysis layer's own settings, and where everything it writes goes.
//
// The frame imports this and so does every module. These are the only definitions of the layout.

nextflow.enable.dsl=2

// Every setting the analysis layer has of its own, and what it is when nobody says otherwise.
//
// A function and not a script-level constant: the strict parser rejects a statement outside a
// process, workflow or function.
def analysisDefaults() {
    return [ runs      : 'all',   // 'all' is a keyword; a list is always run names.
             folderName: ''    ]  // Empty means the module's own name.
}

// One of those settings, as the project set it or as it defaults.
//
// The scope is deliberately not declared anywhere: the default belongs to the code that reads
// it, and analysis.config carries only what the user chose to write.
def analysisSetting(String key) {
    def defaults = analysisDefaults()
    if (!defaults.containsKey(key)) {
        throw new IllegalStateException(
            "analysis.${key} is not a setting the analysis layer has. It has: " +
            "${defaults.keySet().sort().join(', ')}.")
    }
    def scope = params.containsKey('analysis') && params.analysis instanceof Map ? params.analysis : [:]
    // containsKey and not a truthiness test: an empty list is a value the user wrote, and
    // selectedRuns() refuses it by name rather than reading it as 'all'.
    return scope.containsKey(key) ? scope[key] : defaults[key]
}

// The analysis frame's own version, from analysis/frame.version in the installation.
//
// NOT workflow.manifest.version: that is the PIPELINE release, which 0_verify_analysis.nf
// compares against the .poolseqflow_version the results carry. And not a params key either -
// a later -c could set it, and a provenance record a project can rewrite records nothing.
//
// moduleDir is this file's own directory whichever script is the entry point, so the frame
// finds its version without being told where the installation is.
def frameVersion() {
    def record = file("${moduleDir}/../frame.version")
    def version = record.exists()
        ? record.readLines().collect { line -> line.trim() }
              .find { line -> !line.isEmpty() && !line.startsWith('#') } ?: ''
        : ''
    if (!(version ==~ /\d{8}\.\d{3}/)) {
        throw new IllegalStateException(
            "the analysis frame does not know its own version.\n" +
            "    ${record}\n" +
            "should hold one line of the form YYYYMMDD.NNN" +
            (version.isEmpty() ? ', and holds none' : ", and holds '${version}'") + ".\n" +
            "Every intermediate this run derived would otherwise be indistinguishable from one\n" +
            "derived by different code. Install this release again.")
    }
    return version
}

// The installation this invocation was launched from, and a refusal when it cannot be found. A
// module is its own pipeline, so ${projectDir} is the module's own directory and nothing
// Nextflow computes points at the installation. Both wrappers export POOLSEQFLOW_HOME.
def installDir() {
    def dir = "${System.getenv('POOLSEQFLOW_HOME') ?: ''}".trim()
    if (dir.isEmpty() || !file("${dir}/analysis/lib/paths.nf").exists()) {
        throw new IllegalStateException(
            "the installation this analysis belongs to could not be found" +
            (dir.isEmpty() ? ': POOLSEQFLOW_HOME is not set' : " at ${dir}") + ".\n" +
            "Analyses are run through\n" +
            "    PoolSeqFlow analysis <module>\n" +
            "which puts the installation in the environment for the run. Started any other way,\n" +
            "nothing in the run can reach the helpers in bin/.")
    }
    return dir
}

// A setting as it should read back to the user who wrote it.
def renderSetting(Object value) {
    if (value instanceof List) return "[${value.collect { v -> "'${v}'" }.join(', ')}]"
    return "'${value}'"
}

// Everything the analysis layer writes lives under one root, under mainDir.
def analysisRoot() {
    return "${params.mainDir}/Analysis".toString()
}

// Where modules put anything they derive. One directory for the project, shared by all of them.
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

// Where every analysis this project has produced sits, one folder each.
def resultsDir() {
    return "${analysisRoot()}/Results".toString()
}

// This invocation's results folder, holding one analysis.
def resultsRoot(String module) {
    return "${resultsDir()}/${resultsFolderName(module)}".toString()
}

// Where one results directory's analysis goes inside it. A single run has no name anywhere, so
// its analysis sits in the folder directly; runs are told apart by the directory they produced.
def targetResultsDir(String module, String label) {
    if (!params.multiRun) return resultsRoot(module)
    return "${resultsRoot(module)}/${label}".toString()
}

// What the verification record is called wherever it is written. Read by the stage that writes
// it and by the publish that has to carry it across.
def verificationRecordName() {
    return '0_verify_analysis.txt'
}

// The verification record, written beside the results it cleared. One per invocation, however
// many results directories it covers.
def verificationReportFile(String module) {
    return "${resultsRoot(module)}/${verificationRecordName()}".toString()
}
