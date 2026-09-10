#!/usr/bin/env nextflow

// mds: the pools placed by Nei's minimum distance, on a classical multidimensional scaling.
//
// This module is a pipeline of its own. It imports the analysis library by literal relative
// path, reads the results the frame's verification has already cleared, and writes an analysis
// of its own; it never writes into the results tree.

nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { moduleLibraryFiles; moduleCompiledFiles } from '../../lib/nf/modules.nf'
include { installDir; frameVersion; moduleSettings } from '../../lib/nf/paths.nf'
include { designJson } from '../../lib/nf/design.nf'
include { PublishResults } from '../../lib/nf/results.nf'



// This module's settings, with the value each takes when the project does not set it.
// moduleSettings() refuses a key that is not here and names the ones that are.
def settingDefaults() {
    return [ dimensions   : 2,
             colorBy      : '',
             shapeBy      : '',
             includeIndels: false,
             chromosomes  : [],
             binSize      : 100000,
             workers      : 0,
             usecpp       : true ]
}

// The compiled path is the default. `nocpp` after the module name turns it off for one run, and
// analysis.modules.mds.usecpp turns it off for a project.
def useCompiled(Map settings) {
    if (params.containsKey('nocpp')) return false
    return settings.usecpp as boolean
}

// The depth tables of one results directory, by the artifact class the manifest asked for.
//
// Every published frequency is a six-significant-digit rendering of a ratio these hold exactly,
// and a cell with no reads is published there as 0 rather than as missing, so this module reads
// the depth tables and nothing else.
def depthTables(Map target) {
    def spec = target.classes.depths
    def found = file("${spec.dir}/${spec.pattern}")
    if (found.isEmpty()) {
        throw new IllegalStateException(
            "no ${spec.label} in\n    ${spec.dir}\nand mds reads nothing else. The " +
            "verification that cleared this directory counts them, so this means they were " +
            "removed between the two runs.")
    }
    return found.sort { path -> "${path.name}" }
}

// One results directory's analysis.
//
// The design and the pool figures both come off the target: the frame resolved them once, under
// the settings the project declared, so every module in a project reads one answer.
process Analyze {
    tag "${target.label}"

    input:
    tuple val(target), path(depths)

    // One glob, because PublishResults takes the analysis as a single collection. Everything
    // written into published/ is what lands in the results folder.
    output:
    tuple val(target), path('published/*')

    script:
    settings = moduleSettings('mds', settingDefaults())
    design = designJson(target.design).replace("'", "'\\''")
    pools = groovy.json.JsonOutput.toJson(target.pools).replace("'", "'\\''")
    // Rendered here rather than read from the environment inside R: installDir() validates and
    // refuses with a message, where an unset variable at task time is a file-not-found.
    library = moduleLibraryFiles('mds')
    compiled = moduleCompiledFiles('mds')
    // 0 means the cores Nextflow gave this task. Anything else oversubscribes them.
    workers = settings.workers > 0 ? settings.workers : task.cpus
    options = groovy.json.JsonOutput.toJson([ dimensions   : settings.dimensions,
                                              colorBy      : settings.colorBy,
                                              shapeBy      : settings.shapeBy,
                                              includeIndels: settings.includeIndels,
                                              chromosomes  : settings.chromosomes,
                                              binSize      : settings.binSize,
                                              workers      : workers,
                                              usecpp       : useCompiled(settings) ])
                                   .replace("'", "'\\''")
    // The published script's header: the frame version that defined the library, which
    // implementation ran, and the settings that shaped the work.
    header = ["# mds, PoolSeqFlow analysis frame ${frameVersion()}",
              "# ${useCompiled(settings) ? 'allele_frequencies.cpp and nei_distance.cpp, compiled at run time' : 'allele_frequencies() and nei_distance(), vectorized R'}" +
              ", in bins of ${settings.binSize} sites over ${workers} worker(s)",
              "# Nei's minimum distance, corrected for sampling, over " +
              "${settings.includeIndels ? 'SNPs and indels' : 'SNPs'}; ${settings.dimensions} axes",
              "# a distance is a per-site mean over the sites BOTH pools were read at, and is " +
              "not floored at zero"].join('\n').replace("'", "'\\''")

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
        cat ${moduleDir}/mds.R
    } > published/mds.R
    cp ${compiled.join(' ')} published/

    Rscript --vanilla published/mds.R --design design.json --pools pools.json \\
        --options options.json --cpp-frequencies published/allele_frequencies.cpp \\
        --cpp-distance published/nei_distance.cpp \\
        --depths '${depths.collect { path -> path.name }.join(',')}' --out published
    """
}

workflow {
    def targets = analysisPlan('mds').targets
                      .collect { target -> [ target, depthTables(target) ] }
    PublishResults(Analyze(channel.fromList(targets)))
}
