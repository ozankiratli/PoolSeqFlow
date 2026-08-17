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
def analysisParams() {
    def skipKey = [
        'mainDir', 'projectDir', 'dataSource',
        'referencePath', 'gffPath', 'rgTagsPath', 'referenceFa', 'reference', 'gff', 'reads',
        'threads', 'memory'
    ] as Set
    def skipPrefix = ['dir.', 'cores.', 'java.', 'software.']
    return flattenParams(params, '', [:])
        .findAll { k, v -> !skipKey.contains(k) && !skipPrefix.any { p -> k.startsWith(p) } }
        .collect { k, v -> "${k}=${v}" }
        .sort()
        .join('\n')
}

process CheckReference {
    output:
    path 'verify_environment_stage1.txt', emit: report

    script:
    refIn = params.referencePath
    dir_log = "${params.dir.logs}/0_verify_environment/s1_CheckReference"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s1_CheckReference.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s1_CheckReference.err
    """
}

process CheckGFF {
    output:
    path 'verify_environment_stage2.txt', emit: report

    script:
    gffIn = params.gffPath
    dir_log = "${params.dir.logs}/0_verify_environment/s2_CheckGFF"

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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s2_CheckGFF.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s2_CheckGFF.err
    """
}

process SkipGFFCheck {
    output:
    path 'verify_environment_stage2.txt', emit: report

    script:
    dir_log = "${params.dir.logs}/0_verify_environment/s2_CheckGFF"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s2_SkipGFFCheck.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s2_SkipGFFCheck.err
    """
}

process CheckData {
    output:
    path 'verify_environment_stage3.txt', emit: report

    script:
    dataDir = params.dir.data
    dir_log = "${params.dir.logs}/0_verify_environment/s3_CheckData"
    read_pattern = params.readPattern.replace('{','[').replace('}',']')

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

        log_message "The data source is set to: ${params.dataSource}"

        # Check for FASTQ files
        FASTQ_COUNT=\$(find \$DATADIR -name ${read_pattern} | wc -l)
        if [ \$FASTQ_COUNT -eq 0 ]; then
            log_message "No FASTQ files found in data directory!"
            log_message "Expected pattern: ${read_pattern}"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s3_CheckData.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s3_CheckData.err
    """
}

