include { derivedParameterNames } from './resolve_parameters.nf'
include { knownParameterNames } from './resolve_parameters.nf'

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
        .collect { k, v -> "${k}=${v}" }
        .sort()
        .join('\n')
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

process CheckReference {
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage1.txt'), emit: report

    script:
    refIn = run.referencePath
    dir_log = "${run.dir.logs}/0_verify_environment/s1_CheckReference"
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
    } >> ${dir_log}/0_VerifyEnvironment_s1_CheckReference_nextflow.log
    """
}

process CheckGFF {
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage2.txt'), emit: report

    script:
    gffIn = run.gffPath
    dir_log = "${run.dir.logs}/0_verify_environment/s2_CheckGFF"

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
    } >> ${dir_log}/0_VerifyEnvironment_s2_CheckGFF_nextflow.log
    """
}

process SkipGFFCheck {
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage2.txt'), emit: report

    script:
    dir_log = "${run.dir.logs}/0_verify_environment/s2_CheckGFF"
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
    } >> ${dir_log}/0_VerifyEnvironment_s2_SkipGFFCheck_nextflow.log
    """
}

process CheckData {
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage3.txt'), emit: report

    script:
    dataDir = run.dir.data
    dir_log = "${run.dir.logs}/0_verify_environment/s3_CheckData"
    read_pattern = findNameExpr("${run.readPattern}")

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

        log_message "The data source is set to: ${run.dataSource}"

        # Check for FASTQ files
        FASTQ_COUNT=\$(find \$DATADIR ${read_pattern} | wc -l)
        if [ \$FASTQ_COUNT -eq 0 ]; then
            log_message "No FASTQ files found in data directory!"
            log_message "Expected pattern: ${run.readPattern}"
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
    } >> ${dir_log}/0_VerifyEnvironment_s3_CheckData_nextflow.log
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
    tag { rgTagsPath }

    input:
    val rgTagsPath

    output:
    tuple val(rgTagsPath), path('rgtags_lineendings.txt'), emit: report

    script:
    dir_log = "${params.dir.allLogs}/0_verify_environment/s4_RepairRGTagsLineEndings"
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
    } >> ${dir_log}/0_VerifyEnvironment_s4_RepairRGTagsLineEndings_nextflow.log
    """
}

