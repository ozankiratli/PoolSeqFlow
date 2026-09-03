// The experimental design a project records, and the one thing about it the frame refuses.
//
// An exp_ column is sample metadata: the pipeline records it and no step reads it. It describes
// the POOL, so every row of a pool has to give it one value. checkTargetDesign() enforces that at
// DAG-build, for every module.
//
// designSummary() emits the design as data. The frame prints a line of it in the verification
// report; a module writes it as JSON for its own R to read.

nextflow.enable.dsl=2

// The prefix that marks an experimental variable, and the name time is written under.
// Mirrored by EXPERIMENTAL_PREFIX and TIME_VARIABLE in bin/parse_metadata.py.
def experimentalPrefix() {
    return 'exp_'
}

def timeVariable() {
    return 'exp_timepoint'
}

// The pool a row belongs to. parse_metadata.py fills RG_Sample in from SampleID, so a row that
// left the column out still names one.
def poolOf(Map row) {
    return "${row.RG_Sample ?: row.SampleID}".toString()
}

// The exp_ columns these rows carry, in the order their file gives them. A column one row has and
// another does not is still a column: the rows are then in disagreement about it, which is the
// state checkTargetDesign() refuses.
def experimentalColumns(List rows) {
    def found = []
    rows.each { row ->
        row.keySet().each { column ->
            def name = "${column}".toString()
            if (name.startsWith(experimentalPrefix()) && !found.contains(name)) found << name
        }
    }
    return found
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def designRefusal(String label, String pool, String column, Map byValue) {
    def stated = byValue.sort { a, b -> a.key <=> b.key }
        .collect { value, samples -> "'${value ?: '(blank)'}' on ${samples.join(', ')}" }
        .join(', ')
    return new IllegalArgumentException(
        "the pool '${pool}' is given more than one ${column}: ${stated}.\n" +
        "An exp_ column describes the pool, and rows sharing an RG_Sample ARE one pool: their\n" +
        "reads are merged and their depths added into one column of every published table, so\n" +
        "there is one value to have. A blank cell means no value, which is a third answer\n" +
        "rather than agreement with either.\n" +
        "\n" +
        "What differs BETWEEN two rows of one pool - the lane, the batch, the sequencing run -\n" +
        "is not an experimental variable. Record it in a column with no exp_ prefix; those are\n" +
        "kept and never interpreted.\n" +
        "\n" +
        "Every analysis this project publishes records the design it was produced under, so a\n" +
        "project whose design contradicts itself publishes nothing until it is settled - not\n" +
        "only the analyses that read one.\n" +
        "\n" +
        "Results directory: ${label}")
}

// Every row of one pool agrees on every exp_ column, or the run stops here. `rows` are the rows of
// all the runs one results directory covers, so two runs with different metadataFiles that share
// a directory are checked against each other and not only against themselves.
def checkTargetDesign(String label, List rows) {
    def columns = experimentalColumns(rows)
    if (columns.isEmpty()) return

    rows.groupBy { row -> poolOf(row) }.sort { a, b -> a.key <=> b.key }.each { pool, poolRows ->
        columns.each { column ->
            def byValue = [:]
            poolRows.each { row ->
                def value = "${row[column] ?: ''}".toString()
                byValue.get(value, []) << "${row.SampleID}".toString()
            }
            if (byValue.size() > 1) throw designRefusal(label, pool, column, byValue)
        }
    }
}

// The design as data: the variables, their levels, and one entry per pool holding the libraries
// merged into it and the value of every variable. Called only after checkTargetDesign() has
// passed, so one row of a pool speaks for all of them.
def designSummary(List rows) {
    def columns = experimentalColumns(rows)
    def byPool = rows.groupBy { row -> poolOf(row) }.sort { a, b -> a.key <=> b.key }

    def pools = byPool.collect { pool, poolRows ->
        [ pool     : pool,
          libraries: poolRows.collect { row -> "${row.SampleID}".toString() }.unique().sort(),
          values    : columns.collectEntries { column ->
              [ column, "${poolRows[0][column] ?: ''}".toString() ] } ]
    }

    def variables = columns.collect { column ->
        [ name  : column,
          levels: pools.collect { entry -> entry.values[column] }.unique().sort() ]
    }

    return [ variables: variables,
             pools    : pools,
             time     : columns.contains(timeVariable()) ? timeVariable() : null ]
}

// The design as JSON, for a module to hand to its own R.
def designJson(Map summary) {
    return groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(summary))
}

// What the verification report says about the design: one line per results directory, and a
// second naming the variables when there are any.
//
// No metadata file and no exp_ columns are separate messages: the first is a project set up
// somewhere the CSV was never copied to.
def designReportLines(List targets) {
    def lines = ['EXPERIMENTAL DESIGN:   from the exp_ columns of the sample metadata']
    targets.each { target ->
        def design = target.design
        def pools = design.pools.size()
        def libraries = design.pools.sum { entry -> entry.libraries.size() } ?: 0
        if (pools == 0) {
            lines << "EXPERIMENTAL DESIGN:       ${target.label}: no metadata rows - ${params.metadataFile} was not read".toString()
        }
        else if (design.variables.isEmpty()) {
            lines << "EXPERIMENTAL DESIGN:       ${target.label}: ${pools} pools, no exp_ columns".toString()
        }
        else {
            def stated = design.variables.collect { variable ->
                "${variable.name} (${variable.levels.size()} ${variable.levels.size() == 1 ? 'level' : 'levels'})".toString()
            }.join(', ')
            lines << "EXPERIMENTAL DESIGN:       ${target.label}: ${pools} pools from ${libraries} libraries".toString()
            lines << "EXPERIMENTAL DESIGN:           ${stated}".toString()
        }
    }
    return lines
}
