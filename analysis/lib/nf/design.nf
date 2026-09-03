// The experimental design a project records, and the one thing about it the frame refuses.
//
// An exp_ column is sample metadata: the pipeline records it and no step reads it. It describes
// the POOL, so every row of a pool has to give it one value. checkTargetDesign() enforces that at
// DAG-build, for every module.
//
// designSummary() emits the design as data. The frame prints a line of it in the verification
// report; a module writes it as JSON for its own R to read.

nextflow.enable.dsl=2

include { analysisSetting } from './paths.nf'
include { timeKinds; timeUnits; resolveTimeLevels } from './time.nf'

// The prefix that marks an experimental variable, and the name time is written under.
// Mirrored by EXPERIMENTAL_PREFIX and TIME_VARIABLE in bin/parse_metadata.py.
def experimentalPrefix() {
    return 'exp_'
}

def timeVariable() {
    return 'exp_time'
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

// The timeVar settings, checked against each other and against the columns this target has.
// Returns true when there is a time axis to resolve.
def checkTimeSettings(Map settings, List columns) {
    def column = "${settings.column}".trim()
    def kind = "${settings.kind}".trim()
    def unit = "${settings.unit}".trim()
    def format = "${settings.format}".trim()
    def order = settings.order ?: []

    // Anything outside the prefix escapes the pool-agreement refusal, and one pool could then
    // carry two timepoints with nothing to stop it.
    if (!column.startsWith(experimentalPrefix())) {
        throw new IllegalArgumentException(
            "analysis.timeVar.column is '${column}', and a time variable has to be an " +
            "${experimentalPrefix()} column.\n" +
            "Only those are checked for agreeing across the rows of one pool, which is what " +
            "stops a pool carrying two timepoints at once.")
    }

    def present = columns.contains(column)
    if (!present) {
        if (kind.isEmpty()) return false
        throw new IllegalArgumentException(
            "analysis.timeVar.kind is '${kind}', and this project has no ${column} column.\n" +
            "The columns it has are: ${columns.isEmpty() ? '(none)' : columns.join(', ')}\n" +
            "Name the one that holds time with analysis.timeVar.column, or remove the setting.")
    }
    if (kind.isEmpty()) {
        throw new IllegalArgumentException(
            "this project has a ${column} column and analysis.timeVar.kind is not set.\n" +
            "Time is the one variable whose ORDER changes what a result means, and it is not " +
            "guessed: 20240307 reads as a number as readily as a date, which keeps the order " +
            "right and makes every interval wrong. Set it to one of: ${timeKinds().join(', ')}")
    }
    if (!timeKinds().contains(kind)) {
        throw new IllegalArgumentException(
            "analysis.timeVar.kind is '${kind}', which is not one of: ${timeKinds().join(', ')}")
    }

    if (kind == 'numerical' && unit.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.timeVar.kind is 'numerical' and no unit is set.\n" +
            "The numbers are distances, so a rate is meaningful and has to be labelled - per " +
            "generation, per day. Set analysis.timeVar.unit to one of:\n" +
            "    ${timeUnits().keySet().join(', ')}\n" +
            "'step' is for an axis that is evenly spaced in something you have not named.")
    }
    if (!unit.isEmpty() && !timeUnits().containsKey(unit)) {
        throw new IllegalArgumentException(
            "analysis.timeVar.unit is '${unit}', which is not one of:\n" +
            "    ${timeUnits().keySet().join(', ')}")
    }
    if (kind == 'categorical' && !unit.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.timeVar.unit is '${unit}' and kind is 'categorical'.\n" +
            "A unit asserts that the spacing between levels means something, and categorical " +
            "time is an order and nothing more. Set kind to 'numerical' if the spacing is real, " +
            "or drop the unit.")
    }
    if (kind == 'datetime' && !unit.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.timeVar.unit is '${unit}' and kind is 'datetime', which is measured in " +
            "days by construction. Drop the unit.")
    }
    if (kind == 'datetime' && format.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.timeVar.kind is 'datetime' and no format is set.\n" +
            "07/03/2024 is a valid date under dd/MM/yyyy and under MM/dd/yyyy, and the two are " +
            "four months apart. Set analysis.timeVar.format to the pattern your file uses.")
    }
    if (!format.isEmpty() && kind != 'datetime') {
        throw new IllegalArgumentException(
            "analysis.timeVar.format is set and kind is '${kind}'. A format reads dates, so it " +
            "applies only to kind 'datetime'.")
    }
    if (!order.isEmpty() && kind != 'categorical') {
        throw new IllegalArgumentException(
            "analysis.timeVar.order is set and kind is '${kind}'. An explicit order applies only " +
            "to kind 'categorical'; ${kind} time orders itself.")
    }
    return true
}

