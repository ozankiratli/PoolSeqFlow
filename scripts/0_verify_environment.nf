include { derivedParameterNames } from './resolve_parameters.nf'
include { knownParameterNames } from './resolve_parameters.nf'
include { dig; deepCopyVariant; runToken } from './variants.nf'
include { sharingGroups; parentVariant; childVariants; variantForRun } from './variants.nf'

// Flatten the nested params map into dotted keys (dir.output.report.align and so on).
def flattenParams(Map m, String prefix, Map out) {
    m.each { k, v ->
        String key = prefix ? "${prefix}.${k}" : "${k}"
        if (v instanceof Map) flattenParams(v, key, out)
        else out[key] = v
    }
    return out
}

// The parameters that decide what the numbers are. Everything else - where files live,
// how many cores to use, where a tool is installed - can change freely between runs
// without invalidating an existing result.
//
// This is an exclusion list on purpose: a parameter added in a later release is treated
// as analysis-affecting until someone decides otherwise, which fails safe. Add new path
// or resource parameters here.
//
// Takes the run's own effective parameters rather than reading the global `params`. Called
// once per run, it would otherwise write N identical manifests describing the base config -
// so every run would record settings it did not use, and the guard would never fire.
//
// Returns the `key=value` lines rather than one joined string, because what is written to a
// directory is the intersection of its members' - see directoryManifest() below.
def analysisParams(Map p) {
    // dataSource is deliberately NOT excluded. It names the subdirectory the reads are read
    // from, so two different datasets under one storageDir are two different analyses - and
    // while it was excluded, both passed this check and the second run reused the first
    // dataset's trimmed reads, because step 2 keys its skip test on the sample id alone.
    // Nothing recorded which data produced a set of outputs.
    //
    // runId is excluded for the same reason mainDir and storageDir are: it names where the
    // results go, not what they are. It is also the one key here that does not exist in
    // parameters.config at all, so leaving it in would add a line to every manifest and fail
    // the change check on every project that upgrades into 3.0.
    def skipKey = [
        'mainDir', 'storageDir', 'runId',
        'referencePath', 'gffPath', 'rgTagsPath', 'multiRunPath', 'referenceFa', 'reference', 'gff', 'reads',
        'threads', 'memory'
    ] as Set
    def skipPrefix = ['dir.', 'cores.', 'java.', 'software.']
    return flattenParams(p, '', [:])
        .findAll { k, _v -> !skipKey.contains(k) && !skipPrefix.any { prefix -> k.startsWith(prefix) } }
        .collect { k, v -> "${k}=${v}".toString() }
        .sort()
}

// A DIRECTORY'S MANIFEST IS THE INTERSECTION OF ITS MEMBERS'.
//
// A manifest exists to answer "would this parameter invalidate what is already here", and once
// results are shared the thing that has parameters is a directory, not a run. The members of a
// group agree by construction on everything that decided that directory's contents - agreeing
// is what made them a group - so a parameter that affects the directory is necessarily in the
// intersection and cannot be missed. Parameters they differ on are, equally by construction,
// ones that did not affect it.
//
// ONE RULE, THREE CASES, TWO OF THEM UNCHANGED: for a directory with one member the
// intersection is that run's own manifest, which is exactly the file 9f4e647 wrote; for a
// single run, likewise. Only a shared directory is new.
//
// It needs no step map and does no filtering of its own. analysisParams() keeps answering "what
// invalidates a result" while stepParameterMap() keeps answering "what makes two results the
// same" - the two lists are allowed to disagree, and folding one into the other would lose the
// distinction they exist to preserve. The cost is that this can over-fire: a step-7 parameter
// every member happens to share appears in All_Runs' manifest even though nothing there was
// produced by step 7. That is no worse than 9f4e647, where any change failed the whole run.
def directoryManifest(List members) {
    def common = null
    members.each { run ->
        def lines = analysisParams(run)
        common = (common == null) ? lines : common.intersect(lines)
    }
    return (common == null ? [] : common).sort().join('\n')
}

// One manifest task per RESULTS DIRECTORY, which is what sharingGroups() enumerates.
//
// A run belongs to as many of these as it has divergence points - typically its own directory
// plus whatever it shares - and gets all of their verdicts in its report, because all of them
// describe results it depends on.
def manifestGroups(Map plan, List runDefs) {
    return sharingGroups(plan).collect { group ->
        def ordered = runDefs
            .findAll { run -> group.members.contains(run.runId) }
            .sort { a, b -> "${a.runId}" <=> "${b.runId}" }
        def lead = ordered[0]
        return [checkKey    : "${group.dir}".toString(),
                dir         : "${group.dir}".toString(),
                runId       : lead.runId,
                storageDir  : lead.storageDir,
                members     : ordered.collect { m -> m.runId },
                memberTokens: ordered.collect { m -> runToken(m.runId) },
                // The directory's own name in the trace: All_Runs, Shared_1, a RunID. A single
                // run has no name for anything (settled rule 3), so it keeps the bare tag.
                checkTag    : lead.runId == null ? '-' : "${group.dir}".toString().tokenize('/').last(),
                manifest    : directoryManifest(ordered)]
    }
}

// Turn a readPattern into a find(1) expression matching both mates.
//
// The mate group cannot become a bracket class: `{1,2}` -> `[1,2]` happens to work only
// because each alternative is one character. `{R1,R2}` -> `[R1,R2]` is a class matching a
// single character out of R, 1, ',' or 2, so it matches no real FASTQ at all - the check
// then finds nothing and passes vacuously while the run has no data. Expanding the group
// into one -name per alternative is exact for any length.
def findNameExpr(String pattern) {
    def open  = pattern.indexOf('{')
    def close = pattern.indexOf('}')
    if (open < 0 || close < open) {
        return "-name '${pattern}'"
    }
    def head = pattern.substring(0, open)
    def tail = pattern.substring(close + 1)
    def alts = pattern.substring(open + 1, close).split(',').collect { alt -> alt.trim() }
    return '\\( ' + alts.collect { alt -> "-name '${head}${alt}${tail}'" }.join(' -o ') + ' \\)'
}

// WHAT EACH CHECK READS, and therefore how many times it needs to run.
//
// Step 0 used to run every stage once per run, so three runs against one reference produced
// three CheckReference tasks and three identical reports for one file. Z, 2026-08-27: *"the
// pipeline first needs to parse out the multi-run csv, and decide on the shape of the pipeline.
// Then the checks should represent each step that is needed by the pipeline. Otherwise we are
// creating redundant and confusing log files for people to review and it will be harder to
// fix."* A check now runs once per distinct value of what it actually reads, and its verdict is
// handed back to every run that shares that value.
//
// AUTHORED, and carrying the same risk as stepParameterMap(): name too few parameters and one
// run's verdict is used for a run whose value differs - which is worse here than there, because
// catching exactly that is what the check is for. A case in test/suites/00_static.sh
// re-extracts each process body and fails if it reads anything its entry does not declare.
//
// The names are dotted paths into a RUN's own parameters, read with dig(). Never `params`,
// which is the base configuration rather than what any particular run is using.
def checkParameterMap() {
    return [
        // The user-placed files, one check per file however many runs name it. Deliberately not
        // step 1's dictionary key, which is a (reference, GFF) PAIR: what this stage asks is
        // whether one file is on disk, so one file is one check.
        CheckReference     : ['referencePath'],
        CheckGFF           : ['gffPath'],
        // SkipGFFCheck reads nothing - its report is two fixed lines - so one task serves every
        // run that does not annotate. An empty list is a statement, not an omission.
        SkipGFFCheck       : [],
        // dir.data is mainDir + dataSource; dataSource is named as well because the report
        // prints it, and a name that reaches the report is a name that decides the report.
        CheckData          : ['dir.data', 'dataSource', 'readPattern'],
        CheckTrimParameters: ['trim_galore.autodetect', 'trim_galore.adapter1',
                              'trim_galore.adapter2'],
        // Two of the four roots. The other two - the installation and the launch directory -
        // are properties of the invocation and cannot differ between runs.
        CheckDirectories   : ['mainDir', 'storageDir'],
    ]
}

// The key two runs must share to share a check.
//
// THE STORAGE ROOT IS PART OF EVERY KEY, for the reason variantKey() gives: a check writes a
// log, and two runs whose storageDir columns differ have no directory in common to put it in.
// Prefixing makes them simply never group, rather than needing a refusal or a special case.
def checkKey(Map run, String check) {
    def names = checkParameterMap()[check]
    if (names == null) {
        throw new IllegalArgumentException(
            "no entry for '${check}' in checkParameterMap() (scripts/0_verify_environment.nf). " +
            "Every step-0 stage that is keyed rather than per run needs one.")
    }
    def parts = ["store=${run.storageDir}".toString()] +
                names.collect { name -> "${name}=${dig(run, name)}".toString() }
    return parts.join(' | ').toString()
}

// The tasks a check will run: one per distinct key, each carrying the runs it answers for.
//
// The lead member is the lowest RunID rather than the first table row, exactly as variantsAt()
// picks one, so reordering the CSV cannot change which run's map a shared check carries. It is
// a deep copy for the same reason a variant is: the item gains its own bookkeeping and must not
// write it into a run map that the rest of the pipeline is still reading.
def checkGroups(List runDefs, String check) {
    def groups = [:]
    runDefs.each { run ->
        def key = checkKey(run, check)
        if (!groups.containsKey(key)) groups[key] = []
        groups[key] << run
    }
    return groups.collect { key, members ->
        def ordered = members.sort { a, b -> "${a.runId}" <=> "${b.runId}" }
        def item = deepCopyVariant(ordered[0])
        item.checkKey = key
        item.members = ordered.collect { m -> m.runId }
        item.checkTag = ordered.collect { m -> runToken(m.runId) }.join('+')
        return item
    }
}

