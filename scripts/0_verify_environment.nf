include { derivedParameterNames } from './resolve_parameters.nf'
include { knownParameterNames } from './resolve_parameters.nf'
include { dig; deepCopyVariant; runToken } from './variants.nf'
include { sharingGroups; parentVariant; childVariants; variantForRun } from './variants.nf'
// The metadata file's projections. Step 0 compares one of them against the copy beside the
// results, and reports the pooling another of them implies.
include { metadataGuardLines; samplesWithAdapterOverrides; trimOptionsArePinned } from './metadata.nf'

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
// Returns the `key=value` lines rather than one joined string, because sharedParameters() below
// needs to compare them key by key.
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
    // dryRun and dryRunDir describe the INVOCATION, not the project: one says this is a
    // preview rather than a run, the other says where to put the preview. Leaving them in
    // would make every dry run report the parameters as changed - `dryRun=true` against a
    // stored `dryRun=false` - which is the one thing a preview must not do.
    def skipKey = [
        'mainDir', 'storageDir', 'runId', 'dryRun', 'dryRunDir',
        // `metadata` is the parsed contents of the metadata file, carried in every run map. It
        // is excluded because the metadata change guard already compares its own projection of
        // it - read groups and the columns that change a number, never the design columns - and
        // flattening it in here would put the whole file in the parameter manifest, so adding a
        // column of your own would fail the parameter check as a changed parameter.
        'metadata',
        'referencePath', 'gffPath', 'metadataPath', 'multiRunPath', 'referenceFa', 'reference', 'gff', 'reads',
        'threads', 'memory'
    ] as Set
    def skipPrefix = ['dir.', 'cores.', 'java.', 'software.']
    return flattenParams(p, '', [:])
        .findAll { k, _v -> !skipKey.contains(k) && !skipPrefix.any { prefix -> k.startsWith(prefix) } }
        .collect { k, v -> "${k}=${v}".toString() }
        .sort()
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
// already not per run - CheckInstalledSoftware and CheckMultiRun - have
// done since E1t. `All_Runs` means "the invocation" in this one place rather than "shared by
// every run"; the file name says which runs each task actually answered for.
//
// VerifyAll is the exception and stays in the run's own tree, because it really is per run.
//
// ONE DIRECTORY PER WORKFLOW (Z, 2026-08-28), not one per process. Every log file already
// carries the step, the stage and the runs it answered for, so the directory was repeating
// what the name already said - at the cost of a level of nesting per process, in a tree the
// user is expected to read. The one-writer-per-file rule is carried by the FILE NAME, which is
// why collapsing the directories cannot break it.
def checkLogDir(Map check) {
    def root = params.multiRun ? "${check.storageDir}/Logs/All_Runs" : "${check.storageDir}/Logs"
    return "${root}/0_verify_environment".toString()
}

// ONE WRITER PER FILE. Tasks append to their log without locking, which is safe only while no
// two of them share a file - and a keyed check runs N times into one directory. Naming the file
// after the runs it answered for makes collision impossible and says who it is about.
//
// The repair stage this once described had it wrong since E1t, and is gone with the rest of
// the RGTags handling: two runs naming two different tables gave two tasks appending to one
// file.
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