// The columns that identify one thing measured repeatedly. Declared rather than inferred: a
// variable recorded AT each timepoint - a temperature, a census - differs between the pools of one
// series, so every series would have length 1 and the design would dissolve with no error.
def seriesKeyColumns(List columns, String timeColumn, List by) {
    if (by.isEmpty()) return columns.findAll { column -> column != timeColumn }

    def named = by.collect { entry -> "${entry}".toString() }
    if (named.contains(timeColumn)) {
        throw new IllegalArgumentException(
            "analysis.series.by names ${timeColumn}, which is the time column.\n" +
            "A series is what stays the same WHILE time changes, so time cannot be part of what " +
            "identifies it.")
    }
    def unknown = named.findAll { column -> !columns.contains(column) }
    if (!unknown.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.series.by names ${unknown.join(', ')}, which this project's metadata does " +
            "not have.\n" +
            "The experimental variables it has are: ${columns.isEmpty() ? '(none)' : columns.join(', ')}")
    }
    return named
}

// Which of the key columns index repeats rather than naming a condition, checked. Two lists and
// not one: biological replicates are independent and are what degrees of freedom are counted from,
// technical ones are the same material measured twice and carry none.
def replicateRoles(List keyColumns, String timeColumn, Map settings) {
    def biological = (settings.biologicalRep ?: []).collect { entry -> "${entry}".toString() }
    def technical = (settings.technicalRep ?: []).collect { entry -> "${entry}".toString() }

    [['biologicalRep', biological], ['technicalRep', technical]].each { pair ->
        def name = pair[0]
        pair[1].each { column ->
            if (column == timeColumn) {
                throw new IllegalArgumentException(
                    "analysis.series.${name} names ${timeColumn}, which is the time column. A " +
                    "replicate is what a series has instead of a condition, and time is neither.")
            }
            if (!keyColumns.contains(column)) {
                throw new IllegalArgumentException(
                    "analysis.series.${name} names '${column}', which does not identify a series.\n" +
                    "The columns that do are: ${keyColumns.isEmpty() ? '(none)' : keyColumns.join(', ')}\n" +
                    "Add it to analysis.series.by if it should, or correct the name.")
            }
        }
    }
    def both = biological.findAll { column -> technical.contains(column) }
    if (!both.isEmpty()) {
        throw new IllegalArgumentException(
            "${both.join(', ')} is named as both a biological and a technical replicate.\n" +
            "Biological replicates are independent repeats of one condition and carry degrees of " +
            "freedom; technical replicates are one biological unit measured more than once and " +
            "carry none. A column is one or the other.")
    }
    return [ condition : keyColumns.findAll { column -> !biological.contains(column) && !technical.contains(column) },
             biological: biological,
             technical : technical ]
}