process CheckRGTagsFile {
    tag { run.runId ?: '-' }

    input:
    // `lineendings` is RepairRGTagsLineEndings' report for THIS run's table, matched on the
    // path rather than on arrival - one repair task may serve several runs.
    tuple val(run), val(verify), val(lineendings)

    output:
    tuple val(run), path('verify_environment_stage4.txt'), emit: report

    script:
    rgTagsFile = run.rgTagsPath
    dataDir = run.dir.data
    readPattern = findNameExpr(run.readPattern)
    // A sample ID is the part of a FASTQ name that precedes the mate token. Take that
    // token from readPattern rather than assuming _R1/_R2: step 2 keys every sample off
    // Channel.fromFilePairs, which derives the prefix from the glob and accepts any
    // {1,2} scheme, so this check has to agree with it or it rejects valid layouts.
    mateBrace = run.readPattern.indexOf('{')
    mateClose = run.readPattern.indexOf('}')
    hasMateGroup = mateBrace >= 0 && mateClose > mateBrace
    matePrefix = hasMateGroup ? run.readPattern.substring(0, mateBrace).replaceAll(/^.*\*/, '') : ''
    mateTail = hasMateGroup ? run.readPattern.substring(mateClose + 1) : ''
    mateAlts = hasMateGroup ? run.readPattern.substring(mateBrace + 1, mateClose).split(',').collect { alt -> alt.trim() } : []

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
    // Beside the results it describes, not at the storage root: the root is shared by every
    // run now, so three of them would race for one baseline and the last to write would decide
    // what the other two are compared against. Moving an existing project's manifests here is
    // config_migrate.sh's job, not a run's.
    storedRg = "${run.dir.outputs}/.poolseqflow_rgtags"
    // Both roots for the two that are promoted. This is not cosmetic: the branch below
    // treats "no BAMs and no VCF" as "nothing has consumed RGTags.csv yet" and RECORDS A
    // NEW BASELINE. Looking only at permanent storage would therefore, for a project whose
    // BAMs are written but not yet promoted, silently adopt an edited RGTags.csv as the
    // baseline for BAMs that carry the old tags - and no later run could detect it, because
    // the baseline now says they agree. Every other wrong existence answer in this pipeline
    // costs redundant work; this one costs the guard itself.
    //
    // The working roots come from the divergence analysis rather than from this run's own
    // dir.utilized, because they are not the same thing once a step is shared: the ready BAMs
    // are under the root of the variant that CLEANED them, which may serve several runs. A
    // probe that looked only here would answer 0 on every invocation and record a new baseline
    // every time - the guard would still report PASS and would have stopped guarding.
    readyDirOut = "${run.dir.output.ready}"
    readyDirWork = "${run.dir.probe.ready}"
    vcfDirOut = "${run.dir.output.vcf}"
    vcfDirWork = "${run.dir.probe.vcf}"
    // The frequency tables have no consumer, so they are never promoted and permanent
    // storage is the only place they can be.
    readyDir = "${run.dir.output.ready}"
    vcfDir = "${run.dir.output.vcf}"
    freqDir = "${run.dir.output.freq}"
    dir_log = "${run.dir.logs}/0_verify_environment/s4_CheckRGTagsFile"

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
        cat ${lineendings} | tee -a \$REPORTFILE
        if grep -q "RGTAGS LINE ENDING CHECK: FAIL" ${lineendings}; then
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
                log_message "readPattern '${run.readPattern}' has no {1,2} mate group, so sample IDs cannot be derived"
                log_message "Give both mates in one pattern, e.g. '*_R{1,2}.fq.gz'"
                log_message "RGTAGS SAMPLE MATCH CHECK: FAIL"
                STATUS="FAIL"
            elif [ "${mateSeparated}" != "true" ]; then
                sample_ids=""
                log_message "readPattern '${run.readPattern}' runs the mate token straight onto the sample name"
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
            log_message "    ${run.software.samtools} view -H ${readyDir}/<sample>_ready.bam | grep '^@RG'"
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
                log_message "    ${vcfDir}"
                log_message "    ${freqDir}"
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
            log_message "    ${readyDir}"
            log_message "    ${vcfDir}"
            log_message "    ${freqDir}"
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
    } >> ${dir_log}/0_VerifyEnvironment_s4_CheckRGTags_nextflow.log
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
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage6.txt'), emit: report

    script:
    autodetect = run.trim_galore.autodetect
    adapter1   = run.trim_galore.adapter1
    adapter2   = run.trim_galore.adapter2
    dir_log = "${run.dir.logs}/0_verify_environment/s6_CheckTrimParameters"
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
    } >> ${dir_log}/0_VerifyEnvironment_s6_CheckTrimParameters_nextflow.log
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
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage8.txt'), emit: report

    script:
    dir_log = "${run.dir.logs}/0_verify_environment/s8_CheckDirectories"
    """
    REPORTFILE="verify_environment.txt"

    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    STATUS="PASS"

    # -m resolves symlinks, '..' and trailing slashes without requiring the directory to
    # exist yet; mainDir need not be there before the first run creates work/ under it.
    MAIN=\$(realpath -m "${run.mainDir}")
    STORE=\$(realpath -m "${run.storageDir}")
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
    } >> ${dir_log}/0_VerifyEnvironment_s8_CheckDirectories_nextflow.log
    """
}

