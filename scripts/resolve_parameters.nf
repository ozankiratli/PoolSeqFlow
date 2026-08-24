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

def resolveParameters() {
    int threads = params.threads as int

    // Order matters: each of these reads the ones above it, so a value the user pinned is
    // what the rest are computed from.
    fill(params.cores, 'ladder',    coreLadder(threads))
    fill(params.cores, 'trim',      trimCores(threads))
    fill(params.cores, 'trimTotal', params.cores.trim > 1 ? params.cores.trim + 4 : 1)
    fill(params.cores, 'bwa',       params.cores.ladder)
    fill(params.cores, 'cutadapt',  params.cores.ladder)
    // One thread per file; step 2 only ever hands FastQC a pair.
    fill(params.cores, 'fastqc',    threads >= 2 ? 2 : 1)
    // samtools -@ counts ADDITIONAL threads, so 0 means one core and 1 means two.
    fill(params.cores, 'samtools',  threads >= 2 ? 1 : 0)
    // -XX:ParallelGCThreads is a total, not an increment.
    fill(params.cores, 'javaGc',    params.cores.samtools + 1)

    // -t is supplied by each process from task.cpus, so it is deliberately absent here.
    fill(params.fastqc, 'options', "--memory ${params.fastqc.memory}")

    // autodetect true -> no adapter is passed and Trim Galore selects one itself, so
    // adapter1/adapter2 are ignored. false -> both must be set; step 0 refuses otherwise.
    fill(params.trim_galore, 'adapterOptions', params.trim_galore.autodetect
        ? ''
        : "-a ${params.trim_galore.adapter1} -a2 ${params.trim_galore.adapter2}")
    // --cores and --fastqc_args are supplied by TrimReads from task.cpus.
    fill(params.trim_galore, 'options',
        "--fastqc --paired --retain_unpaired -q ${params.trim_galore.quality} ${params.trim_galore.adapterOptions}")

    // -t is supplied by Align from task.cpus.
    fill(params.bwa, 'options',
        "-K ${params.bwa.batchSize} -T ${params.bwa.minScoreOutput}")

    // -q is mapping quality and -Q is base quality; they are not interchangeable and were
    // once supplied to each other.
    fill(params.bcftools, 'mpileupOptions',
        "-B -C ${params.bcftools.scaleMapQ} -q ${params.bcftools.varQualMin} -Q ${params.bcftools.baseQualMin} -d ${params.bcftools.maxDepth} -a AD,DP,SP,INFO/AD -Ou")
}
