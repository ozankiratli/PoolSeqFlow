// Values the pipeline computes when you have not set them yourself: a parameter left commented
// out in parameters.config is filled in here, from whatever the earlier ones ended up being.
// Absence is the signal, not emptiness, and every scope written here must already exist in
// parameters.config - a new top-level key made from inside a module is invisible to processes.

// Assigns only if the user has not.
def fill(Map scope, String key, Object value) {
    if (!scope.containsKey(key)) scope[key] = value
}

// The largest power of two at or below `threads`, capped at 8.
def coreLadder(int threads) {
    if (threads >= 8) return 8
    if (threads >= 4) return 4
    if (threads >= 2) return 2
    return 1
}

// The largest N whose full footprint fits in `threads`: Trim Galore's --cores N runs N+4 threads
// for any N >= 2, while --cores 1 is genuinely single-threaded.
def trimCores(int threads) {
    if (threads >= 12) return 8
    if (threads >= 8)  return 4
    if (threads >= 6)  return 2
    return 1
}

// Every parameter the pipeline works out for itself, as dotted names, whether computed below or
// in parameters.config. Setting one directly is allowed; step 0 reports it.
def derivedParameterNames() {
    return [
        'cores.ladder', 'cores.trim', 'cores.trimTotal', 'cores.bwa', 'cores.cutadapt',
        'cores.fastqc', 'cores.samtools', 'cores.javaGc',
        'fastqc.options',
        'trim_galore.adapterOptions', 'trim_galore.options',
        'bwa.options',
        'bcftools.mpileupOptions',
        // Computed in parameters.config instead: their inputs are all top-level.
        'referenceFa', 'referencePath', 'gffPath', 'metadataPath', 'multiRunPath',
        'reference', 'gff', 'reads',
        'filterFalsePositives.sensitivity',
        'snpEff.db',
    ]
}

// Trim Galore's option string, in one place; the per-sample adapter override calls this too.
def trimOptions(Object quality, Object adapterOptions) {
    return "--fastqc --paired --retain_unpaired -q ${quality} ${adapterOptions}".toString()
}

// The derivations, over any parameter map rather than over the global `params`.
def deriveInto(Map p) {
    int threads = p.threads as int

    // Order matters: each of these reads the ones above it.
    fill(p.cores, 'ladder',    coreLadder(threads))
    fill(p.cores, 'trim',      trimCores(threads))
    fill(p.cores, 'trimTotal', p.cores.trim > 1 ? p.cores.trim + 4 : 1)
    fill(p.cores, 'bwa',       p.cores.ladder)
    fill(p.cores, 'cutadapt',  p.cores.ladder)
    // One thread per file; step 2 only ever hands FastQC a pair.
    fill(p.cores, 'fastqc',    threads >= 2 ? 2 : 1)
    // samtools -@ counts ADDITIONAL threads, so 0 means one core and 1 means two.
    fill(p.cores, 'samtools',  threads >= 2 ? 1 : 0)
    // -XX:ParallelGCThreads is a total, not an increment.
    fill(p.cores, 'javaGc',    p.cores.samtools + 1)

    // -t is absent here; each process supplies it from task.cpus.
    fill(p.fastqc, 'options', "--memory ${p.fastqc.memory}")

    // autodetect true -> Trim Galore selects one itself; false -> both must be set, and step 0
    // refuses otherwise.
    fill(p.trim_galore, 'adapterOptions', p.trim_galore.autodetect
        ? ''
        : "-a ${p.trim_galore.adapter1} -a2 ${p.trim_galore.adapter2}")
    // --cores and --fastqc_args are supplied by TrimReads from task.cpus.
    fill(p.trim_galore, 'options', trimOptions(p.trim_galore.quality, p.trim_galore.adapterOptions))

    // -t is supplied by Align from task.cpus.
    fill(p.bwa, 'options',
        "-K ${p.bwa.batchSize} -T ${p.bwa.minScoreOutput}")

    // -q is mapping quality and -Q is base quality; they are not interchangeable.
    fill(p.bcftools, 'mpileupOptions',
        "-B -C ${p.bcftools.scaleMapQ} -q ${p.bcftools.varQualMin} -Q ${p.bcftools.baseQualMin} -d ${p.bcftools.maxDepth} -a AD,DP,SP,INFO/AD -Ou")
}

