#!/usr/bin/env nextflow

// basicstats: what a project's published tables contain, per pool.
//
// This module is a pipeline of its own. It imports the analysis library by literal relative
// path, reads the results the frame's verification has already cleared, and writes an analysis
// of its own; it never writes into the results tree.

nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { installDir; frameVersion; moduleSettings } from '../../lib/nf/paths.nf'
include { designJson } from '../../lib/nf/design.nf'
include { PublishResults } from '../../lib/nf/results.nf'

// The shared library files this module CALLS, in the order they are concatenated. Exactly this
// list is folded into the script published beside the result, so a function the module does
// not call does not travel with a result it did not compute. 00_static holds the two to one
// another.
def libraryFiles() {
    return ['harmonic_mean.R', 'n_eff.R', 'pool_n_eff.R',
            'site_diversity.R', 'chunk_ranges.R']
}

// This module's settings, with the value each takes when the project does not set it.
// moduleSettings() refuses a key that is not here and names the ones that are.
def settingDefaults() {
    return [ minReads   : 2,
             binSize    : 100000,
             workers    : 0,
             usecpp     : true,
             chromosomes: [] ]
}

// The compiled path is the default: every analysis environment carries a compiler, because
// conda's r-base depends on one. `nocpp` after the module name turns it off for one run, and
// analysis.basicstats.usecpp turns it off for a project.
def useCompiled(Map settings) {
    if (params.containsKey('nocpp')) return false
    return settings.usecpp as boolean
}

// The depth tables of one results directory, by the artifact class the manifest asked for.
def depthTables(Map target) {
    def spec = target.classes.depths
    def found = file("${spec.dir}/${spec.pattern}")
    if (found.isEmpty()) {
        throw new IllegalStateException(
            "no ${spec.label} in\n    ${spec.dir}\nand basicstats reads nothing else. The " +
            "verification that cleared this directory counts them, so this means they were " +
            "removed between the two runs.")
    }
    return found.sort { path -> "${path.name}" }
}

// The step 5 depth histograms of one results directory, per LIBRARY rather than per pool.
//
// Not required, and an empty list is a legitimate answer: DepthProfile skips a sample whose
// ceiling is already decided, so a sound project can lack them. The module reports the pools it
// had none for instead of averaging over the ones it had.
def histogramFiles(Map target) {
    def spec = target.classes.histograms
    return file("${spec.dir}/${spec.pattern}").sort { path -> "${path.name}" }
}

// One results directory's analysis.
//
// The design and the pool figures both come off the target: the frame resolved them once, under
// the settings the project declared, so every module in a project reads one answer.
process Analyse {
    tag "${target.label}"

    input:
    tuple val(target), path(depths), path(hists)

    // One glob, because PublishResults takes the analysis as a single collection. Everything
    // written into published/ is what lands in the results folder.
    output:
    tuple val(target), path('published/*')

    script:
    settings = moduleSettings('basicstats', settingDefaults())
    design = designJson(target.design).replace("'", "'\\''")
    pools = groovy.json.JsonOutput.toJson(target.pools).replace("'", "'\\''")
    // Rendered here rather than read from the environment inside R: installDir() validates and
    // refuses with a message, where an unset variable at task time is a file-not-found.
    library = libraryFiles().collect { name -> "${installDir()}/analysis/lib/R/${name}" }
    compiled = "${installDir()}/analysis/lib/cpp/site_diversity.cpp"
    // 0 means the cores Nextflow gave this task. Anything else oversubscribes them.
    workers = settings.workers > 0 ? settings.workers : task.cpus
    options = groovy.json.JsonOutput.toJson([ minReads   : settings.minReads,
                                              binSize    : settings.binSize,
                                              workers    : workers,
                                              usecpp     : useCompiled(settings),
                                              chromosomes: settings.chromosomes ])
                                   .replace("'", "'\\''")
    // The published script's header: the frame version that defined the library, which
    // implementation of the per-site loop ran, and the settings that shaped the work.
    header = ["# basicstats, PoolSeqFlow analysis frame ${frameVersion()}",
              "# ${useCompiled(settings) ? 'site_diversity.cpp, compiled at run time' : 'site_diversity(), vectorised R'}" +
              ", in bins of ${settings.binSize} sites over ${workers} worker(s)",
              "# minReads ${settings.minReads}"].join('\n').replace("'", "'\\''")

    """
    mkdir -p published
    printf '%s' '${design}' > design.json
    printf '%s' '${pools}' > pools.json
    printf '%s' '${options}' > options.json

    # The script published beside the result, and the one that runs: the shared library first,
    # then this module's own.
    {
        printf '%s\\n' '${header}'
        echo '# The shared library follows, then this module.'
        cat ${library.join(' ')}
        cat ${moduleDir}/basicstats.R
    } > published/basicstats.R
    cp ${compiled} published/site_diversity.cpp

    Rscript --vanilla published/basicstats.R --design design.json --pools pools.json \\
        --options options.json --cpp published/site_diversity.cpp \\
        --depths '${depths.collect { path -> path.name }.join(',')}' \\
        --histograms '${hists.collect { path -> path.name }.join(',')}' --out published
    """
}

workflow {
    def targets = analysisPlan('basicstats').targets
                      .collect { target -> [ target, depthTables(target), histogramFiles(target) ] }
    PublishResults(Analyse(channel.fromList(targets)))
}
