// Time as a measurement scale: how the values of the time variable are ordered, and what
// arithmetic they support.
//
// Nothing here knows about pools or results directories. It takes a list of raw values and the
// project's timeVar settings, and returns one level per distinct value carrying an index, a
// position and any warnings. A categorical axis has no position at all, which is how a module
// tests whether a rate may be fitted against it.

nextflow.enable.dsl=2

def timeKinds() {
    return ['numerical', 'categorical', 'datetime']
}

// The units a numerical time axis may be measured in, grouped as they are documented. The split
// is java.time's own: Duration is exact through hour, Period is calendar from day up, and a
// calendar day is not 24 hours across a daylight-saving boundary.
def timeUnits() {
    return [ millisecond: 'exact',    second : 'exact',    minute: 'exact', hour : 'exact',
             day        : 'calendar', week   : 'calendar', month : 'calendar', year: 'calendar',
             generation : 'count',    passage: 'count',    cycle : 'count',
             step       : 'unnamed' ]
}

// A value with its digit runs zero-padded, so sorting by it compares numbers as numbers.
// 'T10' sorts after 'T2' under this and before it under a plain string comparison.
def naturalKey(String value) {
    def parts = []
    (value =~ /(\d+)|(\D+)/).each { match ->
        parts << (match[1] != null ? match[1].padLeft(20, '0') : match[2])
    }
    return parts.join('')
}

// A locale tag this JVM actually has. forLanguageTag() does not fall back to English for an
// unknown tag: it returns a locale with no month names, which then refuses every value with a
// message about the value rather than about the locale.
def timeLocale(String tag) {
    def wanted = tag.trim()
    def found = Locale.getAvailableLocales().find { candidate -> candidate.toLanguageTag() == wanted }
    if (found == null) {
        throw new IllegalArgumentException(
            "analysis.timeVar.locale is '${wanted}', which is not a locale this Java knows.\n" +
            "It decides what month and weekday names are read as - 'décembre' under fr, " +
            "'Aralık' under tr. Write a language tag such as en, fr, de, tr, ja, or en-GB.")
    }
    return found
}

// The formatter a datetime axis is parsed with.
//
// STRICT rather than SMART: SMART turns 2024-02-31 into 2024-02-29 without a word. Under STRICT
// `yyyy` cannot resolve - it is year-of-era and needs an era - so the pattern everyone writes is
// translated to the proleptic `uuuu`, which means the same thing for any date after year 1.
// Case-insensitive so that '12 JUN 26' reads as well as '12 Jun 26'.
def dateFormatter(String pattern, String locale) {
    def proleptic = pattern.replace('yyyy', 'uuuu').replace('yy', 'uu')
    try {
        return new java.time.format.DateTimeFormatterBuilder()
            .parseCaseInsensitive()
            .appendPattern(proleptic)
            .toFormatter(timeLocale(locale))
            .withResolverStyle(java.time.format.ResolverStyle.STRICT)
    }
    catch (IllegalArgumentException e) {
        throw new IllegalArgumentException(
            "analysis.timeVar.format is '${pattern}', which is not a date pattern: ${e.message}\n" +
            "Patterns are java.time's: uuuu or yyyy for the year, MM for the month as digits, " +
            "MMM for its short name, dd for the day, HH for a 24-hour clock, hh with a for a " +
            "12-hour one. The manual lists them all.")
    }
}

// One value as a date and time. A pattern carrying no time of day is read as midnight, which is
// what makes days-from-earliest exact for a date-only axis.
def parseTimeValue(String value, Object formatter, String pattern, String locale) {
    def parsed
    try {
        parsed = formatter.parse(value)
    }
    catch (Exception _e) {
        throw new IllegalArgumentException(
            "the time value '${value}' does not read as a date under " +
            "analysis.timeVar.format = '${pattern}' (locale ${locale}).\n" +
            "Every value of the time column has to parse, and this one is the first that does " +
            "not. Correct the value, or the pattern if it is the pattern that is wrong.")
    }
    def date
    try {
        date = java.time.LocalDate.from(parsed)
    }
    catch (Exception _e) {
        throw new IllegalArgumentException(
            "analysis.timeVar.format = '${pattern}' does not name a whole date, so '${value}' " +
            "cannot be placed on a timeline. A time of day alone has no order across days: give " +
            "the pattern a year, a month and a day.")
    }
    def clock = parsed.isSupported(java.time.temporal.ChronoField.SECOND_OF_DAY)
        ? java.time.LocalTime.from(parsed)
        : java.time.LocalTime.MIDNIGHT
    return java.time.LocalDateTime.of(date, clock)
}

