include { deepCopy } from './resolve_parameters.nf'

// Which dictionary set a run uses: the paths step 1 writes, and nothing else.
def dictionaryKey(Map run) {
    return [run.dir.dictionaries, run.referenceFa, run.dir.snpEff, run.snpEff.db]
        .collect { part -> "${part}" }
        .join(' | ')
}

// What step 1 reads apart from those paths. Two runs landing on one key must agree on all of it.
def dictionarySettings(Map run) {
    return [
        'referenceFile'      : "${run.referenceFile}",
        'referencePath'      : "${run.referencePath}",
        'gffFile'            : "${run.gffFile}",
        'gffPath'            : "${run.gffPath}",
        'snpEff.buildOptions': "${run.snpEff.buildOptions}",
        'snpEff.config'      : "${run.snpEff.config}",
        'software.bwa'       : "${run.software.bwa}",
        'software.samtools'  : "${run.software.samtools}",
        'software.snpEff'    : "${run.software.snpEff}",
    ]
}

// One entry per distinct dictionary set, in the order the runs first ask for it.
def dictionaryRuns(List runs) {
    def groups = [:]
    runs.each { run ->
        def key = dictionaryKey(run)
        if (!groups.containsKey(key)) groups[key] = []
        groups[key] << run
    }

    return groups.collect { _key, members ->
        def first = members[0]
        def base = dictionarySettings(first)
        members.tail().each { other ->
            dictionarySettings(other).each { name, value ->
                if (value != base[name]) {
                    throw new IllegalStateException(
                        "multi-run: '${first.runId}' and '${other.runId}' build their dictionaries " +
                        "in the same place but disagree about ${name}:\n" +
                        "    ${first.runId}: ${base[name]}\n" +
                        "    ${other.runId}: ${value}\n" +
                        "Step 1 writes to ${first.dir.dictionaries}, which is on mainDir and shared " +
                        "between runs, so only one of these can be on disk at a time. Either give " +
                        "the two runs different reference files, or make them agree.")
                }
            }
        }

        def dict = deepCopy(first)
        // Logs at project level, not under any one run.
        dict.dir.logs = "${params.dir.allLogs}"
        // Built when ANY member wants it.
        dict.annotate = members.any { member -> member.annotate }
        return dict
    }
}

process UngzipReference {
    input:
    tuple val(run), val(verify)

    output:
    tuple val(run), path("${run.referenceFa}"), emit: reference

    script:
    refIn = run.referencePath
    refOut = run.reference
    dir_log = "${run.dir.logs}/1_build_dictionaries"

    """
    set -eo pipefail

    mkdir -p ${run.dir.dictionaries}

    echo "UNGZIP ${run.referenceFile}:             Start unzipping reference file..."
    if [ -f ${refOut} ]; then
        echo "UNGZIP ${run.referenceFile}:             Found existing unzipped reference file"
        echo "UNGZIP ${run.referenceFile}:             Found ${refOut}"
        echo "UNGZIP ${run.referenceFile}:             Creating symbolic link..."
        ln -s ${refOut} .
        echo "UNGZIP ${run.referenceFile}:             COMPLETED"
    else
        # Gzipped or not; the plain case is copied, not symlinked.
        if [[ "${refIn}" == *.gz ]]; then
            echo "UNGZIP ${run.referenceFile}:             Decompressing reference file..."
            gunzip -c ${refIn} > ${run.referenceFa}
        else
            echo "UNGZIP ${run.referenceFile}:             Reference is not compressed - copying it..."
            cp ${refIn} ${run.referenceFa}
        fi
        echo "UNGZIP ${run.referenceFile}:             Moving ${run.referenceFa} to ${run.dir.dictionaries}"
        atomic_mv.sh ${run.referenceFa} ${refOut}
        echo "UNGZIP ${run.referenceFile}:             Creating symbolic link..."
        ln -s ${refOut} .
        echo "UNGZIP ${run.referenceFile}:             COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/1_BuildDictionary_s1_UngzipReference_nextflow.log
    """
}

