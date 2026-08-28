// Values the pipeline computes when you have not set them yourself.
//
// The rule throughout: a parameter you set in parameters.config is used exactly as written,
// and one you leave commented out is computed here. A value you set also feeds whatever is
// computed from it - pinning `cores.samtools` moves `cores.javaGc` with it - so pinning one
// thing never silently strands the things that depend on it.
//
// Why the computation is here and not in the config file. Config interpolation is eager and
// per-file: a scope block assigns its own values and evaluates its own derivations in one
// pass, so an override aimed at something INSIDE a scope arrives after the derivation has
// already been computed from the old value. Measured against the real config: overriding
// `bcftools.maxDepth` to 5000 left `bcftools.mpileupOptions` still emitting `-d 2000`, and
// overriding `trim_galore.quality` to 15 left `trim_galore.options` still saying `-q 25`.
// No warning, exit 0 - the run reports the value you asked for and uses the old one.
//
// Overriding a TOP-LEVEL parameter has no such problem: `poolSize` really does re-derive
// `filterFalsePositives.sensitivity`, and `threads` really does re-derive the cores ladder.
// That is why parameters whose only inputs are top-level - the reference paths, `sensitivity`,
// `snpEff.db` - are still computed in the config file, where they read better.
//
// Two mechanics this relies on, both verified rather than assumed:
//
//   - Writing into an existing scope (`params.cores.trim = 4`) is visible everywhere,
//     because scope blocks are ordinary maps shared across modules. Creating a new
//     TOP-LEVEL key from inside a module is NOT: it is visible only within that module, and
//     processes see null. So every scope written here must already exist in the config file,
//     which is why each one carries its keys commented out rather than being absent.
//   - Absence is the signal, not emptiness. `containsKey` distinguishes "not set" from
//     "deliberately set to nothing", and an empty string is a legitimate value - it is what
//     `trim_galore.adapterOptions` holds whenever adapter autodetection is on.
//
// Called once, first thing in the entry workflow, so it runs before any process script is
// evaluated and before analysisParams() builds the change-guard manifest - which therefore
// records the values actually used, whether they were set or computed.

// Assign only if the user has not. Keeps the intent visible at every call site instead of
// repeating a containsKey test twelve times.
//
// The value is computed by the caller before this is entered, rather than passed as a
// closure: the strict parser rejects invoking a closure-typed parameter. That is harmless
// here because every expression below is pure, and because the calls are ordered so that
// anything one of them reads has already been filled.
def fill(Map scope, String key, Object value) {
    if (!scope.containsKey(key)) scope[key] = value
}

// The largest power of two at or below `threads`, capped at 8, which is where the published
// scaling for these tools flattens out. threads = 1 forces every tool to a single core.
def coreLadder(int threads) {
    if (threads >= 8) return 8
    if (threads >= 4) return 4
    if (threads >= 2) return 2
    return 1
}

// Trim Galore is costed on its full footprint, not its worker count: --cores N runs N+4
// threads (N workers + 2 decompressors + 1 batcher + 1 writer) for any N >= 2, while
// --cores 1 bypasses the pool and is genuinely single-threaded. So pick the largest N whose
// N+4 still fits in `threads`.
def trimCores(int threads) {
    if (threads >= 12) return 8
    if (threads >= 8)  return 4
    if (threads >= 6)  return 2
    return 1
}

// Every parameter this pipeline works out for itself, whether it is computed below or in
// parameters.config, as dotted names.
//
// Setting one of these directly is allowed and always has been - pinning a core count or
// writing an options string outright is a legitimate thing to want, and benchmarking needs
// it. What it costs is the link back to whatever the value was derived from: pin
// `bcftools.mpileupOptions` and `bcftools.maxDepth` stops meaning anything. That is worth
// reporting rather than discovering, so step 0 names any multi-run column that lands here.
//
// The list is here rather than in step 0 because this is the file that decides most of it;
// a copy over there would drift the first time a derivation was added.
def derivedParameterNames() {
    return [
        'cores.ladder', 'cores.trim', 'cores.trimTotal', 'cores.bwa', 'cores.cutadapt',
        'cores.fastqc', 'cores.samtools', 'cores.javaGc',
        'fastqc.options',
        'trim_galore.adapterOptions', 'trim_galore.options',
        'bwa.options',
        'bcftools.mpileupOptions',
        // Computed in parameters.config rather than here, because their inputs are all
        // top-level and an override of a top-level parameter does re-derive correctly.
        'referenceFa', 'referencePath', 'gffPath', 'rgTagsPath', 'multiRunPath',
        'reference', 'gff', 'reads',
        'filterFalsePositives.sensitivity',
        'snpEff.db',
    ]
}

