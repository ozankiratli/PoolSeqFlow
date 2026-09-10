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
             folderName: '',      // Empty means the module's own name.
             // How to READ the metadata file. Everything here describes the project's own
             // records rather than this invocation.
             metadata  : metadataDefaults(),
             // What the experiment WAS: which pools are independent of each other, and what a
             // time axis makes of them.
             design    : designDefaults(),
             // One scope per installed module, named after it. Open, so it has no defaults of
             // its own - moduleSettings() checks a module's scope against that module's list.
             modules   : [:] ]
}

// The settings that say how the metadata file is read.
def metadataDefaults() {
    return [ // Cells that mean "no value" beyond an empty one. Matched whole, case sensitively,
             // with * and ? as wildcards. Empty means only a blank cell is missing.
             missingValueEncoding: [],
             // The time axis. Empty kind means the project has not declared one.
             timeVar   : [ column: 'exp_time', kind: '', unit: '', order: [], format: '', locale: 'en' ],
             // What a pt_ column holds, one scope per column: `kind` and, for a categorical
             // scale, `levels`. Open - the columns are the project's own.
             phenotypes: [:],
             // What a cov_ column holds, on the same shape and the same four kinds. A cov_
             // column left out is recorded and reported; declaring one gives it a typed value.
             covariates: [:] ]
}

// The settings that say what the experiment was.
def designDefaults() {
    return [ // Which exp_ columns identify one thing the experiment set up, and which of those
             // index repeats. Empty `by` means every exp_ variable but time; a key column in
             // neither replicate list is a condition.
             by           : [],
             biologicalRep: [],
             technicalRep : [],
             // Which cov_ columns are part of the design, and so may enter a module's model.
             // Empty means every cov_ column that has a declared scale.
             covariates   : [],
             // What a time axis makes of the design. Only it can leave a trajectory ragged, so
             // this is all the series scope holds.
             series       : [ incomplete: 'fail' ] ]
}

// The `analysis` scope as the project wrote it. It may not exist at all: analysis.config carries
// only what the user chose to write.
def analysisScope() {
    return params.containsKey('analysis') && params.analysis instanceof Map ? params.analysis : [:]
}

// One scope's settings, merged key by key over its defaults, refusing a key the scope does not
// have.
//
// Nextflow REPLACES a map rather than merging into it: a project writing only
// `timeVar { kind = 'numerical' }` gets a map holding kind and nothing else.
def mergeScope(String path, Map defaults, Object written) {
    if (!(written instanceof Map)) {
        throw new IllegalArgumentException(
            "${path} is a scope holding ${defaults.keySet().sort().join(', ')}, and this project " +
            "sets it to a single value.\n" +
            "Write it as a block:\n" +
            "    ${path} {\n        ${defaults.keySet().sort().first()} = ...\n    }")
    }
    def unknown = written.keySet().collect { name -> "${name}".toString() }
                         .findAll { name -> !defaults.containsKey(name) }
    if (!unknown.isEmpty()) {
        throw new IllegalArgumentException(
            "${path} is given ${unknown.size() == 1 ? 'a setting' : 'settings'} it does not have: " +
            "${unknown.join(', ')}\n" +
            "It has: ${defaults.keySet().sort().join(', ')}.")
    }
    return defaults + written
}

// Every key the project wrote under `analysis`, checked before any of them is read.
//
// Nothing else would notice a misspelling: a reader asks for the key it wants by name, so
// `analysis { timevar { ... } }` sits unread and the project runs under defaults it did not
// choose. Called once from analysisPlan(), ahead of any compute.
def checkAnalysisScope() {
    def scope = analysisScope()
    def defaults = analysisDefaults()
    def unknown = scope.keySet().collect { name -> "${name}".toString() }
                       .findAll { name -> !defaults.containsKey(name) }
    if (!unknown.isEmpty()) {
        throw new IllegalArgumentException(
            "the analysis scope is given ${unknown.size() == 1 ? 'a setting' : 'settings'} the " +
            "analysis layer does not have: ${unknown.join(', ')}\n" +
            "It has: ${defaults.keySet().sort().join(', ')}.\n" +
            "A module's settings go in analysis.modules.<name>, how the metadata file is read " +
            "goes in analysis.metadata, and what the experiment was goes in analysis.design.")
    }
    if (scope.containsKey('metadata')) {
        mergeScope('analysis.metadata', metadataDefaults(), scope.metadata)
    }
    if (scope.containsKey('design')) {
        mergeScope('analysis.design', designDefaults(), scope.design)
    }
}

