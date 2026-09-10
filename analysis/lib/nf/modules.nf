// The roster: which modules exist, and what each one declares about itself.
//
// Imported by a MODULE as well as by the frame: analysisPlan() asks it what the module it was
// given needs.
//
// Nothing here includes a module: a module is its own pipeline and imports what it wants from
// here. The report the frame prints is in analysis/modules.nf, which reads this.

nextflow.enable.dsl=2

include { frameVersion; installDir } from './paths.nf'

// Where installed modules live: inside this release's own installation. From installDir() and
// not projectDir, which is the entry script's directory - the MODULE's own when a module is
// running, and the store is not inside a module.
def moduleStore() {
    return "${installDir()}/analysis/modules".toString()
}

// Where installed libraries live, inside the module store under a name no module may take.
// A library is a module's dependency rather than something a project runs, so it is not in the
// roster and `analysis <name>` never resolves to one.
// A function and not a top-level constant: the strict parser allows only declarations at the
// top level of a script.
def libraryDirName() {
    return 'lib'
}

def libraryStore() {
    return "${moduleStore()}/${libraryDirName()}".toString()
}

// The R files a module's script must source, in the order its libraries are declared. Read from
// the module's own manifest so the list exists once: main.nf repeating it was a second list to
// keep equal, and a disagreement between them was silent.
def moduleLibraryFiles(Object name) {
    def manifest = readManifest(file("${moduleStore()}/${name}"))
    if (manifest == null) return []
    return manifest.libraries.collect { lib ->
        def dir = file("${libraryStore()}/${lib}")
        if (!dir.exists()) {
            throw new IllegalStateException(
                "module '${name}' declares the library '${lib}', which is not installed in\n" +
                "    ${libraryStore()}\n" +
                "Reinstall the module so its libraries come with it.")
        }
        dir.listFiles().findAll { f -> f.name.endsWith('.R') }.sort { a, b -> a.name <=> b.name }
    }.flatten().collect { f -> "${f}".toString() }
}

// The .cpp a module's libraries offer, resolved the same way as their R. A module that offers a
// compiled path publishes these beside its result whether or not the run used them.
def moduleCompiledFiles(Object name) {
    def manifest = readManifest(file("${moduleStore()}/${name}"))
    if (manifest == null) return []
    return manifest.libraries.collect { lib ->
        file("${libraryStore()}/${lib}").listFiles()
            .findAll { f -> f.name.endsWith('.cpp') }.sort { a, b -> a.name <=> b.name }
    }.flatten().collect { f -> "${f}".toString() }
}

// The published-table contract a module declares it speaks. Bumped when a column's name or
// meaning changes.
def contractVersion() {
    return 'freq-1'
}

// The modules the frame itself provides. `verify` runs nothing after the checks. It ships with
// the pipeline and installs nothing, so it carries the pipeline's own license and no packages.
def builtinModules() {
    return [
        verify: [
            summary : 'report what the analysis layer can see, and produce nothing',
            version : frameVersion(),
            contract: contractVersion(),
            license : 'Apache-2.0',
            needs   : [],
            libraries: [],
            gates   : [],
            outputs : [],
            packages: [],
            builtin : true,
        ],
    ]
}

// Compares two dotted numeric versions componentwise: negative, zero or positive as the first
// sorts before, with, or after the second. A missing component counts as zero, so 3.0 and 3.0.0
// are one version.
def compareVersions(String a, String b) {
    def width = Math.max(a.tokenize('.').size(), b.tokenize('.').size())
    def pad = [0] * width
    def left = (a.tokenize('.').collect { part -> part.toInteger() } + pad).take(width)
    def right = (b.tokenize('.').collect { part -> part.toInteger() } + pad).take(width)
    def first = (0..<width).find { i -> left[i] != right[i] }
    return first == null ? 0 : (left[first] <=> right[first])
}