// Series rolled up by dropping columns: without the technical ones a series becomes the independent
// biological unit, and without the biological ones too it becomes the condition. A module counting
// degrees of freedom or choosing strata reads units, never series.
def rollUp(List series, List keepColumns) {
    def grouped = [:]
    series.each { entry ->
        def label = keepColumns.isEmpty() ? 'all pools' : keepColumns.collect { column -> entry.key[column] ?: '(blank)' }.join(' | ')
        grouped.get(label, []) << entry
    }
    return grouped.keySet().sort().collect { label ->
        [ label : label,
          key   : keepColumns.collectEntries { column -> [ column, grouped[label][0].key[column] ] },
          series: grouped[label].collect { entry -> entry.label } ]
    }
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def seriesLabel(Map values, List keyColumns) {
    if (keyColumns.isEmpty()) return 'all pools'
    return keyColumns.collect { column -> values[column] ?: '(blank)' }.join(' | ')
}

// The levels a set of indices names, for a message.
def levelNames(Map time, List indices) {
    return indices.sort().collect { index -> time.levels[index].value }.join(', ')
}

// analysis.series.incomplete, applied. Returns the timeline that survives and the series dropped.
//
// keepLeft and keepRight truncate the TIMELINE and not each series, so every series that survives
// covers the same points. None of the four fills a gap in: carrying a frequency forward invents a
// measurement that everything downstream then weights by a depth nobody observed.
def applyIncomplete(String mode, Map time, Map covered, List warnings) {
    def full = time.levels.collect { level -> level.index }
    def ragged = covered.findAll { _label, indices -> indices != full }

    if (ragged.isEmpty()) return [ timeline: full, dropped: [] ]

    if (mode == 'fail') {
        def named = ragged.take(5).collect { label, indices ->
            "    ${label} lacks ${levelNames(time, full.findAll { index -> !indices.contains(index) })}"
        }.join('\n')
        throw new IllegalArgumentException(
            "${ragged.size()} of ${covered.size()} series do not cover every ${time.column}:\n" +
            "${named}${ragged.size() > 5 ? "\n    ... and ${ragged.size() - 5} more" : ''}\n" +
            "A ragged panel analysed as a complete one is a wrong answer that looks like a right " +
            "one, so this refuses by default. Choose what should happen with " +
            "analysis.series.incomplete:\n" +
            "    'drop'       leave the incomplete series out\n" +
            "    'keepLeft'   cut the timeline back to the points every series shares, from the start\n" +
            "    'keepRight'  the same, from the end")
    }

    if (mode == 'drop') {
        warnings << [ code  : 'series-dropped',
                      detail: "analysis.series.incomplete is 'drop', so ${ragged.size()} " +
                              "incomplete series were left out:\n" +
                              ragged.collect { label, indices ->
                                  "    ${label} lacked ${levelNames(time, full.findAll { index -> !indices.contains(index) })}"
                              }.join('\n') ]
        return [ timeline: full, dropped: ragged.keySet().toList() ]
    }

    def timeline = mode == 'keepLeft'
        ? full.takeWhile { index -> covered.every { _label, indices -> indices.contains(index) } }
        : full.reverse().takeWhile { index -> covered.every { _label, indices -> indices.contains(index) } }.reverse()

    if (timeline.isEmpty()) {
        def edge = mode == 'keepLeft' ? full.first() : full.last()
        def without = covered.findAll { _label, indices -> !indices.contains(edge) }.keySet()
        throw new IllegalArgumentException(
            "analysis.series.incomplete is '${mode}', and there is nothing left to keep: " +
            "${without.size() == 1 ? 'the series' : 'the series'} " +
            "${without.take(5).join(', ')} ${without.size() == 1 ? 'does' : 'do'} not cover " +
            "'${time.levels[edge].value}', which is the ${mode == 'keepLeft' ? 'first' : 'last'} " +
            "point of the timeline.\n" +
            "Try '${mode == 'keepLeft' ? 'keepRight' : 'keepLeft'}' if the gap is at the other " +
            "end, or 'drop' to leave those series out.")
    }

    warnings << [ code  : "series-${mode}",
                  detail: "analysis.series.incomplete is '${mode}', so the timeline was cut from " +
                          "${full.size()} points to ${timeline.size()}: kept " +
                          "${levelNames(time, timeline)}; dropped " +
                          "${levelNames(time, full.findAll { index -> !timeline.contains(index) })}." ]

    if (timeline.size() == 1) {
        warnings << [ code  : 'series-collapsed',
                      detail: "the timeline is now a SINGLE point, '${time.levels[timeline[0]].value}', " +
                              "so every series has one measurement and there is no time axis left. " +
                              "Nothing that reads a trajectory can run on this. 'drop' is usually " +
                              "what a design like this wants." ]
    }
    return [ timeline: timeline, dropped: [] ]
}

// Every series in this target, ordered by time, after analysis.series.incomplete has been applied.
// The timeline is truncated rather than each series individually, so what comes out is rectangular
// and every series is comparable with every other.
def buildSeries(List pools, Map time, List keyColumns, String incomplete, List warnings) {
    def timeColumn = time.column
    def indexOf = [:]
    time.levels.each { level -> indexOf[level.value] = level.index }

    def placed = pools.findAll { pool -> indexOf.containsKey(pool.values[timeColumn]) }
    def undated = pools.findAll { pool -> !indexOf.containsKey(pool.values[timeColumn]) }
    if (!undated.isEmpty()) {
        warnings << [ code  : 'time-missing-value',
                      detail: "${undated.size()} pool${undated.size() == 1 ? '' : 's'} have no " +
                              "${timeColumn} and are in no series: " +
                              "${undated.collect { pool -> pool.pool }.join(', ')}" ]
    }

    def grouped = [:]
    placed.each { pool ->
        def label = seriesLabel(pool.values, keyColumns)
        grouped.get(label, []) << pool
    }

    // Two pools at one point leave the series not a function of time.
    grouped.each { label, members ->
        members.groupBy { pool -> indexOf[pool.values[timeColumn]] }.each { index, atPoint ->
            if (atPoint.size() > 1) {
                throw new IllegalArgumentException(
                    "the series '${label}' has ${atPoint.size()} pools at the same ${timeColumn}, " +
                    "'${time.levels[index].value}': ${atPoint.collect { pool -> pool.pool }.join(', ')}\n" +
                    "A series is one thing measured repeatedly, so each point is one pool. Which " +
                    "these are decides what to do:\n" +
                    "  - separate biological material, or the same material sequenced separately:\n" +
                    "    give them an ${experimentalPrefix()} column that tells them apart, and name it in\n" +
                    "    analysis.series.biologicalRep or technicalRep. They become separate series.\n" +
                    "  - one pool sequenced twice that you meant to merge: give the rows the same\n" +
                    "    RG_Sample. The pipeline pools their reads and adds their depths, and they\n" +
                    "    become one column of every published table.")
            }
        }
    }

    def covered = grouped.collectEntries { label, members ->
        [ label, members.collect { pool -> indexOf[pool.values[timeColumn]] }.sort() ]
    }
    def keep = applyIncomplete(incomplete, time, covered, warnings)

    def series = grouped.keySet().sort()
        .findAll { label -> !keep.dropped.contains(label) }
        .collect { label ->
            def members = grouped[label].findAll { pool -> keep.timeline.contains(indexOf[pool.values[timeColumn]]) }
                                        .sort { a, b -> indexOf[a.values[timeColumn]] <=> indexOf[b.values[timeColumn]] }
            [ label   : label,
              key     : keyColumns.collectEntries { column -> [ column, members[0].values[column] ] },
              pools   : members.collect { pool -> pool.pool },
              timeline: members.collect { pool -> indexOf[pool.values[timeColumn]] } ]
        }
    return [ series: series, timeline: keep.timeline ]
}

// The design as data: the variables, their levels, one entry per pool holding the libraries merged
// into it and the value of every variable, the time axis, and the series. Called only after
// checkTargetDesign() has passed, so one row of a pool speaks for all of them.
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

    def settings = analysisSetting('timeVar')
    def warnings = []
    def time = null
    def series = []
    def keyColumns = []
    def roles = [ condition: [], biological: [], technical: [] ]
    def units = []
    def conditions = []

    if (checkTimeSettings(settings, columns)) {
        def column = "${settings.column}".trim()
        def resolved = resolveTimeLevels(pools.collect { entry -> entry.values[column] }, settings)
        warnings.addAll(resolved.warnings)
        // format and locale travel with the levels: 'these dates were in this order' is not
        // reproducible from a published folder unless the folder says how they were read.
        time = [ column: column,
                 kind  : "${settings.kind}".trim(),
                 unit  : resolved.unit,
                 format: "${settings.format}".trim() ?: null,
                 locale: "${settings.kind}".trim() == 'datetime' ? "${settings.locale}".trim() : null,
                 levels: resolved.levels ]

        def seriesSettings = analysisSetting('series')
        keyColumns = seriesKeyColumns(columns, column, seriesSettings.by ?: [])
        if ((seriesSettings.by ?: []).isEmpty()) {
            warnings << [ code  : 'series-key-computed',
                          detail: "analysis.series.by is not set, so a series is every pool sharing " +
                                  "${keyColumns.isEmpty() ? 'nothing but the project' : keyColumns.join(' and ')}. " +
                                  "Set it if a variable here is recorded AT each timepoint rather " +
                                  "than identifying what is being followed." ]
        }
        roles = replicateRoles(keyColumns, column, seriesSettings)
        def built = buildSeries(pools, time, keyColumns,
                                "${seriesSettings.incomplete}".trim(), warnings)
        series = built.series
        time.timeline = built.timeline
        units = rollUp(series, roles.condition + roles.biological)
        conditions = rollUp(series, roles.condition)

        def singletons = series.findAll { entry -> entry.pools.size() == 1 }
        if (!singletons.isEmpty() && series.size() > singletons.size()) {
            warnings << [ code  : 'series-singleton',
                          detail: "${singletons.size()} series hold one pool each and carry no " +
                                  "trajectory: ${singletons.collect { entry -> entry.label }.join(', ')}" ]
        }
    }

    return [ variables : variables,
             pools     : pools,
             time      : time,
             seriesBy  : keyColumns,
             roles     : roles,
             series    : series,
             units     : units,
             conditions: conditions,
             warnings  : warnings ]
}