// The derivations, over any parameter map rather than over the global `params`.
//
// Split out so one run's parameters can be derived without touching anyone else's:
// resolveParameters() applies this to the global map exactly as before, and runDefinitions()
// applies the SAME function to each run's own copy. One derivation, not two that have to be
// kept in step by hand.
def deriveInto(Map p) {
    int threads = p.threads as int

    // Order matters: each of these reads the ones above it, so a value the user pinned is
    // what the rest are computed from.
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

    // -t is supplied by each process from task.cpus, so it is deliberately absent here.
    fill(p.fastqc, 'options', "--memory ${p.fastqc.memory}")

    // autodetect true -> no adapter is passed and Trim Galore selects one itself, so
    // adapter1/adapter2 are ignored. false -> both must be set; step 0 refuses otherwise.
    fill(p.trim_galore, 'adapterOptions', p.trim_galore.autodetect
        ? ''
        : "-a ${p.trim_galore.adapter1} -a2 ${p.trim_galore.adapter2}")
    // --cores and --fastqc_args are supplied by TrimReads from task.cpus.
    fill(p.trim_galore, 'options',
        "--fastqc --paired --retain_unpaired -q ${p.trim_galore.quality} ${p.trim_galore.adapterOptions}")

    // -t is supplied by Align from task.cpus.
    fill(p.bwa, 'options',
        "-K ${p.bwa.batchSize} -T ${p.bwa.minScoreOutput}")

    // -q is mapping quality and -Q is base quality; they are not interchangeable and were
    // once supplied to each other.
    fill(p.bcftools, 'mpileupOptions',
        "-B -C ${p.bcftools.scaleMapQ} -q ${p.bcftools.varQualMin} -Q ${p.bcftools.baseQualMin} -d ${p.bcftools.maxDepth} -a AD,DP,SP,INFO/AD -Ou")
}

def resolveParameters() {
    deriveInto(params)
}

// Every parameter that exists, as dotted names.
//
// This is NOT a whitelist of what may be varied between runs - any parameter may be, that is
// settled and there is deliberately no such list. It is the set of names that ARE parameters,
// so that a column naming something else can be refused instead of quietly doing nothing.
// A run whose setting is silently ignored is worse than one that will not start.
//
// Derived from the live params map rather than written out, so a parameter added to
// parameters.config is varyable the moment it exists, with nothing here to update.
// A plain recursive function, not a self-referencing closure: the strict parser rejects
// `def walk; walk = { ... walk(...) }` with "`walk` is not defined".
def collectNames(Map m, String prefix, List out) {
    m.each { k, v ->
        def name = prefix ? "${prefix}.${k}" : "${k}"
        if (v instanceof Map) collectNames(v, name, out)
        else out << name
    }
    return out
}

def knownParameterNames() {
    // The derived names are unioned in because the template leaves them commented out - they
    // do not exist in params until resolveParameters() fills them, and varying one is
    // allowed. Without this the check would reject exactly the parameters settled rule 7
    // exists to permit.
    return (collectNames(params, '', []) + derivedParameterNames()).unique().sort()
}

// A run's own copy of the parameters. Deep, because the scope blocks are shared maps: a
// shallow copy would leave every run writing into one `cores` and one `trim_galore`, so the
// last row parsed would silently decide the settings for all of them.
def deepCopy(Object value) {
    if (value instanceof Map) {
        def copy = [:]
        value.each { k, v -> copy[k] = deepCopy(v) }
        return copy
    }
    if (value instanceof List) return value.collect { item -> deepCopy(item) }
    return value
}

