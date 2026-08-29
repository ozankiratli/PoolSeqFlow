// THE SAMPLE METADATA FILE, AND EVERY QUESTION ANYONE ASKS OF IT.
//
// One row per pair of FASTQ files. `SampleID` joins the row to the reads and becomes the read
// group's ID; the `RG_*` columns become the rest of the read group; `adapter1`/`adapter2` are
// per-sample overrides of the global trim settings; everything else is the user's own design
// metadata, recorded and never interpreted by steps 0-8.
//
// NOTHING HERE READS THE CSV. `resolveParameters()` runs bin/parse_metadata.py once and hands
// every run map the parsed rows as `run.metadata`; these functions project that list. That is
// the whole point of the file: RGTags.csv was parsed in three places - `head`/`awk`/`IFS` in
// step 4, a naive `split(',')` in step 6, and another in the divergence analysis - and the
// naive splits already mis-read a quoted value containing a comma, which a description field
// is the likeliest place in the pipeline to find one.
//
// THE THREE PROJECTIONS ARE THE SAME MECHANISM ASKED THREE QUESTIONS, and they have to be, or
// the pipeline could share an artifact between two runs while telling the user their metadata
// had not changed:
//
//   what a step's artifact depends on   -> stepIdentity() in variants.nf
//   what invalidates existing results   -> the change guard in step 0
//   what a task actually needs          -> the @RG line, the column order, the adapters
//
// A design column appears in none of them, which is what makes it free to add and edit. Z,
// 2026-08-28: the guard compares "the @RG projection plus the analysis-affecting columns",
// not the file.

nextflow.enable.dsl=2

// Trim Galore's option string is derived in one place; the per-sample override below rebuilds
// it through the same function rather than assembling the flags a second time.
include { trimOptions } from './resolve_parameters.nf'

// The read group tags this pipeline accepts, by the name the user writes.
//
// A SECOND COPY OF THE TABLE IN bin/parse_metadata.py, and deliberately: the parser has to
// refuse an unknown RG_ column before anything else runs, and this side has to render the tag.
// test/suites/00_static.sh checks the two agree, so a tag added to one and not the other fails
// a test rather than becoming a column that validates and then silently vanishes from the BAM.
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

// The per-sample overrides that change a number rather than a label.
def overrideColumns() {
    return ['adapter1', 'adapter2']
}

// One sample's row.
def metadataRow(Map run, String sampleId) {
    return run.metadata.find { row -> "${row.SampleID}" == sampleId }
}

// The `@RG` line for one sample, ready for `samtools addreplacerg`.
//
// Built here rather than in step 4's shell, which read the header and projected EVERY non-empty
// column into a tag - fine while every column was a tag, and exactly what a design column would
// have broken. An empty cell omits its tag, which is what it always meant.
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

// WHICH COLUMNS DECIDE WHAT A STEP PASSES ON. Authored, like stepParameterMap(), and checked
// against the processes by a case in test/suites/00_static.sh.
//
// Step 6 is absent on purpose: what it takes from this file is the ROW ORDER and nothing else -
// see metadataOrder() - so a column list cannot express it.
def metadataColumnsPerStep() {
    return [
        // Trim Galore's adapters, when a row overrides the global ones.
        2: overrideColumns(),
        // The read group baked into every cleaned BAM.
        4: rgTagMap().keySet().toList(),
    ]
}

// A step's view of the file: one line per sample, only the columns that step depends on, in a
// fixed column order so that adding a column of your own moves nothing.
//
// Sorted by SampleID, because these lines answer "are two runs' metadata the same for this
// step", and row order is a separate question with a separate answer below.
def metadataProjection(Map run, List columns) {
    return run.metadata
        .collect { row ->
            ([ "${row.SampleID}".toString() ] +
             columns.collect { column -> "${column}=${row[column] ?: ''}".toString() }).join('\t')
        }
        .sort()
}

// The sample order, which is the other thing the file decides: bcftools names the VCF's sample
// columns in the order the BAMs are given, step 6 orders them by this, and the frequency tables
// inherit it. Two files that are permutations of each other therefore share step 4 and diverge
// at step 6 - which a single "the metadata file" token would get wrong in one direction.
def metadataOrder(Map run) {
    return run.metadata.collect { row -> "${row.SampleID}".toString() }
}

// WHAT THE CHANGE GUARD COMPARES (Z, 2026-08-28): the read group projection plus the columns
// that change a number - and never the design columns, so recording that a sample came from a
// second collection site does not tell you to delete your results.
//
// In FILE order, not sorted, because the guard has to tell a value change from a permutation:
// the tag values live in the BAMs and a reordering leaves them correct, while the column order
// lives in the VCF and nothing else. Step 0 sorts both sides itself to draw that distinction,
// exactly as it did when this was the raw file.
def metadataGuardLines(Map run) {
    def columns = (rgTagMap().keySet().toList() + overrideColumns())
    return run.metadata.collect { row ->
        ([ "${row.SampleID}".toString() ] +
         columns.collect { column -> "${column}=${row[column] ?: ''}".toString() }).join('\t')
    }
}

// One sample's effective Trim Galore options.
//
// A row that sets both adapters replaces the run's adapter fragment for that sample and
// nothing else; a row that sets neither gets the run's own string unchanged, which is what
// keeps a project with no overrides byte-identical to one from before this file existed.
// Both-or-neither is enforced by the parser, so this only has to decide which source wins.
//
// Built through resolve_parameters.nf's own trimOptions(), never by assembling the flags here:
// one format string, so a flag added to the derivation reaches the per-sample path too.
def sampleTrimOptions(Map run, String sampleId) {
    def row = metadataRow(run, sampleId)
    def one = row == null ? '' : "${row.adapter1 ?: ''}"
    def two = row == null ? '' : "${row.adapter2 ?: ''}"
    if (!one || !two) return "${run.trim_galore.options}".toString()
    return trimOptions(run.trim_galore.quality, "-a ${one} -a2 ${two}")
}

// Does this run pin trim_galore.options outright, rather than letting it be derived?
//
// Settled rule 7 allows it, and it makes a per-sample adapter unactionable: the pinned string
// is used verbatim, so the row's adapters would be silently dropped. Step 0 refuses the
// combination rather than picking a winner - a run whose setting is quietly ignored is worse
// than one that will not start.
def trimOptionsArePinned(Map run) {
    return "${run.trim_galore.options}" !=
           trimOptions(run.trim_galore.quality, run.trim_galore.adapterOptions)
}

// The samples whose rows override the adapters.
def samplesWithAdapterOverrides(Map run) {
    return run.metadata
        .findAll { row -> row.adapter1 && row.adapter2 }
        .collect { row -> "${row.SampleID}".toString() }
}
