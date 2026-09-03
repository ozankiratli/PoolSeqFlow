// What the pipeline was told about each pool of a results directory: how many individuals went
// into it, how many chromosomes that is, and the smallest frequency the tables it produced carry.
//
// A module reads these off its target. `poolSizes()` and `diploidy` belong to the pipeline's own
// scripts, which a module does not import - the library is what reads the pipeline.

nextflow.enable.dsl=2

include { poolSizes; poolSizeColumn } from '../../../scripts/metadata.nf'
include { runToken } from '../../../scripts/variants.nf'

// One pool's detection limit: the frequency below which the false-positive filter took a call to
// be error. Mirrored by SENS[name] in bin/filterFalsePositives.sh, which is what filtered.
def poolSensitivity(int diploidy, int size) {
    return 1.0d / (2 * diploidy * size)
}

// A sensitivity for a report: three significant figures, never in scientific notation.
def shownSensitivity(double value) {
    return new java.math.BigDecimal(value)
        .round(new java.math.MathContext(3))
        .stripTrailingZeros()
        .toPlainString()
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def poolSizeRefusal(String label, String pool, Map byValue) {
    def stated = byValue.sort { a, b -> a.key <=> b.key }
        .collect { size, runs -> "'${size}' by ${runs.join(', ')}" }
        .join(', ')
    return new IllegalArgumentException(
        "the pool '${pool}' is given more than one size by the runs whose results are in one\n" +
        "directory: ${stated}.\n" +
        "Those runs produced ONE set of tables, filtered against ONE of these sizes, and\n" +
        "nothing in the directory records which. Every frequency in it is read against how\n" +
        "many chromosomes the pool holds, so the analysis stops here rather than choose.\n" +
        "\n" +
        "A blank ${poolSizeColumn()} cell takes the run's own poolSize, and poolSize is not part of\n" +
        "what decides whether two runs share step 7: two runs that set\n" +
        "filterFalsePositives.sensitivity themselves agree there and can still disagree here.\n" +
        "\n" +
        "Give the pool a ${poolSizeColumn()} in each run's metadata, or give each run a storageDir\n" +
        "of its own so that neither reads the other's tables.\n" +
        "\n" +
        "Results directory: ${label}")
}

// The one diploidy the runs of a results directory were filtered under.
//
// Step 7's identity includes diploidy, so runs that disagree about it never share a directory:
// reaching the throw means stepParameterMap() no longer names it.
def targetDiploidy(String label, List members) {
    def byValue = [:]
    members.each { run -> byValue.get("${run.diploidy}".toString(), []) << runToken(run.runId) }

    if (byValue.size() > 1) {
        def stated = byValue.sort { a, b -> a.key <=> b.key }
            .collect { value, runs -> "'${value}' for ${runs.join(', ')}" }
            .join(', ')
        throw new IllegalStateException(
            "the runs whose results are in ${label} disagree about diploidy: ${stated}. " +
            "The plan and the run table disagree about which runs share work.")
    }
    return (byValue.keySet() as List)[0] as Integer
}

// One entry per pool of a results directory, ordered by pool, holding the figures every
// frequency published there is read against.
//
// `members` are the run definitions the directory covers, checked against each other the way the
// design is: a run whose param_poolSize cell is blank gives the pool its own poolSize, and two
// runs can share a results directory while their poolSize differs.
def poolFigures(String label, List members) {
    def byPool = [:]
    members.each { run ->
        poolSizes(run).each { pool, size ->
            byPool.get("${pool}".toString(), [:])
                  .get("${size}".toString(), []) << runToken(run.runId)
        }
    }
    if (byPool.isEmpty()) return []

    def diploidy = targetDiploidy(label, members)
    return byPool.sort { a, b -> a.key <=> b.key }.collect { pool, byValue ->
        if (byValue.size() > 1) throw poolSizeRefusal(label, pool, byValue)
        def size = (byValue.keySet() as List)[0] as Integer
        [ pool       : pool,
          size       : size,
          diploidy   : diploidy,
          nChrom     : diploidy * size,
          sensitivity: poolSensitivity(diploidy, size) ]
    }
}

// One pool group, named and measured.
def poolGroupLine(List entries) {
    def first = entries[0]
    return "${entries.collect { entry -> entry.pool }.join(', ')}: ${first.size} individuals, " +
           "${first.nChrom} chromosomes, frequencies above ${shownSensitivity(first.sensitivity)}"
}

// What the verification report says about the pools, per results directory. Pools of one size are
// one line: a project usually has a single size, and what the block is for is the number every
// frequency in the tables was read against.
def poolReportLines(List targets) {
    def lines = []
    targets.each { target ->
        def pools = target.pools
        if (pools.isEmpty()) return

        def groups = pools.groupBy { entry -> entry.size }.sort { a, b -> a.key <=> b.key }
        def counted = "${pools.size()} ${pools.size() == 1 ? 'pool' : 'pools'}".toString()
        lines << "POOL SIZES:            ${target.label}".toString()
        if (groups.size() == 1) {
            def first = pools[0]
            lines << ("POOL SIZES:                diploidy ${first.diploidy}, ${counted} of " +
                      "${first.size} individuals - ${first.nChrom} chromosomes, " +
                      "frequencies above ${shownSensitivity(first.sensitivity)}").toString()
        }
        else {
            lines << "POOL SIZES:                diploidy ${pools[0].diploidy}, ${counted}".toString()
            groups.each { _size, entries ->
                lines << "POOL SIZES:                    ${poolGroupLine(entries)}".toString()
            }
        }
    }
    return lines
}