// A plain function, not a local closure: the strict parser rejects calling one by name.
def duplicatePositionRefusal(String column, String rendered, List values) {
    return new IllegalArgumentException(
        "two values of ${column} mean the same point in time: ${values.collect { v -> "'${v}'" }.join(' and ')} " +
        "both resolve to ${rendered}.\n" +
        "Each level of the time axis has to be one point, so which of the two a pool belongs to " +
        "has no answer. Write them the same way in the metadata.")
}

// Every distinct value of the time column, ordered, with the position each sits at. Warnings are
// returned rather than printed: they reach the verification report and the published README from
// one list, and rendering them twice is how the two would drift.
def resolveTimeLevels(List values, Map settings) {
    def distinct = values.findAll { value -> value != null && !"${value}".trim().isEmpty() }
                         .collect { value -> "${value}".toString() }.unique()
    def kind = "${settings.kind}".trim()
    def warnings = []

    if (distinct.isEmpty()) return [ levels: [], warnings: warnings, unit: null ]

    def ordered
    def positions = [:]
    def rendered = [:]

    if (kind == 'numerical') {
        distinct.each { value ->
            if (!(value ==~ /-?\d+(\.\d+)?/)) {
                throw new IllegalArgumentException(
                    "the time value '${value}' is not a number, and analysis.timeVar.kind is " +
                    "'numerical'.\n" +
                    "Set kind to 'datetime' if these are dates, or 'categorical' if they are " +
                    "labels whose order you give with analysis.timeVar.order.")
            }
            positions[value] = value.toDouble()
            rendered[value] = "${positions[value]}".toString()
        }
        ordered = distinct.toSorted { a, b -> positions[a] <=> positions[b] }
    }
    else if (kind == 'datetime') {
        def formatter = dateFormatter("${settings.format}", "${settings.locale}")
        def parsed = [:]
        distinct.each { value ->
            parsed[value] = parseTimeValue(value, formatter, "${settings.format}", "${settings.locale}")
            rendered[value] = "${parsed[value]}".toString()
        }
        ordered = distinct.toSorted { a, b -> parsed[a] <=> parsed[b] }
        def earliest = parsed[ordered[0]]
        ordered.each { value ->
            positions[value] = java.time.Duration.between(earliest, parsed[value]).seconds / 86400.0d
        }
    }
    else {
        def given = (settings.order ?: []).collect { entry -> "${entry}".toString() }
        if (given.isEmpty()) {
            ordered = distinct.toSorted { a, b -> a <=> b }
            def natural = distinct.toSorted { a, b -> naturalKey(a) <=> naturalKey(b) }
            if (natural != ordered) {
                warnings << [ code  : 'time-order-alphabetical',
                              detail: "the time levels are in alphabetical order because " +
                                      "analysis.timeVar.order is not set, and reading their digits " +
                                      "as numbers would order them differently:\n" +
                                      "    alphabetical  ${ordered.join('  ')}\n" +
                                      "    by number     ${natural.join('  ')}\n" +
                                      "Set analysis.timeVar.order if the second is what you mean." ]
            }
        }
        else {
            def missing = distinct.findAll { value -> !given.contains(value) }
            if (!missing.isEmpty()) {
                throw new IllegalArgumentException(
                    "analysis.timeVar.order does not include ${missing.collect { m -> "'${m}'" }.join(', ')}, " +
                    "which the metadata uses.\n" +
                    "Every level has to be placed, and matching is exact - 'Pre' and 'pre' are " +
                    "different. The order given is: ${given.join(', ')}")
            }
            def unused = given.findAll { entry -> !distinct.contains(entry) }
            if (!unused.isEmpty()) {
                warnings << [ code  : 'time-order-unused',
                              detail: "analysis.timeVar.order names " +
                                      "${unused.collect { u -> "'${u}'" }.join(', ')}, which no pool " +
                                      "has. Ordinary while an experiment is still running; the " +
                                      "levels below are the ones that exist." ]
            }
            ordered = distinct.toSorted { a, b -> given.indexOf(a) <=> given.indexOf(b) }
        }
        ordered.each { value -> rendered[value] = value }
    }

    // Two spellings of one point leave no answer to which level a pool is on.
    rendered.groupBy { _value, text -> text }.each { text, entries ->
        if (entries.size() > 1) {
            throw duplicatePositionRefusal("${settings.column}", text, entries.keySet().toList().sort())
        }
    }

    def levels = ordered.withIndex().collect { value, index ->
        [ value   : value,
          index   : index,
          position: kind == 'categorical' ? null : positions[value],
          shown   : rendered[value] ]
    }
    return [ levels  : levels,
             warnings: warnings,
             unit    : kind == 'datetime' ? 'day' : (kind == 'numerical' ? "${settings.unit}".trim() : null) ]
}