// Set a dotted name - `trim_galore.quality` - inside a nested map, creating nothing that is
// not already there. A column naming a scope that does not exist is a mistake worth failing
// on: writing a new top-level key from a module is invisible to processes anyway (see the
// header), so accepting it silently would produce a run whose setting was simply ignored.
def setDotted(Map p, String dotted, Object value) {
    def parts = dotted.tokenize('.')
    def scope = p
    // Guarded: a top-level column like `poolSize` has no scopes to walk into, and `[0..-2]`
    // on a one-element list is a negative range rather than an empty one.
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
    // A DERIVED parameter is absent at this point and that is normal, not an error: the
    // template leaves the computed ones commented out so that changing their inputs moves
    // them together, and runDefinitions() deliberately runs before anything is filled in.
    // Setting one directly is explicitly allowed - benchmarking needs it - so the row
    // creates the key and the derivation later declines to overwrite it.
    if (!scope.containsKey(leaf) && !derivedParameterNames().contains(dotted)) {
        throw new IllegalArgumentException(
            "multi-run column '${dotted}' does not name a parameter in parameters.config. " +
            "Any parameter may be varied between runs, but a name that is not one cannot " +
            "be: nothing would read it, so the run would quietly ignore whatever you set.")
    }
    // Keep the type the config gave it. Everything arrives from CSV as a string, and a
    // `poolSize` of "50" would divide differently from 50 - `sensitivity` is
    // 1.0 / (2 * diploidy * poolSize), which is integer-vs-string, not cosmetic.
    def current = scope[leaf]
    // Nothing to copy the type from when the key is being created, so infer the obvious
    // case: a derived value like `cores.bwa` has to arrive as a number or `task.cpus` gets
    // a String and the process fails somewhere far from here.
    if (current == null && value.toString() ==~ /-?\d+/) { scope[leaf] = value.toString() as Integer; return }
    if (current == null)                 { scope[leaf] = value; return }
    if (current instanceof Integer)      scope[leaf] = value.toString() as Integer
    else if (current instanceof Long)    scope[leaf] = value.toString() as Long
    else if (current instanceof Number)  scope[leaf] = value.toString() as BigDecimal
    else if (current instanceof Boolean) scope[leaf] = value.toString().toLowerCase() == 'true'
    else                                 scope[leaf] = value
}

// The derivations that live in parameters.config, recomputed for one run.
//
// THIS IS A SECOND COPY OF LOGIC THAT ALSO EXISTS IN parameters.config, and there is no way
// around it: config interpolation runs once, at parse time, against one set of values, and a
// run that changes `referenceFile` needs `referencePath`, `reference` and `snpEff.db` to move
// with it. The config's copy cannot be dropped either - `nextflow config -flat` is how the
// wrapper learns the paths that `clean` and `reset` delete, and it only ever sees the config.
//
// The duplication is held together by a test rather than by care: for a single run this
// function must reproduce exactly what the config computed. Drift then fails a test instead
// of silently sending one run's output somewhere else.
def deriveRunPaths(Map p) {
    p.referenceFa = p.referenceFile.replace('.gz', '')

    p.dir.data         = "${p.mainDir}/${p.dataSource}"
    p.dir.references   = "${p.mainDir}/Reference"
    p.dir.dictionaries = "${p.dir.references}/Dictionaries"
    p.dir.snpEff       = "${p.dir.dictionaries}/snpEff"
    // ONE RESULTS TREE, AND ONLY DIVERGENCE GETS A NAME (Z, 2026-08-27).
    //
    // A run does not get its own storageDir. There is one Output/ and one Logs/ per project,
    // and what a single run produced ALONE lands in a directory named for it inside them;
    // work several runs share lands in a directory named for the group, and work all of them
    // share lands at the ordinary subpaths. The same rule three times, so assembling "what
    // did runA produce" is a walk down one tree rather than a comparison of parallel ones.
    //
    // A run's own directory is the case this function can answer. The other two depend on who
    // shares what, which only the divergence analysis knows, so variantPlan() overrides these
    // for a variant exactly as it already overrides dir.utilized.
    //
    // Single run: no name anywhere, so both are what they have always been. Settled rule 3.
    def owned          = p.runId ? "/${p.runId}" : ''
    p.dir.outputs      = "${p.storageDir}/Output${owned}"
    // Per run and not merely per project, because the log files are named for the step and
    // the sample: three runs sharing one Logs tree would put three writers on one file, and
    // one-writer-per-file is what lets tasks append without locking.
    p.dir.logs         = "${p.storageDir}/Logs${owned}"

    p.dir.subpath.each { name, value ->
        if (value instanceof Map) value.each { k, v -> p.dir.output[name][k] = "${p.dir.outputs}/${v}" }
        else p.dir.output[name] = "${p.dir.outputs}/${value}"
    }

    p.referencePath = "${p.dir.references}/${p.referenceFile}"
    p.gffPath       = "${p.dir.references}/${p.gffFile}"
    p.rgTagsPath    = "${p.mainDir}/${p.rgTagsFile}"
    p.multiRunPath  = "${p.mainDir}/${p.multiRunFile}"
    p.reference     = "${p.dir.dictionaries}/${p.referenceFile.replace('.gz', '')}"
    p.gff           = "${p.dir.dictionaries}/${p.gffFile.replace('.gz', '')}"
    p.reads         = "${p.dir.data}/${p.readPattern}"

    p.filterFalsePositives.sensitivity = 1.0 / (2 * p.diploidy * p.poolSize)
    p.snpEff.db = p.gffFile.replace('.gz', '')
}