process CreateBwaIndex {
    input:
    tuple val(run), path(reference)

    output:
    tuple val(run), path("${run.referenceFa}.{bwt,ann,amb,pac,sa}"), emit: bwa_index

    script:
    referenceDir = run.dir.dictionaries
    dir_log = "${run.dir.logs}/1_build_dictionaries"

    """
    set -eo pipefail

    echo "BWA INDEX ${run.referenceFile}:          Start building BWA index..."
    # The exact five files the symlinks below point at, one test each.
    INDEX_COMPLETE=true
    for ext in bwt ann amb pac sa; do
        if [ ! -f "${run.reference}.\$ext" ]; then INDEX_COMPLETE=false; fi
    done

    if [ "\$INDEX_COMPLETE" = true ]; then
        echo "BWA INDEX ${run.referenceFile}:          Found a complete existing index"
        echo "BWA INDEX ${run.referenceFile}:          No need to create the index again"
        echo "BWA INDEX ${run.referenceFile}:          Creating symbolic links..."
        for ext in bwt ann amb pac sa; do
            echo "BWA INDEX ${run.referenceFile}:          Creating symbolic link for ${run.referenceFile}.\$ext"
            ln -s ${run.reference}.\$ext .
        done
        echo "BWA INDEX ${run.referenceFile}:          COMPLETED"
    else
        echo "BWA INDEX ${run.referenceFile}:          Building BWA index files..."
        ${run.software.bwa} index -a bwtsw ${reference}
        for ext in bwt ann amb pac sa; do
            echo "BWA INDEX ${run.referenceFile}:          Moving ${run.referenceFile}.\$ext to ${referenceDir}"
            atomic_mv.sh ${run.referenceFa}.\$ext ${referenceDir}/
            echo "BWA INDEX ${run.referenceFile}:          Creating symbolic link for ${run.referenceFile}.\$ext"
            ln -s ${run.reference}.\$ext .
        done
        echo "BWA INDEX ${run.referenceFile}:          COMPLETED"
    fi
    
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/1_BuildDictionary_s2_1_CreateBwaIndex_nextflow.log
    """
}

process CreateSamtoolsFaiIndex {
    input:
    tuple val(run), path(reference)

    output:
    tuple val(run), path("${run.referenceFa}.fai"), emit: fai_index

    script:
    referenceDir = run.dir.dictionaries
    dir_log = "${run.dir.logs}/1_build_dictionaries"

    """
    set -eo pipefail

    echo "SAMTOOLS INDEX ${run.referenceFile}:     Start building samtools fai index..."
    # The exact file the symlink below points at, not any *.fai in the directory.
    if [ -f "${run.reference}.fai" ]; then
        echo "SAMTOOLS INDEX ${run.referenceFile}:     Found existing fai index file"
        echo "SAMTOOLS INDEX ${run.referenceFile}:     Found: ${run.reference}.fai"
        echo "SAMTOOLS INDEX ${run.referenceFile}:     Creating symbolic link..."
        ln -s ${run.reference}.fai .
        echo "SAMTOOLS INDEX ${run.referenceFile}:     COMPLETED"
    else
        echo "SAMTOOLS INDEX ${run.referenceFile}:     Building samtools fai index..."
        ${run.software.samtools} faidx ${reference}

        echo "SAMTOOLS INDEX ${run.referenceFile}:     Moving ${run.referenceFa}.fai to ${referenceDir}"
        atomic_mv.sh ${run.referenceFa}.fai ${referenceDir}/
        echo "SAMTOOLS INDEX ${run.referenceFile}:     Creating symbolic link..."
        ln -s ${run.reference}.fai .
        echo "SAMTOOLS INDEX ${run.referenceFile}:     COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/1_BuildDictionary_s2_2_CreateSamtoolsFaiIndex_nextflow.log
    """
}