// The design as JSON, for a module to hand to its own R.
def designJson(Map summary) {
    return groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(summary))
}

// How the time axis was read, as three lines. The levels are printed IN THE ORDER THE ANALYSIS
// WILL USE THEM, and as they resolved rather than as they were written: 07/03/2024 shown as
// 2024-03-07 is the only thing that catches a user who meant July, and no check can.
def timeReportLines(Map time) {
    if (time == null) return ['TIME VARIABLE:         none - no time column, so nothing is a trajectory']

    def head = "TIME VARIABLE:         ${time.column}, ${time.kind}"
    if (time.kind == 'numerical') head += ", in ${time.unit}s"
    if (time.kind == 'datetime') head += ", '${time.format}' (${time.locale})"
    def lines = [head.toString()]

    def shown = time.levels.collect { level -> level.shown }.join('  ')
    lines << "TIME VARIABLE:             ${shown}   (${time.levels.size()} levels)".toString()
    return lines
}

// A count that varies across groups, as a range. Technical replication is legitimately unbalanced
// - one sample sequenced three times for validation and another once - and a single number would
// be a plausible-looking lie.
def spread(List counts) {
    if (counts.isEmpty()) return '0'
    def low = counts.min()
    def high = counts.max()
    return low == high ? "${low}".toString() : "${low}-${high}".toString()
}