// One of the analysis layer's own settings, as the project set it or as it defaults.
def analysisSetting(String key) {
    def defaults = analysisDefaults()
    if (!defaults.containsKey(key)) {
        throw new IllegalStateException(
            "analysis.${key} is not a setting the analysis layer has. It has: " +
            "${defaults.keySet().sort().join(', ')}.")
    }
    def scope = analysisScope()
    // containsKey and not a truthiness test: an empty list is a value the user wrote, and
    // selectedRuns() refuses it by name.
    if (!scope.containsKey(key)) return defaults[key]
    if (!(defaults[key] instanceof Map)) return scope[key]
    return mergeScope("analysis.${key}", defaults[key], scope[key])
}

// One setting from a scope the frame owns, as the project set it or as it defaults.
//
// The whole scope is merged before one key is read, so a project that wrote a single sub-key
// keeps every other default in that scope and a key it does not have is refused.
def frameSetting(String scope, Map defaults, String key) {
    if (!defaults.containsKey(key)) {
        throw new IllegalStateException(
            "analysis.${scope}.${key} is not a setting the analysis layer has. It has: " +
            "${defaults.keySet().sort().join(', ')}.")
    }
    def outer = analysisScope()
    def written = outer.containsKey(scope)
        ? mergeScope("analysis.${scope}", defaults, outer[scope]) : defaults
    if (!(defaults[key] instanceof Map)) return written[key]
    // An empty default map is an OPEN namespace - covariates are named after the project's own
    // columns, so there is no list to check them against here. Whatever reads it does its own
    // checking, against the columns the metadata actually has.
    if (defaults[key].isEmpty()) {
        if (written[key] instanceof Map) return written[key]
        throw new IllegalArgumentException(
            "analysis.${scope}.${key} is set to a single value, and it is a scope holding one " +
            "block per column.")
    }
    if (written[key].is(defaults[key])) return defaults[key]
    return mergeScope("analysis.${scope}.${key}", defaults[key], written[key])
}

// One of the settings that say how the metadata file is read.
def metadataSetting(String key) {
    return frameSetting('metadata', metadataDefaults(), key)
}

// One of the settings that say what the experiment was.
def designSetting(String key) {
    return frameSetting('design', designDefaults(), key)
}

// Every setting one module has, as the project set them over the module's own defaults.
//
// The module passes its whole scope's defaults and gets the whole scope back. A key the defaults
// do not have is refused, and a key they have that the project did not set takes the default.
def moduleSettings(String module, Map defaults) {
    if (params.containsKey(module)) {
        throw new IllegalArgumentException(
            "params.${module} is set at the top level of a configuration file, and a module's " +
            "settings belong inside the analysis scope:\n" +
            "    analysis {\n" +
            "        modules {\n" +
            "            ${module} {\n" +
            "                // ...\n" +
            "            }\n" +
            "        }\n" +
            "    }\n" +
            "A top-level key reaches the manifest this project is checked against, so every " +
            "analysis would report it as a setting added since the results were produced and " +
            "refuse to run.")
    }

    def scope = analysisScope()
    // A module's own scope, one level down. The nesting is what keeps a module named `series` or
    // `metadata` from reading a setting of the frame's.
    def installed = scope.containsKey('modules') && scope.modules instanceof Map ? scope.modules : [:]
    if (scope.containsKey('modules') && !(scope.modules instanceof Map)) {
        throw new IllegalArgumentException(
            "analysis.modules is set to a single value, and it is the scope every module's own " +
            "settings sit inside.\n" +
            "Write it as\n    analysis {\n        modules {\n            ${module} {\n" +
            "                // ...\n            }\n        }\n    }")
    }
    def mine = installed.containsKey(module) && installed[module] instanceof Map
        ? installed[module] : [:]

    def unknown = mine.keySet().collect { key -> "${key}".toString() }
                      .findAll { key -> !defaults.containsKey(key) }
    if (!unknown.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.modules.${module} is given ${unknown.size() == 1 ? 'a setting' : 'settings'} " +
            "the module '${module}' does not have: ${unknown.join(', ')}\n" +
            "It has: ${defaults.keySet().sort().join(', ')}.")
    }

    // containsKey and not a truthiness test: an empty list is a value the user wrote.
    return defaults.collectEntries { key, fallback ->
        [ key, mine.containsKey(key) ? mine[key] : fallback ]
    }
}

// The analysis frame's own version, from analysis/frame.version in the installation.
//
// Not workflow.manifest.version: that is the PIPELINE release, which 0_verify_analysis.nf
// compares against the .poolseqflow_version the results carry.
//
// moduleDir is this file's own directory whichever script is the entry point.
def frameVersion() {
    def record = file("${moduleDir}/../../frame.version")
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
// Nextflow computes points at the installation. The wrapper exports POOLSEQFLOW_HOME.
def installDir() {
    def dir = "${System.getenv('POOLSEQFLOW_HOME') ?: ''}".trim()
    if (dir.isEmpty() || !file("${dir}/analysis/lib/nf/paths.nf").exists()) {
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

// What this invocation's results folder is called. Empty means the module's own name.
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
