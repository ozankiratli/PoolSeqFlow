// The roster: which modules exist, and what each one declares about itself.
//
// Imported by a MODULE as well as by the frame: analysisPlan() asks it what the module it was
// given needs, so a module's manifest is the one statement of that and its main.nf repeats
// nothing.
//
// Nothing here includes a module: a module is its own pipeline and imports what it wants from
// here. The report the frame prints is in analysis/modules.nf, which reads this.

nextflow.enable.dsl=2

include { installDir } from './paths.nf'

// Where installed modules live: inside this release's own installation. From installDir() and
// not projectDir, which is the entry script's directory - the MODULE's own when a module is
// running, and the store is not inside a module.
def moduleStore() {
    return "${installDir()}/analysis/modules".toString()
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