def resolveParameters() {
    deriveInto(params)
}

// A plain recursive function: the strict parser rejects a self-referencing closure.
def collectNames(Map m, String prefix, List out) {
    m.each { k, v ->
        def name = prefix ? "${prefix}.${k}" : "${k}"
        if (v instanceof Map) collectNames(v, name, out)
        else out << name
    }
    return out
}

// Every name that IS a parameter, so a multi-run column naming something else can be refused.
// The derived names are unioned in: the template leaves them commented out, so they do not exist
// in params until resolveParameters() runs.
def knownParameterNames() {
    return (collectNames(params, '', []) + derivedParameterNames()).unique().sort()
}

// A run's own copy of the parameters. Deep: the scope blocks are shared maps.
def deepCopy(Object value) {
    if (value instanceof Map) {
        def copy = [:]
        value.each { k, v -> copy[k] = deepCopy(v) }
        return copy
    }
    if (value instanceof List) return value.collect { item -> deepCopy(item) }
    return value
}

// Sets a dotted name inside a nested map, creating nothing that is not already there.
def setDotted(Map p, String dotted, Object value) {
    def parts = dotted.tokenize('.')
    def scope = p
    // Guarded: `[0..-2]` on a one-element list is a negative range, not an empty one.
    if (parts.size() > 1) {
        parts[0..-2].each { name ->
            if (!(scope[name] instanceof Map)) {
                throw new IllegalArgumentException(
                    "multi-run column '${dotted}': '${name}' is not a parameter scope in " +
                    "parameters.config, so there is nothing for this column to set.")
            }
            scope = scope[name]
        }
    }
    def leaf = parts[-1]
    // A derived parameter is absent at this point and that is normal: the row creates the key,
    // and the derivation later declines to overwrite it.
    if (!scope.containsKey(leaf) && !derivedParameterNames().contains(dotted)) {
        throw new IllegalArgumentException(
            "multi-run column '${dotted}' does not name a parameter in parameters.config. " +
            "Any parameter may be varied between runs, but a name that is not one cannot " +
            "be: nothing would read it, so the run would quietly ignore whatever you set.")
    }
    // Keep the type the config gave it: everything arrives from CSV as a string, and a
    // `poolSize` of "50" divides differently from 50.
    def current = scope[leaf]
    // Nothing to copy a type from when the key is new, so a numeric-looking value becomes one.
    if (current == null && value.toString() ==~ /-?\d+/) { scope[leaf] = value.toString() as Integer; return }
    if (current == null)                 { scope[leaf] = value; return }
    if (current instanceof Integer)      scope[leaf] = value.toString() as Integer
    else if (current instanceof Long)    scope[leaf] = value.toString() as Long
    else if (current instanceof Number)  scope[leaf] = value.toString() as BigDecimal
    else if (current instanceof Boolean) scope[leaf] = value.toString().toLowerCase() == 'true'
    else                                 scope[leaf] = value
}