// What a series is, and which of the columns identifying it name a condition rather than a repeat.
//
// EVERY key column is printed under exactly one role. A column left out of technicalRep is read as
// a condition, which turns one treatment into three and hands a test strata that are the same DNA -
// and no check can catch that, for the same reason none can catch dd/MM against MM/dd.
def seriesReportLines(Map design) {
    if (design.time == null) return []
    def points = design.time.timeline == null ? 0 : design.time.timeline.size()
    def lines = []

    if (design.seriesBy.isEmpty()) {
        lines << 'SERIES:                by nothing - every pool is one series'
    }
    else {
        lines << "SERIES:                conditions   ${design.roles.condition.isEmpty() ? '(none - one condition)' : design.roles.condition.join(', ')}".toString()
        lines << "SERIES:                biological   ${design.roles.biological.isEmpty() ? '(none declared)' : design.roles.biological.join(', ')}".toString()
        lines << "SERIES:                technical    ${design.roles.technical.isEmpty() ? '(none declared)' : design.roles.technical.join(', ')}".toString()
    }

    def perCondition = design.conditions.collect { entry ->
        design.units.count { unit -> entry.series.containsAll(unit.series) }
    }
    def perUnit = design.units.collect { unit -> unit.series.size() }
    lines << "SERIES:                    ${design.conditions.size()} condition${design.conditions.size() == 1 ? '' : 's'}, " +
             "${spread(perCondition)} biological replicate${perCondition.max() == 1 ? '' : 's'} each, " +
             "${spread(perUnit)} technical".toString()
    lines << "SERIES:                    ${design.series.size()} series over ${points} timepoint${points == 1 ? '' : 's'}, " +
             "from ${design.units.size()} independent unit${design.units.size() == 1 ? '' : 's'}".toString()

    design.series.take(6).each { entry ->
        lines << "SERIES:                        ${entry.label}  (${entry.pools.size()})".toString()
    }
    if (design.series.size() > 6) {
        lines << "SERIES:                        ... and ${design.series.size() - 6} more".toString()
    }
    return lines
}