// WHERE A STEP-0 STAGE WRITES ITS LOG, and why it is not a run's own Logs tree.
//
// A check keyed to what it validates can answer for two runs out of three, which belongs to
// neither of their trees - and step 0 runs before any run has results for a log to sit beside.
// So every stage here logs at invocation level, which is what the three stages that were
// already not per run - RepairRGTagsLineEndings, CheckInstalledSoftware, CheckMultiRun - have
// done since E1t. `All_Runs` means "the invocation" in this one place rather than "shared by
// every run"; the file name says which runs each task actually answered for.
//
// VerifyAll is the exception and stays in the run's own tree, because it really is per run.
def checkLogDir(Map check, String stage) {
    def root = params.multiRun ? "${check.storageDir}/Logs/All_Runs" : "${check.storageDir}/Logs"
    return "${root}/0_verify_environment/${stage}".toString()
}

// ONE WRITER PER FILE. Tasks append to their log without locking, which is safe only while no
// two of them share a file - and a keyed check runs N times into one directory. Naming the file
// after the runs it answered for makes collision impossible and says who it is about.
//
// RepairRGTagsLineEndings has had this wrong since E1t: two runs naming two different RGTags
// tables give two tasks, and both appended to one file.
//
// Single run: no synthetic key anywhere (settled rule 3), so the name is exactly what it was.
def checkLogFile(Map check, String stage) {
    def token = check.runId == null ? '' : "_${check.members.collect { m -> runToken(m) }.join('+')}"
    return "0_VerifyEnvironment_${stage}${token}_nextflow.log".toString()
}

// A check's verdict, handed back to every run it answers for.
//
// combine(by: 0) on the key rather than a join: what is matched is the same string computed by
// one function on both sides, and every run reaches exactly one task of every check that
// applies to it. A join would drop an unmatched key silently, which is the failure mode this
// whole design exists to avoid.
def reportPerRun(Object runs, Object reports, String check) {
    return runs
        .map { run -> tuple(checkKey(run, check), run) }
        .combine(reports.map { item, report -> tuple(item.checkKey, report) }, by: 0)
        .map { _key, run, report -> tuple(run, report) }
}

// The RGTags tables to repair: one task per distinct PATH, and deliberately NOT store-prefixed
// the way checkKey() is. The file lives in mainDir, which every run shares whatever its storage
// root, and the repair WRITES to it - so two tasks on one path would be a race on the user's
// own data. See RepairRGTagsLineEndings below.
//
// The log root is the invocation's own rather than the lead member's, for the same reason: the
// file being repaired belongs to no single run.
def rgTagsRepairs(List runDefs) {
    def groups = [:]
    runDefs.each { run ->
        def path = "${run.rgTagsPath}".toString()
        if (!groups.containsKey(path)) groups[path] = []
        groups[path] << run
    }
    return groups.collect { path, members ->
        def ordered = members.sort { a, b -> "${a.runId}" <=> "${b.runId}" }
        return [rgTagsPath: path,
                runId     : ordered[0].runId,
                storageDir: "${params.storageDir}".toString(),
                members   : ordered.collect { m -> m.runId }]
    }
}

// THE RGTAGS CHANGE GUARD IS KEYED TO THE STEP-6 VARIANT, and nothing coarser will do.
//
// What it asks is whether the table has been edited since the things that absorbed it were
// produced - the tag values, which step 4 bakes into each BAM, and the row order, which step 6
// turns into the VCF's sample column order. So its answer depends on the CONTENT of two
// directories, and two runs may share the table and still have different ones.
//
// Step 6's key is the finest of the two and contains step 4's, so runs that share it share both
// artifacts and therefore share one answer. Anything coarser lets a run with no BAMs decide for
// a run that has them - and the branch below treats "no BAMs and no VCF" as "nothing has
// consumed the table yet" and RECORDS A NEW BASELINE, so the edit would be adopted while the
// BAMs on disk still carried the old tags. Every other wrong existence answer in this pipeline
// costs redundant work; this one costs the guard itself.
//
// THE PROBE LOOKS IN FOUR PLACES, NOT TWO. Permanent storage as well as the working volume, and
// the producing VARIANT's directories rather than the member's own: since sharing was turned on
// the ready BAMs are promoted to (say) Output/All_Runs/Ready, which no member's own Output/
// contains - so a guard that looked only there answered 0 on every invocation after promotion
// and had already stopped guarding. Found while keying this stage; it is the reason it could
// not be left per run.
def rgTagsChecks(Map plan, List runDefs) {
    return plan.variants[6].collect { variant ->
        def members = runDefs
            .findAll { run -> variant.members.contains(run.runId) }
            .sort { a, b -> "${a.runId}" <=> "${b.runId}" }
        // The BAMs came from step 4, which is step 6's parent; the filtered VCFs and the
        // frequency tables are step 7's, which may be several branches below one call.
        def ready = parentVariant(plan, variant)
        def filtered = childVariants(plan, variant, 7)

        // What has to go for an edit to become the new baseline, in the order it is listed.
        // The row order lives only in the called VCF and everything derived from it; the tag
        // values live in the BAMs as well, which is why the two lists differ by one entry.
        def orderDelete = ([variant.dir.output.vcf] +
                           filtered.collect { child -> child.dir.output.vcf } +
                           filtered.collect { child -> child.dir.output.freq })
                          .collect { d -> d.toString() }.unique()

        return [checkKey    : variant.variantKey,
                runId       : variant.runId,
                storageDir  : variant.storageDir,
                members     : variant.members,
                checkTag    : variant.members.collect { m -> runToken(m) }.join('+'),
                // The key of the CheckData task whose verdict this stage reads. Every member
                // shares it: step 2's identity contains `reads`, which is dir.data plus
                // readPattern, and step 6's identity contains step 2's.
                dataKey     : checkKey(variant, 'CheckData'),
                rgTagsPath  : "${variant.rgTagsPath}".toString(),
                // Two runs may name two different files with identical contents - the identity
                // is the normalised rows, not the path - so every distinct one is repaired, and
                // every repair report is folded in below.
                rgTagsPaths : members.collect { m -> "${m.rgTagsPath}".toString() }.unique(),
                dataDir     : "${variant.dir.data}".toString(),
                readPattern : "${variant.readPattern}".toString(),
                samtools    : "${variant.software.samtools}".toString(),
                storedRg    : "${variant.dir.outputs}/.poolseqflow_rgtags".toString(),
                readyOut    : "${ready.dir.output.ready}".toString(),
                readyWork   : "${ready.dir.utilized}/${ready.dir.subpath.ready}".toString(),
                vcfOut      : "${variant.dir.output.vcf}".toString(),
                vcfWork     : "${variant.dir.utilized}/${variant.dir.subpath.vcf}".toString(),
                orderDelete : orderDelete,
                tagDelete   : (["${ready.dir.output.ready}".toString()] + orderDelete).unique()]
    }
}

