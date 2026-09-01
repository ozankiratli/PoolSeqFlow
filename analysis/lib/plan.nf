// Which published results one analysis invocation covers, and where inside each of them the
// files a module reads sit.
//
// `analysisPlan` is the whole answer and the only entry point a module needs. It recomputes the
// pipeline's own partition of the runs; no directory name is ever parsed.

nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from '../../scripts/resolve_parameters.nf'
include { variantPlan; runToken } from '../../scripts/variants.nf'
include { analysisSetting; renderSetting; targetResultsDir; installDir } from './paths.nf'
include { moduleNeeds } from './modules.nf'

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
// `needs` names the classes the module cannot run without.
def resultsTargets(Map plan, List selected, String module, List needs) {
    def wanted = selected.collect { run -> run.runId }
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

// Everything an invocation needs to know about what it is reading: the runs the project defines,
// the ones selected, and one target per results directory they land in.
//
// The artifact classes it marks required come from the module's own manifest, so a module states
// what it reads once and the verification and the module itself cannot disagree about it.
//
// The two calls are ordered: runDefinitions() copies each run's own parameters before
// resolveParameters() fills the computed ones in.
def analysisPlan(String module) {
    // runDefinitions() calls a helper in bin/, so where bin/ is has to be settled before it.
    installDir()
    def runDefs = runDefinitions()
    resolveParameters()
    def selected = selectedRuns(runDefs)
    return [ runs    : runDefs,
             selected: selected,
             targets : resultsTargets(variantPlan(runDefs), selected, module, moduleNeeds(module)) ]
}