// THE METADATA CHANGE GUARD IS KEYED TO THE STEP-6 VARIANT, and nothing coarser will do.
//
// What it asks is whether the file has been edited since the things that absorbed it were
// produced - the read group values, which step 4 bakes into each BAM, and the row order, which
// step 6 turns into the VCF's sample column order. So its answer depends on the CONTENT of two
// directories, and two runs may share the file and still have different ones.
//
// Step 6's key is the finest of the two and contains step 4's, so runs that share it share both
// artifacts and therefore share one answer. Anything coarser lets a run with no BAMs decide for
// a run that has them - and the branch below treats "no BAMs and no VCF" as "nothing has
// consumed the file yet" and RECORDS A NEW BASELINE, so the edit would be adopted while the
// BAMs on disk still carried the old read groups. Every other wrong existence answer in this
// pipeline costs redundant work; this one costs the guard itself.
//
// THE PROBE LOOKS IN FOUR PLACES, NOT TWO. Permanent storage as well as the working volume, and
// the producing VARIANT's directories rather than the member's own: since sharing was turned on
// the ready BAMs are promoted to (say) Output/All_Runs/Ready, which no member's own Output/
// contains - so a guard that looked only there answered 0 on every invocation after promotion
// and had already stopped guarding.
def metadataChecks(Map plan) {
    return plan.variants[6].collect { variant ->
        // The BAMs came from step 4, which is step 6's parent; the filtered VCFs and the
        // frequency tables are step 7's, which may be several branches below one call.
        def ready = parentVariant(plan, variant)
        def filtered = childVariants(plan, variant, 7)

        // What has to go for an edit to become the new baseline, in the order it is listed.
        // The row order lives only in the called VCF and everything derived from it; the read
        // group values live in the BAMs as well, which is why the lists differ by one entry.
        def orderDelete = ([variant.dir.output.vcf] +
                           filtered.collect { child -> child.dir.output.vcf } +
                           filtered.collect { child -> child.dir.output.freq })
                          .collect { d -> d.toString() }.unique()

        // WHICH ROWS MERGE INTO ONE COLUMN. Rows sharing an RG_Sample are one pool: bcftools
        // names VCF sample columns by SM, so their reads are pooled and their depths added.
        // That is the one thing in this file that silently changes what a result MEANS rather
        // than whether it is produced, so step 0 states it before any compute is spent.
        def pools = [:]
        variant.metadata.each { row ->
            def pool = "${row.RG_Sample}".toString()
            if (!pools.containsKey(pool)) pools[pool] = []
            pools[pool] << "${row.SampleID}".toString()
        }

        return [checkKey    : variant.variantKey,
                runId       : variant.runId,
                storageDir  : variant.storageDir,
                members     : variant.members,
                checkTag    : variant.members.collect { m -> runToken(m) }.join('+'),
                // The key of the CheckData task whose verdict this stage reads. Every member
                // shares it: step 2's identity contains `reads`, which is dir.data plus
                // readPattern, and step 6's identity contains step 2's.
                dataKey     : checkKey(variant, 'CheckData'),
                metadataPath: "${variant.metadataPath}".toString(),
                sampleIds   : variant.metadata.collect { row -> "${row.SampleID}".toString() },
                pooled      : pools.findAll { _pool, ids -> ids.size() > 1 }
                                   .collect { pool, ids -> [pool: pool, ids: ids.sort()] }
                                   .sort { a, b -> a.pool <=> b.pool },
                // The projection the guard compares - read groups and the columns that change a
                // number, never the design columns. See scripts/metadata.nf.
                guardLines  : metadataGuardLines(variant),
                // A row that overrides the adapters cannot be honoured when the run pins
                // trim_galore.options outright, so the combination is refused rather than
                // silently resolved in one direction.
                adapterOverrides: samplesWithAdapterOverrides(variant),
                optionsPinned: trimOptionsArePinned(variant),
                dataDir     : "${variant.dir.data}".toString(),
                readPattern : "${variant.readPattern}".toString(),
                samtools    : "${variant.software.samtools}".toString(),
                // Beside the results it describes: the baseline belongs in the directory holding
                // the VCF whose column order it decided, which for a shared step is the group's
                // rather than any one member's.
                storedMeta  : "${variant.dir.outputs}/.poolseqflow_metadata".toString(),
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
    dir_log = checkLogDir(check)
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
    dir_log = checkLogDir(check)
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
    dir_log = checkLogDir(check)
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
    dir_log = checkLogDir(check)
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

// THE SAMPLE METADATA, AND WHAT IT HAS ALREADY DECIDED.
//
// Much smaller than the stage it replaces, because bin/parse_metadata.py now owns everything
// that is a property of the FILE - unknown RG_ columns, duplicate SampleIDs, ragged rows,
// half-set adapter pairs - and runs while the DAG is being built, before this exists. What is
// left here is everything that needs the project rather than the file: whether the reads and
// the rows describe the same samples, which rows merge into one pool, and whether the file has
// been edited since the results that absorbed it were produced.
//
// The empty-value check went with the rest. It refused any blank cell, which was right when
// every column was a read group tag and is wrong now: a blank RG_ cell omits that tag on
// purpose, and a blank design column is just a blank.
process CheckMetadataFile {
    tag { check.checkTag }

    input:
    tuple val(check), val(verify)

    output:
    tuple val(check), path('verify_environment_stage4.txt'), emit: report

    script:
    metadataFile = check.metadataPath
    dataDir = check.dataDir
    readPattern = findNameExpr(check.readPattern)
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
    storedMeta = check.storedMeta
    // FOUR ROOTS, NOT TWO, and all of them the producing variant's - see metadataChecks() for
    // why each half of that matters. Permanent storage and the working volume both, because the
    // branch below reads "no BAMs and no VCF" as "nothing has consumed the file yet" and
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
    // The rows as the guard sees them, and the sample ids as the reads check compares them.
    // Rendered here, from the parsed file, so the task never touches a CSV.
    guardBlock = check.guardLines.join('\n')
    idsBlock = check.sampleIds.join('\n')
    poolBlock = check.pooled.isEmpty()
        ? '    log_message "METADATA CHECK:        every sample is its own pool"'
        : check.pooled.collect { entry ->
              "    log_message \"METADATA CHECK:        ${entry.pool} is one column, pooling ${entry.ids.join(', ')}\"" }.join('\n')
    // The one combination a per-sample adapter cannot be honoured in.
    adapterBlock = (check.optionsPinned && !check.adapterOverrides.isEmpty())
        ? (['    log_message "METADATA CHECK:        these samples set adapter1/adapter2, but this run pins"',
            '    log_message "METADATA CHECK:        trim_galore.options outright, so the pinned string is used"',
            '    log_message "METADATA CHECK:        verbatim and the per-sample adapters could not be applied:"'] +
           check.adapterOverrides.collect { id -> "    log_message \"METADATA CHECK:            ${id}\"" } +
           ['    log_message "METADATA CHECK:        Remove the pin, or remove the adapter columns."',
            '    STATUS="FAIL"']).join('\n')
        : '    :'
    dir_log = checkLogDir(check)
    // The file has always been named for the stage rather than for the process; kept, so that a
    // single run's log tree is the same tree it was.
    log_file = checkLogFile(check, 's4_CheckMetadata')

    """
    REPORTFILE="verify_environment.txt"
    STATUS="PASS"
    DRY_RUN="${params.dryRun}"

    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    # THE ROWS, AS THE PIPELINE READ THEM. Not the file: bin/parse_metadata.py parsed it once
    # while the DAG was being built, and what arrives here is the projection the guard compares
    # - read groups and the columns that change a number, never the design columns.
    cat > current_metadata.txt <<'METADATA'
${guardBlock}
METADATA

    cat > metadata_ids.txt <<'SAMPLEIDS'
${idsBlock}
SAMPLEIDS

    # Check previous verification
    if [ ! -f ${verify} ]; then
        log_message "Verify file not found: ${verify}"
        STATUS="FAIL"
    elif grep -q "FAIL" ${verify}; then
        log_message "Previous step failed"
        STATUS="FAIL"
    elif [ ! -f "${metadataFile}" ]; then
        log_message "Sample metadata file ${metadataFile} not found"
        log_message "It says what your samples are: one row per pair of FASTQ files, with a"
        log_message "SampleID column matching the sample names your reads give. Copy the"
        log_message "template from the installation and edit it:"
        log_message "    cp \\\$POOLSEQFLOW_HOME/metadata.csv.template ${metadataFile}"
        log_message "METADATA FILE CHECK:   FAIL"
        STATUS="FAIL"
    else
        log_message "Sample metadata file exists: ${metadataFile}"
        log_message "METADATA FILE CHECK:   PASS"

        # THE READS AND THE ROWS MUST DESCRIBE THE SAME SAMPLES.
        #
        # Derived from readPattern rather than assumed, because step 2 derives it that way and
        # two implementations of one rule is how they come to disagree.
        if [ "${hasMateGroup}" != "true" ]; then
            sample_ids=""
            log_message "readPattern '${check.readPattern}' has no {1,2} mate group, so sample IDs cannot be derived"
            log_message "Give both mates in one pattern, e.g. '*_R{1,2}.fq.gz'"
            log_message "METADATA SAMPLE MATCH: FAIL"
            STATUS="FAIL"
        elif [ "${mateSeparated}" != "true" ]; then
            sample_ids=""
            log_message "readPattern '${check.readPattern}' runs the mate token straight onto the sample name"
            log_message "Sample IDs would be ambiguous: 'Sample11' and 'Sample12' read equally well as"
            log_message "one sample's two mates or as two separate samples."
            log_message "Separate the mate token with '_', '.' or '-', e.g. '*_R{1,2}.fq.gz' or '*_{1,2}.fq.gz'"
            log_message "METADATA SAMPLE MATCH: FAIL"
            STATUS="FAIL"
        else
            sample_ids=\$(find ${dataDir} ${readPattern} | while read -r fq; do
                base=\$(basename "\$fq")
                ${stripMate}
                echo "\$base"
            done | sort -u)

            MATCHED="yes"
            # Reads with no row: a hard failure. Step 4 would have no read group to write.
            for sample in \$sample_ids; do
                if ! grep -qxF "\$sample" metadata_ids.txt; then
                    log_message "Sample '\$sample' has reads but no row in ${metadataFile}"
                    MATCHED="no"
                fi
            done
            if [ "\$MATCHED" = "no" ]; then
                log_message "METADATA SAMPLE MATCH: FAIL"
                STATUS="FAIL"
            else
                log_message "METADATA SAMPLE MATCH: PASS"
            fi

            # A row with no reads is the other direction, and it is NOT a failure: a table
            # kept ahead of the data is a reasonable thing to have. It is said out loud
            # because the row still counts - it is part of what decides whether two runs
            # share step 6 - and because it is usually a typo in a sample name.
            printf '%s\\n' \$sample_ids > read_ids.txt
            while IFS= read -r row_id; do
                [ -n "\$row_id" ] || continue
                if ! grep -qxF "\$row_id" read_ids.txt; then
                    log_message "NOTE: ${metadataFile} has a row for '\$row_id', which has no reads in ${dataDir}"
                fi
            done < metadata_ids.txt
        fi

        # WHICH ROWS BECOME ONE COLUMN. bcftools names VCF sample columns by SM, so rows that
        # share an RG_Sample are pooled - their reads merged and their depths added. Stated
        # before any compute is spent, because it changes what the numbers MEAN and nothing
        # downstream can tell you it was not what you wanted.
${poolBlock}

${adapterBlock}

        # Detect edits made after the file was already consumed. Step 4 bakes the read group
        # into each BAM, and the row order sets the sample column order of the VCF in step 6.
        # Neither is re-derived once its output exists, so an edit after that point leaves the
        # results describing a version of this file that is no longer on disk - silently,
        # because completed steps are skipped by looking for output files rather than by
        # checking what produced them.
        #
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

        # Every message about the baseline is written in this verb, so a dry run cannot
        # report having recorded something it did not write.
        RGVERB="Recording"
        if [ "\$DRY_RUN" = "true" ]; then RGVERB="Would record"; fi

        # A dry run never records a baseline. This is the only writer, so guarding it here
        # covers both branches that call it - and it is a guard rather than a caller-side
        # check because the two callers are the two branches where a preview is most tempting
        # to treat as a real run: nothing has consumed the file yet, so recording "costs
        # nothing". It costs the next real run its baseline.
        record_baseline() {
            if [ "\$DRY_RUN" = "true" ]; then return 0; fi
            mkdir -p "\$(dirname "${storedMeta}")"
            cp current_metadata.txt "${storedMeta}"
        }

        if [ "\$HAVE_BAMS" -eq 0 ] && [ "\$HAVE_VCF" -eq 0 ]; then
            # Nothing has consumed the file yet, so an edit costs nothing. Record it.
            record_baseline
            log_message "\$RGVERB the metadata baseline - nothing has consumed the file yet"
            log_message "METADATA CHANGE CHECK: PASS"
        elif [ ! -f "${storedMeta}" ]; then
            # Outputs from before this check existed. There is no baseline to compare
            # against and no way to reconstruct one, so adopt the current file and say so.
            record_baseline
            log_message "Cleaned BAMs exist but predate this check - no baseline to compare"
            log_message "\$RGVERB the current metadata as the baseline"
            log_message "Verify it still matches what is in the BAMs:"
            log_message "    ${check.samtools} view -H ${readyDir}/<sample>_ready.bam | grep '^@RG'"
            log_message "METADATA CHANGE CHECK: PASS"
        elif diff -q "${storedMeta}" current_metadata.txt > /dev/null 2>&1; then
            log_message "Sample metadata unchanged since the existing outputs were produced"
            log_message "METADATA CHANGE CHECK: PASS"
        elif [ "\$(sort "${storedMeta}")" = "\$(sort current_metadata.txt)" ]; then
            # Same rows, different order. The read groups in the BAMs are matched by ID rather
            # than by position, so they are untouched; only the VCF column order is wrong.
            if [ "\$HAVE_VCF" -eq 0 ]; then
                record_baseline
                log_message "Row order changed, but no VCF exists to have used it"
                log_message "\$RGVERB the new order as the baseline"
                log_message "METADATA CHANGE CHECK: PASS"
            else
                # Report this as two orderings - a line diff of a permutation shows the
                # same text as both removed and added, which reads as nonsense.
                id_list() { awk -F'\\t' '{ printf "%s%s", sep, \$1; sep=", " }' "\$1"; }
                log_message "Row order has CHANGED since the existing outputs were produced:"
                log_message ""
                log_message "  was  \$(id_list "${storedMeta}")"
                log_message "  now  \$(id_list current_metadata.txt)"
                log_message ""
                log_message "The read groups in the BAMs are matched by ID and are still correct,"
                log_message "but the VCF sample column order is not."
                log_message "Delete these and run again to apply it:"
${orderDeleteBlock}
                log_message "Or discard the whole analysis and start over:  ./PoolSeqFlow reset"
                log_message "METADATA CHANGE CHECK: FAIL"
                STATUS="FAIL"
            fi
        else
            log_message "Sample metadata has CHANGED since the existing outputs were produced:"
            log_message ""
            while IFS= read -r line; do
                case "\$line" in
                    '<'*) printf '  was  %s\\n' "\${line#< }" | tee -a \$REPORTFILE ;;
                    '>'*) printf '  now  %s\\n' "\${line#> }" | tee -a \$REPORTFILE ;;
                esac
            done < <(diff "${storedMeta}" current_metadata.txt | grep -E '^[<>]')
            log_message ""
            log_message "Read group or adapter values changed. Every BAM in"
            log_message "    ${readyDir}"
            log_message "carries the old ones, and everything called from them carries them too."
            log_message "Columns you added of your own are not compared, so this is a change to"
            log_message "something the pipeline acted on."
            log_message "Delete these and run again to apply it:"
${tagDeleteBlock}
            log_message "Or discard the whole analysis and start over:  ./PoolSeqFlow reset"
            log_message "METADATA CHANGE CHECK: FAIL"
            STATUS="FAIL"
        fi
    fi

    log_message "METADATA VERIFICATION:  STATUS=\$STATUS"
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
    dir_log = "${params.dir.allLogs}/0_verify_environment"
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
    dir_log = checkLogDir(check)
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
    dir_log = checkLogDir(check)
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

// THE REPRODUCIBILITY GUARD, and it is ONE task for the whole project.
//
// Z, 2026-08-28: *"Copy the parameters.config and multirun.csv to .parameters.config and
// .multirun.csv, if they don't exist it is the first run, if they exist they can be compared in
// terms of what they contain."* And the rule those copies enforce: *"the parameter file being
// the same with what it was in the beginning and the parameters that are set for each run being
// kept as they are."*
//
// TWO INPUTS, COMPARED THE WAY EACH ONE HAS TO BE.
//
//   .multirun.csv     compared AS WRITTEN. It is the user's own file, nothing in a release
//                     touches it, and by settled rule 7 every column is a deliberate
//                     divergence - so any edit to it is a change to the run set, full stop.
//                     This is also what makes a REGROUPING visible: `Shared_<N>` numbers are
//                     assigned in order of appearance, so an edited table can leave `Shared_1`
//                     naming a different pair than the one whose results are in it, and the
//                     table copy sees that directly instead of inferring it from a member list.
//
//   .parameters.config  compared BY RESOLVED VALUE, because it also carries settings that
//                     cannot change a number - mainDir, storageDir, threads, memory, cores.*,
//                     software.*, java.* (Z, 2026-08-28: "Ignore resources and paths"). Moving
//                     a project to another disk or running it on a bigger node must not
//                     invalidate finished results. That is exactly what analysisParams()
//                     excludes, so the comparison runs on its output; the raw file is stored
//                     beside it as the record of what was actually written.
//
// The two together freeze every run's effective configuration: the base from the config, the
// per-run overrides from the table. That is why this needs no per-run task and no per-directory
// manifest - both of which it replaces.
//
// THE VERSION IS A BLOCK OF ITS OWN, checked first and short-circuiting everything else. Z,
// 2026-08-28: *"Nobody should ever resume to a pipeline using a different version. That needs a
// block on its own. Reset and re-run."* This REVERSES the old rule, under which a version was
// recorded and never enforced - so a project can no longer span two releases, and the whole
// added-by-a-release classification that existed to let it is gone with it.
process CheckRunParameters {
    input:
    // The base configuration's analysis parameters, already flattened. Rendered while the DAG
    // is built, like the sharing report - `params` is fully resolved by then, and doing it here
    // would mean a process reading the global configuration instead of being handed it.
    val manifest

    output:
    path 'verify_environment_stage7.txt', emit: report

    script:
    root        = "${params.storageDir}/Output"
    version     = "${root}/.poolseqflow_version"
    stored      = "${root}/.poolseqflow_params"
    storedCfg   = "${root}/.parameters.config"
    storedTable = "${root}/.multirun.csv"
    readable    = "${root}/run_parameters.txt"
    // Where the two files actually are. parameters.config is read from the directory the run
    // was launched in (nextflow.config: includeConfig "${launchDir}/parameters.config"), which
    // is not necessarily mainDir; the table is a parameter like any other.
    liveCfg     = "${workflow.launchDir}/parameters.config"
    liveTable   = params.multiRun ? "${params.multiRunPath}" : ''
    release     = workflow.manifest.version ?: 'unknown'
    """
    REPORTFILE="verify_environment.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    cat <<'CURRENT_PARAMS' > current_params.txt
${manifest}
CURRENT_PARAMS

    STATUS="PASS"

    # A DRY RUN RECORDS NOTHING. Every comparison below is made exactly as it would be in a
    # real run and gives exactly the same answer; what does not happen is the writing of the
    # files that answer it next time. A preview that left a baseline behind would have the
    # next real run comparing against parameters no result was ever produced under - which is
    # the one thing a preview must not be able to do.
    DRY_RUN="${params.dryRun}"
    RECORD="Recording"
    if [ "\$DRY_RUN" = "true" ]; then
        RECORD="Would record"
        log_message "RUN PARAMETERS:        DRY RUN - everything is checked, nothing is recorded"
    fi

    # THE VERSION, FIRST AND ON ITS OWN. Completed steps are skipped by looking for output
    # files, so continuing into a different release would mix results produced by two versions
    # of the code with nothing on disk to say which is which. Nothing else is compared when
    # this fires: the parameter set moves between releases, and reporting that as an edit to
    # your own config on top of this would be two wrong messages instead of one right one.
    if [ ! -f "${version}" ]; then
        if [ "\$DRY_RUN" != "true" ]; then
            mkdir -p "${root}"
            printf '%s\\t%s\\n' "${release}" "\$(date -u '+%Y-%m-%d')" > "${version}"
        fi
        log_message "PIPELINE VERSION:      ${release} - first run in this project"
    elif [ "\$(cut -f1 < "${version}")" != "${release}" ]; then
        log_message "PIPELINE VERSION:      These results were produced by \$(cut -f1 < "${version}"),"
        log_message "PIPELINE VERSION:      and this is ${release}."
        log_message "PIPELINE VERSION:"
        log_message "PIPELINE VERSION:      Completed steps are skipped by looking for output files, not by"
        log_message "PIPELINE VERSION:      checking what produced them, so continuing would leave one set of"
        log_message "PIPELINE VERSION:      results built by two versions of the pipeline with nothing on disk"
        log_message "PIPELINE VERSION:      to say which is which. A project belongs to one release."
        log_message "PIPELINE VERSION:"
        log_message "PIPELINE VERSION:      Start it again under this one:  ./PoolSeqFlow reset"
        log_message "PIPELINE VERSION:      Or run the release that made them; ./PoolSeqFlow version tells"
        log_message "PIPELINE VERSION:      you what is installed now."
        log_message "PIPELINE VERSION:      STATUS=FAIL"
        log_message "RUN PARAMETER CHECK:   STATUS=FAIL"
        mv \$REPORTFILE verify_environment_stage7.txt
        mkdir -p ${params.dir.allLogs}/0_verify_environment
        {
            echo ""
            echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
            cat .command.log
        } >> ${params.dir.allLogs}/0_verify_environment/0_VerifyEnvironment_s7_CheckRunParameters_nextflow.log
        exit 0
    else
        log_message "PIPELINE VERSION:      ${release}"
    fi

    # THE MULTI-RUN TABLE, AS WRITTEN. Line endings and trailing blanks are normalised, and
    # nothing else: row order decides which group gets which Shared_<N> name, and a comment is
    # a thing a user writes on purpose.
    if [ -n "${liveTable}" ]; then
        sed -e 's/\\r\$//' -e 's/[[:space:]]*\$//' -e '/^\$/d' "${liveTable}" > current_table.csv
        if [ ! -f "${storedTable}" ]; then
            if [ "\$DRY_RUN" != "true" ]; then
                mkdir -p "${root}"
                cp current_table.csv "${storedTable}"
            fi
            log_message "RUN PARAMETERS:        No previous run recorded - this is a fresh project"
            log_message "RUN PARAMETERS:        \$RECORD ${params.multiRunFile} as \$(( \$(wc -l < current_table.csv) - 1 )) run(s)"
        elif diff -q "${storedTable}" current_table.csv > /dev/null 2>&1; then
            log_message "RUN PARAMETERS:        ${params.multiRunFile} unchanged since the outputs were produced"
        else
            log_message "RUN PARAMETERS:        ${params.multiRunFile} has CHANGED since the outputs were produced:"
            log_message ""
            while IFS= read -r line; do
                case "\$line" in
                    '<'*) printf '  was  %s\\n' "\${line#< }" | tee -a \$REPORTFILE ;;
                    '>'*) printf '  now  %s\\n' "\${line#> }" | tee -a \$REPORTFILE ;;
                esac
            done < <(diff "${storedTable}" current_table.csv | grep -E '^[<>]')
            log_message ""
            log_message "RUN PARAMETERS:        Every cell of that table is a setting some run was analysed"
            log_message "RUN PARAMETERS:        under, and which runs share a results directory is decided by"
            log_message "RUN PARAMETERS:        it - so an edit can also move work between directories that"
            log_message "RUN PARAMETERS:        already hold results. Adding a run counts: it can regroup the"
            log_message "RUN PARAMETERS:        ones already there."
            log_message "RUN PARAMETERS:"
            log_message "RUN PARAMETERS:        Restore the table, or start a fresh run:"
            log_message "RUN PARAMETERS:            ./PoolSeqFlow reset"
            STATUS="FAIL"
        fi
    fi

    # parameters.config, by resolved value rather than as written - see the note above this
    # process for which families are excluded and why.
    if [ ! -f "${stored}" ]; then
        if [ "\$DRY_RUN" != "true" ]; then
            mkdir -p "${root}"
            cp current_params.txt "${stored}"
        fi
        log_message "RUN PARAMETERS:        \$RECORD \$(wc -l < current_params.txt) analysis parameters"
    elif diff -q "${stored}" current_params.txt > /dev/null 2>&1; then
        log_message "RUN PARAMETERS:        parameters.config unchanged since the outputs were produced"
    else
        # The classification is only about how the difference READS now. Every kind of it fails:
        # the one case that used to be forgiven - a parameter a release introduced - cannot
        # happen any more, because a release change is blocked above before this runs.
        classify_manifest.sh "${stored}" current_params.txt > param_diff.txt

        N_MALFORMED=\$(awk -F'\\t' '\$1 == "COUNTS" { print \$5 }' param_diff.txt)
        if [ "\${N_MALFORMED:-0}" -gt 0 ]; then
            log_message "RUN PARAMETERS:        \$N_MALFORMED unparseable line(s) in the stored manifest:"
            while IFS=\$'\\t' read -r kind line which _rest; do
                [ "\$kind" = "MALFORMED" ] || continue
                printf '  %-8s %s\\n' "\$which" "\$line" | tee -a \$REPORTFILE
            done < param_diff.txt
            log_message "RUN PARAMETERS:        ${stored} is written by the pipeline and should not be"
            log_message "RUN PARAMETERS:        edited by hand. Restore it, or start a fresh run."
        fi

        log_message "RUN PARAMETERS:        parameters.config has CHANGED since the outputs were produced:"
        log_message ""
        while IFS=\$'\\t' read -r kind key was now; do
            case "\$kind" in
                CHANGED) printf '  %s\\n      was  %s\\n      now  %s\\n' "\$key" "\$was" "\$now" | tee -a \$REPORTFILE ;;
                ADDED)   printf '  added    %s = %s\\n' "\$key" "\$now" | tee -a \$REPORTFILE ;;
                REMOVED) printf '  removed  %s (was %s)\\n' "\$key" "\$was" | tee -a \$REPORTFILE ;;
            esac
        done < param_diff.txt
        log_message ""
        log_message "RUN PARAMETERS:        The pipeline skips completed steps by checking for output files,"
        log_message "RUN PARAMETERS:        not by checking which parameters produced them, so continuing"
        log_message "RUN PARAMETERS:        would mix old and new results."
        log_message "RUN PARAMETERS:"
        log_message "RUN PARAMETERS:        Where files live and how much of the machine to use are NOT"
        log_message "RUN PARAMETERS:        compared - mainDir, storageDir, threads, memory and the cores,"
        log_message "RUN PARAMETERS:        software and java blocks can all change freely. What is listed"
        log_message "RUN PARAMETERS:        above changes the numbers."
        log_message "RUN PARAMETERS:"
        log_message "RUN PARAMETERS:        Either restore the previous values, or start a fresh run:"
        log_message "RUN PARAMETERS:            ./PoolSeqFlow reset"
        STATUS="FAIL"
    fi

    # THE COPIES THEMSELVES, kept whether or not they are what is compared. They are the record
    # of what was actually written - comments, layout and all - which is what you would cite,
    # and what tells you months later why a value was what it was. Refreshed only on a clean
    # pass, so a failure leaves the originals for the diff above to keep reporting against.
    if [ "\$STATUS" = "PASS" ] && [ "\$DRY_RUN" = "true" ]; then
        log_message "RUN PARAMETERS:        Nothing was written - re-run without dryrun to record it"
    elif [ "\$STATUS" = "PASS" ]; then
        mkdir -p "${root}"
        cp current_params.txt "${stored}"
        cp "${liveCfg}" "${storedCfg}"
        if [ -n "${liveTable}" ]; then cp current_table.csv "${storedTable}"; fi

        rm -f "${readable}"
        {
            echo "# PoolSeqFlow ${release} - the configuration behind the results in ${root}"
            echo "# Generated \$(date -u '+%Y-%m-%d %H:%M:%S UTC') - read-only; edit parameters.config instead."
            echo "#"
            echo "# The files themselves are kept beside this one, exactly as written:"
            echo "#   .parameters.config"
            if [ -n "${liveTable}" ]; then echo "#   .multirun.csv"; fi
            echo "#"
            echo "# Below: the analysis-affecting parameters as the pipeline resolved them. Paths"
            echo "# and resources are absent on purpose - they cannot change a result."
            echo "#"
            cat current_params.txt
        } > "${readable}"
        chmod 444 "${readable}"
        log_message "RUN PARAMETERS:        Written to ${readable}"
    fi

    log_message "RUN PARAMETER CHECK:   STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage7.txt
    mkdir -p ${params.dir.allLogs}/0_verify_environment
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${params.dir.allLogs}/0_verify_environment/0_VerifyEnvironment_s7_CheckRunParameters_nextflow.log
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
    // this task exists - so what arrives is text and a list of directories, not the plan.
    tuple val(sharing_lines), val(conflict_lines), val(member_files)

    output:
    path 'verify_environment_stage9.txt', emit: report

    script:
    dir_log = "${params.dir.allLogs}/0_verify_environment"
    derived = derivedParameterNames().join(' ')
    known = knownParameterNames().join(' ')
    // Rendered as log_message calls rather than a heredoc so each line lands in the report and
    // on the console the same way every other line here does.
    sharing_block = sharing_lines.collect { line -> "        log_message \"${line}\"" }.join('\n')
    conflict_block = conflict_lines.isEmpty()
        ? '        :'
        : (conflict_lines.collect { line -> "        log_message \"${line}\"" } + ['        STATUS="FAIL"']).join('\n')
    // `mkdir -p` then write: the directory does not exist yet on a first run, and this is the
    // only thing that creates it before the analysis starts filling it.
    member_block = member_files.isEmpty()
        ? '        :'
        : member_files.collect { entry ->
              "        mkdir -p '${entry.dir}'\n" +
              "        printf '%s\\n' ${entry.members.collect { m -> "'${m}'" }.join(' ')} > '${entry.dir}/members.txt'"
          }.join('\n')
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

        # A members file inside each shared directory, so the grouping can be recovered from
        # the results themselves rather than only from this report. A RECORD, not a guard: what
        # stops an edited table from mixing two groupings in one directory is the stored copy of
        # the table itself, in stage 7 above.
