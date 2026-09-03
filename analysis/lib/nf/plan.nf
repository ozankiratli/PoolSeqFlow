// Which published results one analysis invocation covers, and where inside each of them the
// files a module reads sit.
//
// `analysisPlan` is the whole answer and the only entry point a module needs. It recomputes the
// pipeline's own partition of the runs; no directory name is ever parsed.

nextflow.enable.dsl=2

include { runDefinitions; resolveParameters } from '../../../scripts/resolve_parameters.nf'
include { variantPlan; runToken; dig } from '../../../scripts/variants.nf'
include { analysisSetting; renderSetting; targetResultsDir; installDir } from './paths.nf'
include { moduleNeeds } from './modules.nf'
include { checkTargetDesign; designSummary } from './design.nf'
include { poolFigures } from './pools.nf'
include { checkModuleOutputs; moduleOutputs } from './outputs.nf'

// The published files a module can read. `step` is the step that produced the class, and
// therefore whose variant owns the directory it was promoted into; `subdir` is a dotted name
// under dir.output naming that directory.
def artifactClasses() {
    return [
        frequencies: [ step: 7, subdir: 'freq',         pattern: '*_freq.tsv',            label: 'frequency tables' ],
        depths     : [ step: 7, subdir: 'freq',         pattern: '*_depth.tsv',           label: 'depth tables' ],
        vcf        : [ step: 6, subdir: 'vcf',          pattern: '*.vcf',                 label: 'called VCF' ],
        bams       : [ step: 4, subdir: 'ready',        pattern: '*_ready.bam',           label: 'ready BAMs' ],
        histograms : [ step: 5, subdir: 'report.depth', pattern: '*_depth_histogram.tsv', label: 'depth histograms' ],
    ]
}

// The classes a module's manifest asks for, checked against the classes there are.
// resultsTargets() asks only whether `needs` contains each class it knows, so a name no class
// answers to is never asked about at all and nothing else would notice it.
def checkModuleNeeds(String module, List needs) {
    def known = artifactClasses().keySet()
    def unknown = needs.collect { need -> "${need}".toString() }.findAll { need -> !known.contains(need) }
    if (unknown.isEmpty()) return

    throw new IllegalArgumentException(
        "the module '${module}' declares it needs ${unknown.size() == 1 ? 'an artifact class' : 'artifact classes'} " +
        "the analysis layer does not publish: ${unknown.join(', ')}\n" +
        "The classes a module can name are: ${known.sort().join(', ')}\n" +
        "Correct the 'needs' list in the module's manifest.json, or install a release whose " +
        "analysis layer publishes what it asks for.")
}

// The runs this invocation covers, from analysis.runs. `all` is a keyword and a list is always
// run names.
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
//
// The design and the pool figures cover ALL the directory's members and not only the selected
// ones: the tables hold a column per pool of every run that produced them.
def resultsTargets(Map plan, List runDefs, List selected, String module, List needs) {
    def wanted = selected.collect { run -> run.runId }
    return plan.variants[7]
        .findAll { variant -> variant.members.any { member -> wanted.contains(member) } }
        .sort { a, b -> "${a.dir.outputs}" <=> "${b.dir.outputs}" }
        .collect { variant ->
            def classes = artifactClasses().collectEntries { name, spec ->
                def owner = ancestorAt(plan, variant.members, spec.step)
                def dir = dig(owner.dir.output, spec.subdir)
                if (dir == null) {
                    throw new IllegalStateException(
                        "the artifact class '${name}' sits at dir.output.${spec.subdir}, which this " +
                        "project's parameters do not define. artifactClasses() and the dir.subpath " +
                        "block in parameters.config have to name the same directories.")
                }
                [ name, [ label   : spec.label,
                          pattern : spec.pattern,
                          dir     : "${dir}".toString(),
                          required: needs.contains(name) ] ]
            }
            def label = directoryLabel(variant)
            def covered = runDefs.findAll { run -> variant.members.contains(run.runId) }
            def rows = covered.collectMany { run -> run.metadata }
            checkTargetDesign(label, rows)
            return [ label   : label,
                     module  : module,
                     dir     : "${variant.dir.outputs}".toString(),
                     members : variant.members.collect { member -> runToken(member) },
                     selected: variant.members.findAll { member -> wanted.contains(member) }
                                              .collect { member -> runToken(member) },
                     classes : classes,
                     design  : designSummary(rows),
                     pools   : poolFigures(label, covered),
                     results : targetResultsDir(module, label) ]
        }
}

// Everything an invocation needs to know about what it is reading: the runs the project defines,
// the ones selected, and one target per results directory they land in.
//
// The artifact classes it marks required come from the module's own manifest.
//
// The two calls are ordered: runDefinitions() copies each run's own parameters before
// resolveParameters() fills the computed ones in.
def analysisPlan(String module) {
    // runDefinitions() calls a helper in bin/, so where bin/ is has to be settled before it.
    // parameters.config sets dir.bin beside the entry script, which for a module is the module.
    params.dir.bin = "${installDir()}/bin".toString()
    def runDefs = runDefinitions()
    resolveParameters()
    def needs = moduleNeeds(module)
    checkModuleNeeds(module, needs)
    checkModuleOutputs(module, moduleOutputs(module))
    def selected = selectedRuns(runDefs)
    return [ runs    : runDefs,
             selected: selected,
             targets : resultsTargets(variantPlan(runDefs), runDefs, selected, module, needs) ]
}