process BuildSnpEffDb {
    cpus { run.cores.javaGc }
    input:
    tuple val(run), val(verify)

    output:
    tuple val(run), path(".build_complete"), emit: snpeff_db_verify

    script:
    gff = run.gffPath
    ref = run.referencePath
    // The marker lives inside the genome's own database directory.
    build_verify_path = "${run.dir.snpEff}/data/${run.snpEff.db}/.build_complete"
    dir_log = "${run.dir.logs}/1_build_dictionaries"

    """
    set -eo pipefail

    buildSnpEffDb() {
        echo "SNPEFF DB BUILD:    Building SnpEff database..."
        echo "SNPEFF DB BUILD:    Creating SNPEff directory structure"

        mkdir -p data
        mkdir -p data/${run.snpEff.db}

        echo "SNPEFF DB BUILD:    Copying the gff file..."
        if [[ ${gff} == *.gz ]]; then
            cp ${gff} data/${run.snpEff.db}/genes.gff.gz
        else
            cp ${gff} data/${run.snpEff.db}/genes.gff
        fi

        echo "SNPEFF DB BUILD:    Copying the reference file..."
        if [[ ${ref} == *.gz ]]; then
            cp ${ref} data/${run.snpEff.db}/sequences.fa.gz
        else
            cp ${ref} data/${run.snpEff.db}/sequences.fa
        fi

        echo "SNPEFF DB BUILD:    Creating snpEff config file..."
        GENOME_LINE="${run.snpEff.db}.genome : ${run.snpEff.db}"
        printf '%s\\n' "\$GENOME_LINE" > ${run.snpEff.config}

        echo "SNPEFF DB BUILD:    Build database"
        # -c names the config explicitly: without it snpEff falls back to the bundled one, which
        # has no entry for this genome.
        ${run.software.snpEff} build ${run.snpEff.buildOptions} \
            -c ${run.snpEff.config} \
            ${run.snpEff.db}

        echo "SNPEFF DB BUILD:    Checking if database was created..."
        BIN_COUNT=\$(find data/${run.snpEff.db} -name "*.bin" | wc -l)
        if [ \$BIN_COUNT -eq 0 ]; then
            echo "SNPEFF DB BUILD:    ERROR: No .bin files found! Database creation failed."
            return 1
        else
            echo "SNPEFF DB BUILD:    Found \$BIN_COUNT .bin files."
            echo "SNPEFF DB BUILD:    Database creation successful!"
            echo "SNPEFF DB BUILD:    Publishing database to ${run.dir.snpEff}"

            # Published as ONE directory with the marker inside it, so "marker present" means
            # "database complete". The unit is the GENOME's directory, never data/, which several
            # genomes share.
            touch data/${run.snpEff.db}/\$BUILD_COMPLETE || return 1
            mkdir -p ${run.dir.snpEff}/data || return 1
            # A database with no marker is discarded, not merged into.
            rm -rf ${run.dir.snpEff}/data/${run.snpEff.db} || return 1
            atomic_mv.sh data/${run.snpEff.db} ${run.dir.snpEff}/data/${run.snpEff.db} || return 1

            # Merged into the shared config, which has to name every genome built here.
            DEST_CONFIG="${run.dir.snpEff}/${run.snpEff.config}"
            if [ ! -f "\$DEST_CONFIG" ]; then
                cp ${run.snpEff.config} "\$DEST_CONFIG" || return 1
            elif ! grep -qxF "\$GENOME_LINE" "\$DEST_CONFIG"; then
                printf '%s\\n' "\$GENOME_LINE" >> "\$DEST_CONFIG" || return 1
            fi
            return 0
        fi
    }

    export _JAVA_OPTIONS="${run.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

    # First check existing database
    BUILD_COMPLETE=".build_complete"
    if [ -f ${build_verify_path} ]; then
        echo "SNPEFF DB BUILD: Existing database found for ${run.snpEff.db}, skipping..."
        ln -s ${build_verify_path} .
    else
        # A pre-3.0 project has its marker at the top of the snpEff folder.
        if [ -f "${run.dir.snpEff}/.build_complete" ]; then
            echo "SNPEFF DB BUILD: Found a marker from a release that kept one marker for"
            echo "SNPEFF DB BUILD: the whole snpEff folder. It does not say which genome it"
            echo "SNPEFF DB BUILD: was built for, so ${run.snpEff.db} is being rebuilt once."
        fi
        buildSnpEffDb || exit 1
        ln -s ${build_verify_path} .
    fi
    
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/1_BuildDictionary_s2_3_BuildSnpEffDb_nextflow.log
    """
}

workflow BuildDictionaries {
    take:
    // One entry per distinct dictionary set, NOT one per run - see dictionaryKey.
    dictionary_runs
    // Every run's step 0, as one signal: an ordering barrier, never read.
    verify

    main:
    ready = dictionary_runs.combine(verify)

    UngzipReference(ready)
    CreateBwaIndex(UngzipReference.out.reference)
    CreateSamtoolsFaiIndex(UngzipReference.out.reference)

    // `annotate` is per run, so this filters the channel.
    BuildSnpEffDb(ready.filter { run, _verify -> run.annotate })

    emit:
    // No `reference` emit: it is consumed inside this workflow by the two index builders, and
    // BuildSnpEffDb copies the user's reference itself.
    bwa_index         = CreateBwaIndex.out.bwa_index
    fai_index         = CreateSamtoolsFaiIndex.out.fai_index
    snpeff_db_verify  = BuildSnpEffDb.out.snpeff_db_verify
}
