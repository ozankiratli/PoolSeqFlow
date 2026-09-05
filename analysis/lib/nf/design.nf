// The experimental design a project records, and the one thing about it the frame refuses.
//
// An exp_ column is sample metadata: the pipeline records it and no step reads it. It describes
// the POOL, so every row of a pool has to give it one value. checkTargetDesign() enforces that at
// DAG-build, for every module.
//
// designSummary() emits the design as data. The frame prints a line of it in the verification
// report; a module writes it as JSON for its own R to read.

nextflow.enable.dsl=2

include { analysisSetting; metadataSetting } from './paths.nf'
include { timeKinds; timeUnits; resolveTimeLevels } from './time.nf'

// The prefix that marks an experimental variable, and the name time is written under.
// Mirrored by EXPERIMENTAL_PREFIX and TIME_VARIABLE in bin/parse_metadata.py.
def experimentalPrefix() {
    return 'exp_'
}

def timeVariable() {
    return 'exp_time'
}

// The prefix that marks a phenotype measured on the pool. Mirrored by PHENOTYPE_PREFIX in
// bin/parse_metadata.py.
//
// Separate from exp_ because only an experimental variable identifies a series: seriesKeyColumns()
// takes every exp_ column but time, and a trait value differs per pool, so admitting one there
// would leave every series a single timepoint long.
def phenotypePrefix() {
    return 'pt_'
}

// The prefix that marks a covariate measured on the pool. Mirrored by COVARIATE_PREFIX in
// bin/parse_metadata.py.
//
// Neither set nor the response: a cage temperature, an altitude, a collection site. Its own prefix
// for the same reason pt_ has one - seriesKeyColumns() takes every exp_ column but time, so a
// temperature recorded at each timepoint would give every series length 1, which is the
// dissolution the series settings can only be told to work around.
//
// A cov_ column is optional to DECLARE. Undeclared it is recorded, checked and reported like any
// pool-level column; declared in analysis.metadata.covariates it also carries a typed value a
// module can compute with.
def covariatePrefix() {
    return 'cov_'
}

// The pool a row belongs to. parse_metadata.py fills RG_Sample in from SampleID, so a row that
// left the column out still names one.
def poolOf(Map row) {
    return "${row.RG_Sample ?: row.SampleID}".toString()
}

// The columns these rows carry under one prefix, in the order their file gives them. A column one
// row has and another does not is still a column: the rows are then in disagreement about it,
// which is the state checkTargetDesign() refuses.
def columnsWithPrefix(List rows, String prefix) {
    def found = []
    rows.each { row ->
        row.keySet().each { column ->
            def name = "${column}".toString()
            if (name.startsWith(prefix) && !found.contains(name)) found << name
        }
    }
    return found
}

def experimentalColumns(List rows) {
    return columnsWithPrefix(rows, experimentalPrefix())
}

def phenotypeColumns(List rows) {
    return columnsWithPrefix(rows, phenotypePrefix())
}

def covariateColumns(List rows) {
    return columnsWithPrefix(rows, covariatePrefix())
}

// Every column that describes the pool rather than the library, which is what one row of a pool
// has to speak for all of them about.
def poolLevelColumns(List rows) {
    return experimentalColumns(rows) + phenotypeColumns(rows) + covariateColumns(rows)
}

// One analysis.metadata.missingValueEncoding entry as a matcher: `*` is any run of characters,
// `?` is one, and everything else is literal. Matched whole and case sensitively - a project that
// writes both NA and na lists both, because a level genuinely called `na` must stay a level.
// Pattern.compile and not a slashy string: the strict parser rejects an interpolated ~/.../.
def missingValueMatcher(String glob) {
    def pattern = new StringBuilder()
    glob.each { character ->
        if (character == '*') pattern << '.*'
        else if (character == '?') pattern << '.'
        else pattern << java.util.regex.Pattern.quote("${character}".toString())
    }
    return java.util.regex.Pattern.compile("${pattern}".toString())
}

