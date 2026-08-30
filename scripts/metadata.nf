// Projections of the sample metadata file. One row per pair of FASTQ files: `SampleID` joins the
// row to the reads, `RG_*` becomes the read group, `param_*` overrides a parameter for those
// samples, and every other column is the user's own and is never interpreted.
//
// Nothing here reads the CSV: `resolveParameters()` parses it once into `run.metadata`.

nextflow.enable.dsl=2

include { trimOptions } from './resolve_parameters.nf'

// The read group tags this pipeline accepts, by the name the user writes.
// Mirrored by RG_TAGS in bin/parse_metadata.py.
def rgTagMap() {
    return ['RG_Sample'      : 'SM',
            'RG_Library'     : 'LB',
            'RG_Platform'    : 'PL',
            'RG_PlatformUnit': 'PU',
            'RG_Description' : 'DS',
            'RG_Center'      : 'CN',
            'RG_Date'        : 'DT',
            'RG_FlowOrder'   : 'FO']
}

// The parameters a row may override, mapped to the parameter each one displaces.
// Mirrored by PARAM_COLUMNS in bin/parse_metadata.py.
def paramColumns() {
    return ['param_poolSize'   : 'poolSize',
            'param_capMaxDepth': 'capBAM.maxDepth',
            'param_adapter1'   : 'trim_galore.adapter1',
            'param_adapter2'   : 'trim_galore.adapter2']
}

// All of them, in a fixed order.
def overrideColumns() {
    return paramColumns().keySet().toList()
}

def adapterColumns() {
    return ['param_adapter1', 'param_adapter2']
}

def poolSizeColumn() {
    return 'param_poolSize'
}

def capMaxDepthColumn() {
    return 'param_capMaxDepth'
}

def metadataRow(Map run, String sampleId) {
    return run.metadata.find { row -> "${row.SampleID}" == sampleId }
}

// The `@RG` line for one sample, ready for `samtools addreplacerg`. An empty cell omits its tag.
def rgTagString(Map run, String sampleId) {
    def row = metadataRow(run, sampleId)
    if (row == null) {
        throw new IllegalStateException(
            "sample '${sampleId}' has no row in ${run.metadataPath}. Step 0 refuses a run whose " +
            "reads and metadata disagree, so reaching step 4 with one means the two were read " +
            "differently.")
    }
    def parts = ["@RG", "ID:${sampleId}"]
    rgTagMap().each { column, tag ->
        def value = "${row[column] ?: ''}"
        if (value) parts << "${tag}:${value}"
    }
    return parts.join('\\t')
}

// Which columns each step's output depends on, by step number. Step 6 is absent: what it takes
// is the row ORDER, which a column list cannot express.
def metadataColumnsPerStep() {
    return [
        2: adapterColumns(),
        4: rgTagMap().keySet().toList(),
        5: [capMaxDepthColumn()],
        7: [poolSizeColumn()],
    ]
}

// One line per sample, holding only the named columns, sorted by SampleID.
def metadataProjection(Map run, List columns) {
    return run.metadata
        .collect { row ->
            ([ "${row.SampleID}".toString() ] +
             columns.collect { column -> "${column}=${row[column] ?: ''}".toString() }).join('\t')
        }
        .sort()
}

// The sample order. Step 6 hands bcftools its BAMs in it, and the VCF's columns follow.
def metadataOrder(Map run) {
    return run.metadata.collect { row -> "${row.SampleID}".toString() }
}

// The read group and `param_*` columns, one line per sample, IN FILE ORDER. The change guard
// sorts both sides itself to tell an edited value from a reordered file.
def metadataGuardLines(Map run) {
    def columns = (rgTagMap().keySet().toList() + overrideColumns())
    return run.metadata.collect { row ->
        ([ "${row.SampleID}".toString() ] +
         columns.collect { column -> "${column}=${row[column] ?: ''}".toString() }).join('\t')
    }
}

// Every pool and how many individuals are in it, keyed by RG_Sample, which bcftools names a VCF
// column after. A blank param_poolSize falls back to the run's global poolSize; the parser has
// already refused a pool whose rows disagree, so the first row speaks for it.
def poolSizes(Map run) {
    def sizes = [:]
    run.metadata.each { row ->
        def pool = "${row.RG_Sample}".toString()
        if (!sizes.containsKey(pool)) {
            def own = "${row[poolSizeColumn()] ?: ''}"
            sizes[pool] = (own ? own : "${run.poolSize}").toString()
        }
    }
    return sizes
}

// The pool sizes as bin/filterFalsePositives.sh takes them: `Name=count,Name=count`, keyed by
// VCF sample column name. Sizes, not sensitivities - the filter derives the threshold itself.
def poolSizeArgument(Map run) {
    return poolSizes(run)
        .collect { pool, size -> "${pool}=${size}".toString() }
        .sort()
        .join(',')
}

// One sample's effective capBAM.maxDepth: its own param_capMaxDepth cell, or the run's setting
// where the cell is blank.
def sampleCapMaxDepth(Map run, String sampleId) {
    def row = metadataRow(run, sampleId)
    def own = row == null ? '' : "${row[capMaxDepthColumn()] ?: ''}"
    return (own ?: "${run.capBAM.maxDepth}").toString()
}

// One sample's effective Trim Galore options: a row setting both adapters replaces the run's
// adapter fragment, anything else gets the run's string unchanged.
def sampleTrimOptions(Map run, String sampleId) {
    def row = metadataRow(run, sampleId)
    def one = row == null ? '' : "${row.param_adapter1 ?: ''}"
    def two = row == null ? '' : "${row.param_adapter2 ?: ''}"
    if (!one || !two) return "${run.trim_galore.options}".toString()
    return trimOptions(run.trim_galore.quality, "-a ${one} -a2 ${two}")
}

// True when the run pins trim_galore.options instead of letting it derive. A pinned string is
// used verbatim, so a per-sample adapter cannot be applied and step 0 refuses the combination.
def trimOptionsArePinned(Map run) {
    return "${run.trim_galore.options}" !=
           trimOptions(run.trim_galore.quality, run.trim_galore.adapterOptions)
}

def samplesWithAdapterOverrides(Map run) {
    return run.metadata
        .findAll { row -> row.param_adapter1 && row.param_adapter2 }
        .collect { row -> "${row.SampleID}".toString() }
}
