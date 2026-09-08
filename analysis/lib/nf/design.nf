// The experimental design a project records, and the one thing about it the frame refuses.
//
// An exp_ column is sample metadata: the pipeline records it and no step reads it. It describes
// the POOL, so every row of a pool has to give it one value. checkTargetDesign() enforces that at
// DAG-build, for every module.
//
// designSummary() emits the design as data. The frame prints a line of it in the verification
// report; a module writes it as JSON for its own R to read.

nextflow.enable.dsl=2

include { analysisSetting; metadataSetting; designSetting } from './paths.nf'
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
def phenotypePrefix() {
    return 'pt_'
}

// The prefix that marks a covariate measured on the pool - neither set nor the response: a cage
// temperature, an altitude, a collection site. Mirrored by COVARIATE_PREFIX in
// bin/parse_metadata.py.
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
// `?` is one, and everything else is literal. Matched whole and case sensitively, so a project
// that writes both NA and na lists both.
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

// The matchers this project declared, checked. An empty entry and one that matches every value
// are both refused.
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
// spelling to mean no value. Everything downstream treats empty as missing.
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
def checkTargetDesign(String label, List rows) {
    // exp_ and pt_ only. A cov_ column may differ between the rows of one pool; designSummary()
    // records that it did.
    def columns = experimentalColumns(rows) + phenotypeColumns(rows)
    if (columns.isEmpty()) return

    // Through readCell(), so a pool whose rows say 'NA' and nothing at all agree when the project
    // has declared 'NA' to mean no value.
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

// What a phenotype or a covariate can be declared as - a measurement SCALE, not a storage type,
// and never inferred:
//
//   quantitative  a number, counts and proportions included
//   binary        presence and absence. Exactly two levels, ordered [absent, present]
//   ordinal       groups whose ORDER means something and whose spacing does not
//   nominal       groups with no order at all
def measurementKinds() {
    return ['quantitative', 'binary', 'ordinal', 'nominal']
}

// The kinds whose levels are named, and how many each takes. `most: 0` is no upper bound.
def measurementLevelRule() {
    return [ binary : [ least: 2, most: 2 ],
             ordinal: [ least: 2, most: 0 ],
             nominal: [ least: 2, most: 0 ] ]
}

// The phenotype declarations, checked against each other and against the columns this target has.
// A project may declare every pt_ column it records; which of them a module tests against is that
// module's own setting.
def checkPhenotypeSettings(Map declared, List columns) {
    declared.each { name, settings ->
        def column = "${name}".toString()
        def path = "analysis.metadata.phenotypes.${column}"
        if (!column.startsWith(phenotypePrefix())) {
            throw new IllegalArgumentException(
                "${path} declares '${column}', and a phenotype has to be a " +
                "${phenotypePrefix()} column.\n" +
                "Only those are checked for agreeing across the rows of one pool, which is what " +
                "stops a pool carrying two values at once.")
        }
        if (!columns.contains(column)) {
            throw new IllegalArgumentException(
                "${path} is declared, and this project has no such column.\n" +
                "The phenotype columns it has are: " +
                "${columns.isEmpty() ? '(none)' : columns.join(', ')}")
        }
        if (!(settings instanceof Map)) {
            throw new IllegalArgumentException(
                "${path} is set to a single value, and a phenotype is declared as a scope:\n" +
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

// One column resolved against one declared scale, for every pool. Shared by the phenotype and by
// every declared covariate. Three fields per pool:
//
//   shown   the cell as the file wrote it, empty when blank
//   group   which declared level it is, by index, or null for a quantitative scale
//   value   the number a module may fit a slope on, or null when there is none
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

// Every declared phenotype, resolved. An UNDECLARED pt_ column is not here and is not an error:
// it is recorded, checked and reported like any pool-level column, and simply carries no typed
// value for a module to test against.
def resolvePhenotypes(List pools, Map declared, List columns) {
    def warnings = []
    def resolved = declared.collect { name, settings ->
        def column = "${name}".toString()
        def path = "analysis.metadata.phenotypes.${column}"
        def kind = "${settings.kind}".trim()
        def levels = (settings.levels ?: []).collect { level -> "${level}".toString() }

        def values = resolveScale(pools, path, column, kind, levels)

        // Missingness is the blank cell, not the null `value` - a nominal phenotype has a group
        // for every pool and no value for any of them.
        def missing = values.findAll { entry -> !entry.shown }
        if (!missing.isEmpty()) {
            warnings << [ code  : 'phenotype-missing',
                          detail: "${missing.size()} of ${values.size()} pools have no ${column} " +
                                  "and cannot be fitted against it: " +
                                  "${missing.collect { entry -> entry.pool }.join(', ')}" ]
        }

        if (kind != 'quantitative') {
            def unseen = levels.findAll { level -> !values.any { entry -> entry.shown == level } }
            if (!unseen.isEmpty()) {
                warnings << [ code  : 'phenotype-level-unused',
                              detail: "${path}.levels names ${unseen.join(', ')}, which no " +
                                      "pool of this results directory has. Declared levels are " +
                                      "kept either way, so a group you have not sequenced yet is " +
                                      "not an error - but a misspelling looks exactly like one." ]
            }
            def counts = values.findAll { entry -> entry.shown }.groupBy { entry -> entry.shown }
            def alone = counts.findAll { _level, members -> members.size() == 1 }.keySet()
            if (!alone.isEmpty() && counts.size() > 1) {
                warnings << [ code  : 'phenotype-singleton-group',
                              detail: "${column}: ${alone.join(', ')} " +
                                      "${alone.size() == 1 ? 'holds' : 'hold'} one pool each, so " +
                                      "${alone.size() == 1 ? 'it contributes' : 'they contribute'} " +
                                      "no within-group variance. A comparison against a group of " +
                                      "one rests on that pool alone." ]
            }
        }

        // On `shown` and not on `value`: a nominal phenotype has a null value for every pool, so
        // comparing values would call every one of them constant.
        def held = values.findAll { entry -> entry.shown }
        if (held.size() > 1 && held.collect { entry -> entry.shown }.unique().size() == 1) {
            warnings << [ code  : 'phenotype-constant',
                          detail: "every pool has the same ${column} (${held[0].shown}), so there " +
                                  "is no variation to associate anything with. A module that fits " +
                                  "against it will refuse." ]
        }

        return [ column: column,
                 kind  : kind,
                 levels: kind == 'quantitative' ? null : levels,
                 values: values ]
    }
    // A pt_ column nobody declared, reported once for all of them.
    def undeclared = columns.findAll { column -> !declared.containsKey(column) }
    if (!undeclared.isEmpty()) {
        warnings << [ code  : 'phenotype-undeclared',
                      detail: "${undeclared.join(', ')} " +
                              "${undeclared.size() == 1 ? 'is a phenotype column' : 'are phenotype columns'} " +
                              "this project records and does not declare, so no module can test " +
                              "against ${undeclared.size() == 1 ? 'it' : 'them'}. Declare " +
                              "${undeclared.size() == 1 ? 'it' : 'them'} under " +
                              "analysis.metadata.phenotypes to give a scale, or leave as is to " +
                              "keep on the record only." ]
    }
    return [ phenotypes: resolved, warnings: warnings ]
}

// The covariate declarations, checked against each other and against the columns this target has.
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

// Which of the recorded covariates are part of the design, and so are what a module adjusts for.
// Empty means every one that has a declared scale.
def designCovariates(Map declared, List columns, List chosen) {
    def declaredNames = declared.keySet().collect { name -> "${name}".toString() }
    if (chosen.isEmpty()) return declaredNames

    def named = chosen.collect { entry -> "${entry}".toString() }
    def path = 'analysis.design.covariates'
    named.each { column ->
        if (!column.startsWith(covariatePrefix())) {
            throw new IllegalArgumentException(
                "${path} names '${column}', and a covariate has to be a " +
                "${covariatePrefix()} column.\n" +
                "What the experiment SET is named in analysis.design.by; a covariate is " +
                "what was measured alongside and neither set nor tested against.")
        }
        if (!columns.contains(column)) {
            throw new IllegalArgumentException(
                "${path} names '${column}', and this project has no such column.\n" +
                "The covariate columns it has are: " +
                "${columns.isEmpty() ? '(none)' : columns.join(', ')}")
        }
        if (!declaredNames.contains(column)) {
            throw new IllegalArgumentException(
                "${path} names '${column}', which has no declared scale.\n" +
                "A column with no scale has no value a model can take. Give it one:\n" +
                "    analysis.metadata.covariates.${column} { kind = 'quantitative' }")
        }
    }
    return named
}

// Every declared covariate, resolved, each saying whether it is part of the design. An UNDECLARED
// cov_ column is not here and is not an error: it is recorded, checked and reported like any
// pool-level column, and simply carries no typed value for a module to compute with.
def resolveCovariates(List pools, Map declared, List columns, List inDesign) {
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
        return [ column  : column,
                 kind    : kind,
                 levels  : kind == 'quantitative' ? null : levels,
                 inDesign: inDesign.contains(column),
                 values  : values ]
    }
    // A covariate declared and left out of the design.
    def excluded = resolved.findAll { entry -> !entry.inDesign }.collect { entry -> entry.column }
    if (!excluded.isEmpty()) {
        warnings << [ code  : 'covariate-not-in-design',
                      detail: "analysis.design.covariates leaves ${excluded.join(', ')} " +
                              "out, so ${excluded.size() == 1 ? 'it is' : 'they are'} reported " +
                              "and no module adjusts for ${excluded.size() == 1 ? 'it' : 'them'}." ]
    }
    // A cov_ column nobody declared, reported once for all of them.
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

// The columns that identify one thing the experiment set up: analysis.design.by where it is set,
// every exp_ column but time otherwise. timeColumn is null for a project with no time axis, and
// then nothing is held back.
def designKeyColumns(List columns, String timeColumn, List by) {
    if (by.isEmpty()) return columns.findAll { column -> timeColumn == null || column != timeColumn }

    def named = by.collect { entry -> "${entry}".toString() }
    if (timeColumn != null && named.contains(timeColumn)) {
        throw new IllegalArgumentException(
            "analysis.design.by names ${timeColumn}, which is the time column.\n" +
            "A series is what stays the same WHILE time changes, so time cannot be part of what " +
            "identifies it.")
    }
    def unknown = named.findAll { column -> !columns.contains(column) }
    if (!unknown.isEmpty()) {
        throw new IllegalArgumentException(
            "analysis.design.by names ${unknown.join(', ')}, which this project's " +
            "metadata does not have.\n" +
            "The experimental variables it has are: ${columns.isEmpty() ? '(none)' : columns.join(', ')}")
    }
    return named
}

// Which of the key columns index repeats rather than naming a condition, checked. Returns the key
// columns split three ways: condition, biological, technical.
def replicateRoles(List keyColumns, String timeColumn, List biologicalRep, List technicalRep) {
    def biological = biologicalRep.collect { entry -> "${entry}".toString() }
    def technical = technicalRep.collect { entry -> "${entry}".toString() }

    [['biologicalRep', biological], ['technicalRep', technical]].each { pair ->
        def name = pair[0]
        pair[1].each { column ->
            if (timeColumn != null && column == timeColumn) {
                throw new IllegalArgumentException(
                    "analysis.design.${name} names ${timeColumn}, which is the time " +
                    "column. A replicate is what a series has instead of a condition, and time " +
                    "is neither.")
            }
            if (!keyColumns.contains(column)) {
                throw new IllegalArgumentException(
                    "analysis.design.${name} names '${column}', which is not one of the " +
                    "columns that identify the design.\n" +
                    "The columns that do are: ${keyColumns.isEmpty() ? '(none)' : keyColumns.join(', ')}\n" +
                    "Add it to analysis.design.by if it should, or correct the name.")
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

// The finest thing the design tells apart: a series where there is a time axis, a pool where there
// is not. Rolling up into units starts here.
//
// A pool is its own member: RG_Sample has already decided what was merged into one, so only a
// technicalRep column can put two of them back together.
def designMembers(List pools, List series, List keyColumns) {
    if (series != null) {
        return series.collect { entry -> [ label: entry.label, key: entry.key, pools: entry.pools ] }
    }
    return pools.collect { pool ->
        [ label: pool.pool,
          key  : keyColumns.collectEntries { column -> [ column, pool.values[column] ] },
          pools: [ pool.pool ] ] }
}

// Members rolled up into the independent biological units they came from. Two members are one unit
// when they agree on every condition and biological column AND a technical column tells them apart.
// Nothing else merges them.
//
// A group whose members all carry the same technical key is a group nothing tells apart, so each
// member stands alone - which is every untimed project with no technicalRep declared. A group that
// is partly one and partly the other cannot be partitioned either way, and refuses.
def unitsOf(List members, List unitColumns, List technical) {
    def grouped = [:]
    members.each { entry -> grouped.get(keyLabel(entry.key, unitColumns), []) << entry }

    def units = []
    grouped.each { label, held ->
        def apart = held.groupBy { entry -> keyLabel(entry.key, technical) }
        if (apart.size() > 1 && apart.size() < held.size()) {
            def sharing = apart.findAll { _key, entries -> entries.size() > 1 }
            throw new IllegalArgumentException(
                "'${label}' holds pools that ${technical.join(', ')} does not tell apart, beside " +
                "pools it does:\n" +
                sharing.collect { technicalKey, entries ->
                    "    ${technicalKey}: ${entries.collectMany { entry -> entry.pools }.join(', ')}"
                }.join('\n') + "\n" +
                "A unit is what a technical replicate column tells apart, so this group is partly " +
                "one unit and partly several and can be neither. Which these pools are decides " +
                "what to do:\n" +
                "  - separate biological material: give them an ${experimentalPrefix()} column that tells them\n" +
                "    apart, and name it in analysis.design.biologicalRep.\n" +
                "  - the same material sequenced separately: name the column that tells them apart\n" +
                "    in analysis.design.technicalRep.\n" +
                "  - one pool sequenced twice that you meant to merge: give the rows the same\n" +
                "    RG_Sample. The pipeline pools their reads and adds their depths, and they\n" +
                "    become one column of every published table.")
        }
        def key = unitColumns.collectEntries { column -> [ column, held[0].key[column] ] }
        // Sorted, so a unit's pools are a sub-sequence of design.pools and a module can index the
        // published columns with them. Only design.series orders pools by time.
        if (apart.size() == held.size()) {
            units << [ label  : label,
                       key    : key,
                       pools  : held.collectMany { entry -> entry.pools }.sort(),
                       members: held.collect { entry -> entry.label } ]
        }
        else {
            held.each { entry ->
                units << [ label: entry.label, key: key, pools: entry.pools, members: [entry.label] ]
            }
        }
    }
    return units.sort { a, b -> a.label <=> b.label }
}

// Units rolled up into the conditions they are repeats of, by dropping the biological columns too.
// Two units of one condition always merge: a condition is what they are repeats OF.
def conditionsOf(List units, List conditionColumns) {
    def grouped = [:]
    units.each { unit -> grouped.get(keyLabel(unit.key, conditionColumns), []) << unit }
    return grouped.keySet().sort().collect { label ->
        [ label: label,
          key  : conditionColumns.collectEntries { column -> [ column, grouped[label][0].key[column] ] },
          pools: grouped[label].collectMany { unit -> unit.pools }.sort(),
          units: grouped[label].collect { unit -> unit.label } ]
    }
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def keyLabel(Map values, List keyColumns) {
    if (keyColumns.isEmpty()) return 'all pools'
    return keyColumns.collect { column -> values[column] ?: '(blank)' }.join(' | ')
}

// The levels a set of indices names, for a message.
def levelNames(Map time, List indices) {
    return indices.sort().collect { index -> time.levels[index].value }.join(', ')
}

// analysis.design.series.incomplete, applied. Returns the timeline that survives and the series dropped.
//
// keepLeft and keepRight truncate the TIMELINE and not each series, so every series that survives
// covers the same points. None of the four fills a gap in.
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
            "analysis.design.series.incomplete:\n" +
            "    'drop'       leave the incomplete series out\n" +
            "    'keepLeft'   cut the timeline back to the points every series shares, from the start\n" +
            "    'keepRight'  the same, from the end")
    }

    if (mode == 'drop') {
        warnings << [ code  : 'series-dropped',
                      detail: "analysis.design.series.incomplete is 'drop', so ${ragged.size()} " +
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
            "analysis.design.series.incomplete is '${mode}', and there is nothing left to keep: " +
            "${without.size() == 1 ? 'the series' : 'the series'} " +
            "${without.take(5).join(', ')} ${without.size() == 1 ? 'does' : 'do'} not cover " +
            "'${time.levels[edge].value}', which is the ${mode == 'keepLeft' ? 'first' : 'last'} " +
            "point of the timeline.\n" +
            "Try '${mode == 'keepLeft' ? 'keepRight' : 'keepLeft'}' if the gap is at the other " +
            "end, or 'drop' to leave those series out.")
    }

    warnings << [ code  : "series-${mode}",
                  detail: "analysis.design.series.incomplete is '${mode}', so the timeline was cut from " +
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

// Every series in this target, ordered by time, after analysis.design.series.incomplete has been
// applied. The timeline is truncated and not each series, so what comes out is rectangular.
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
        def label = keyLabel(pool.values, keyColumns)
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
                    "    analysis.design.biologicalRep or technicalRep. They become separate series.\n" +
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
    // A pool's values carry all three prefixes; `variables` and the series key take only exp_.
    def valueColumns = poolLevelColumns(rows)
    def byPool = rows.groupBy { row -> poolOf(row) }.sort { a, b -> a.key <=> b.key }
    def matchers = missingValueMatchers()
    def encoded = [:]

    // A cov_ column that differs between the rows of one pool has no single value, so the pool
    // gets none and what it held is recorded instead. checkTargetDesign() has already refused the
    // same state on an exp_ or pt_ column.
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
    // What the declared encodings actually blanked.
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
    // The key columns and their roles, resolved for every project. timeColumn is null where the
    // project declared no time axis, and the time block below is then skipped.
    def timeColumn = checkTimeSettings(settings, columns) ? "${settings.column}".trim() : null
    def by = designSetting('by') ?: []
    def keyColumns = designKeyColumns(columns, timeColumn, by)
    if (by.isEmpty() && !keyColumns.isEmpty()) {
        warnings << [ code  : 'design-key-computed',
                      detail: "analysis.design.by is not set, so what identifies one " +
                              "thing set up is every ${experimentalPrefix()} variable " +
                              "${timeColumn == null ? 'there is' : 'but time'}: " +
                              "${keyColumns.join(', ')}. Set it if a variable here is recorded ON " +
                              "each pool rather than saying what the pool is." ]
    }
    def roles = replicateRoles(keyColumns, timeColumn,
                               designSetting('biologicalRep') ?: [], designSetting('technicalRep') ?: [])

    def time = null
    def series = null
    if (timeColumn != null) {
        def resolved = resolveTimeLevels(pools.collect { entry -> entry.values[timeColumn] }, settings)
        warnings.addAll(resolved.warnings)
        // format and locale travel with the levels, so a published folder says how the dates
        // were read.
        time = [ column: timeColumn,
                 kind  : "${settings.kind}".trim(),
                 unit  : resolved.unit,
                 format: "${settings.format}".trim() ?: null,
                 locale: "${settings.kind}".trim() == 'datetime' ? "${settings.locale}".trim() : null,
                 levels: resolved.levels ]

        def built = buildSeries(pools, time, keyColumns,
                                "${designSetting('series').incomplete}".trim(), warnings)
        series = built.series
        time.timeline = built.timeline

        def singletons = series.findAll { entry -> entry.pools.size() == 1 }
        if (!singletons.isEmpty() && series.size() > singletons.size()) {
            warnings << [ code  : 'series-singleton',
                          detail: "${singletons.size()} series hold one pool each and carry no " +
                                  "trajectory: ${singletons.collect { entry -> entry.label }.join(', ')}" ]
        }
    }

    def units = unitsOf(designMembers(pools, series, keyColumns),
                        roles.condition + roles.biological, roles.technical)
    def conditions = conditionsOf(units, roles.condition)

    def phenotypeNames = phenotypeColumns(rows)
    def declaredPhenotypes = metadataSetting('phenotypes') ?: [:]
    checkPhenotypeSettings(declaredPhenotypes, phenotypeNames)
    def phenotypes = []
    if (!phenotypeNames.isEmpty()) {
        def built = resolvePhenotypes(pools, declaredPhenotypes, phenotypeNames)
        phenotypes = built.phenotypes
        warnings.addAll(built.warnings)
    }

    def covariateNames = covariateColumns(rows)
    def declared = metadataSetting('covariates') ?: [:]
    checkCovariateSettings(declared, covariateNames)
    def inDesign = designCovariates(declared, covariateNames, designSetting('covariates') ?: [])
    def covariates = []
    if (!covariateNames.isEmpty()) {
        def built = resolveCovariates(pools, declared, covariateNames, inDesign)
        covariates = built.covariates
        warnings.addAll(built.warnings)
    }

    return [ variables : variables,
             pools     : pools,
             time      : time,
             keyColumns: keyColumns,
             roles     : roles,
             series    : series ?: [],
             units     : units,
             conditions: conditions,
             phenotypes: phenotypes,
             covariates: covariates,
             warnings  : warnings ]
}

// The design as JSON, for a module to hand to its own R.
def designJson(Map summary) {
    return groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(summary))
}

// How the time axis was read: one line where there is none, two where there is. The levels are
// printed in the order the analysis will use them, and as they resolved rather than as written.
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

// Every declared phenotype, with each pool's value as WRITTEN beside what it became.
def phenotypeReportLines(List phenotypes) {
    if (phenotypes.isEmpty()) {
        return ['PHENOTYPE:             none - analysis.metadata.phenotypes declares no column']
    }
    def lines = ["PHENOTYPE:             ${phenotypes.size()} declared".toString()]
    phenotypes.each { phenotype ->
        def head = "PHENOTYPE:                 ${phenotype.column}, ${phenotype.kind}"
        if (phenotype.kind == 'binary') {
            head += ", '${phenotype.levels[0]}' absent and '${phenotype.levels[1]}' present"
        }
        else if (phenotype.kind == 'ordinal') {
            head += ", in this order: ${phenotype.levels.join(' < ')}"
        }
        else if (phenotype.kind == 'nominal') {
            head += ", unordered: ${phenotype.levels.join(', ')}"
        }
        lines << head.toString()

        def held = phenotype.values.findAll { entry -> entry.shown }
        if (phenotype.kind == 'quantitative' && !held.isEmpty()) {
            def numbers = held.collect { entry -> entry.value }
            lines << ("PHENOTYPE:                     ${held.size()} pools, " +
                      "${numbers.min()} to ${numbers.max()}").toString()
        }
        // An unordered scale carries no number, so the line says so instead of giving a range.
        if (phenotype.kind == 'nominal') {
            lines << ("PHENOTYPE:                     ${held.size()} pools over " +
                      "${held.collect { entry -> entry.shown }.unique().size()} groups; " +
                      "unordered, so a module compares groups and fits no trend").toString()
        }
        phenotype.values.each { entry ->
            def became = !entry.shown ? '(no value)'
                : (entry.value == null ? "group ${entry.group}" : "${entry.value}")
            lines << "PHENOTYPE:                     ${entry.pool}  ${entry.shown ?: '(blank)'} -> ${became}".toString()
        }
    }
    return lines
}

// The declared covariates, and every pool's value as it resolved. Nothing is adjusted for here:
// the report is the whole of what the frame does with them.
def covariateReportLines(List covariates) {
    if (covariates.isEmpty()) return []
    def fitted = covariates.count { covariate -> covariate.inDesign }
    def lines = ["COVARIATES:            ${covariates.size()} declared, ${fitted} in the design".toString()]
    covariates.each { covariate ->
        def head = "COVARIATES:                ${covariate.column}, ${covariate.kind}"
        if (covariate.kind != 'quantitative') head += ": ${covariate.levels.join(', ')}"
        head += covariate.inDesign ? '  [in the design]' : '  [on the record only]'
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

// A count that varies across groups, as a range: the single number where it does not.
def spread(List counts) {
    if (counts.isEmpty()) return '0'
    def low = counts.min()
    def high = counts.max()
    return low == high ? "${low}".toString() : "${low}-${high}".toString()
}

// Which of the columns identifying the setup name a condition rather than a repeat, and what that
// leaves as an independent unit. Printed whether or not the project has a time axis, and every key
// column appears under exactly one role.
def replicationReportLines(Map design) {
    if (design.units.isEmpty()) return []
    def lines = []

    if (design.keyColumns.isEmpty()) {
        lines << "REPLICATION:           no ${experimentalPrefix()} columns, so every pool stands alone".toString()
    }
    else {
        lines << "REPLICATION:           conditions   ${design.roles.condition.isEmpty() ? '(none - one condition)' : design.roles.condition.join(', ')}".toString()
        lines << "REPLICATION:           biological   ${design.roles.biological.isEmpty() ? '(none declared)' : design.roles.biological.join(', ')}".toString()
        lines << "REPLICATION:           technical    ${design.roles.technical.isEmpty() ? '(none declared)' : design.roles.technical.join(', ')}".toString()
    }

    def perCondition = design.conditions.collect { entry -> entry.units.size() }
    def perUnit = design.units.collect { unit -> unit.members.size() }
    def poolCount = design.units.sum { unit -> unit.pools.size() }
    lines << "REPLICATION:               ${design.conditions.size()} condition${design.conditions.size() == 1 ? '' : 's'}, " +
             "${spread(perCondition)} biological replicate${perCondition.max() == 1 ? '' : 's'} each, " +
             "${spread(perUnit)} technical".toString()
    lines << "REPLICATION:               ${design.units.size()} independent unit${design.units.size() == 1 ? '' : 's'} " +
             "from ${poolCount} pool${poolCount == 1 ? '' : 's'}".toString()

    design.units.take(6).each { unit ->
        lines << "REPLICATION:                   ${unit.label}  (${unit.pools.size()})".toString()
    }
    if (design.units.size() > 6) {
        lines << "REPLICATION:                   ... and ${design.units.size() - 6} more".toString()
    }
    return lines
}

// The trajectories the time axis makes of those pools, and how much of the timeline each covers.
def seriesReportLines(Map design) {
    if (design.time == null) return []
    def points = design.time.timeline == null ? 0 : design.time.timeline.size()
    def lines = ["SERIES:                    ${design.series.size()} series over ${points} timepoint${points == 1 ? '' : 's'}".toString()]

    design.series.take(6).each { entry ->
        lines << "SERIES:                        ${entry.label}  (${entry.pools.size()})".toString()
    }
    if (design.series.size() > 6) {
        lines << "SERIES:                        ... and ${design.series.size() - 6} more".toString()
    }
    return lines
}

// What is worth knowing and is not an error. Rendered from design.warnings, which the published
// README renders too.
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
        lines.addAll(replicationReportLines(design))
        lines.addAll(seriesReportLines(design))
        lines.addAll(phenotypeReportLines(design.phenotypes ?: []))
        lines.addAll(covariateReportLines(design.covariates ?: []))
        lines.addAll(designNoteLines(design))
    }
    return lines
}