process CheckReference {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage1.txt'), emit: report

    script:
    refIn = check.referencePath
    dir_log = checkLogDir(check, 's1_CheckReference')
    log_file = checkLogFile(check, 's1_CheckReference')
    """
    REFFILE=${refIn}
    REPORTFILE="verify_environment.txt"

    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    if [ ! -f \$REFFILE ]; then
        log_message "REFERENCE FILE CHECK:  Reference file [ \$REFFILE ] not found! Check PARAMETERS file"
        STATUS="FAIL"
    else
        log_message "REFERENCE FILE CHECK:  Reference file is found at: \$REFFILE"
        STATUS="PASS"
    fi
    log_message "REFERENCE FILE CHECK:  STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage1.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

process CheckGFF {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage2.txt'), emit: report

    script:
    gffIn = check.gffPath
    dir_log = checkLogDir(check, 's2_CheckGFF')
    log_file = checkLogFile(check, 's2_CheckGFF')

    """
    GFFFILE=${gffIn}
    REPORTFILE="verify_environment.txt"

    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    if [ ! -f \$GFFFILE ]; then
        log_message "GFF FILE CHECK:        GFF file [ \$GFFFILE ] not found! Check PARAMETERS file"
        STATUS="FAIL"
    else
        log_message "GFF FILE CHECK:        GFF file is found at: \$GFFFILE"
        STATUS="PASS"
    fi
    log_message "GFF FILE CHECK:        STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage2.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

process SkipGFFCheck {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage2.txt'), emit: report

    script:
    dir_log = checkLogDir(check, 's2_CheckGFF')
    log_file = checkLogFile(check, 's2_SkipGFFCheck')
    """
    REPORTFILE="verify_environment.txt"
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }
    log_message "GFF FILE CHECK:        Annotation disabled!"
    log_message "GFF FILE CHECK:        STATUS=SKIPPED"
    mv \$REPORTFILE verify_environment_stage2.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

process CheckData {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage3.txt'), emit: report

    script:
    dataDir = check.dir.data
    dir_log = checkLogDir(check, 's3_CheckData')
    log_file = checkLogFile(check, 's3_CheckData')
    read_pattern = findNameExpr("${check.readPattern}")

    """
    DATADIR=${dataDir}
    REPORTFILE="verify_environment.txt"

    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    # Check if directory exists
    if [ ! -d \$DATADIR ]; then
        log_message "Data directory [ \$DATADIR ] does not exist! Check parameters.config file"
        log_message "DATA FOLDER CHECK:     FAIL"
        STATUS="FAIL"
    else
        log_message "Data directory is found at: \$DATADIR"
        log_message "DATA FOLDER CHECK:     PASS"

        log_message "The data source is set to: ${check.dataSource}"

        # Check for FASTQ files
        FASTQ_COUNT=\$(find \$DATADIR ${read_pattern} | wc -l)
        if [ \$FASTQ_COUNT -eq 0 ]; then
            log_message "No FASTQ files found in data directory!"
            log_message "Expected pattern: ${check.readPattern}"
            log_message "DATA FILES CHECK:      FAIL"
            STATUS="FAIL"
        else
            log_message "Found \$FASTQ_COUNT FASTQ files"
            # Check if we have pairs
            if [ \$((\$FASTQ_COUNT % 2)) -eq 0 ]; then
                log_message "All FASTQ files are properly paired"
                log_message "DATA FILES CHECK:      PASS"
                STATUS="PASS"
            else
                log_message "Unpaired FASTQ files detected!"
                log_message "DATA FILES CHECK:      FAIL"
                STATUS="FAIL"
            fi
        fi
    fi
    log_message "DATA SOURCE CHECK:     STATUS=\$STATUS"
    mv \$REPORTFILE verify_environment_stage3.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

// Repair Windows line endings in the RGTags file - the one thing step 0 CHANGES rather than
// checks, and therefore the one thing that cannot be done once per run.
//
// A file saved from Excel on Windows ends every line with CR, which rides along into the last
// field of each row: the header check in CheckRGTagsFile rejects 'PU\r' as an invalid tag,
// and were it to get past that, the CR would end up inside the RG tag written into the BAM.
// Neither failure names the real cause, so it is fixed here and said out loud.
//
// KEYED ON THE PATH, NOT THE RUN. rgTagsFile is a parameter like any other, so a multi-run
// table may point two runs at two different tables - or, far more usually, at the same one.
// N runs repairing one file at the same time is a race on a user's own data, and the write is
// `cat tmp > file` rather than an atomic rename, so a loser leaves it truncated. One task per
// distinct path is both correct cases at once: shared file, one repair; separate files, one
// each.
//
// It reports rather than fixing silently, and its report is folded into stage 4 below so the
// output reads exactly as it did when the repair lived there.
process RepairRGTagsLineEndings {
    tag { repair.rgTagsPath }

    input:
    val repair

    output:
    tuple val(repair), path('rgtags_lineendings.txt'), emit: report

    script:
    rgTagsPath = repair.rgTagsPath
    dir_log = checkLogDir(repair, 's4_RepairRGTagsLineEndings')
    log_file = checkLogFile(repair, 's4_RepairRGTagsLineEndings')
    """
    REPORTFILE="rgtags_lineendings.txt"
    : > \$REPORTFILE

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    # A missing or unreadable file is stage 4's business, not this one's: it has the message
    # for it, and reporting the same thing twice would put it in the report twice.
    if [ ! -f "${rgTagsPath}" ]; then
        exit 0
    fi

    # Detection and repair use the same expression, so a file that is reported as fixed really
    # is fixed - a mismatch between the two would report it on every run.
    if ! sed 's/\\r\$//' ${rgTagsPath} | cmp -s - ${rgTagsPath}; then
        # Rewrite the file's contents rather than replacing the file. 'sed -i' swaps in a new
        # inode and does not carry the mode across - it turned a 444 file into a 644 one in
        # testing, quietly making a deliberately read-only RGTags file writable. Redirecting
        # into the existing path keeps mode and ownership, and fails honestly when the file
        # really is not writable.
        if sed 's/\\r\$//' ${rgTagsPath} > rgtags_norm.tmp && [ -s rgtags_norm.tmp ] &&
           cat rgtags_norm.tmp > ${rgTagsPath} 2>/dev/null; then
            log_message "RGTags file had Windows (CRLF) line endings - repaired in place"
            log_message "RGTAGS LINE ENDING CHECK: FIXED"
        else
            log_message "RGTags file has Windows (CRLF) line endings and could not be rewritten"
            log_message "Convert it yourself with:"
            log_message "    sed -i 's/\\\\r\$//' ${rgTagsPath}"
            log_message "RGTAGS LINE ENDING CHECK: FAIL"
        fi
    else
        log_message "RGTAGS LINE ENDING CHECK: PASS"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

process CheckRGTagsFile {
    tag { check.checkTag }

    input:
    // `lineendings` is every repair report for the tables this group's members named - usually
    // one, matched on the path rather than on arrival.
    tuple val(check), val(verify), val(lineendings)

    output:
    tuple val(check), path('verify_environment_stage4.txt'), emit: report

    script:
    rgTagsFile = check.rgTagsPath
    dataDir = check.dataDir
    readPattern = findNameExpr(check.readPattern)
    // Sorted rather than taken in arrival order: with more than one table the reports are
    // concatenated into the stage's output, and a report whose lines move between invocations
    // reads as a change that did not happen.
    lineendingFiles = lineendings.collect { f -> "${f}".toString() }.sort().join(' ')
    // A sample ID is the part of a FASTQ name that precedes the mate token. Take that
    // token from readPattern rather than assuming _R1/_R2: step 2 keys every sample off
    // Channel.fromFilePairs, which derives the prefix from the glob and accepts any
    // {1,2} scheme, so this check has to agree with it or it rejects valid layouts.
    mateBrace = check.readPattern.indexOf('{')
    mateClose = check.readPattern.indexOf('}')
    hasMateGroup = mateBrace >= 0 && mateClose > mateBrace
    matePrefix = hasMateGroup ? check.readPattern.substring(0, mateBrace).replaceAll(/^.*\*/, '') : ''
    mateTail = hasMateGroup ? check.readPattern.substring(mateClose + 1) : ''
    mateAlts = hasMateGroup ? check.readPattern.substring(mateBrace + 1, mateClose).split(',').collect { alt -> alt.trim() } : []

    // The mate token must be separated from the sample name. Without a separator the
    // split is guesswork: Sample11/Sample12 are equally readable as one sample's two
    // mates or as two different samples, so refuse rather than pick one.
    mateSeparators = ['_', '.', '-']
    mateSeparated = hasMateGroup && mateAlts.every { alt ->
        mateSeparators.any { sep -> (matePrefix + alt).startsWith(sep) }
    }

    // Strip the exact text the pattern says follows the sample name, one alternative at
    // a time. Literal, so it holds for non-numeric mates (_F/_R) too.
    stripMate = mateAlts.collect { alt -> 'base="${base%' + matePrefix + alt + mateTail + '}"' }.join('; ')
    // Beside the results it describes: the baseline belongs in the directory holding the VCF
    // whose column order it decided, which for a shared step is the group's rather than any one
    // member's. Moving an existing project's baseline here is config_migrate.sh's job.
    storedRg = check.storedRg
    // FOUR ROOTS, NOT TWO, and all of them the producing variant's - see rgTagsChecks() for why
    // each half of that matters. Permanent storage and the working volume both, because the
    // branch below reads "no BAMs and no VCF" as "nothing has consumed the table yet" and
    // records a new baseline; and the variant's directories rather than a member's, because a
    // shared artifact is promoted to the group's directory and appears in no member's own.
    readyDirOut = check.readyOut
    readyDirWork = check.readyWork
    vcfDirOut = check.vcfOut
    vcfDirWork = check.vcfWork
    // What has to be deleted for an edit to take effect, rendered as log_message calls because
    // there may be several: one call per step-7 branch below this VCF.
    readyDir = check.readyOut
    tagDeleteBlock = check.tagDelete.collect { d -> "        log_message \"    ${d}\"" }.join('\n')
    orderDeleteBlock = check.orderDelete.collect { d -> "                log_message \"    ${d}\"" }.join('\n')
    dir_log = checkLogDir(check, 's4_CheckRGTagsFile')
    // The file has always been named for the stage rather than for the process; kept, so that a
    // single run's log tree is the same tree it was.
    log_file = checkLogFile(check, 's4_CheckRGTags')

    """
    REPORTFILE="verify_environment.txt"
    STATUS="PASS"
    
    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    # Define allowed tags array
    allowed_tags=("ID" "PL" "PU" "LB" "SM" "CN" "DS" "DT" "FO")

    # Check previous verification
    if [ ! -f ${verify} ]; then
        log_message "Verify file not found: ${verify}"
        STATUS="FAIL"
    elif grep -q "FAIL" ${verify}; then
        log_message "Previous step failed"
        STATUS="FAIL"
    elif [ ! -f "${rgTagsFile}" ]; then
        log_message "RG tags file ${rgTagsFile} not found"
        log_message "RGTAGS FILE CHECK:     FAIL"
        STATUS="FAIL"
    else
        log_message "RGTags file exists: ${rgTagsFile}"
        log_message "RGTAGS FILE CHECK:     PASS"

        # The line-ending repair itself has been hoisted into RepairRGTagsLineEndings above,
        # because it WRITES to a file that several runs share. What arrives here is its
        # report, folded in at the point the messages used to be produced so that the stage
        # reads exactly as it did before, and re-read for FAIL so that an unrepairable file
        # still fails the stage that owns the RGTags verdict.
        cat ${lineendingFiles} | tee -a \$REPORTFILE
        if grep -q "RGTAGS LINE ENDING CHECK: FAIL" ${lineendingFiles}; then
            STATUS="FAIL"
        fi

        # Get header and validate format
        header=\$(head -n 1 ${rgTagsFile})
        IFS=',' read -ra HEADER <<< "\$header"

        # Check for invalid tags
        for tag in "\${HEADER[@]}"; do
            valid=0
            for allowed in "\${allowed_tags[@]}"; do
                if [ "\$tag" = "\$allowed" ]; then
                    valid=1
                    break
                fi
            done
            if [ \$valid -eq 0 ]; then
                log_message "Invalid tag '\$tag' found in header"
                log_message "RGTAGS VALID TAGS CHECK: FAIL" 
                STATUS="FAIL"
            fi
        done

        # Find ID column position
        id_col=\$(echo "\$header" | tr ',' '\\n' | grep -n "^ID\$" | cut -d: -f1)
        if [ -z "\$id_col" ]; then
            log_message "No ID column found in ${rgTagsFile}"
            log_message "RGTAGS ID COLUMN CHECK: FAIL"
            STATUS="FAIL"
        else
            log_message "ID column found at position \$id_col"
            log_message "RGTAGS ID COLUMN CHECK: PASS"

            # Every ID must be unique. Step 4 looks its row up by ID and reads only the
            # first line of the result, so a repeated ID means the later rows are dropped
            # without a word and the sample silently takes the first row's tags. Nothing
            # downstream can detect that, because the resulting BAM is perfectly valid.
            dup_ids=\$(awk -F',' -v col=\$id_col '
                NR > 1 && \$col != "" { seen[\$col]++ }
                END { for (id in seen) if (seen[id] > 1) printf "  %s (%d rows)\\n", id, seen[id] }
            ' ${rgTagsFile} | sort)
            if [ -n "\$dup_ids" ]; then
                log_message "Duplicate ID values in ${rgTagsFile}:"
                echo "\$dup_ids" | tee -a \$REPORTFILE
                log_message "Each ID must appear once. Only the first row of a repeated ID is"
                log_message "used, so the rest would be discarded without any error."
                log_message "RGTAGS UNIQUE ID CHECK: FAIL"
                STATUS="FAIL"
            else
                log_message "RGTAGS UNIQUE ID CHECK: PASS"
            fi

            # Get sample IDs from data directory
            if [ "${hasMateGroup}" != "true" ]; then
                sample_ids=""
                log_message "readPattern '${check.readPattern}' has no {1,2} mate group, so sample IDs cannot be derived"
                log_message "Give both mates in one pattern, e.g. '*_R{1,2}.fq.gz'"
                log_message "RGTAGS SAMPLE MATCH CHECK: FAIL"
                STATUS="FAIL"
            elif [ "${mateSeparated}" != "true" ]; then
                sample_ids=""
                log_message "readPattern '${check.readPattern}' runs the mate token straight onto the sample name"
                log_message "Sample IDs would be ambiguous: 'Sample11' and 'Sample12' read equally well as"
                log_message "one sample's two mates or as two separate samples."
                log_message "Separate the mate token with '_', '.' or '-', e.g. '*_R{1,2}.fq.gz' or '*_{1,2}.fq.gz'"
                log_message "RGTAGS SAMPLE MATCH CHECK: FAIL"
                STATUS="FAIL"
            else
                sample_ids=\$(find ${dataDir} ${readPattern} | while read -r fq; do
                    base=\$(basename "\$fq")
                    ${stripMate}
                    echo "\$base"
                done | sort -u)
            fi

            # Every row must carry as many columns as the header. The empty-value loop
            # below bounds on NF, which is the row's own field count, so a short row
            # passes it and then loses that tag silently in step 4. A missing middle
            # column is worse: every later value shifts one tag left, so the wrong tags
            # are written rather than merely absent ones.
            column_report=\$(awk -F',' '
            NR == 1 { ncol = NF; next }
            NF == 0 { next }
            NF != ncol {
                printf "Row %d has %d column(s), the header has %d\\n", NR, NF, ncol
                exit 1
            }' ${rgTagsFile}) || {
                log_message "\$column_report"
                log_message "Every row needs one value per header column, in the same order."
                log_message "RGTAGS COLUMN COUNT CHECK: FAIL"
                STATUS="FAIL"
            }

            # Check all rows for empty values
            empty_report=\$(awk -F',' '
            NR == 1 { for (i=1; i<=NF; i++) header[i] = \$i; next }
            {
                for (i=1; i<=NF; i++) {
                    if (length(\$i) == 0 || \$i ~ /^[[:space:]]*\$/) {
                        printf "Empty value found in row %d, column %d (%s)\\n", NR, i, header[i]
                        exit 1
                    }
                }
            }' ${rgTagsFile}) || {
                log_message "\$empty_report"
                log_message "RGTAGS EMPTY VALUES CHECK: FAIL"
                STATUS="FAIL"
            }

            # Check if all samples have RG tags
            for sample in \$sample_ids; do
                sample_in_rg=\$(awk -F',' -v col=\$id_col -v sample=\$sample '\$col == sample {print "1"}' ${rgTagsFile})
                if [ -z "\$sample_in_rg" ]; then
                    log_message "Sample '\$sample' not found in RG tags file"
                    log_message "RGTAGS SAMPLE MATCH CHECK: FAIL"
                    STATUS="FAIL"
                fi
            done
        fi

        # Detect edits made after the file was already consumed. Step 4 bakes the tags
        # into each BAM with 'samtools addreplacerg', and the row order sets the sample
        # column order of the VCF in step 6. Neither is re-derived once its output
        # exists, so an edit after that point leaves the results describing a version of
        # this file that is no longer on disk - silently, because completed steps are
        # skipped by looking for output files rather than by checking what produced them.
        #
        # Normalise line endings and trailing blanks before comparing, but never the row
        # order: that is significant now, and sorting it away would hide a real change.
        sed -e 's/\\r\$//' -e 's/[[:space:]]*\$//' -e '/^\$/d' ${rgTagsFile} > current_rgtags.csv

        # The two things that consume this file have different lifetimes, so ask about
        # each separately. The tag values live in the cleaned BAMs; the row order lives in
        # the VCF and nowhere else. A change only matters while the thing that absorbed it
        # is still on disk - which is what makes the recovery below terminate: delete that
        # output and the same edit stops being a change and becomes the new baseline.
        # Test each candidate separately: 'ls a b' reports failure when either operand is
        # missing, so a single ls over two globs would call an existing VCF absent.
        any_exists() {
            for f in "\$@"; do
                [ -e "\$f" ] && return 0
            done
            return 1
        }
        HAVE_BAMS=0; any_exists ${readyDirOut}/*_ready.bam ${readyDirWork}/*_ready.bam && HAVE_BAMS=1
        HAVE_VCF=0;  any_exists ${vcfDirOut}/*.vcf ${vcfDirOut}/*.vcf.gz \\
                                ${vcfDirWork}/*.vcf ${vcfDirWork}/*.vcf.gz && HAVE_VCF=1

        record_baseline() {
            mkdir -p "\$(dirname "${storedRg}")"
            cp current_rgtags.csv "${storedRg}"
        }

        if [ "\$HAVE_BAMS" -eq 0 ] && [ "\$HAVE_VCF" -eq 0 ]; then
            # Nothing has consumed the file yet, so an edit costs nothing. Record it.
            record_baseline
            log_message "RGTags baseline recorded - nothing has consumed the file yet"
            log_message "RGTAGS CHANGE CHECK:   PASS"
        elif [ ! -f "${storedRg}" ]; then
            # Outputs from before this check existed. There is no baseline to compare
            # against and no way to reconstruct one, so adopt the current file and say so.
            cp current_rgtags.csv "${storedRg}"
            log_message "Cleaned BAMs exist but predate this check - no baseline to compare"
            log_message "Adopting the current RGTags file as the baseline"
            log_message "Verify it still matches what is in the BAMs:"
            log_message "    ${check.samtools} view -H ${readyDir}/<sample>_ready.bam | grep '^@RG'"
            log_message "RGTAGS CHANGE CHECK:   PASS"
        elif diff -q "${storedRg}" current_rgtags.csv > /dev/null 2>&1; then
            log_message "RGTags file unchanged since the existing outputs were produced"
            log_message "RGTAGS CHANGE CHECK:   PASS"
        elif [ "\$(sort "${storedRg}")" = "\$(sort current_rgtags.csv)" ]; then
            # Same rows, different order. The tags in the BAMs are matched by ID rather
            # than by position, so they are untouched; only the VCF column order is wrong.
            if [ "\$HAVE_VCF" -eq 0 ]; then
                record_baseline
                log_message "RGTags row order changed, but no VCF exists to have used it"
                log_message "RGTAGS CHANGE CHECK:   PASS"
            else
                # Report this as two orderings - a line diff of a permutation shows the
                # same text as both removed and added, which reads as nonsense.
                id_list() { awk -F',' -v c="\$id_col" 'NR>1 { printf "%s%s", sep, \$c; sep=", " }' "\$1"; }
                log_message "RGTags row order has CHANGED since the existing outputs were produced:"
                log_message ""
                log_message "  was  \$(id_list "${storedRg}")"
                log_message "  now  \$(id_list current_rgtags.csv)"
                log_message ""
                log_message "The tags in the BAMs are matched by ID and are still correct, but"
                log_message "the VCF sample column order is not."
                log_message "Delete these and run again to apply it:"
${orderDeleteBlock}
                log_message "Or discard the whole analysis and start over:  ./PoolSeqFlow reset"
                log_message "RGTAGS CHANGE CHECK:   FAIL"
                STATUS="FAIL"
            fi
        else
            log_message "RGTags file has CHANGED since the existing outputs were produced:"
            log_message ""
            while IFS= read -r line; do
                case "\$line" in
                    '<'*) printf '  was  %s\\n' "\${line#< }" | tee -a \$REPORTFILE ;;
                    '>'*) printf '  now  %s\\n' "\${line#> }" | tee -a \$REPORTFILE ;;
                esac
            done < <(diff "${storedRg}" current_rgtags.csv | grep -E '^[<>]')
            log_message ""
            log_message "Tag values changed. Every BAM in"
            log_message "    ${readyDir}"
            log_message "carries the old tags, and everything called from them carries them too."
            log_message "Delete these and run again to apply it:"
${tagDeleteBlock}
            log_message "Or discard the whole analysis and start over:  ./PoolSeqFlow reset"
            log_message "RGTAGS CHANGE CHECK:   FAIL"
            STATUS="FAIL"
        fi
    fi

    log_message "RGTAGS VERIFICATION:    STATUS=\$STATUS"
    mv \$REPORTFILE verify_environment_stage4.txt

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

// ONCE, not once per run: what is on PATH is a property of the machine, and asking N times
// would give N identical answers at the cost of N tasks.
//
// It is handed the union of every run's software settings rather than reading params.software
// itself. A multi-run table may name a different binary for one run - any parameter may be
// varied, that is settled - and a check that only ever looked at the base config would pass
// while that run's tool was missing, which is exactly the class of failure step 0 exists to
// catch before any compute is spent.
process CheckInstalledSoftware {
    input:
    val software_list

    output:
    path 'verify_environment_stage5.txt', emit: report

    script:
    dir_log = "${params.dir.allLogs}/0_verify_environment/s5_CheckInstalledSoftware"
    """
    REPORTFILE="verify_environment.txt"

    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    missing_software=false
    for software in ${software_list}; do
        if ! command -v \$software &> /dev/null; then
            log_message "Missing:   \$software"
            missing_software=true
        else
            log_message "Installed: \$software"
        fi
    done

    if [ "\$missing_software" = true ]; then
        log_message ""
        log_message "Please install the missing software."
        STATUS="FAIL"
    else
        log_message ""
        log_message "All software needed is installed."
        STATUS="PASS"
    fi
    log_message "SOFTWARE CHECK:        STATUS=\$STATUS"
    mv \$REPORTFILE verify_environment_stage5.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/0_VerifyEnvironment_s5_CheckInstalledSoftware_nextflow.log
    """
}

process CheckTrimParameters {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage6.txt'), emit: report

    script:
    autodetect = check.trim_galore.autodetect
    adapter1   = check.trim_galore.adapter1
    adapter2   = check.trim_galore.adapter2
    dir_log = checkLogDir(check, 's6_CheckTrimParameters')
    log_file = checkLogFile(check, 's6_CheckTrimParameters')
    """
    REPORTFILE="verify_environment.txt"

    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    AUTODETECT="${autodetect}"
    ADAPTER1="${adapter1}"
    ADAPTER2="${adapter2}"
    STATUS="PASS"

    if [ "\$AUTODETECT" = "true" ]; then
        log_message "TRIM PARAMETERS:       Adapter auto-detection is ENABLED"
        log_message "TRIM PARAMETERS:       Trim Galore will select the adapter; adapter1/adapter2 are ignored"
    else
        log_message "TRIM PARAMETERS:       Adapter auto-detection is DISABLED"
        log_message "TRIM PARAMETERS:       Both adapter1 and adapter2 must be set in parameters.config"

        for N in 1 2; do
            eval "SEQ=\\\$ADAPTER\$N"
            if [ -z "\$SEQ" ]; then
                log_message "TRIM PARAMETERS:       adapter\$N is empty - set it, or set autodetect = true"
                STATUS="FAIL"
            elif ! echo "\$SEQ" | grep -qiE '^[ACGTN]+\$'; then
                log_message "TRIM PARAMETERS:       adapter\$N is not a DNA sequence: \$SEQ"
                STATUS="FAIL"
            else
                log_message "TRIM PARAMETERS:       adapter\$N OK (\${#SEQ} bp): \$SEQ"
            fi
        done
    fi

    log_message "TRIM PARAMETER CHECK:  STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage6.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

// A run stands in four directories, and confusing any two of them is the failure this
// catches. The installation holds the code; the project directory is where you launched and
// where parameters.config was read from; mainDir is the fast working volume; storageDir is
// permanent storage.
//
// mainDir and storageDir are two tiers, not two names for one place: outputs are written to
// the working volume and promoted to permanent storage once whatever consumes them has
// succeeded. Pointing both at the same directory makes every promotion a no-op that moves a
// file onto itself, and makes `clean` and `reset` - which treat the two roots differently -
// impossible to reason about.
//
// Neither storage root may BE the installation. The installation is a tool: one copy serves
// any number of projects, it is replaced wholesale on upgrade, and from 3.0 it may be
// read-only and shared. A project working directory kept inside it would be destroyed by an
// upgrade and would make two projects impossible; permanent storage kept inside it would
// take the results and their provenance with it.
//
// Compared as RESOLVED paths. A string comparison passes happily on `/data/x` versus
// `/data/x/`, versus `/data/y/../x`, versus a symlink to the same directory, and each of
// those is the same directory with a different spelling.
//
// Containment is warned about, not rejected. One root inside another is harmless in itself -
// the managed subdirectories still do not collide - but the lifetimes differ sharply enough
// that it is worth saying out loud. The check that actually matters for collisions is that
// no two computed directories in the `dir` block resolve alike, and that belongs where the
// block is built, not here.
process CheckDirectories {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage8.txt'), emit: report

    script:
    dir_log = checkLogDir(check, 's8_CheckDirectories')
    log_file = checkLogFile(check, 's8_CheckDirectories')
    """
    REPORTFILE="verify_environment.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    STATUS="PASS"

    # -m resolves symlinks, '..' and trailing slashes without requiring the directory to
    # exist yet; mainDir need not be there before the first run creates work/ under it.
    MAIN=\$(realpath -m "${check.mainDir}")
    STORE=\$(realpath -m "${check.storageDir}")
    INSTALL=\$(realpath -m "${workflow.projectDir}")
    LAUNCH=\$(realpath -m "${workflow.launchDir}")

    log_message "DIRECTORY CHECK:       installation \$INSTALL"
    log_message "DIRECTORY CHECK:       project      \$LAUNCH"
    log_message "DIRECTORY CHECK:       mainDir      \$MAIN"
    log_message "DIRECTORY CHECK:       storageDir   \$STORE"

    if [ "\$MAIN" = "\$STORE" ]; then
        log_message "DIRECTORY CHECK:       mainDir and storageDir are the same directory."
        log_message "DIRECTORY CHECK:       They are two storage tiers: mainDir is the fast volume the"
        log_message "DIRECTORY CHECK:       pipeline works on and keeps Data/ and Reference/ in, and"
        log_message "DIRECTORY CHECK:       storageDir is where finished results are kept. Outputs move"
        log_message "DIRECTORY CHECK:       from the first to the second as each step that needs them"
        log_message "DIRECTORY CHECK:       completes, which cannot mean anything if they are one place."
        log_message "DIRECTORY CHECK:       Set them to two different directories in parameters.config."
        STATUS="FAIL"
    else
        log_message "DIRECTORY CHECK:       The two storage tiers are distinct"
    fi

    if [ "\$MAIN" = "\$INSTALL" ]; then
        log_message "DIRECTORY CHECK:       mainDir is the PoolSeqFlow installation itself."
        log_message "DIRECTORY CHECK:       The installation is a tool, not a workspace: one copy serves"
        log_message "DIRECTORY CHECK:       any number of projects, it is replaced wholesale on upgrade,"
        log_message "DIRECTORY CHECK:       and it may be read-only or shared between users. A project"
        log_message "DIRECTORY CHECK:       kept inside it does not survive an upgrade, and a second"
        log_message "DIRECTORY CHECK:       project has nowhere to go."
        log_message "DIRECTORY CHECK:       Make a directory for this project, put parameters.config in"
        log_message "DIRECTORY CHECK:       it, point mainDir at it, and run from there."
        STATUS="FAIL"
    fi

    if [ "\$STORE" = "\$INSTALL" ]; then
        log_message "DIRECTORY CHECK:       storageDir is the PoolSeqFlow installation itself."
        log_message "DIRECTORY CHECK:       storageDir is permanent storage - it holds the results and the"
        log_message "DIRECTORY CHECK:       record of what produced them. The installation is neither"
        log_message "DIRECTORY CHECK:       permanent nor yours alone: it is replaced wholesale on upgrade"
        log_message "DIRECTORY CHECK:       and may be read-only or shared. Results kept inside it are"
        log_message "DIRECTORY CHECK:       destroyed by the next upgrade, which is the one loss this"
        log_message "DIRECTORY CHECK:       pipeline can least afford."
        log_message "DIRECTORY CHECK:       Point storageDir at a volume that outlives the installation."
        STATUS="FAIL"
    fi

    # Containment. Harmless mechanically - nothing collides - but the lifetimes differ, so
    # it is said out loud rather than discovered during an upgrade or a reset.
    case "\$MAIN/" in
        "\$INSTALL"/*)
            log_message "DIRECTORY CHECK:       WARNING: mainDir is inside the installation. Allowed, but"
            log_message "DIRECTORY CHECK:       an upgrade replaces the installation and this project with it."
            ;;
    esac
    case "\$STORE/" in
        "\$INSTALL"/*)
            log_message "DIRECTORY CHECK:       WARNING: storageDir is inside the installation. Allowed, but"
            log_message "DIRECTORY CHECK:       an upgrade replaces the installation and these results with it."
            ;;
    esac

    # parameters.config is read from the directory the run was launched in. When that is not
    # mainDir the run still works, but the project's settings and the project's working files
    # are in two different places, which is worth knowing before wondering where a file went.
    if [ "\$MAIN" != "\$LAUNCH" ]; then
        log_message "DIRECTORY CHECK:       NOTE: the run was launched in \$LAUNCH, which is not mainDir."
        log_message "DIRECTORY CHECK:       parameters.config was read from there; the work happens in mainDir."
    fi

    log_message "DIRECTORY CHECK:       STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage8.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

// ONE TASK PER RESULTS DIRECTORY, not one per run.
//
// A manifest answers "would this parameter invalidate what is already here", and once results
// are shared the thing that HAS parameters is a directory. A run belongs to several - its own,
// plus whatever it shares - and its report carries all of their verdicts, because all of them
// describe results it depends on. See directoryManifest() for the intersection rule and why it
// cannot miss a parameter that matters.
//
// It also owns the members file. Who a directory belongs to and what parameters describe it are
// the same fact recorded twice, so one task writes both and they cannot disagree - and the
// previous copy is what distinguishes an edited config from a REGROUPED table, which look
// identical to a plain diff and want opposite advice.
process CheckRunParameters {
    tag { check.checkTag }

    input:
    val check

    output:
    tuple val(check), path('verify_environment_stage7.txt'), emit: report

    script:
    manifest    = check.manifest
    stored      = "${check.dir}/.poolseqflow_params"
    readable    = "${check.dir}/run_parameters.txt"
    versions    = "${check.dir}/.poolseqflow_versions"
    // A run's own directory is named after it and needs no list; a shared one does. All_Runs
    // gets one too, because "every run" is a list worth having on disk once the table is edited.
    members     = check.members.size() > 1 ? "${check.dir}/members.txt" : ''
    memberLines = check.memberTokens.sort().join('\n')
    release     = workflow.manifest.version ?: 'unknown'
    dir_log     = checkLogDir(check, 's7_CheckRunParameters')
    log_file    = checkLogFile(check, 's7_CheckRunParameters')
    """
    REPORTFILE="verify_environment.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    cat <<'CURRENT_PARAMS' > current_params.txt
${manifest}
CURRENT_PARAMS

    cat <<'CURRENT_MEMBERS' > current_members.txt
${memberLines}
CURRENT_MEMBERS

    STATUS="PASS"
    ADOPTED=0
    REGROUPED=0
    log_message "RUN PARAMETERS:        ${check.dir}"

    # WHO THIS DIRECTORY BELONGS TO, asked before what describes it. A directory whose member
    # set changed holds results produced for a different set of runs, so comparing its manifest
    # would be comparing two different things - and the answer would be "parameters were added
    # or removed", which reads as an edit to parameters.config and is not one. The number in a
    # Shared_<N> name is assigned in order of appearance, so it is exactly the name that can
    # come to mean a different group between two invocations.
    if [ -n "${members}" ] && [ -f "${members}" ] &&
       ! diff -q "${members}" current_members.txt > /dev/null 2>&1; then
        log_message "RUN PARAMETERS:        The runs sharing this directory have CHANGED:"
        log_message ""
        log_message "  was  \$(paste -sd, "${members}" | sed 's/,/, /g')"
        log_message "  now  \$(paste -sd, current_members.txt | sed 's/,/, /g')"
        log_message ""
        log_message "RUN PARAMETERS:        What is already here was produced for the earlier set. The new"
        log_message "RUN PARAMETERS:        one will not read all of it, and completed steps are skipped by"
        log_message "RUN PARAMETERS:        looking for output files - so results from two different"
        log_message "RUN PARAMETERS:        groupings would be mixed in one directory."
        log_message "RUN PARAMETERS:"
        log_message "RUN PARAMETERS:        Delete this directory and run again to rebuild it for the new"
        log_message "RUN PARAMETERS:        set, or restore ${params.multiRunFile} to what it was:"
        log_message "RUN PARAMETERS:            ${check.dir}"
        STATUS="FAIL"
        REGROUPED=1
    fi

    if [ "\$REGROUPED" = "1" ]; then
        :
    elif [ ! -f "${stored}" ]; then
        log_message "RUN PARAMETERS:        No previous run recorded - this is a fresh directory"
        log_message "RUN PARAMETERS:        Recording \$(wc -l < current_params.txt) analysis parameters"
        mkdir -p "\$(dirname "${stored}")"
        cp current_params.txt "${stored}"
    elif diff -q "${stored}" current_params.txt > /dev/null 2>&1; then
        log_message "RUN PARAMETERS:        Unchanged since the outputs here were produced"
    else
        # Three things can happen to a manifest and they do not mean the same thing:
        #
        #   CHANGED           a parameter that existed before now holds a different value.
        #                     The user changed a setting, and continuing would mix results.
        #   ADDED / REMOVED   the set of parameters itself differs. That is what a release
        #                     does when it introduces or retires one - the outputs on disk
        #                     were produced before the parameter existed, so there is no
        #                     earlier value for it to conflict with.
        #
        # A plain `diff` cannot tell these apart, so every release that added a parameter
        # failed every existing project and told it to run `reset` - which deletes the
        # results. Whether an add or remove is a release event or the user editing their own
        # config is settled by ${versions}: it records every release that has run here, and
        # this block runs before the version line below is appended, so its last entry is
        # still the release that produced the outputs on disk.
        # The classification itself lives in bin/classify_manifest.sh so it can be called and
        # tested directly. Every case it has to get right - a value containing '=', an empty
        # value, a key present twice, a manifest with no trailing newline - is a one-second
        # unit test there, where checking the same thing through a pipeline run costs a JVM
        # start each time. What stays here is the part that is genuinely about this pipeline:
        # deciding which kind of difference invalidates existing outputs.
        #
        # Emitted once and read several times, so the classification cannot disagree with
        # itself between the counts and the listings.
        classify_manifest.sh "${stored}" current_params.txt > param_diff.txt

        N_ADDED=\$(awk -F'\\t' '\$1 == "COUNTS" { print \$2 }' param_diff.txt)
        N_CHANGED=\$(awk -F'\\t' '\$1 == "COUNTS" { print \$3 }' param_diff.txt)
        N_REMOVED=\$(awk -F'\\t' '\$1 == "COUNTS" { print \$4 }' param_diff.txt)
        N_MALFORMED=\$(awk -F'\\t' '\$1 == "COUNTS" { print \$5 }' param_diff.txt)

        # A manifest is machine-written, so a line that does not parse means something is
        # wrong upstream - and a dropped line hides a key from the comparison, which can make
        # a real change look like no change at all. Never silent.
        if [ "\${N_MALFORMED:-0}" -gt 0 ]; then
            log_message "RUN PARAMETERS:        \$N_MALFORMED unparseable line(s) in a parameter manifest:"
            while IFS=\$'\\t' read -r kind line which _rest; do
                [ "\$kind" = "MALFORMED" ] || continue
                printf '  %-8s %s\\n' "\$which" "\$line" | tee -a \$REPORTFILE
            done < param_diff.txt
            log_message "RUN PARAMETERS:        ${stored} is written by the pipeline and should not be"
            log_message "RUN PARAMETERS:        edited by hand. Restore it, or start a fresh run."
            STATUS="FAIL"
        fi

        PREVIOUS_RELEASE=""
        if [ -f "${versions}" ]; then
            PREVIOUS_RELEASE=\$(tail -n 1 "${versions}" | cut -f1)
        fi

        list_set_changes() {
            while IFS=\$'\\t' read -r kind key was now; do
                case "\$kind" in
                    ADDED)   printf '  added    %s = %s\\n' "\$key" "\$now" | tee -a \$REPORTFILE ;;
                    REMOVED) printf '  removed  %s (was %s)\\n' "\$key" "\$was" | tee -a \$REPORTFILE ;;
                esac
            done < param_diff.txt
        }

        if [ "\${N_CHANGED:-0}" -gt 0 ]; then
            log_message "RUN PARAMETERS:        CHANGED since the existing outputs were produced:"
            log_message ""
            while IFS=\$'\\t' read -r kind key was now; do
                [ "\$kind" = "CHANGED" ] || continue
                printf '  %s\\n      was  %s\\n      now  %s\\n' "\$key" "\$was" "\$now" | tee -a \$REPORTFILE
            done < param_diff.txt
            log_message ""
            log_message "RUN PARAMETERS:        The pipeline skips completed steps by checking for output"
            log_message "RUN PARAMETERS:        files, not by checking which parameters produced them, so"
            log_message "RUN PARAMETERS:        continuing would mix old and new results."
            log_message "RUN PARAMETERS:"
            log_message "RUN PARAMETERS:        Either restore the previous values, or start a fresh run:"
            log_message "RUN PARAMETERS:            ./PoolSeqFlow reset"
            STATUS="FAIL"
        fi

        if [ "\${N_ADDED:-0}" -gt 0 ] || [ "\${N_REMOVED:-0}" -gt 0 ]; then
            log_message ""
            if [ -n "\$PREVIOUS_RELEASE" ] && [ "\$PREVIOUS_RELEASE" != "${release}" ]; then
                log_message "RUN PARAMETERS:        The set of parameters changed between \$PREVIOUS_RELEASE,"
                log_message "RUN PARAMETERS:        which produced the outputs here, and ${release}:"
                log_message ""
                list_set_changes
                log_message ""
                log_message "RUN PARAMETERS:        Recorded rather than treated as a change: a parameter that did"
                log_message "RUN PARAMETERS:        not exist cannot have produced the outputs already on disk. This"
                log_message "RUN PARAMETERS:        is the reasoning the pipeline version check below already uses."
                log_message "RUN PARAMETERS:        Read the new values before relying on results that span two"
                log_message "RUN PARAMETERS:        releases; they are listed in ${readable}."
                ADOPTED=1
            else
                log_message "RUN PARAMETERS:        Parameters were added to or removed from parameters.config"
                log_message "RUN PARAMETERS:        without a release change:"
                log_message ""
                list_set_changes
                log_message ""
                log_message "RUN PARAMETERS:        ${release} has run in this project before, so this is an edit to"
                log_message "RUN PARAMETERS:        your own config rather than something a release introduced, and"
                log_message "RUN PARAMETERS:        what it does to the existing outputs cannot be known. Restore"
                log_message "RUN PARAMETERS:        the file, or start a fresh run:"
                log_message "RUN PARAMETERS:            ./PoolSeqFlow reset"
                STATUS="FAIL"
            fi
        fi

        # Adopted only when nothing conflicted, so the notice appears on the upgrade run and
        # not on every run after it. A failed check leaves ${stored} untouched, which is what
        # keeps the failure reproducible instead of self-clearing.
        if [ "\$STATUS" = "PASS" ] && [ "\$ADOPTED" = "1" ]; then
            cp current_params.txt "${stored}"
        fi
    fi

    # Which release produced these outputs. Recorded, never enforced: most releases do
    # not change results, so a version change must not invalidate outputs the way a
    # parameter change does. But "cite the version you ran" is unanswerable if nothing
    # writes it down, and a project that several versions have touched is worth knowing
    # about - the file is append-only for exactly that reason.
    #
    # Skipped entirely on a regrouping: appending there would record this release against
    # results it did not produce, and would clear the classification the next invocation needs.
    if [ "\$REGROUPED" = "1" ]; then
        :
    elif [ ! -f "${versions}" ]; then
        mkdir -p "\$(dirname "${versions}")"
        printf '%s\\t%s\\n' "${release}" "\$(date -u '+%Y-%m-%d')" > "${versions}"
        log_message "PIPELINE VERSION:      ${release} - first run in this directory"
    elif [ "\$(tail -n 1 "${versions}" | cut -f1)" = "${release}" ]; then
        log_message "PIPELINE VERSION:      ${release}"
    else
        PREVIOUS=\$(tail -n 1 "${versions}" | cut -f1)
        printf '%s\\t%s\\n' "${release}" "\$(date -u '+%Y-%m-%d')" >> "${versions}"
        log_message "PIPELINE VERSION:      ${release} - earlier runs here used \$PREVIOUS"
        log_message "PIPELINE VERSION:      Outputs already present were produced by the earlier"
        log_message "PIPELINE VERSION:      release, and completed steps are not redone. Cite the"
        log_message "PIPELINE VERSION:      version that produced the results you report."
        log_message "PIPELINE VERSION:      Full history: ${versions}"
    fi

    # Publish a readable copy next to the results. ${stored} stays the file the check
    # compares against; this one exists so the settings behind a set of outputs can be
    # read without picking through parameters.config. Read-only, because editing it
    # changes nothing - the pipeline reads ${stored}.
    if [ "\$STATUS" = "PASS" ]; then
        mkdir -p "\$(dirname "${readable}")"
        rm -f "${readable}"
        {
            echo "# PoolSeqFlow analysis parameters for the outputs in ${check.dir}"
            echo "# Generated \$(date -u '+%Y-%m-%d %H:%M:%S UTC') - read-only; edit parameters.config instead."
            echo "#"
            echo "# Pipeline version(s) that have run in this project, oldest first."
            echo "# More than one means these outputs were not all produced by the same release."
            sed 's/^/#   /' "${versions}"
            echo "#"
            cat current_params.txt
        } > "${readable}"
        chmod 444 "${readable}"
        log_message "RUN PARAMETERS:        Written to ${readable}"
    fi

    # The members file, written last and only on a clean pass - so a directory whose grouping is
    # in dispute keeps the record of what it was, which is what the check reads next time.
    if [ "\$STATUS" = "PASS" ] && [ -n "${members}" ]; then
        mkdir -p "\$(dirname "${members}")"
        cp current_members.txt "${members}"
    fi

    log_message "RUN PARAMETER CHECK:   STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage7.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/${log_file}
    """
}

// Stage 9: the multi-run table, when there is one.
//
// The parsing and the syntactic checks are in bin/parse_multirun.py rather than here. Two
// reasons, and the first is a correctness one: the values in that file are parameter values,
// and readPattern - which is exactly the sort of thing people vary between runs - defaults to
// `*_R{1,2}.fq.gz`, a value with a comma in it. Splitting on commas would cut it in half and
// produce a row with the wrong number of fields, reported as a completely different mistake.
// Python's csv module implements the real quoting rules. The second reason is that a script
// can be unit-tested in milliseconds, while every check written here costs a JVM start.
//
// What this stage adds on top is the part that needs to know the parameters: which columns
// name a value the pipeline would otherwise compute for itself.
//
// FROM E1u ONWARDS THIS IS NOT THE FIRST GATE. The runs have to exist before the DAG can be
// built, so resolve_parameters.nf parses and validates the table earlier still, and an
// unusable one stops the invocation before any task is submitted - including this one. What
// is left here is the part that is worth having in the durable record rather than only on a
// terminal: what the table expanded to, and what it detached from its derivation. The FAIL
// branches below are kept as a backstop and because this stage can be run on its own; in the
// ordinary entry point they are not reached.
process CheckMultiRun {
    input:
    // The divergence analysis, already rendered. It is computed while the DAG is built - before
    // this task exists - so what arrives is text, not the plan.
    tuple val(sharing_lines), val(conflict_lines)

    output:
    path 'verify_environment_stage9.txt', emit: report

    script:
    dir_log = "${params.dir.allLogs}/0_verify_environment/s9_CheckMultiRun"
    derived = derivedParameterNames().join(' ')
    known = knownParameterNames().join(' ')
    // Rendered as log_message calls rather than a heredoc so each line lands in the report and
    // on the console the same way every other line here does.
    sharing_block = sharing_lines.collect { line -> "        log_message \"${line}\"" }.join('\n')
    conflict_block = conflict_lines.isEmpty()
        ? '        :'
        : (conflict_lines.collect { line -> "        log_message \"${line}\"" } + ['        STATUS="FAIL"']).join('\n')
    """
    REPORTFILE="verify_environment.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    STATUS="PASS"

    if [ "${params.multiRun}" != "true" ]; then
        log_message "MULTI-RUN CHECK:       single run - every parameter comes from parameters.config"
        log_message "MULTI-RUN CHECK:       STATUS=\$STATUS"
        mv \$REPORTFILE verify_environment_stage9.txt
        mkdir -p ${dir_log}
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${dir_log}/0_VerifyEnvironment_s9_CheckMultiRun_nextflow.log
        exit 0
    fi

    log_message "MULTI-RUN CHECK:       table ${params.multiRunPath}"

    if [ ! -f "${params.multiRunPath}" ]; then
        log_message "MULTI-RUN CHECK:       multiRun is on but that file is not there."
        log_message "MULTI-RUN CHECK:       Either create it, or set multiRun = false to run the single"
        log_message "MULTI-RUN CHECK:       set of parameters in parameters.config."
        STATUS="FAIL"
    elif ! RUNS=\$(parse_multirun.py "${params.multiRunPath}" 2> parse_errors.txt); then
        while IFS= read -r line; do
            log_message "MULTI-RUN CHECK:       \$line"
        done < parse_errors.txt
        STATUS="FAIL"
    else
        printf '%s' "\$RUNS" > runs.json

        # Every RunID, and what each row actually sets. Printed in full because this is the
        # only place the expansion is visible before it starts costing compute.
        printf '%s\\n' ${known} > known_params.txt
        python3 - runs.json "${params.storageDir}" known_params.txt ${derived} <<'PYEOF' >> \$REPORTFILE || STATUS="FAIL"
import json, sys

runs = json.load(open(sys.argv[1]))
storage = sys.argv[2]
known = {line.strip() for line in open(sys.argv[3]) if line.strip()}
derived = set(sys.argv[4:])

print(f"MULTI-RUN CHECK:       {len(runs)} runs")
for run in runs:
    run_id = run["RunID"]
    # Where this run's OWN results go. There is one results tree per project now, and a run
    # is a directory inside it rather than a tree of its own - so what is named here is only
    # the part no other run shares. A storageDir column still sends a run somewhere else
    # entirely, which is why it is read rather than assumed.
    where = f'{run.get("storageDir", storage)}/Output/{run_id}'
    print(f"MULTI-RUN CHECK:       {run_id} -> {where}")
    varied = {k: v for k, v in run.items() if k not in ("RunID", "storageDir")}
    if varied:
        for key, value in sorted(varied.items()):
            print(f"MULTI-RUN CHECK:           {key} = {value}")
    else:
        print("MULTI-RUN CHECK:           (nothing differs from parameters.config)")

# Encouraged, not enforced. Runs that share one storageDir share one results tree, and that
# is what lets work common to several of them be done once and filed where they can all
# reach it. A run pointed somewhere else has no tree in common with the others, so it
# repeats every step for itself - which is a legitimate thing to want and an expensive
# thing to do by accident, so it is said out loud rather than refused.
detached = sorted({run["RunID"] for run in runs if "storageDir" in run})
if detached:
    print("MULTI-RUN CHECK:       these runs set a storageDir of their own:")
    for run_id in detached:
        print(f"MULTI-RUN CHECK:           {run_id}")
    print("MULTI-RUN CHECK:       Allowed, and worth being sure you meant it. Runs that share a")
    print("MULTI-RUN CHECK:       storageDir share one results tree, so work several of them agree")
    print("MULTI-RUN CHECK:       on is done once and filed under All_Runs or Shared_<N>. A run with")
    print("MULTI-RUN CHECK:       its own storageDir shares nothing and repeats every step alone.")

# A column naming something the pipeline computes is allowed on purpose - benchmarking a
# pinned thread count or an options string outright is a real use. It is reported because
# the value then stops tracking whatever it was derived from, which is easy to set up by
# accident and impossible to see afterwards.
# A column that is not a parameter at all. Any parameter may be varied - that is settled,
# and there is deliberately no whitelist - but a name that is not one cannot be, and
# accepting it would mean a run whose setting was silently ignored. Almost always a typo.
unknown = sorted({k for run in runs for k in run if k != "RunID" and k not in known})
if unknown:
    print("MULTI-RUN CHECK:       these columns do not name a parameter in parameters.config:")
    for key in unknown:
        print(f"MULTI-RUN CHECK:           {key}")
    print("MULTI-RUN CHECK:       nothing would read them, so the run would quietly ignore")
    print("MULTI-RUN CHECK:       whatever you set. Check the spelling, or add the parameter")
    print("MULTI-RUN CHECK:       to parameters.config first.")
    sys.exit(1)

overrides = sorted({k for run in runs for k in run if k in derived})
if overrides:
    print("MULTI-RUN CHECK:       these columns replace a value the pipeline would compute:")
    for key in overrides:
        print(f"MULTI-RUN CHECK:           {key}")
    print("MULTI-RUN CHECK:       used exactly as written; nothing is re-derived from them.")
PYEOF

        # WHERE THE RUNS DIVERGE, said out loud before any compute is spent.
        #
        # A wrong entry in stepParameterMap() is the failure this design risks and it is
        # silent: two runs would share an artifact one of them did not ask for. Stating the
        # partition here is what makes it reviewable - a grouping you did not expect is
        # visible in seconds rather than inferred months later from a result.
${sharing_block}

        # The members file inside each shared directory - written by CheckRunParameters, which
        # owns that directory's record, so that the grouping can be recovered from the results
        # themselves rather than only from this report.

        # And the one disagreement a group cannot absorb.
${conflict_block}
    fi

    log_message "MULTI-RUN CHECK:       STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage9.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/0_VerifyEnvironment_s9_CheckMultiRun_nextflow.log
    """
}

process VerifyAll {
    errorStrategy 'finish'
    tag { run.runId ?: '-' }

    input:
    // ONE TUPLE, JOINED ON THE RUN. These used to be nine separate `val` inputs, which
    // Nextflow matches POSITIONALLY - item k of each channel is paired with item k of the
    // others. That was safe while every stage emitted exactly one report, and becomes a
    // silent mismatch the moment there are N: nothing would make run B's reference check line
    // up with run B's trim check, and the report would describe a run that never existed.
    //
    // The two global stages stay separate on purpose. They ride value channels, which
    // broadcast to every task of this process, which is the behaviour that is wanted for a
    // check that ran once for the whole invocation.
    tuple val(run), val(reference_log), val(gffFile_log), val(dataSource_log),
          val(rgtags_log), val(trim_log), val(runparam_logs), val(directory_log)
    val software_log
    val multirun_log

    output:
    tuple val(run), path('0_verify_environment.txt')

    script:
    output_folder = "${run.dir.output.reports}"
    dir_log = "${run.dir.logs}/0_verify_environment"
    // A LIST, because a run belongs to as many results directories as it has divergence points
    // and each of them has its own manifest. Already ordered by directory upstream, so the
    // report reads the same way on every invocation.
    runparam_log = runparam_logs.collect { f -> "${f}".toString() }.join(' ')
    """
    REPORTFILE="0_verify_environment.txt"
    
    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    # The report is the durable record of what step 0 checked, so it has to leave the
    # task directory: `cleanup = true` empties that on success, which means the report
    # currently survives only when the run fails. Publishing it also makes the path
    # docs/pipeline/steps.md and directories.md already advertise real.
    # The log mirror belongs here too. It used to sit below the `exit 1`, so a failed
    # verification - the one case where the log is actually wanted - never reached it.
    archive_logs() {
        mkdir -p ${output_folder}
        atomic_mv.sh \$REPORTFILE ${output_folder}/\$REPORTFILE
        ln -s ${output_folder}/\$REPORTFILE .
        mkdir -p ${dir_log}
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${dir_log}/0_VerifyEnvironment_VerifyAll_nextflow.log
    }

    log_message "==================== ENVIRONMENT VERIFICATION REPORT ===================="
    log_message "Date: \$(date)"
    log_message "========================================================================="
    log_message ""

    cat ${reference_log} ${gffFile_log} ${dataSource_log} ${rgtags_log} ${software_log} ${trim_log} ${runparam_log} ${directory_log} ${multirun_log} | tee -a \$REPORTFILE
    log_message ""
    log_message "========================================================================="

    CHECKFAIL=\$(grep "STATUS=FAIL" \$REPORTFILE | wc -l)
    if [ \$CHECKFAIL -gt 0 ]; then
        log_message "Environment verification failed with \$CHECKFAIL issues:"
        log_message ""
        grep "STATUS=FAIL" \$REPORTFILE | tee -a \$REPORTFILE
        log_message ""
        log_message "ENVIRONMENT VERIFICATION: FAILED"

        archive_logs
        exit 1
    else
        log_message "All verification checks passed successfully."
        log_message ""
        log_message "ENVIRONMENT VERIFICATION: SUCCESS"

    fi

    archive_logs
    """
}

workflow VerifyEnvironment {
    take:
    // THE PLAN AND THE RUN LIST, in one value channel rather than a channel of runs.
    //
    // Which checks this invocation needs is worked out before anything runs, exactly as the
    // divergence analysis is - and two of them are keyed by the analysis itself, so they need
    // it here. flatMap expands the pair into one item per check task. N separate items would
    // have to be regrouped at runtime by an operator that cannot see the shape, which is the
    // thing this stage exists to stop doing.
    context
    // The divergence analysis, rendered at DAG-build time: what step 0 should say about the
    // grouping, and any publish-only disagreement that makes a group impossible. A value
    // channel, because it describes the invocation rather than a run.
    sharing

    main:
    runs = context.flatMap { ctx -> ctx.runs }

    CheckReference(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckReference') })
    // `annotate` is a per-run parameter, so which runs need a GFF is decided by filtering the
    // runs rather than by an `if` over the base config. Under multiRun one run may annotate
    // while another does not; the `if` this replaces could only answer for all of them.
    //
    // Filtered BEFORE grouping, so the two stages key on the runs they actually serve: an empty
    // side produces an empty list and therefore no task at all.
    CheckGFF(context.flatMap { ctx -> checkGroups(ctx.runs.findAll { run -> run.annotate }, 'CheckGFF') })
    SkipGFFCheck(context.flatMap { ctx -> checkGroups(ctx.runs.findAll { run -> !run.annotate }, 'SkipGFFCheck') })

    CheckData(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckData') })
    CheckTrimParameters(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckTrimParameters') })
    CheckDirectories(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckDirectories') })
    CheckRunParameters(context.flatMap { ctx -> manifestGroups(ctx.plan, ctx.runs) })

    // Every distinct RGTags table, repaired once. Keyed on the PATH and on nothing else - see
    // rgTagsRepairs() - because this stage writes to the user's own file.
    RepairRGTagsLineEndings(context.flatMap { ctx -> rgTagsRepairs(ctx.runs) })

    // The RGTags change guard, one task per step-6 variant. It needs two things matched onto it
    // rather than computed: this group's CheckData verdict, and the repair report of every
    // distinct table its members named.
    //
    // groupKey carries the number of tables with the key, so a group is released as soon as ITS
    // repairs are in rather than when the repair channel closes.
    rgtags_reports = RepairRGTagsLineEndings.out.report.map { repair, report -> tuple(repair.rgTagsPath, report) }
    CheckRGTagsFile(
        context.flatMap { ctx -> rgTagsChecks(ctx.plan, ctx.runs) }
            .map { item -> tuple(item.dataKey, item) }
            .combine(CheckData.out.report.map { check, report -> tuple(check.checkKey, report) }, by: 0)
            .flatMap { _key, item, verify ->
                item.rgTagsPaths.collect { path ->
                    tuple(path, groupKey(item.checkKey, item.rgTagsPaths.size()), item, verify) } }
            .combine(rgtags_reports, by: 0)
            .map { _path, gate, item, verify, lineending -> tuple(gate, item, verify, lineending) }
            .groupTuple(by: 0)
            .map { _gate, items, verifies, lineendings -> tuple(items[0], verifies[0], lineendings) })

    // The two stages that describe the invocation rather than a run. Both emit value
    // channels, which is what lets one report reach every run's VerifyAll.
    //
    // The union is taken over the run list itself rather than by collecting a channel, so the
    // order is the table's and not the order N tasks happened to finish in. For a single run it
    // is exactly params.software.values() in the order the config wrote them.
    CheckInstalledSoftware(context.map { ctx ->
        ctx.runs.collectMany { run -> run.software.values().collect { tool -> "${tool}".toString() } }
            .unique()
            .join(' ') })
    CheckMultiRun(sharing)

    // EVERY CHECK'S VERDICT, HANDED BACK TO THE RUNS IT ANSWERED FOR. CheckData's is needed
    // twice, so it is named rather than recomputed: the key is a string built from parameter
    // values, and two spellings of one key match nothing.
    data_by_run = reportPerRun(runs, CheckData.out.report, 'CheckData')
    gff_by_run = reportPerRun(runs.filter { run -> run.annotate }, CheckGFF.out.report, 'CheckGFF')
        .mix(reportPerRun(runs.filter { run -> !run.annotate }, SkipGFFCheck.out.report, 'SkipGFFCheck'))
    // The two keyed by the analysis rather than by a parameter list, so their keys come from it
    // too - the step-6 variant a run belongs to, and the results directories it is a member of.
    rgtags_by_run = context
        .flatMap { ctx -> ctx.runs.collect { run -> tuple(variantForRun(ctx.plan, run, 6).variantKey, run) } }
        .combine(CheckRGTagsFile.out.report.map { check, report -> tuple(check.checkKey, report) }, by: 0)
        .map { _key, run, report -> tuple(run, report) }
    // A LIST per run, not one report: a run has as many manifests as it has directories. Sorted
    // by directory so the assembled report is stable between invocations.
    runparams_by_run = context
        .flatMap { ctx ->
            def pairs = []
            manifestGroups(ctx.plan, ctx.runs).each { group ->
                ctx.runs.each { run ->
                    if (group.members.contains(run.runId)) pairs << tuple(group.checkKey, run)
                }
            }
            return pairs }
        .combine(CheckRunParameters.out.report.map { check, report -> tuple(check.checkKey, check.dir, report) }, by: 0)
        .map { _key, run, dir, report -> tuple(run, dir, report) }
        .groupTuple(by: 0)
        .map { run, dirs, reports ->
            def pairs = []
            dirs.eachWithIndex { dir, i -> pairs << [dir, reports[i]] }
            tuple(run, pairs.sort { a, b -> a[0] <=> b[0] }.collect { pair -> pair[1] }) }

    VerifyAll(
        reportPerRun(runs, CheckReference.out.report, 'CheckReference')
            .join(gff_by_run, by: 0)
            .join(data_by_run, by: 0)
            .join(rgtags_by_run, by: 0)
            .join(reportPerRun(runs, CheckTrimParameters.out.report, 'CheckTrimParameters'), by: 0)
            .join(runparams_by_run, by: 0)
            .join(reportPerRun(runs, CheckDirectories.out.report, 'CheckDirectories'), by: 0),
        CheckInstalledSoftware.out.report,
        CheckMultiRun.out.report)

    emit:
    VerifyAll.out
}
