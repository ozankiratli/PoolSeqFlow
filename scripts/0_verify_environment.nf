include { derivedParameterNames } from './resolve_parameters.nf'
include { knownParameterNames } from './resolve_parameters.nf'
include { dig; deepCopyVariant; runToken } from './variants.nf'
include { sharingGroups; parentVariant; childVariants; variantForRun } from './variants.nf'
include { metadataGuardLines; samplesWithAdapterOverrides; trimOptionsArePinned;
          poolSizes; poolSizeColumn } from './metadata.nf'

// Flatten the nested params map into dotted keys (dir.output.report.align and so on).
def flattenParams(Map m, String prefix, Map out) {
    m.each { k, v ->
        String key = prefix ? "${prefix}.${k}" : "${k}"
        if (v instanceof Map) flattenParams(v, key, out)
        else out[key] = v
    }
    return out
}

// The parameters that decide what the numbers are, as `key=value` lines. Takes a run's own
// effective parameters, never the global `params`.
def analysisParams(Map p) {
    // Excluded: paths, resources, tool locations, and the parsed metadata, which has its own
    // guard. Everything not named here counts as analysis-affecting.
    //
    // capBAM.histogramMax bounds how deep step 5 looks, not what it decides: samtools reports
    // only the depths that occur, and a run whose histogram is truncated stops, so every value
    // the run completes at yields the same histogram and the same ceiling.
    def skipKey = [
        'mainDir', 'storageDir', 'runId', 'dryRun', 'dryRunDir',
        'metadata',
        'referencePath', 'gffPath', 'metadataPath', 'multiRunPath', 'referenceFa', 'reference', 'gff', 'reads',
        'threads', 'memory',
        'capBAM.histogramMax'
    ] as Set
    def skipPrefix = ['dir.', 'cores.', 'java.', 'software.']
    return flattenParams(p, '', [:])
        .findAll { k, _v -> !skipKey.contains(k) && !skipPrefix.any { prefix -> k.startsWith(prefix) } }
        .collect { k, v -> "${k}=${v}".toString() }
        .sort()
}

// Turns a readPattern into a find(1) expression matching both mates, one -name per alternative.
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

// What each check reads, and therefore how many times it runs: once per distinct value, with the
// verdict handed back to every run sharing it. Dotted paths into a run's own parameters.
def checkParameterMap() {
    return [
        // One check per file, however many runs name it.
        CheckReference     : ['referencePath'],
        CheckGFF           : ['gffPath'],
        // Reads nothing: its report is two fixed lines.
        SkipGFFCheck       : [],
        CheckData          : ['dir.data', 'dataSource', 'readPattern'],
        CheckTrimParameters: ['trim_galore.autodetect', 'trim_galore.adapter1',
                              'trim_galore.adapter2'],
        CheckDirectories   : ['mainDir', 'storageDir'],
    ]
}

// The key two runs must share to share a check. The storage root is part of it.
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

// Where a step-0 stage writes its log: invocation level. VerifyAll is the exception and is per
// run.
def checkLogDir(Map check) {
    def root = params.multiRun ? "${check.storageDir}/Logs/All_Runs" : "${check.storageDir}/Logs"
    return "${root}/0_verify_environment".toString()
}

// One log file per stage, named after the runs it answered for. One writer per file.
def checkLogFile(Map check, String stage) {
    def token = check.runId == null ? '' : "_${check.members.collect { m -> runToken(m) }.join('+')}"
    return "0_VerifyEnvironment_${stage}${token}_nextflow.log".toString()
}

// A check's verdict, handed back to every run it answers for.
def reportPerRun(Object runs, Object reports, String check) {
    return runs
        .map { run -> tuple(checkKey(run, check), run) }
        .combine(reports.map { item, report -> tuple(item.checkKey, report) }, by: 0)
        .map { _key, run, report -> tuple(run, report) }
}

