#!/usr/bin/env nextflow

// association: each allele's frequency regressed on a phenotype measured per pool.
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
// not call does not travel with a result it did not compute.
def libraryFiles() {
    return ['n_eff.R', 'allele_frequencies.R', 'chunk_ranges.R']
}

// This module's settings, with the value each takes when the project does not set it.
// moduleSettings() refuses a key that is not here and names the ones that are.
def settingDefaults() {
    return [ phenotypes  : [],
             permutations: 10000,
             fdr         : 'BH',
             dispersion  : null,
             reportBelow : 0.05,
             reportTop   : 1000,
             chromosomes : [],
             binSize     : 100000,
             workers     : 0,
             usecpp      : true ]
}

// The compiled path is the default. `nocpp` after the module name turns it off for one run, and
// analysis.modules.association.usecpp turns it off for a project.
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
            "no ${spec.label} in\n    ${spec.dir}\nand association reads nothing else. The " +
            "verification that cleared this directory counts them, so this means they were " +
            "removed between the two runs.")
    }
    return found.sort { path -> "${path.name}" }
}

// One results directory's analysis.
//
// The design and the pool figures both come off the target: the frame resolved them once, under
// the settings the project declared, so every module in a project reads one answer.
process Analyse {
    tag "${target.label}"

    input:
    tuple val(target), path(depths)

    // One glob, because PublishResults takes the analysis as a single collection. Everything
    // written into published/ is what lands in the results folder.
    output:
    tuple val(target), path('published/*')

    script:
    settings = moduleSettings('association', settingDefaults())
    design = designJson(target.design).replace("'", "'\\''")
    pools = groovy.json.JsonOutput.toJson(target.pools).replace("'", "'\\''")
    // Rendered here rather than read from the environment inside R: installDir() validates and
    // refuses with a message, where an unset variable at task time is a file-not-found.
    library = libraryFiles().collect { name -> "${installDir()}/analysis/lib/R/${name}" }
    compiled = "${installDir()}/analysis/lib/cpp/allele_frequencies.cpp"
    // 0 means the cores Nextflow gave this task. Anything else oversubscribes them.
    workers = settings.workers > 0 ? settings.workers : task.cpus
    options = groovy.json.JsonOutput.toJson([ phenotypes  : settings.phenotypes,
                                              permutations: settings.permutations,
                                              fdr         : settings.fdr,
                                              dispersion  : settings.dispersion,
                                              reportBelow : settings.reportBelow,
                                              reportTop   : settings.reportTop,
                                              chromosomes : settings.chromosomes,
                                              binSize     : settings.binSize,
                                              workers     : workers,
                                              usecpp      : useCompiled(settings) ])
                                   .replace("'", "'\\''")
    // The published script's header: the frame version that defined the library, which
    // implementation of the parse ran, and the settings that shaped the work. The permutation
    // budget is here because it sets the smallest p a run can report.
    header = ["# association, PoolSeqFlow analysis frame ${frameVersion()}",
              "# ${useCompiled(settings) ? 'allele_frequencies.cpp, compiled at run time' : 'allele_frequencies(), vectorised R'}" +
              ", in bins of ${settings.binSize} sites over ${workers} worker(s)",
              "# phenotype ${settings.phenotypes.join(', ')}, up to ${settings.permutations} rearrangements, ${settings.fdr} across sites",
              "# beta > 0 means the allele is more frequent at the higher phenotype value"].join('\n').replace("'", "'\\''")

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
        cat ${moduleDir}/association.R
    } > published/association.R
    cp ${compiled} published/allele_frequencies.cpp

    Rscript --vanilla published/association.R --design design.json --pools pools.json \\
        --options options.json --cpp published/allele_frequencies.cpp \\
        --depths '${depths.collect { path -> path.name }.join(',')}' --out published
    """
}

workflow {
    def targets = analysisPlan('association').targets
                      .collect { target -> [ target, depthTables(target) ] }
    PublishResults(Analyse(channel.fromList(targets)))
}
