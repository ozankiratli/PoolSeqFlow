// What the pipeline was told about each pool of a results directory: how many individuals went
// into it, how many chromosomes that is, and the smallest frequency the tables it produced carry.
//
// A module reads these off its target. `poolSizes()` and `ploidy` belong to the pipeline's own
// scripts, which a module does not import - the library is what reads the pipeline.

nextflow.enable.dsl=2

include { poolSizes } from '../../../scripts/metadata.nf'
include { runToken } from '../../../scripts/variants.nf'

// One pool's detection limit: the frequency below which the false-positive filter took a call to
// be error. Mirrored by SENS[name] in bin/filterFalsePositives.sh, which is what filtered.
def poolSensitivity(int ploidy, int size) {
    return 1.0d / (2 * ploidy * size)
}

// A sensitivity for a report: three significant figures, never in scientific notation.
def shownSensitivity(double value) {
    return new java.math.BigDecimal(value)
        .round(new java.math.MathContext(3))
        .stripTrailingZeros()
        .toPlainString()
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
//
// Step 7's identity names poolSize, ploidy and every param_poolSize cell, so runs that hold a
// pool to different sizes never share a results directory. Reaching either throw means
// stepParameterMap() no longer names one of them.
def figureConflict(String label, String what, Map byValue) {
    def stated = byValue.sort { a, b -> a.key <=> b.key }
        .collect { value, runs -> "'${value}' for ${runs.join(', ')}" }
        .join(', ')
    return new IllegalStateException(
        "the runs whose results are in ${label} disagree about ${what}: ${stated}. " +
        "Step 7 filters with the pool sizes and the ploidy and its identity names both, so runs " +
        "that disagree about either get results of their own. The plan and the run table " +
        "disagree about which runs share work.")
}

// The one ploidy the runs of a results directory were filtered under.
def targetPloidy(String label, List members) {
    def byValue = [:]
    members.each { run -> byValue.get("${run.ploidy}".toString(), []) << runToken(run.runId) }
    if (byValue.size() > 1) throw figureConflict(label, 'ploidy', byValue)
    return (byValue.keySet() as List)[0] as Integer
}

// One entry per pool of a results directory, ordered by pool, holding the figures every
// frequency published there is read against.
//
// `members` are the run definitions the directory covers, and the sizes they give are checked
// against each other: a run whose param_poolSize cell is blank gives the pool its own poolSize,
// which is a second place two members can differ.
def poolFigures(String label, List members) {
    def byPool = [:]
    members.each { run ->
        poolSizes(run).each { pool, size ->
            byPool.get("${pool}".toString(), [:])
                  .get("${size}".toString(), []) << runToken(run.runId)
        }
    }
    if (byPool.isEmpty()) return []

    def ploidy = targetPloidy(label, members)
    return byPool.sort { a, b -> a.key <=> b.key }.collect { pool, byValue ->
        if (byValue.size() > 1) throw figureConflict(label, "the size of pool '${pool}'", byValue)
        def size = (byValue.keySet() as List)[0] as Integer
        [ pool       : pool,
          size       : size,
          ploidy     : ploidy,
          nChrom     : ploidy * size,
          sensitivity: poolSensitivity(ploidy, size) ]
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
            lines << ("POOL SIZES:                ploidy ${first.ploidy}, ${counted} of " +
                      "${first.size} individuals - ${first.nChrom} chromosomes, " +
                      "frequencies above ${shownSensitivity(first.sensitivity)}").toString()
        }
        else {
            lines << "POOL SIZES:                ploidy ${pools[0].ploidy}, ${counted}".toString()
            groups.each { _size, entries ->
                lines << "POOL SIZES:                    ${poolGroupLine(entries)}".toString()
            }
        }
    }
    return lines
}