// The matchers this project declared, checked. An entry that matches everything would blank every
// cell of every experimental column, so it is refused rather than obeyed.
def missingValueMatchers() {
    def declared = metadataSetting('missingValueEncoding') ?: []
    def entries = (declared instanceof List ? declared : [declared])
        .collect { entry -> "${entry}".toString() }
    entries.each { entry ->
        if (entry.trim().isEmpty()) {
            throw new IllegalArgumentException(
                "analysis.metadata.missingValueEncoding holds an empty entry.\n" +
                "A blank cell already means no value; the setting is for the other spellings of " +
                "it - 'NA', 'N/A', '-'. Remove the empty entry.")
        }
        if (entry.replace('*', '').replace('?', '').isEmpty()) {
            throw new IllegalArgumentException(
                "analysis.metadata.missingValueEncoding holds '${entry}', which matches every " +
                "value.\n" +
                "Every experimental and phenotype cell in the project would be read as missing " +
                "and no analysis would have a design left. Name the spellings your file uses.")
        }
    }
    return entries.collect { entry -> missingValueMatcher(entry) }
}

// A cell as the analysis layer reads it: the text, or empty when the project declared that
// spelling to mean no value. Everything downstream already treats empty as missing, so an encoded
// value becomes one rather than a second kind of absence.
def readCell(Object raw, List matchers) {
    def value = "${raw ?: ''}".toString()
    if (value.isEmpty() || matchers.isEmpty()) return value
    return matchers.any { matcher -> matcher.matcher(value).matches() } ? '' : value
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def designRefusal(String label, String pool, String column, Map byValue) {
    def stated = byValue.sort { a, b -> a.key <=> b.key }
        .collect { value, samples -> "'${value ?: '(blank)'}' on ${samples.join(', ')}" }
        .join(', ')
    def kind = "An ${experimentalPrefix()} column describes the pool"
    if (column.startsWith(phenotypePrefix())) {
        kind = "A ${phenotypePrefix()} column is a phenotype measured ON the pool"
    }
    else if (column.startsWith(covariatePrefix())) {
        kind = "A ${covariatePrefix()} column is a covariate measured ON the pool"
    }
    return new IllegalArgumentException(
        "the pool '${pool}' is given more than one ${column}: ${stated}.\n" +
        "${kind}, and rows sharing an RG_Sample ARE one pool: their\n" +
        "reads are merged and their depths added into one column of every published table, so\n" +
        "there is one value to have. A blank cell means no value, which is a third answer\n" +
        "rather than agreement with either.\n" +
        "\n" +
        "If it genuinely varies between the rows of this pool - two libraries reared warmer and\n" +
        "cooler, handled by two people - then it is a CIRCUMSTANCE and not this.\n" +
        "Record it under ${covariatePrefix()}, which may differ within a pool and reports that it did.\n" +
        "\n" +
        "If it is a property of the row rather than the pool - the lane, the run, the kit lot -\n" +
        "record it with no prefix. Those are kept and never interpreted, and no analysis can use\n" +
        "one: the reads are merged, so nothing can attribute one to the row it came from.\n" +
        "\n" +
        "Every analysis this project publishes records the design it was produced under, so a\n" +
        "project whose design contradicts itself publishes nothing until it is settled - not\n" +
        "only the analyses that read one.\n" +
        "\n" +
        "Results directory: ${label}")
}

// Every row of one pool agrees on every exp_ and pt_ column, or the run stops here. `rows` are the
// rows of all the runs one results directory covers, so two runs with different metadataFiles that
// share a directory are checked against each other and not only against themselves.
//
// Both prefixes and not only exp_: a phenotype is measured on the pool, so a pool carrying two of
// them is the same contradiction, and analysis.phenotype.column is confined to pt_ precisely so
// that every column it can name has been through here.
def checkTargetDesign(String label, List rows) {
    // exp_ and pt_ only. A cov_ column may legitimately differ between the rows of one pool - two
    // libraries really can have had two technicians, or been reared at two temperatures - so a
    // disagreement there is a fact about the pool rather than a contradiction, and designSummary()
    // records it instead. What you SET and what you MEASURED ON the pool cannot vary that way: one
    // pool had one treatment, and one pool has one trait value.
    def columns = experimentalColumns(rows) + phenotypeColumns(rows)
    if (columns.isEmpty()) return

    // Through readCell(), so a pool whose rows say 'NA' and nothing at all agree when the project
    // has declared 'NA' to mean no value. Comparing the raw text would call that a contradiction
    // and refuse a file the user wrote consistently.
    def matchers = missingValueMatchers()

    rows.groupBy { row -> poolOf(row) }.sort { a, b -> a.key <=> b.key }.each { pool, poolRows ->
        columns.each { column ->
            def byValue = [:]
            poolRows.each { row ->
                def value = readCell(row[column], matchers)
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

// What a phenotype can be declared as - a measurement SCALE, not a storage type. Like
// timeVar.kind and for the same reason, it is never inferred: 0 and 1 read as numbers as readily
// as they encode two groups, and which of 'case' and 'control' means 1 is not in the data at all.
//
//   quantitative  a number. Counts and proportions are this too - a phenotype is a predictor,
//                 and a predictor carries no distributional assumption.
//   binary        PRESENCE AND ABSENCE. Affected or not, resistant or not. Exactly two levels,
//                 ordered [absent, present].
//   ordinal       groups whose ORDER means something and whose spacing does not.
//   nominal       groups with no order at all.
//
// The three categorical kinds are not cardinalities, they are claims about the scale, and each
// licenses something the others do not. An ordinal scale carries a trend; a nominal one carries
// only "these differ"; a binary one names a reference state, which is what makes a case/control
// design a case/control design rather than a comparison of two arbitrary groups.
//
// So two groups that are not an absence and a presence - coastal and inland, two host plants -
// are `nominal` with two levels, not `binary`. The published result says which was declared.
def measurementKinds() {
    return ['quantitative', 'binary', 'ordinal', 'nominal']
}

// The kinds whose levels are named, and how many each takes. Only `binary` is fixed, because only
// `binary` asserts a shape: one state is the absence of the other, and a third would leave neither
// meaning.
def measurementLevelRule() {
    return [ binary : [ least: 2, most: 2 ],
             ordinal: [ least: 2, most: 0 ],
             nominal: [ least: 2, most: 0 ] ]
}

// The phenotype settings, checked against each other and against the columns this target has.
// Returns true when there is a phenotype to resolve.
def checkPhenotypeSettings(Map settings, List columns) {
    def column = "${settings.column}".trim()
    def kind = "${settings.kind}".trim()
    def levels = settings.levels ?: []
    def available = columns.isEmpty() ? '(none)' : columns.join(', ')

    if (column.isEmpty()) {
        if (kind.isEmpty() && levels.isEmpty()) return false
        throw new IllegalArgumentException(
            "analysis.metadata.phenotype is set and names no column.\n" +
            "The phenotype columns this project has are: ${available}\n" +
            "Set analysis.metadata.phenotype.column to one of them, or remove the settings.")
    }
    // Anything outside the prefix escapes the pool-agreement refusal, and one pool could then
    // carry two phenotype values with nothing to stop it.
    if (!column.startsWith(phenotypePrefix())) {
        throw new IllegalArgumentException(
            "analysis.metadata.phenotype.column is '${column}', and a phenotype has to be a " +
            "${phenotypePrefix()} column.\n" +
            "Only those are checked for agreeing across the rows of one pool, which is what " +
            "stops a pool carrying two values at once.")
    }
    if (!columns.contains(column)) {
        throw new IllegalArgumentException(
            "analysis.metadata.phenotype.column is '${column}', and this project has no such " +
            "column.\nThe phenotype columns it has are: ${available}")
    }
    checkScaleDeclaration('analysis.metadata.phenotype', kind, levels)
    return true
}

// One declared scale, checked. Shared by the phenotype and by every covariate, so the four kinds
// mean the same thing wherever they are written.
def checkScaleDeclaration(String path, String kind, List levels) {
    if (kind.isEmpty()) {
        throw new IllegalArgumentException(
            "${path}.kind is not set.\n" +
            "It is not guessed: 0 and 1 read as numbers as readily as they encode two groups. " +
            "Set it to one of: ${measurementKinds().join(', ')}")
    }
    if (!measurementKinds().contains(kind)) {
        throw new IllegalArgumentException(
            "${path}.kind is '${kind}', which is not one of: ${measurementKinds().join(', ')}")
    }
    if (kind == 'quantitative') {
        if (!levels.isEmpty()) {
            throw new IllegalArgumentException(
                "${path}.levels is set and kind is 'quantitative'.\n" +
                "Levels name the groups of a categorical scale; a quantitative one is a " +
                "measurement and has no encoding to declare. Set kind to 'binary', 'ordinal' or " +
                "'nominal' if it has groups, or drop the levels.")
        }
        return
    }

    def rule = measurementLevelRule()[kind]
    if (levels.size() < rule.least || (rule.most > 0 && levels.size() > rule.most)) {
        def wanted = rule.most > 0 ? "exactly ${rule.least}" : "at least ${rule.least}"
        def why = kind == 'binary'
            ? "Binary is presence and absence, so it takes ${wanted}, ordered as [absent, present].\n" +
              "Which level is the presence decides the SIGN of every effect reported against it, " +
              "and nothing in the data says which you meant.\n" +
              "If neither of your two groups is the absence of the other, this is 'nominal'."
            : "A ${kind} scale names its groups, in the order you want them reported" +
              (kind == 'ordinal' ? " - which for an ordinal scale IS the scale." : ".")
        throw new IllegalArgumentException(
            "${path}.kind is '${kind}' and ${path}.levels " +
            "${levels.isEmpty() ? 'is not set' : "names ${levels.size()}"}.\n${why}")
    }
    if (levels.collect { level -> "${level}".toString() }.unique().size() != levels.size()) {
        throw new IllegalArgumentException(
            "${path}.levels repeats a level: [${levels.join(', ')}]\n" +
            "Each names one group, so a repeat would put a pool in two of them.")
    }
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def phenotypeRefusal(String column, String pool, String value, String why) {
    return new IllegalArgumentException(
        "the pool '${pool}' has ${column} = '${value}', which ${why}.\n" +
        "Every published analysis records the phenotype it was produced under, so a value the " +
        "declared kind cannot hold stops the run rather than being dropped quietly.")
}

// Each pool's phenotype under the declared kind. Three fields per pool, and the difference between
// them is the whole point:
//
//   shown   the cell as the file wrote it
//   group   which declared level it is, by index, or null for a quantitative scale
//   value   THE NUMBER A MODULE MAY FIT A SLOPE ON, or null when there is none
//
// `value` is null for a NOMINAL phenotype, and that is not an omission. Wing types spotted,
// striped and curly have an index each, and fitting a slope on that index asserts curly is twice
// as far from spotted as striped is. Null makes "you may not fit a rate on this" checkable by a
// module rather than remembered by its author - the same thing analysis.timeVar does with
// `position` for a categorical time axis.
//
// A blank cell is carried as null and named: recording the design is the frame's job and deciding
// a pool cannot be fitted is the module's.
// One column resolved against one declared scale, for every pool. Shared by the phenotype and by
// every declared covariate: the scales are the same four and reading them twice would let the two
// drift.
def resolveScale(List pools, String setting, String column, String kind, List levels) {
    return pools.collect { entry ->
        def raw = "${entry.values[column] ?: ''}".trim()
        def number = null
        def group = null
        if (!raw.isEmpty()) {
            if (kind == 'quantitative') {
                if (!(raw ==~ /-?\d+(\.\d+)?([eE][-+]?\d+)?/)) {
                    throw phenotypeRefusal(column, entry.pool, raw,
                        "is not a number, and ${setting}.kind is 'quantitative'")
                }
                number = raw.toDouble()
            }
            else {
                if (!levels.contains(raw)) {
                    throw phenotypeRefusal(column, entry.pool, raw,
                        "is not one of the declared levels [${levels.join(', ')}]")
                }
                group = levels.indexOf(raw)
                // Ordered scales carry a position; an unordered one does not, and must not be
                // handed an index that looks like one.
                number = kind == 'nominal' ? null : group as double
            }
        }
        return [ pool: entry.pool, shown: raw, group: group, value: number ]
    }
}

def resolvePhenotype(List pools, Map settings) {
    def column = "${settings.column}".trim()
    def kind = "${settings.kind}".trim()
    def levels = (settings.levels ?: []).collect { level -> "${level}".toString() }
    def warnings = []

    def values = resolveScale(pools, 'analysis.metadata.phenotype', column, kind, levels)

    // Missingness is the blank cell, not the null `value` - a nominal phenotype has a group for
    // every pool and no value for any of them.
    def missing = values.findAll { entry -> !entry.shown }
    if (!missing.isEmpty()) {
        warnings << [ code  : 'phenotype-missing',
                      detail: "${missing.size()} of ${values.size()} pools have no ${column} and " +
                              "cannot be fitted: " +
                              "${missing.collect { entry -> entry.pool }.join(', ')}" ]
    }

    if (kind != 'quantitative') {
        def unseen = levels.findAll { level -> !values.any { entry -> entry.shown == level } }
        if (!unseen.isEmpty()) {
            warnings << [ code  : 'phenotype-level-unused',
                          detail: "analysis.phenotype.levels names ${unseen.join(', ')}, which no " +
                                  "pool of this results directory has. Declared levels are kept " +
                                  "either way, so a group you have not sequenced yet is not an " +
                                  "error - but a misspelling looks exactly like one." ]
        }
        def counts = values.findAll { entry -> entry.shown }.groupBy { entry -> entry.shown }
        def alone = counts.findAll { _level, members -> members.size() == 1 }.keySet()
        if (!alone.isEmpty() && counts.size() > 1) {
            warnings << [ code  : 'phenotype-singleton-group',
                          detail: "${alone.join(', ')} ${alone.size() == 1 ? 'holds' : 'hold'} one " +
                                  "pool each, so ${alone.size() == 1 ? 'it contributes' : 'they contribute'} " +
                                  "no within-group variance. A comparison against a group of one " +
                                  "rests on that pool alone." ]
        }
    }

    // On `shown` and not on `value`: a nominal phenotype has a null value for every pool, so
    // comparing values would call every one of them constant.
    def held = values.findAll { entry -> entry.shown }
    if (held.size() > 1 && held.collect { entry -> entry.shown }.unique().size() == 1) {
        warnings << [ code  : 'phenotype-constant',
                      detail: "every pool has the same ${column} (${held[0].shown}), so there is " +
                              "no variation to associate anything with. A module that fits " +
                              "against it will refuse." ]
    }

    return [ column : column,
             kind   : kind,
             levels : kind == 'quantitative' ? null : levels,
             values : values,
             warnings: warnings ]
}

// The covariate declarations, checked against each other and against the columns this target has.
//
// analysis.metadata.covariates is a scope per column rather than a list, so a declaration reads
// the way every other scope in this file does and a repeated column is impossible by construction.
def checkCovariateSettings(Map declared, List columns) {
    declared.each { name, settings ->
        def column = "${name}".toString()
        def path = "analysis.metadata.covariates.${column}"
        if (!column.startsWith(covariatePrefix())) {
            throw new IllegalArgumentException(
                "${path} declares '${column}', and a covariate has to be a " +
                "${covariatePrefix()} column.\n" +
                "Only pool-level columns are checked for agreeing across the rows of one pool. " +
                "What differs BETWEEN two rows of a pool cannot be a covariate of it: the reads " +
                "are merged, so nothing downstream can attribute one to the row it came from.")
        }
        if (!columns.contains(column)) {
            throw new IllegalArgumentException(
                "${path} is declared, and this project has no such column.\n" +
                "The covariate columns it has are: " +
                "${columns.isEmpty() ? '(none)' : columns.join(', ')}")
        }
        if (!(settings instanceof Map)) {
            throw new IllegalArgumentException(
                "${path} is set to a single value, and a covariate is declared as a scope:\n" +
                "    ${column} {\n        kind = 'quantitative'\n    }")
        }
        def unknown = settings.keySet().collect { key -> "${key}".toString() }
                              .findAll { key -> !['kind', 'levels'].contains(key) }
        if (!unknown.isEmpty()) {
            throw new IllegalArgumentException(
                "${path} is given ${unknown.size() == 1 ? 'a setting' : 'settings'} it does not " +
                "have: ${unknown.join(', ')}\nIt has: kind, levels.")
        }
        checkScaleDeclaration(path, "${settings.kind ?: ''}".trim(), settings.levels ?: [])
    }
}

// Every declared covariate, resolved. An UNDECLARED cov_ column is not here and is not an error:
// it is recorded, checked and reported like any pool-level column, and simply carries no typed
// value for a module to compute with.
def resolveCovariates(List pools, Map declared, List columns) {
    def warnings = []
    def resolved = declared.collect { name, settings ->
        def column = "${name}".toString()
        def kind = "${settings.kind}".trim()
        def levels = (settings.levels ?: []).collect { level -> "${level}".toString() }
        def values = resolveScale(pools, "analysis.metadata.covariates.${column}",
                                  column, kind, levels)
        def missing = values.findAll { entry -> !entry.shown }
        if (!missing.isEmpty()) {
            warnings << [ code  : 'covariate-missing',
                          detail: "${missing.size()} of ${values.size()} pools have no ${column}: " +
                                  "${missing.collect { entry -> entry.pool }.join(', ')}" ]
        }
        def held = values.findAll { entry -> entry.shown }
        if (held.size() > 1 && held.collect { entry -> entry.shown }.unique().size() == 1) {
            warnings << [ code  : 'covariate-constant',
                          detail: "every pool has the same ${column} (${held[0].shown}), so it " +
                                  "separates nothing and can confound nothing." ]
        }
        return [ column: column,
                 kind  : kind,
                 levels: kind == 'quantitative' ? null : levels,
                 values: values ]
    }
    // A cov_ column nobody declared. Reported once, because the difference between "recorded for
    // the record" and "forgot to declare it" is not in the file.
    def undeclared = columns.findAll { column -> !declared.containsKey(column) }
    if (!undeclared.isEmpty()) {
        warnings << [ code  : 'covariate-undeclared',
                      detail: "${undeclared.join(', ')} " +
                              "${undeclared.size() == 1 ? 'is a covariate column' : 'are covariate columns'} " +
                              "this project records and does not declare, so no module can compute " +
                              "with ${undeclared.size() == 1 ? 'it' : 'them'}. Declare " +
                              "${undeclared.size() == 1 ? 'it' : 'them'} under " +
                              "analysis.metadata.covariates to give a scale, or leave as is to " +
                              "keep on the record only." ]
    }
    return [ covariates: resolved, warnings: warnings ]
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
    // A pool's values carry both prefixes; `variables` and the series key take only exp_. A
    // phenotype describes the pool and so belongs on it, but it is not a variable the experiment
    // set, and seriesKeyColumns() would make one that differs per pool split every series.
    def valueColumns = poolLevelColumns(rows)
    def byPool = rows.groupBy { row -> poolOf(row) }.sort { a, b -> a.key <=> b.key }
    def matchers = missingValueMatchers()
    def encoded = [:]

    // A cov_ column that differs between the rows of one pool has no single value, so the pool
    // gets none and what it held is recorded instead. checkTargetDesign() has already refused the
    // same state on an exp_ or pt_ column, where it is a contradiction rather than a circumstance.
    def varies = []

    def pools = byPool.collect { pool, poolRows ->
        [ pool     : pool,
          libraries: poolRows.collect { row -> "${row.SampleID}".toString() }.unique().sort(),
          values    : valueColumns.collectEntries { column ->
              def seen = poolRows.collect { row -> readCell(row[column], matchers) }.unique()
              def written = "${poolRows[0][column] ?: ''}".toString()
              if (seen.size() > 1) {
                  varies << [ pool: pool, column: column, seen: seen.sort() ]
                  return [ column, '' ]
              }
              def read = seen[0]
              if (!written.isEmpty() && read.isEmpty()) {
                  encoded.get(column, []) << "${pool} '${written}'".toString()
              }
              [ column, read ] } ]
    }

    def variables = columns.collect { column ->
        [ name  : column,
          levels: pools.collect { entry -> entry.values[column] }.unique().sort() ]
    }

    def settings = metadataSetting('timeVar')
    def warnings = []
    // What the declared encodings actually blanked. A pattern wider than the user meant would
    // otherwise remove values silently, and a design with fewer levels than the file has is not
    // an error anywhere downstream - it is just a smaller design.
    if (!encoded.isEmpty()) {
        def total = encoded.values().sum { held -> held.size() }
        warnings << [ code  : 'metadata-missing-encoded',
                      detail: "analysis.metadata.missingValueEncoding read ${total} " +
                              "${total == 1 ? 'cell' : 'cells'} as having no value:\n" +
                              encoded.collect { column, held ->
                                  "    ${column}: ${held.join(', ')}" }.join('\n') ]
    }
    if (!varies.isEmpty()) {
        warnings << [ code  : 'covariate-varies-within-pool',
                      detail: "${varies.size()} pool-and-covariate " +
                              "${varies.size() == 1 ? 'pair has' : 'pairs have'} more than one " +
                              "value, so ${varies.size() == 1 ? 'it has' : 'they have'} none for " +
                              "the pool as a whole:\n" +
                              varies.collect { entry ->
                                  "    ${entry.pool} ${entry.column}: " +
                                  "${entry.seen.collect { value -> value ?: '(blank)' }.join(', ')}"
                              }.join('\n') + "\n" +
                              "The value is recorded here and the pool carries none, so a module " +
                              "that needs this covariate treats that pool as having no value and " +
                              "says so. Nothing is averaged and nothing is chosen for you." ]
    }
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

        def seriesSettings = metadataSetting('series')
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

    def phenotypeSettings = metadataSetting('phenotype')
    def phenotype = null
    if (checkPhenotypeSettings(phenotypeSettings, phenotypeColumns(rows))) {
        phenotype = resolvePhenotype(pools, phenotypeSettings)
        warnings.addAll(phenotype.warnings)
    }

    def covariateNames = covariateColumns(rows)
    def declared = metadataSetting('covariates') ?: [:]
    checkCovariateSettings(declared, covariateNames)
    def covariates = []
    if (!covariateNames.isEmpty()) {
        def built = resolveCovariates(pools, declared, covariateNames)
        covariates = built.covariates
        warnings.addAll(built.warnings)
    }

    return [ variables : variables,
             pools     : pools,
             time      : time,
             seriesBy  : keyColumns,
             roles     : roles,
             series    : series,
             units     : units,
             conditions: conditions,
             phenotype : phenotype,
             covariates: covariates,
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

// The phenotype, and every pool's value as it resolved.
//
// The values are printed as WRITTEN beside what they became, which is the only thing that catches a
// reversed binary encoding: [control, case] and [case, control] are both legal, both silent, and
// give every slope the opposite sign. No check can tell which was meant.
def phenotypeReportLines(Map phenotype) {
    if (phenotype == null) return ['PHENOTYPE:             none - analysis.phenotype names no column']

    def head = "PHENOTYPE:             ${phenotype.column}, ${phenotype.kind}"
    if (phenotype.kind == 'binary') {
        head += ", '${phenotype.levels[0]}' absent and '${phenotype.levels[1]}' present"
    }
    else if (phenotype.kind == 'ordinal') {
        head += ", in this order: ${phenotype.levels.join(' < ')}"
    }
    else if (phenotype.kind == 'nominal') {
        head += ", unordered: ${phenotype.levels.join(', ')}"
    }
    def lines = [head.toString()]

    def held = phenotype.values.findAll { entry -> entry.shown }
    if (phenotype.kind == 'quantitative' && !held.isEmpty()) {
        def numbers = held.collect { entry -> entry.value }
        lines << ("PHENOTYPE:                 ${held.size()} pools, " +
                  "${numbers.min()} to ${numbers.max()}").toString()
    }
    // No slope may be fitted on an unordered scale, so the report says so rather than leaving a
    // column of nulls to be read as a failure.
    if (phenotype.kind == 'nominal') {
        lines << ("PHENOTYPE:                 ${held.size()} pools over " +
                  "${held.collect { entry -> entry.shown }.unique().size()} groups; " +
                  "unordered, so a module compares groups and fits no trend").toString()
    }
    phenotype.values.each { entry ->
        def became = !entry.shown ? '(no value)'
            : (entry.value == null ? "group ${entry.group}" : "${entry.value}")
        lines << "PHENOTYPE:                 ${entry.pool}  ${entry.shown ?: '(blank)'} -> ${became}".toString()
    }
    return lines
}

// The declared covariates, and every pool's value as it resolved.
//
// Printed for the same reason the phenotype is: what a covariate does to a result is confound it,
// and a reader who cannot see that the high-phenotype pools were also the warm ones has no way to
// suspect it. Nothing is adjusted for here - at six pools there are no degrees of freedom to
// spend on one - so the report IS the whole of what the frame does with them.
def covariateReportLines(List covariates) {
    if (covariates.isEmpty()) return []
    def lines = ["COVARIATES:            ${covariates.size()} declared".toString()]
    covariates.each { covariate ->
        def head = "COVARIATES:                ${covariate.column}, ${covariate.kind}"
        if (covariate.kind != 'quantitative') head += ": ${covariate.levels.join(', ')}"
        lines << head.toString()
        def held = covariate.values.findAll { entry -> entry.shown }
        if (covariate.kind == 'quantitative' && !held.isEmpty()) {
            def numbers = held.collect { entry -> entry.value }
            lines << "COVARIATES:                    ${held.size()} pools, ${numbers.min()} to ${numbers.max()}".toString()
        }
        else if (!held.isEmpty()) {
            def counts = held.groupBy { entry -> entry.shown }
                             .collect { level, members -> "${level} (${members.size()})" }
            lines << "COVARIATES:                    ${counts.join(', ')}".toString()
        }
    }
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
        lines.addAll(phenotypeReportLines(design.phenotype))
        lines.addAll(covariateReportLines(design.covariates ?: []))
        lines.addAll(designNoteLines(design))
    }
    return lines
}