${member_block}

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
          val(metadata_log), val(trim_log), val(directory_log)
    val software_log
    val runparam_log
    val multirun_log

    output:
    tuple val(run), path('0_verify_environment.txt')

    script:
    output_folder = "${run.dir.output.reports}"
    dir_log = "${run.dir.logs}/0_verify_environment"
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

    cat ${reference_log} ${gffFile_log} ${dataSource_log} ${metadata_log} ${software_log} ${trim_log} ${runparam_log} ${directory_log} ${multirun_log} | tee -a \$REPORTFILE
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
    // ONE task for the whole project, like the software and multi-run stages: it compares the
    // two files the user wrote, not anything a run resolved for itself.
    CheckRunParameters(channel.value(analysisParams(params).join('\n')))

    // The metadata check, one task per step-6 variant. It needs one thing matched onto it
    // rather than computed - this group's CheckData verdict - and nothing else: the file has
    // already been parsed, and the rows travel in the run map.
    //
    // The repair stage that used to sit here is gone. It existed because three consumers read
    // the raw bytes, and none of them does now; a dedicated stage that rewrote a file the user
    // wrote was the price of that, and there is nothing left to pay it for.
    CheckMetadataFile(
        context.flatMap { ctx -> metadataChecks(ctx.plan) }
            .map { item -> tuple(item.dataKey, item) }
            .combine(CheckData.out.report.map { check, report -> tuple(check.checkKey, report) }, by: 0)
            .map { _key, item, verify -> tuple(item, verify) })

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
    metadata_by_run = context
        .flatMap { ctx -> ctx.runs.collect { run -> tuple(variantForRun(ctx.plan, run, 6).variantKey, run) } }
        .combine(CheckMetadataFile.out.report.map { check, report -> tuple(check.checkKey, report) }, by: 0)
        .map { _key, run, report -> tuple(run, report) }
    VerifyAll(
        reportPerRun(runs, CheckReference.out.report, 'CheckReference')
            .join(gff_by_run, by: 0)
            .join(data_by_run, by: 0)
            .join(metadata_by_run, by: 0)
            .join(reportPerRun(runs, CheckTrimParameters.out.report, 'CheckTrimParameters'), by: 0)
            .join(reportPerRun(runs, CheckDirectories.out.report, 'CheckDirectories'), by: 0),
        CheckInstalledSoftware.out.report,
        CheckRunParameters.out.report,
        CheckMultiRun.out.report)

    emit:
    VerifyAll.out
}
