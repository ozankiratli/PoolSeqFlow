// The analysis layer's own settings, and where everything it writes goes.
//
// The frame imports this and so does every module. These are the only definitions of the layout.

nextflow.enable.dsl=2

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

// The installation this invocation was launched from, and the only way anything in a run can
// find bin/, the library or the module store: a module is its own pipeline, so ${projectDir} is
// the module's own directory.
def installDir() {
    def dir = "${analysisSetting('installDir') ?: ''}".trim()
    if (dir.isEmpty() || !file("${dir}/analysis/lib/paths.nf").exists()) {
        throw new IllegalStateException(
            "the installation this analysis belongs to could not be found" +
            (dir.isEmpty() ? ': POOLSEQFLOW_HOME is not set' : " at ${dir}") + ".\n" +
            "Analyses are run through\n" +
            "    PoolSeqFlow-analysis <module>\n" +
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