// The metadata change guard: has the file been edited since the read groups step 4 baked into
// each BAM, and the row order step 6 turned into the VCF's sample columns? One per step-6 variant.
def metadataChecks(Map plan) {
    return plan.variants[6].collect { variant ->
        // The BAMs are step 4's, which is step 6's parent; the VCFs and tables are step 7's.
        def ready = parentVariant(plan, variant)
        def filtered = childVariants(plan, variant, 7)

        // What has to go for an edit to become the new baseline. Row order lives only in the
        // called VCF and what follows it; read group values live in the BAMs too.
        def orderDelete = ([variant.dir.output.vcf] +
                           filtered.collect { child -> child.dir.output.vcf } +
                           filtered.collect { child -> child.dir.output.freq })
                          .collect { d -> d.toString() }.unique()

        // Which rows merge into one column: rows sharing an RG_Sample are one pool.
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
                // The CheckData task whose verdict this stage reads; every member shares it.
                dataKey     : checkKey(variant, 'CheckData'),
                metadataPath: "${variant.metadataPath}".toString(),
                sampleIds   : variant.metadata.collect { row -> "${row.SampleID}".toString() },
                pooled      : pools.findAll { _pool, ids -> ids.size() > 1 }
                                   .collect { pool, ids -> [pool: pool, ids: ids.sort()] }
                                   .sort { a, b -> a.pool <=> b.pool },
                // Only the pools that set param_poolSize.
                poolOverrides: variant.metadata
                                   .findAll { row -> row[poolSizeColumn()] }
                                   .collect { row -> "${row.RG_Sample}".toString() }
                                   .unique()
                                   .sort()
                                   .collect { pool -> [pool: pool, size: poolSizes(variant)[pool]] },
                globalPoolSize: "${variant.poolSize}".toString(),
                // What the guard compares: read groups and the columns that change a number.
                guardLines  : metadataGuardLines(variant),
                adapterOverrides: samplesWithAdapterOverrides(variant),
                optionsPinned: trimOptionsArePinned(variant),
                dataDir     : "${variant.dir.data}".toString(),
                readPattern : "${variant.readPattern}".toString(),
                samtools    : "${variant.software.samtools}".toString(),
                storedMeta  : "${variant.dir.outputs}/.poolseqflow_metadata".toString(),
                readyOut    : "${ready.dir.output.ready}".toString(),
                readyWork   : "${ready.dir.utilized}/${ready.dir.subpath.ready}".toString(),
                vcfOut      : "${variant.dir.output.vcf}".toString(),
                vcfWork     : "${variant.dir.utilized}/${variant.dir.subpath.vcf}".toString(),
                orderDelete : orderDelete,
                // A pool size change invalidates only what step 7 derived.
                sizeDelete  : (filtered.collect { child -> child.dir.output.freq } +
                               filtered.collect { child ->
                                   "${child.dir.utilized}/${child.dir.subpath.vcf}" })
                              .collect { d -> d.toString() }.unique(),
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

// The sample metadata, checked against the project: whether the reads and the rows describe the
// same samples, which rows merge into one pool, how big each pool is, and whether the file has
// been edited since the results that absorbed it were produced. Everything that is a property of
// the FILE alone belongs to bin/parse_metadata.py and has already run.
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
    // A sample ID is the part of a FASTQ name before the mate token, which comes from
    // readPattern, as step 2's own Channel.fromFilePairs derives it.
    mateBrace = check.readPattern.indexOf('{')
    mateClose = check.readPattern.indexOf('}')
    hasMateGroup = mateBrace >= 0 && mateClose > mateBrace
    matePrefix = hasMateGroup ? check.readPattern.substring(0, mateBrace).replaceAll(/^.*\*/, '') : ''
    mateTail = hasMateGroup ? check.readPattern.substring(mateClose + 1) : ''
    mateAlts = hasMateGroup ? check.readPattern.substring(mateBrace + 1, mateClose).split(',').collect { alt -> alt.trim() } : []

    // The mate token must be separated from the sample name: Sample11/Sample12 read equally as
    // one sample's two mates and as two samples.
    mateSeparators = ['_', '.', '-']
    mateSeparated = hasMateGroup && mateAlts.every { alt ->
        mateSeparators.any { sep -> (matePrefix + alt).startsWith(sep) }
    }

    // Strips the exact text the pattern says follows the sample name, one alternative at a time.
    stripMate = mateAlts.collect { alt -> 'base="${base%' + matePrefix + alt + mateTail + '}"' }.join('; ')
    storedMeta = check.storedMeta
    // Where the producing variant left them: both volumes for the BAMs, both for the VCF.
    readyDirOut = check.readyOut
    readyDirWork = check.readyWork
    vcfDirOut = check.vcfOut
    vcfDirWork = check.vcfWork
    readyDir = check.readyOut
    // What has to be deleted for an edit to take effect, one log_message call per directory.
    tagDeleteBlock = check.tagDelete.collect { d -> "        log_message \"    ${d}\"" }.join('\n')
    orderDeleteBlock = check.orderDelete.collect { d -> "                log_message \"    ${d}\"" }.join('\n')
    sizeDeleteBlock = check.sizeDelete.collect { d -> "            log_message \"    ${d}\"" }.join('\n')
    sizeColumn = poolSizeColumn()
    guardBlock = check.guardLines.join('\n')
    idsBlock = check.sampleIds.join('\n')
    poolBlock = check.pooled.isEmpty()
        ? '    log_message "METADATA CHECK:        every sample is its own pool"'
        : check.pooled.collect { entry ->
              "    log_message \"METADATA CHECK:        ${entry.pool} is one column, pooling ${entry.ids.join(', ')}\"" }.join('\n')
    sizeBlock = check.poolOverrides.isEmpty()
        ? "    log_message \"METADATA CHECK:        every pool is ${check.globalPoolSize} individuals, from parameters.config\""
        : (["    log_message \"METADATA CHECK:        pools sized in the metadata file, the rest ${check.globalPoolSize}:\""] +
           check.poolOverrides.collect { entry ->
               "    log_message \"METADATA CHECK:            ${entry.pool} is ${entry.size} individuals\"" }).join('\n')
    // The one combination a per-sample adapter cannot be honoured in.
    adapterBlock = (check.optionsPinned && !check.adapterOverrides.isEmpty())
        ? (['    log_message "METADATA CHECK:        these samples set param_adapter1/param_adapter2, but this run pins"',
            '    log_message "METADATA CHECK:        trim_galore.options outright, so the pinned string is used"',
            '    log_message "METADATA CHECK:        verbatim and the per-sample adapters could not be applied:"'] +
           check.adapterOverrides.collect { id -> "    log_message \"METADATA CHECK:            ${id}\"" } +
           ['    log_message "METADATA CHECK:        Remove the pin, or remove the adapter columns."',
            '    STATUS="FAIL"']).join('\n')
        : '    :'
    dir_log = checkLogDir(check)
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

    # The guard's projection of the rows, not the file itself.
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

        # The reads and the rows must describe the same samples.
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
            # Reads with no row: a hard failure.
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

            # A row with no reads is reported but not a failure.
            printf '%s\\n' \$sample_ids > read_ids.txt
            while IFS= read -r row_id; do
                [ -n "\$row_id" ] || continue
                if ! grep -qxF "\$row_id" read_ids.txt; then
                    log_message "NOTE: ${metadataFile} has a row for '\$row_id', which has no reads in ${dataDir}"
                fi
            done < metadata_ids.txt
        fi

        # Which rows become one column: rows sharing an RG_Sample are pooled.
${poolBlock}

        # And how many individuals each column stands for.
${sizeBlock}

${adapterBlock}

        # Detect edits made after the file was already consumed.
        any_exists() {
            for f in "\$@"; do
                [ -e "\$f" ] && return 0
            done
            return 1
        }
        HAVE_BAMS=0; any_exists ${readyDirOut}/*_ready.bam ${readyDirWork}/*_ready.bam && HAVE_BAMS=1
        HAVE_VCF=0;  any_exists ${vcfDirOut}/*.vcf ${vcfDirOut}/*.vcf.gz \\
                                ${vcfDirWork}/*.vcf ${vcfDirWork}/*.vcf.gz && HAVE_VCF=1

        # Every message about the baseline uses this verb.
        RGVERB="Recording"
        if [ "\$DRY_RUN" = "true" ]; then RGVERB="Would record"; fi

        # The only writer of the baseline, and where the dry-run guard sits.
        record_baseline() {
            if [ "\$DRY_RUN" = "true" ]; then return 0; fi
            mkdir -p "\$(dirname "${storedMeta}")"
            cp current_metadata.txt "${storedMeta}"
        }

        # A guard line with the pool size field removed.
        drop_size() {
            awk -F'\\t' -v OFS='\\t' '{
                out = \$1
                for (i = 2; i <= NF; i++) if (\$i !~ /^${sizeColumn}=/) out = out OFS \$i
                print out
            }' "\$1"
        }

        if [ "\$HAVE_BAMS" -eq 0 ] && [ "\$HAVE_VCF" -eq 0 ]; then
            record_baseline
            log_message "\$RGVERB the metadata baseline - nothing has consumed the file yet"
            log_message "METADATA CHANGE CHECK: PASS"
        elif [ ! -f "${storedMeta}" ]; then
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
            # Same rows, different order.
            if [ "\$HAVE_VCF" -eq 0 ]; then
                record_baseline
                log_message "Row order changed, but no VCF exists to have used it"
                log_message "\$RGVERB the new order as the baseline"
                log_message "METADATA CHANGE CHECK: PASS"
            else
                # Reported as two orderings.
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
        elif [ "\$(drop_size "${storedMeta}")" = "\$(drop_size current_metadata.txt)" ]; then
            # Only the pool sizes moved, which is a step 7 parameter.
            log_message "Pool sizes have CHANGED since the existing outputs were produced:"
            log_message ""
            # Only the field that moved, per sample, matched by id.
            while IFS= read -r line; do
                printf '%s\\n' "\$line" | tee -a \$REPORTFILE
            done < <(awk -F'\\t' '
                function size(line,   n, f, i, v) {
                    n = split(line, f, "\\t"); v = ""
                    for (i = 2; i <= n; i++)
                        if (f[i] ~ /^${sizeColumn}=/) v = substr(f[i], index(f[i], "=") + 1)
                    return v == "" ? "the global poolSize" : v
                }
                NR == FNR { was[\$1] = size(\$0); next }
                {
                    now = size(\$0)
                    if (now != was[\$1])
                        printf "  %s  was %s, now %s\\n", \$1, was[\$1], now
                }' "${storedMeta}" current_metadata.txt)
            log_message ""
            log_message "A pool's size sets its detection limit, so this changes which variants"
            log_message "survive the filter. The BAMs and the called VCF are unaffected - they"
            log_message "are what the filter reads, not what it writes - so only step 7's own"
            log_message "output has to go."
            log_message "Delete these and run again to apply it:"
${sizeDeleteBlock}
            log_message "METADATA CHANGE CHECK: FAIL"
            STATUS="FAIL"
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

// Once per invocation, not once per run, and handed the UNION of every run's software settings.
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

// mainDir and storageDir must DIFFER, and neither may BE the installation. Compared as resolved
// paths. Containment is warned about, not refused.
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

    # -m resolves symlinks, '..' and trailing slashes without requiring the directory to exist.
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

    # parameters.config comes from the launch directory.
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

// The reproducibility guard: ONE task for the whole project, freezing every run's effective
// configuration. Two inputs, compared differently:
//
//   .multirun.csv       AS WRITTEN.
//   .parameters.config  BY RESOLVED VALUE, through analysisParams(). The file itself is stored
//                       beside it verbatim.
//
// The version is checked FIRST and short-circuits everything else.
process CheckRunParameters {
    input:
    // Rendered while the DAG is built, where `params` is fully resolved.
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
    // parameters.config comes from the LAUNCH directory; the multi-run table is a parameter.
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

    # A dry run makes every comparison below and writes none of the files that answer it.
    DRY_RUN="${params.dryRun}"
    RECORD="Recording"
    if [ "\$DRY_RUN" = "true" ]; then
        RECORD="Would record"
        log_message "RUN PARAMETERS:        DRY RUN - everything is checked, nothing is recorded"
    fi

    # The version, first and on its own.
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

    # The multi-run table, as written. Line endings and trailing blanks are normalised, nothing
    # else.
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

    # parameters.config, by resolved value rather than as written.
    if [ ! -f "${stored}" ]; then
        if [ "\$DRY_RUN" != "true" ]; then
            mkdir -p "${root}"
            cp current_params.txt "${stored}"
        fi
        log_message "RUN PARAMETERS:        \$RECORD \$(wc -l < current_params.txt) analysis parameters"
    elif diff -q "${stored}" current_params.txt > /dev/null 2>&1; then
        log_message "RUN PARAMETERS:        parameters.config unchanged since the outputs were produced"
    else
        # The classification only decides how the difference reads; every kind fails.
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

    # The copies themselves, comments and layout and all, refreshed only on a clean pass.
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

// Stage 9: the multi-run table, when there is one. The syntactic checks belong to
// bin/parse_multirun.py; what this adds needs the parameters - which columns name a value the
// pipeline computes for itself. Not the first gate: resolve_parameters.nf has already refused an
// unusable table, and the FAIL branches here are a backstop.
process CheckMultiRun {
    input:
    // The divergence analysis arrives already rendered: text and a list of directories, not the
    // plan.
    tuple val(sharing_lines), val(conflict_lines), val(member_files)

    output:
    path 'verify_environment_stage9.txt', emit: report

    script:
    dir_log = "${params.dir.allLogs}/0_verify_environment"
    derived = derivedParameterNames().join(' ')
    known = knownParameterNames().join(' ')
    sharing_block = sharing_lines.collect { line -> "        log_message \"${line}\"" }.join('\n')
    conflict_block = conflict_lines.isEmpty()
        ? '        :'
        : (conflict_lines.collect { line -> "        log_message \"${line}\"" } + ['        STATUS="FAIL"']).join('\n')
    // `mkdir -p` then write: on a first run this is what creates the directory.
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

        # Every RunID, and what each row actually sets, printed in full.
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
    # Where this run's OWN results go, from its own storageDir column when it has one.
    where = f'{run.get("storageDir", storage)}/Output/{run_id}'
    print(f"MULTI-RUN CHECK:       {run_id} -> {where}")
    varied = {k: v for k, v in run.items() if k not in ("RunID", "storageDir")}
    if varied:
        for key, value in sorted(varied.items()):
            print(f"MULTI-RUN CHECK:           {key} = {value}")
    else:
        print("MULTI-RUN CHECK:           (nothing differs from parameters.config)")

# The runs that set a storageDir of their own: reported, not refused.
detached = sorted({run["RunID"] for run in runs if "storageDir" in run})
if detached:
    print("MULTI-RUN CHECK:       these runs set a storageDir of their own:")
    for run_id in detached:
        print(f"MULTI-RUN CHECK:           {run_id}")
    print("MULTI-RUN CHECK:       Allowed, and worth being sure you meant it. Runs that share a")
    print("MULTI-RUN CHECK:       storageDir share one results tree, so work several of them agree")
    print("MULTI-RUN CHECK:       on is done once and filed under All_Runs or Shared_<N>. A run with")
    print("MULTI-RUN CHECK:       its own storageDir shares nothing and repeats every step alone.")

# A column naming a derived value is allowed and reported; the value then stops tracking what it
# was derived from. A column that is not a parameter at all is refused.
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

        # Where the runs diverge.
${sharing_block}

        # A members file inside each shared directory. A record, not a guard.
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
    // ONE TUPLE, joined on the run. The three invocation-level stages stay separate: they ride
    // value channels and broadcast to every task.
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

    # The report has to leave the task directory, which `cleanup = true` empties on success. Called
    # on both paths, and before the `exit 1`, so a failed verification is archived too.
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
    // The plan and the run list in ONE value channel; flatMap expands the pair into one item per
    // check task.
    context
    // Rendered at DAG-build time: what step 0 says about the grouping, and any publish-only
    // disagreement that makes a group impossible.
    sharing

    main:
    runs = context.flatMap { ctx -> ctx.runs }

    CheckReference(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckReference') })
    // `annotate` is per run: the two sides are filtered out of the run list before grouping, so
    // an empty side produces no task at all.
    CheckGFF(context.flatMap { ctx -> checkGroups(ctx.runs.findAll { run -> run.annotate }, 'CheckGFF') })
    SkipGFFCheck(context.flatMap { ctx -> checkGroups(ctx.runs.findAll { run -> !run.annotate }, 'SkipGFFCheck') })

    CheckData(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckData') })
    CheckTrimParameters(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckTrimParameters') })
    CheckDirectories(context.flatMap { ctx -> checkGroups(ctx.runs, 'CheckDirectories') })
    // One task for the whole project: the two files the user wrote.
    CheckRunParameters(channel.value(analysisParams(params).join('\n')))

    // One task per step-6 variant, with this group's CheckData verdict matched onto it.
    CheckMetadataFile(
        context.flatMap { ctx -> metadataChecks(ctx.plan) }
            .map { item -> tuple(item.dataKey, item) }
            .combine(CheckData.out.report.map { check, report -> tuple(check.checkKey, report) }, by: 0)
            .map { _key, item, verify -> tuple(item, verify) })

    // The two stages describing the invocation rather than a run; both emit value channels. The
    // software union is taken over the run list, in table order.
    CheckInstalledSoftware(context.map { ctx ->
        ctx.runs.collectMany { run -> run.software.values().collect { tool -> "${tool}".toString() } }
            .unique()
            .join(' ') })
    CheckMultiRun(sharing)

    // Every check's verdict, handed back to the runs it answered for.
    data_by_run = reportPerRun(runs, CheckData.out.report, 'CheckData')
    gff_by_run = reportPerRun(runs.filter { run -> run.annotate }, CheckGFF.out.report, 'CheckGFF')
        .mix(reportPerRun(runs.filter { run -> !run.annotate }, SkipGFFCheck.out.report, 'SkipGFFCheck'))
    // Keyed by the step-6 variant a run belongs to, not by a parameter list.
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