// The rows of the multi-run table, via the script that already validates them.
//
// Shelling out rather than parsing here: bin/parse_multirun.py handles the CSV quoting that
// `readPattern` needs (its default contains a comma) and is unit-tested at a millisecond a
// case. Step 0 has usually reported the problems already by the time this throws, but this
// runs while the DAG is being built, which is before step 0 executes - so the message has to
// stand on its own.
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

// One run's complete effective parameters.
//
// The row is applied TWICE, on purpose. Between the two passes the derivations run, so a row
// that sets an INPUT to a derivation gets the derived value recomputed - setting `poolSize`
// moves `filterFalsePositives.sensitivity` with it. The second pass is what makes a row that
// sets a DERIVED value directly win anyway, which settled rule 7 requires: any parameter may
// be varied, including the computed ones, because benchmarking needs it.
def buildRun(Map row) {
    def p = deepCopy(params)
    p.runId = row.RunID

    row.each { key, value -> if (key != 'RunID') setDotted(p, key, value) }

    // A RUN NO LONGER GETS ITS OWN storageDir (Z, 2026-08-27). It used to default to
    // ${storageDir}/${RunID}, which gave every run a complete parallel tree - and once work is
    // shared there is no such thing as one run's complete tree, so the parallel trees were
    // describing something that had stopped being true. There is one storage root now, and
    // deriveRunPaths() names the run INSIDE Output/ and Logs/ instead.
    //
    // A storageDir column still works, because settled rule 7 lets any parameter be varied -
    // it just means that run's results are somewhere else entirely rather than beside the
    // others. Two runs that do not share a storage root cannot share a results directory, so
    // sharing between them has to be refused rather than resolved; that lands with sharing.
    //
    // And the working files stay apart, which matters more than it looks: dir.utilized hangs off
    // mainDir, and runs SHARE mainDir. Without the suffix every run writes Utilized/VCF/Test.vcf
    // to one path, and the second run's skip check finds the first run's file and symlinks to
    // it - the whole VCF chain silently reused across runs that differ.
    p.dir.utilized = "${p.mainDir}/Utilized_${p.runId}"

    deriveRunPaths(p)
    deriveInto(p)

    row.each { key, value -> if (key != 'RunID') setDotted(p, key, value) }
    return p
}

// The runs this invocation will execute.
//
// MUST be called before resolveParameters(). After that has run there is no way to tell a
// value the user pinned from one we filled in, and `fill` refuses to overwrite a key that is
// already there - so a run changing an input to a derivation would keep the base run's
// derived value and quietly use the old setting. The copy has to be taken while "absent"
// still means "not set".
def runDefinitions() {
    if (!params.multiRun) {
        // One run, and no RunID: settled rule 3. Nothing is suffixed and nothing is filed
        // under a run, so single-run paths stay exactly what they were before multi-run
        // existed.
        def single = deepCopy(params)
        single.runId = null
        deriveRunPaths(single)
        deriveInto(single)
        return [single]
    }
    return multiRunRows().collect { row -> buildRun(row) }
}