process CheckRunParameters {
    tag { run.runId ?: '-' }

    input:
    val run

    output:
    tuple val(run), path('verify_environment_stage7.txt'), emit: report

    script:
    manifest    = analysisParams(run)
    // Beside the results they describe, for the reason recorded in CheckRGTagsFile above.
    stored      = "${run.dir.outputs}/.poolseqflow_params"
    readable    = "${run.dir.outputs}/run_parameters.txt"
    versions    = "${run.dir.outputs}/.poolseqflow_versions"
    release     = workflow.manifest.version ?: 'unknown'
    dir_log     = "${run.dir.logs}/0_verify_environment/s7_CheckRunParameters"
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
    ADOPTED=0
    if [ ! -f "${stored}" ]; then
        log_message "RUN PARAMETERS:        No previous run recorded - this is a fresh project"
        log_message "RUN PARAMETERS:        Recording \$(wc -l < current_params.txt) analysis parameters"
        mkdir -p "\$(dirname "${stored}")"
        cp current_params.txt "${stored}"
    elif diff -q "${stored}" current_params.txt > /dev/null 2>&1; then
        log_message "RUN PARAMETERS:        Unchanged since the outputs in ${run.dir.outputs} were produced"
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
    if [ ! -f "${versions}" ]; then
        mkdir -p "\$(dirname "${versions}")"
        printf '%s\\t%s\\n' "${release}" "\$(date -u '+%Y-%m-%d')" > "${versions}"
        log_message "PIPELINE VERSION:      ${release} - first run in this project"
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
            echo "# PoolSeqFlow analysis parameters for the outputs in ${run.dir.outputs}"
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

    log_message "RUN PARAMETER CHECK:   STATUS=\$STATUS"

    mv \$REPORTFILE verify_environment_stage7.txt
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/0_VerifyEnvironment_s7_CheckRunParameters_nextflow.log
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
    dir_log = "${params.dir.allLogs}/0_verify_environment/s9_CheckMultiRun"
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
        # the results themselves rather than only from this report.
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
          val(rgtags_log), val(trim_log), val(runparam_log), val(directory_log)
    val software_log
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
    runs
    // The divergence analysis, rendered at DAG-build time: what step 0 should say about the
    // grouping, any publish-only disagreement that makes a group impossible, and the members
    // files to write. A value channel, because it describes the invocation rather than a run.
    sharing

    main:
    CheckReference(runs)
    // `annotate` is a per-run parameter, so which runs need a GFF is decided by filtering the
    // runs rather than by an `if` over the base config. Under multiRun one run may annotate
    // while another does not; the `if` this replaces could only answer for all of them.
    CheckGFF(runs.filter { run -> run.annotate })
    SkipGFFCheck(runs.filter { run -> !run.annotate })
    gff_report = CheckGFF.out.report.mix(SkipGFFCheck.out.report)

    CheckData(runs)

    // Every distinct RGTags table, repaired once. `unique` on the PATH, not on the run: the
    // usual case is N runs sharing one table, and repairing it N times concurrently is a race
    // on the user's own file.
    RepairRGTagsLineEndings(runs.map { run -> "${run.rgTagsPath}" }.unique())
    CheckRGTagsFile(
        CheckData.out.report
            .map { run, report -> tuple("${run.rgTagsPath}", run, report) }
            .combine(RepairRGTagsLineEndings.out.report, by: 0)
            .map { _path, run, report, lineendings -> tuple(run, report, lineendings) })

    CheckTrimParameters(runs)
    CheckRunParameters(runs)
    CheckDirectories(runs)

    // The two stages that describe the invocation rather than a run. Both emit value
    // channels, which is what lets one report reach every run's VerifyAll.
    //
    // collect(flat: false) keeps each run's list whole, so flatten() concatenates them in run
    // order and unique() then keeps the first appearance of each - which for a single run is
    // exactly params.software.values() in the order the config wrote them.
    CheckInstalledSoftware(
        runs.map { run -> run.software.values().collect { tool -> "${tool}" } }
            .collect(flat: false)
            .map { lists -> lists.flatten().unique().join(' ') })
    CheckMultiRun(sharing)

    VerifyAll(
        CheckReference.out.report
            .join(gff_report, by: 0)
            .join(CheckData.out.report, by: 0)
            .join(CheckRGTagsFile.out.report, by: 0)
            .join(CheckTrimParameters.out.report, by: 0)
            .join(CheckRunParameters.out.report, by: 0)
            .join(CheckDirectories.out.report, by: 0),
        CheckInstalledSoftware.out.report,
        CheckMultiRun.out.report)

    emit:
    VerifyAll.out
}