// What is worth knowing and is not an error. Rendered from design.warnings, which the published
// README renders too - written twice they would drift, and the folder would end up disagreeing
// with the record beside it.
def designNoteLines(Map design) {
    if (design.warnings.isEmpty()) return []
    def lines = ['DESIGN NOTES:          things that change what these numbers mean:']
    design.warnings.each { note ->
        note.detail.split('\n').eachWithIndex { text, index ->
            lines << "DESIGN NOTES:              ${index == 0 ? '- ' : '  '}${text}".toString()
        }
    }
    return lines
}

// What the verification report says about the design, per results directory.
//
// No metadata file and no exp_ columns are separate messages: the first is a project set up
// somewhere the CSV was never copied to.
def designReportLines(List targets) {
    def lines = []
    targets.each { target ->
        def design = target.design
        def pools = design.pools.size()
        def libraries = design.pools.sum { entry -> entry.libraries.size() } ?: 0
        lines << "EXPERIMENTAL DESIGN:   ${target.label}".toString()
        if (pools == 0) {
            lines << "EXPERIMENTAL DESIGN:       no metadata rows - ${params.metadataFile} was not read".toString()
        }
        else if (design.variables.isEmpty()) {
            lines << "EXPERIMENTAL DESIGN:       ${pools} pools from ${libraries} libraries, no exp_ columns".toString()
        }
        else {
            def stated = design.variables.collect { variable ->
                "${variable.name} (${variable.levels.size()} ${variable.levels.size() == 1 ? 'level' : 'levels'})".toString()
            }.join(', ')
            lines << "EXPERIMENTAL DESIGN:       ${pools} pools from ${libraries} libraries".toString()
            lines << "EXPERIMENTAL DESIGN:           ${stated}".toString()
        }
        lines.addAll(timeReportLines(design.time))
        lines.addAll(seriesReportLines(design))
        lines.addAll(designNoteLines(design))
    }
    return lines
}