// One `packages` entry, checked. A spec is a name and an exact version and nothing else: no
// build string, no range, no channel.
def checkPackageSpec(Object manifest, Object spec) {
    if (!(spec instanceof CharSequence) || !("${spec}" ==~ /[a-z0-9][a-z0-9._-]*=[A-Za-z0-9][A-Za-z0-9._+]*/)) {
        throw new IllegalStateException(
            "${manifest} asks for the package '${spec}', which is not a pinned conda spec.\n" +
            "Each entry of 'packages' is <name>=<version> and nothing else - one '=', an exact\n" +
            "version, no build string, no range, and no channel prefix. The release decides\n" +
            "which channels it installs from; the module decides what, and at which version.")
    }
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
    ['name', 'version', 'contract', 'summary', 'license', 'frame', 'environment'].each { field ->
        if (!parsed.containsKey(field)) {
            throw new IllegalStateException(
                "${manifest} has no '${field}'. A module manifest needs name, version, " +
                "contract, summary, license, frame and environment.")
        }
    }
    if ("${parsed.license}".trim().isEmpty()) {
        throw new IllegalStateException(
            "${manifest} carries an empty 'license'. It is the SPDX identifier the module is " +
            "published under - 'Apache-2.0', 'GPL-3.0-or-later' - and a result produced by this " +
            "module is produced under it.")
    }
    if (!("${parsed.frame}" ==~ /\d{8}\.\d{3}/)) {
        throw new IllegalStateException(
            "${manifest} gives 'frame' as '${parsed.frame}'. It is the oldest analysis frame " +
            "the module runs on, written as YYYYMMDD.NNN like analysis/frame.version itself.")
    }
    if (!("${parsed.environment}" ==~ /\d+(\.\d+)*/)) {
        throw new IllegalStateException(
            "${manifest} gives 'environment' as '${parsed.environment}'. It is the oldest " +
            "PoolSeqFlow release whose analysis environment holds what this module needs, " +
            "written as the release is - 3.0.0.")
    }
    if (parsed.containsKey('packages')) {
        if (!(parsed.packages instanceof List)) {
            throw new IllegalStateException(
                "${manifest} gives 'packages' as ${parsed.packages}. It is a list of conda " +
                "specs, and a module needing nothing beyond the release's own environment " +
                "leaves it out.")
        }
        parsed.packages.each { spec -> checkPackageSpec(manifest, spec) }
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
    if (!file("${dir}/citations.json").exists()) {
        throw new IllegalStateException(
            "${dir} has no citations.json. Every module says what it should be cited with - " +
            "the method it implements and the R packages it uses - because the frame cannot " +
            "know them for a module published separately.\n" +
            "Install the module again, or remove the directory.")
    }
    return [ summary    : "${parsed.summary}".toString(),
             version    : "${parsed.version}".toString(),
             contract   : "${parsed.contract}".toString(),
             license    : "${parsed.license}".trim().toString(),
             frame      : "${parsed.frame}".toString(),
             environment: "${parsed.environment}".toString(),
             needs      : parsed.needs ?: [],
             libraries  : (parsed.libraries ?: []).collect { lib -> "${lib}".toString() },
             gates      : parsed.gates ?: [],
             outputs    : parsed.outputs ?: [],
             packages   : (parsed.packages ?: []).collect { spec -> "${spec}".toString() },
             builtin    : false,
             dir        : "${dir}".toString(),
             entry      : "${entry}".toString() ]
}

// What the named module needs of the installation it is about to run in, against what the
// installation is. The frame is read from a file either half of an analysis can see. The release
// is null in a module's own run - Nextflow reads the root nextflow.config only for an entry
// script beside it - so the environment check is skipped there.
def checkModuleCompatible(String module) {
    def entry = moduleEntry(module)
    if (entry.builtin) return
    def frame = frameVersion()
    if (compareVersions(entry.frame, frame) > 0) {
        throw new IllegalStateException(
            "'${module}' v${entry.version} needs analysis frame ${entry.frame} or newer, and " +
            "this installation is ${frame}.\n" +
            "The frame is what a module imports and runs under. Install a newer PoolSeqFlow, or " +
            "a build of '${module}' published for this one.")
    }
    def release = "${workflow.manifest.version ?: ''}".trim()
    if (!release.isEmpty() && compareVersions(entry.environment, release) > 0) {
        throw new IllegalStateException(
            "'${module}' v${entry.version} needs the analysis environment of PoolSeqFlow " +
            "${entry.environment} or newer, and this is ${release}.\n" +
            "The packages a module runs on are installed once, for the release. Install a newer " +
            "PoolSeqFlow, or a build of '${module}' published for this one.")
    }
}

// Every module available to this invocation: the frame's own, plus whatever is installed.
def moduleRoster() {
    def roster = builtinModules()
    def store = file(moduleStore())
    if (store.exists()) {
        store.listFiles().findAll { entry -> entry.isDirectory() && entry.name != libraryDirName() }
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

// The named module, or a refusal listing what there is. Called while the DAG is built.
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