process CheckRGTagsFile {
    input:
    val verify

    output:
    path 'verify_environment_stage4.txt', emit: report

    script:
    rgTagsFile = params.rgTagsPath
    dataDir = params.dir.data
    readPattern = params.readPattern.replace('{','[').replace('}',']')
    // A sample ID is the part of a FASTQ name that precedes the mate token. Take that
    // token from readPattern rather than assuming _R1/_R2: step 2 keys every sample off
    // Channel.fromFilePairs, which derives the prefix from the glob and accepts any
    // {1,2} scheme, so this check has to agree with it or it rejects valid layouts.
    mateBrace = params.readPattern.indexOf('{')
    mateClose = params.readPattern.indexOf('}')
    hasMateGroup = mateBrace >= 0 && mateClose > mateBrace
    matePrefix = hasMateGroup ? params.readPattern.substring(0, mateBrace).replaceAll(/^.*\*/, '') : ''
    mateTail = hasMateGroup ? params.readPattern.substring(mateClose + 1) : ''
    mateAlts = hasMateGroup ? params.readPattern.substring(mateBrace + 1, mateClose).split(',').collect { alt -> alt.trim() } : []

    // The mate token must be separated from the sample name. Without a separator the
    // split is guesswork: Sample11/Sample12 are equally readable as one sample's two
    // mates or as two different samples, so refuse rather than pick one.
    mateSeparated = hasMateGroup && mateAlts.every { alt ->
        (matePrefix + alt).startsWith('_') || (matePrefix + alt).startsWith('.')
    }

    // Strip the exact text the pattern says follows the sample name, one alternative at
    // a time. Literal, so it holds for non-numeric mates (_F/_R) too.
    stripMate = mateAlts.collect { alt -> 'base="${base%' + matePrefix + alt + mateTail + '}"' }.join('; ')
    storedRg = "${params.projectDir}/.poolseqflow_rgtags"
    readyDir = "${params.dir.output.ready}"
    vcfDir = "${params.dir.output.vcf}"
    freqDir = "${params.dir.output.freq}"
    dir_log = "${params.dir.logs}/0_verify_environment/s4_CheckRGTagsFile"

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

        # Repair Windows line endings in place. A file saved from Excel on Windows ends
        # every line with CR, which rides along into the last field of each row: the
        # header check below rejects 'PU\\r' as an invalid tag, and were it to get past
        # that, the CR would end up inside the RG tag written into the BAM. Neither
        # failure names the real cause, so fix it here and say so.
        #
        # Detection and repair use the same expression, so a file that is reported as
        # fixed really is fixed - a mismatch between the two would report it every run.
        if ! sed 's/\\r\$//' ${rgTagsFile} | cmp -s - ${rgTagsFile}; then
            # Rewrite the file's contents rather than replacing the file. 'sed -i' swaps
            # in a new inode and does not carry the mode across - it turned a 444 file
            # into a 644 one in testing, quietly making a deliberately read-only RGTags
            # file writable. Redirecting into the existing path keeps mode and ownership,
            # and fails honestly when the file really is not writable.
            if sed 's/\\r\$//' ${rgTagsFile} > rgtags_norm.tmp && [ -s rgtags_norm.tmp ] &&
               cat rgtags_norm.tmp > ${rgTagsFile} 2>/dev/null; then
                log_message "RGTags file had Windows (CRLF) line endings - repaired in place"
                log_message "RGTAGS LINE ENDING CHECK: FIXED"
            else
                log_message "RGTags file has Windows (CRLF) line endings and could not be rewritten"
                log_message "Convert it yourself with:"
                log_message "    sed -i 's/\\\\r\$//' ${rgTagsFile}"
                log_message "RGTAGS LINE ENDING CHECK: FAIL"
                STATUS="FAIL"
            fi
        else
            log_message "RGTAGS LINE ENDING CHECK: PASS"
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
                log_message "readPattern '${params.readPattern}' has no {1,2} mate group, so sample IDs cannot be derived"
                log_message "Give both mates in one pattern, e.g. '*_R{1,2}.fq.gz'"
                log_message "RGTAGS SAMPLE MATCH CHECK: FAIL"
                STATUS="FAIL"
            elif [ "${mateSeparated}" != "true" ]; then
                sample_ids=""
                log_message "readPattern '${params.readPattern}' runs the mate token straight onto the sample name"
                log_message "Sample IDs would be ambiguous: 'Sample11' and 'Sample12' read equally well as"
                log_message "one sample's two mates or as two separate samples."
                log_message "Separate the mate token with '_' or '.', e.g. '*_R{1,2}.fq.gz' or '*_{1,2}.fq.gz'"
                log_message "RGTAGS SAMPLE MATCH CHECK: FAIL"
                STATUS="FAIL"
            else
                sample_ids=\$(find ${dataDir} -name "${readPattern}" | while read -r fq; do
                    base=\$(basename "\$fq")
                    ${stripMate}
                    echo "\$base"
                done | sort -u)
            fi

            # Check all rows for empty values
            awk -F',' '
            NR > 1 {
                for (i=1; i<=NF; i++) {
                    if (length(\$i) == 0 || \$i ~ /^[[:space:]]*\$/) {
                        printf "Empty value found in row %d, column %d (%s)\\n", NR, i, header[i]
                        exit 1
                    }
                }
            }' ${rgTagsFile} || {
                log_message "Empty values found in RGTags file"
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
        HAVE_BAMS=0; any_exists ${readyDir}/*_ready.bam && HAVE_BAMS=1
        HAVE_VCF=0;  any_exists ${vcfDir}/*.vcf ${vcfDir}/*.vcf.gz && HAVE_VCF=1

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
            log_message "    ${params.software.samtools} view -H ${readyDir}/<sample>_ready.bam | grep '^@RG'"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s4_CheckRGTags.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s4_CheckRGTags.err
    """
}

process CheckInstalledSoftware {
    output:
    path 'verify_environment_stage5.txt', emit: report

    script:
    software_list = params.software.values().join(' ')
    dir_log = "${params.dir.logs}/0_verify_environment/s5_CheckInstalledSoftware"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s5_CheckInstalledSoftware.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s5_CheckInstalledSoftware.err
    """
}

process CheckTrimParameters {
    output:
    path 'verify_environment_stage6.txt', emit: report

    script:
    autodetect = params.trim_galore.autodetect
    adapter1   = params.trim_galore.adapter1
    adapter2   = params.trim_galore.adapter2
    dir_log = "${params.dir.logs}/0_verify_environment/s6_CheckTrimParameters"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s6_CheckTrimParameters.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s6_CheckTrimParameters.err
    """
}

process CheckRunParameters {
    output:
    path 'verify_environment_stage7.txt', emit: report

    script:
    manifest    = analysisParams()
    stored      = "${params.projectDir}/.poolseqflow_params"
    readable    = "${params.dir.outputs}/run_parameters.txt"
    versions    = "${params.projectDir}/.poolseqflow_versions"
    release     = workflow.manifest.version ?: 'unknown'
    dir_log     = "${params.dir.logs}/0_verify_environment/s7_CheckRunParameters"
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
    if [ ! -f "${stored}" ]; then
        log_message "RUN PARAMETERS:        No previous run recorded - this is a fresh project"
        log_message "RUN PARAMETERS:        Recording \$(wc -l < current_params.txt) analysis parameters"
        mkdir -p "\$(dirname "${stored}")"
        cp current_params.txt "${stored}"
    elif diff -q "${stored}" current_params.txt > /dev/null 2>&1; then
        log_message "RUN PARAMETERS:        Unchanged since the outputs in ${params.dir.outputs} were produced"
    else
        log_message "RUN PARAMETERS:        CHANGED since the existing outputs were produced:"
        log_message ""
        # report each parameter that differs, old -> new
        while IFS= read -r line; do
            case "\$line" in
                '<'*) printf '  was  %s\\n' "\${line#< }" | tee -a \$REPORTFILE ;;
                '>'*) printf '  now  %s\\n' "\${line#> }" | tee -a \$REPORTFILE ;;
            esac
        done < <(diff "${stored}" current_params.txt | grep -E '^[<>]')
        log_message ""
        log_message "RUN PARAMETERS:        Existing outputs were produced with different settings."
        log_message "RUN PARAMETERS:        The pipeline skips completed steps by checking for output"
        log_message "RUN PARAMETERS:        files, not by checking which parameters produced them, so"
        log_message "RUN PARAMETERS:        continuing would mix old and new results."
        log_message "RUN PARAMETERS:"
        log_message "RUN PARAMETERS:        Either restore the previous values, or start a fresh run:"
        log_message "RUN PARAMETERS:            ./PoolSeqFlow reset"
        STATUS="FAIL"
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
            echo "# PoolSeqFlow analysis parameters for the outputs in ${params.dir.outputs}"
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
    cp .command.log ${dir_log}/0_VerifyEnvironment_s7_CheckRunParameters.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_s7_CheckRunParameters.err
    """
}

process VerifyAll {
    errorStrategy 'finish'

    input:
    val reference_log
    val gffFile_log
    val dataSource_log
    val rgtags_log
    val software_log
    val trim_log
    val runparam_log

    output:
    path '0_verify_environment.txt'

    script:
    output_folder = "${params.dir.output.reports}"
    dir_log = "${params.dir.logs}/0_verify_environment"
    """
    REPORTFILE="0_verify_environment.txt"
    
    # Function to write to both file and console
    log_message() {
        echo "\$1" >> \$REPORTFILE
        echo "\$1"
    }

    log_message "==================== ENVIRONMENT VERIFICATION REPORT ===================="
    log_message "Date: \$(date)"
    log_message "========================================================================="
    log_message ""

    cat ${reference_log} ${gffFile_log} ${dataSource_log} ${rgtags_log} ${software_log} ${trim_log} ${runparam_log} | tee -a \$REPORTFILE
    log_message ""
    log_message "========================================================================="

    CHECKFAIL=\$(grep "STATUS=FAIL" \$REPORTFILE | wc -l)
    if [ \$CHECKFAIL -gt 0 ]; then
        log_message "Environment verification failed with \$CHECKFAIL issues:"
        log_message ""
        grep "STATUS=FAIL" \$REPORTFILE | tee -a \$REPORTFILE
        log_message ""
        log_message "ENVIRONMENT VERIFICATION: FAILED"

        exit 1
    else
        log_message "All verification checks passed successfully."
        log_message ""
        log_message "ENVIRONMENT VERIFICATION: SUCCESS"
        
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/0_VerifyEnvironment_VerifyAll.log
    cp .command.err ${dir_log}/0_VerifyEnvironment_VerifyAll.err
    """
}

workflow VerifyEnvironment {
    main:
    CheckReference()
    //CheckGFF()
    if (params.annotate) {
        CheckGFF()
        gff_report = CheckGFF.out.report
    } else {
        SkipGFFCheck()
        gff_report = SkipGFFCheck.out.report
    }
    //gff_report = params.annotate ? CheckGFF.out.report : SkipGFFCheck.out.report
    CheckData()
    CheckRGTagsFile(CheckData.out.report)
    CheckInstalledSoftware()
    CheckTrimParameters()
    CheckRunParameters()
    VerifyAll(CheckReference.out.report, gff_report, CheckData.out.report, CheckRGTagsFile.out.report, CheckInstalledSoftware.out.report, CheckTrimParameters.out.report, CheckRunParameters.out.report)

    emit:
    report = VerifyAll.out
}