// The derivations that live in parameters.config, recomputed for one run: config interpolation
// runs once at parse time, against one set of values.
def deriveRunPaths(Map p) {
    p.referenceFa = p.referenceFile.replace('.gz', '')

    p.dir.data         = "${p.mainDir}/${p.dataSource}"
    p.dir.references   = "${p.mainDir}/Reference"
    p.dir.dictionaries = "${p.dir.references}/Dictionaries"
    p.dir.snpEff       = "${p.dir.dictionaries}/snpEff"
    // One Output/ and one Logs/ per project. Only what a run produced ALONE can be named here;
    // variantPlan() overrides these for a variant. A single run gets no name anywhere.
    def owned          = p.runId ? "/${p.runId}" : ''
    p.dir.outputs      = "${p.storageDir}/Output${owned}"
    // Per run: log files are named for the step and the sample, one writer per file.
    p.dir.logs         = "${p.storageDir}/Logs${owned}"

    p.dir.subpath.each { name, value ->
        if (value instanceof Map) value.each { k, v -> p.dir.output[name][k] = "${p.dir.outputs}/${v}" }
        else p.dir.output[name] = "${p.dir.outputs}/${value}"
    }

    p.referencePath = "${p.dir.references}/${p.referenceFile}"
    p.gffPath       = "${p.dir.references}/${p.gffFile}"
    p.metadataPath  = "${p.mainDir}/${p.metadataFile}"
    p.multiRunPath  = "${p.mainDir}/${p.multiRunFile}"
    p.reference     = "${p.dir.dictionaries}/${p.referenceFile.replace('.gz', '')}"
    p.gff           = "${p.dir.dictionaries}/${p.gffFile.replace('.gz', '')}"
    p.reads         = "${p.dir.data}/${p.readPattern}"

    p.filterFalsePositives.sensitivity = 1.0 / (2 * p.diploidy * p.poolSize)
    p.snpEff.db = p.gffFile.replace('.gz', '')

    // Read once and carried; no consumer re-reads the CSV. Per run, because metadataFile may
    // itself be varied.
    p.metadata = metadataRows("${p.metadataPath}".toString())
}

// The rows of the multi-run table, via the script that validates them. Runs while the DAG is
// being built, before step 0, so the message has to stand on its own.
def multiRunRows() {
    def proc = ['python3', "${params.dir.bin}/parse_multirun.py", "${params.multiRunPath}"].execute()
    def out = new StringBuilder()
    def err = new StringBuilder()
    proc.waitForProcessOutput(out, err)
    if (proc.exitValue() != 0) {
        throw new IllegalStateException(
            "multiRun is on, but ${params.multiRunPath} cannot be used:\n${err}")
    }
    return new groovy.json.JsonSlurper().parseText(out.toString())
}

// The rows of the sample metadata file, via the script that validates them. A MISSING file is
// not an error here and a MALFORMED one is: absent is the ordinary state of a half-set-up
// project, and step 0 reports it in context.
def metadataRows(String path) {
    if (!file(path).exists()) return []
    def proc = ['python3', "${params.dir.bin}/parse_metadata.py", path].execute()
    def out = new StringBuilder()
    def err = new StringBuilder()
    proc.waitForProcessOutput(out, err)
    if (proc.exitValue() != 0) {
        throw new IllegalStateException("${path} cannot be used:\n${err}")
    }
    return new groovy.json.JsonSlurper().parseText(out.toString())
}

// One run's complete effective parameters. The row is applied TWICE, with the derivations in
// between: the first pass re-derives from a row that set an INPUT, the second lets a row that set
// a DERIVED value win.
def buildRun(Map row) {
    def p = deepCopy(params)
    p.runId = row.RunID

    row.each { key, value -> if (key != 'RunID') setDotted(p, key, value) }

    // Suffixed: dir.utilized hangs off mainDir, which runs share.
    p.dir.utilized = "${p.mainDir}/Utilized_${p.runId}"

    deriveRunPaths(p)
    deriveInto(p)

    row.each { key, value -> if (key != 'RunID') setDotted(p, key, value) }
    return p
}

// The runs this invocation will execute. MUST be called before resolveParameters(): afterwards a
// value the user pinned is indistinguishable from one that was filled in.
def runDefinitions() {
    if (!params.multiRun) {
        // One run, and no RunID: nothing is suffixed and nothing is filed under a run.
        def single = deepCopy(params)
        single.runId = null
        deriveRunPaths(single)
        deriveInto(single)
        return [single]
    }
    return multiRunRows().collect { row -> buildRun(row) }
}
