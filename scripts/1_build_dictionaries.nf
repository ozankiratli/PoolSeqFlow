process UngzipReference {
    input:
    path verify

    output:
    path params.referenceFa, emit: reference

    script:
    refIn = params.referencePath
    refOut = params.reference
    dir_log = "${params.dir.logs}/1_build_dictionaries/s1_UngzipReference"

    """
    set -eo pipefail

    #if [ ! -f ${verify} ]; then
    #    echo "UNGZIP:             Verify file not found: ${verify}"
    #    exit 1
    #fi

    mkdir -p ${params.dir.references}

    echo "UNGZIP ${params.referenceFile}:             Start unzipping reference file..."
    if [ -f ${refOut} ]; then
        echo "UNGZIP ${params.referenceFile}:             Found existing unzipped reference file"
        echo "UNGZIP ${params.referenceFile}:             Found ${refOut}"
        echo "UNGZIP ${params.referenceFile}:             Creating symbolic link..."
        ln -s ${refOut} .
        echo "UNGZIP ${params.referenceFile}:             COMPLETED"
    else
        echo "UNGZIP ${params.referenceFile}:             Unzipping reference file..."
        gunzip -c ${refIn} > ${params.referenceFa}
        echo "UNGZIP ${params.referenceFile}:             Moving ${params.referenceFa} to ${params.dir.references}"
        atomic_mv.sh ${params.referenceFa} ${refOut}
        echo "UNGZIP ${params.referenceFile}:             Creating symbolic link..."
        ln -s ${refOut} .
        echo "UNGZIP ${params.referenceFile}:             COMPLETED"
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
    path reference

    output:
    path "${params.referenceFa}.{bwt,ann,amb,pac,sa}", emit: bwa_index

    script:
    referenceDir = params.dir.references
    dir_log = "${params.dir.logs}/1_build_dictionaries/s2_1_CreateBwaIndex"

    """
    set -eo pipefail

    echo "BWA INDEX ${params.referenceFile}:          Start building BWA index..."
    # Test the exact five files the symlinks below point at, one test each. The previous
    # form counted output lines from `ls ${referenceDir}/*.bwt` and friends chained with
    # &&, which was wrong twice over: an unmatched glob makes ls exit non-zero, so on a
    # first run the whole substitution fails and takes the task with it once pipefail is
    # on; and *.bwt matches an index built for a differently named reference, so the
    # check could pass while the `ln -s` below still had nothing to point at.
    INDEX_COMPLETE=true
    for ext in bwt ann amb pac sa; do
        if [ ! -f "${params.reference}.\$ext" ]; then INDEX_COMPLETE=false; fi
    done

    if [ "\$INDEX_COMPLETE" = true ]; then
        echo "BWA INDEX ${params.referenceFile}:          Found a complete existing index"
        echo "BWA INDEX ${params.referenceFile}:          No need to create the index again"
        echo "BWA INDEX ${params.referenceFile}:          Creating symbolic links..."
        for ext in bwt ann amb pac sa; do
            echo "BWA INDEX ${params.referenceFile}:          Creating symbolic link for ${params.referenceFile}.\$ext"
            ln -s ${params.reference}.\$ext .
        done
        echo "BWA INDEX ${params.referenceFile}:          COMPLETED"
    else
        echo "BWA INDEX ${params.referenceFile}:          Building BWA index files..."
        ${params.software.bwa} index -a bwtsw ${reference}
        for ext in bwt ann amb pac sa; do
            echo "BWA INDEX ${params.referenceFile}:          Moving ${params.referenceFile}.\$ext to ${referenceDir}"
            atomic_mv.sh ${params.referenceFa}.\$ext ${referenceDir}/
            echo "BWA INDEX ${params.referenceFile}:          Creating symbolic link for ${params.referenceFile}.\$ext"
            ln -s ${params.reference}.\$ext .
        done
        echo "BWA INDEX ${params.referenceFile}:          COMPLETED"
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
    path reference

    output:
    path "${params.referenceFa}.fai", emit: fai_index

    script:
    referenceDir = params.dir.references
    dir_log = "${params.dir.logs}/1_build_dictionaries/s2_2_CreateSamtoolsFaiIndex"

    """
    set -eo pipefail

    echo "SAMTOOLS INDEX ${params.referenceFile}:     Start building samtools fai index..."
    # The exact file the symlink below points at, rather than counting any *.fai in the
    # directory - see the note in CreateBwaIndex for why the ls|wc form had to go.
    if [ -f "${params.reference}.fai" ]; then
        echo "SAMTOOLS INDEX ${params.referenceFile}:     Found existing fai index file"
        echo "SAMTOOLS INDEX ${params.referenceFile}:     Found: ${params.reference}.fai"
        echo "SAMTOOLS INDEX ${params.referenceFile}:     Creating symbolic link..."
        ln -s ${params.reference}.fai .
        echo "SAMTOOLS INDEX ${params.referenceFile}:     COMPLETED"
    else
        echo "SAMTOOLS INDEX ${params.referenceFile}:     Building samtools fai index..."
        ${params.software.samtools} faidx ${reference}

        echo "SAMTOOLS INDEX ${params.referenceFile}:     Moving ${params.referenceFa}.fai to ${referenceDir}"
        atomic_mv.sh ${params.referenceFa}.fai ${referenceDir}/
        echo "SAMTOOLS INDEX ${params.referenceFile}:     Creating symbolic link..."
        ln -s ${params.reference}.fai .
        echo "SAMTOOLS INDEX ${params.referenceFile}:     COMPLETED"
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
    cpus { params.cores.javaGc }
    input:
    path verify

    output:
    path ".build_complete", emit: snpeff_db_verify

    script:
    gff = params.gffPath
    ref = params.referencePath
    // The marker lives inside the genome's own database directory, not at the top of the
    // snpEff folder. One snpEff folder serves every reference a project has built, so a
    // single top-level marker answered "has any database been built here?" when the
    // question is "has THIS genome's database been built?". Building against a second
    // reference found the marker, skipped the build, and inherited the first genome's
    // database - and the failure did not surface until step 8, after alignment and
    // calling, as "Genome download failed!" (snpEff falls through to -download when the
    // config names a database it cannot find). Every index file in this step was already
    // keyed by reference name; this was the one artifact that was not.
    build_verify_path = "${params.dir.snpEff}/data/${params.snpEff.db}/.build_complete"
    dir_log = "${params.dir.logs}/1_build_dictionaries/s2_3_BuildSnpEffDb"

    """
    set -eo pipefail

    buildSnpEffDb() {
        echo "SNPEFF DB BUILD:    Building SnpEff database..."
        echo "SNPEFF DB BUILD:    Creating SNPEff directory structure"

        mkdir -p data
        mkdir -p data/${params.snpEff.db}

        echo "SNPEFF DB BUILD:    Copying the gff file..."
        if [[ ${gff} == *.gz ]]; then
            cp ${gff} data/${params.snpEff.db}/genes.gff.gz
        else
            cp ${gff} data/${params.snpEff.db}/genes.gff
        fi

        echo "SNPEFF DB BUILD:    Copying the reference file..."
        if [[ ${ref} == *.gz ]]; then
            cp ${ref} data/${params.snpEff.db}/sequences.fa.gz
        else
            cp ${ref} data/${params.snpEff.db}/sequences.fa
        fi

        echo "SNPEFF DB BUILD:    Creating snpEff config file..."
        GENOME_LINE="${params.snpEff.db}.genome : ${params.snpEff.db}"
        printf '%s\\n' "\$GENOME_LINE" > ${params.snpEff.config}

        echo "SNPEFF DB BUILD:    Build database"
        # -c names the config explicitly. Without it snpEff only finds a config in the
        # working directory when it is called exactly 'snpEff.config', and otherwise
        # silently falls back to the one bundled with the install - which has no entry
        # for this genome, so the build dies with "Property: '<db>.genome' not found".
        # That made params.snpEff.config a parameter that broke the run if it was ever
        # changed from its default.
        ${params.software.snpEff} build ${params.snpEff.buildOptions} \
            -c ${params.snpEff.config} \
            ${params.snpEff.db}

        echo "SNPEFF DB BUILD:    Checking if database was created..."
        BIN_COUNT=\$(find data/${params.snpEff.db} -name "*.bin" | wc -l)
        if [ \$BIN_COUNT -eq 0 ]; then
            echo "SNPEFF DB BUILD:    ERROR: No .bin files found! Database creation failed."
            return 1
        else
            echo "SNPEFF DB BUILD:    Found \$BIN_COUNT .bin files."
            echo "SNPEFF DB BUILD:    Database creation successful!"
            echo "SNPEFF DB BUILD:    Copying database to ${params.dir.snpEff}"
            mkdir -p ${params.dir.snpEff} || return 1
            # cp -r merges rather than nests when the destination already has a data/
            # directory, so a second genome lands alongside the first instead of at
            # data/data/ (verified).
            cp -r data ${params.dir.snpEff}/ || return 1
            # Merge this genome's line into the shared config instead of replacing the
            # file. The config sits next to the shared data/ directory and snpEff reads
            # every entry in it, so it has to name every genome built here - a plain cp
            # left it holding only the most recently built one, which made every earlier
            # genome unannotatable even though its database was still on disk.
            DEST_CONFIG="${params.dir.snpEff}/${params.snpEff.config}"
            if [ ! -f "\$DEST_CONFIG" ]; then
                cp ${params.snpEff.config} "\$DEST_CONFIG" || return 1
            elif ! grep -qxF "\$GENOME_LINE" "\$DEST_CONFIG"; then
                printf '%s\\n' "\$GENOME_LINE" >> "\$DEST_CONFIG" || return 1
            fi
            return 0
        fi
    }

    export _JAVA_OPTIONS="${params.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

    # First check existing database
    BUILD_COMPLETE=".build_complete"
    if [ -f ${build_verify_path} ]; then
        echo "SNPEFF DB BUILD: Existing database found for ${params.snpEff.db}, skipping..."
        ln -s ${build_verify_path} .
    else
        # A project built by an earlier release has its marker at the top of the snpEff
        # folder rather than inside the genome's database directory, so the first run
        # after upgrading rebuilds once. Deliberate: the old marker records that *a*
        # database was built, not which genome it was for, so it cannot be adopted
        # without guessing. The rebuild lands in the same place and merges its config
        # line, and every run after it skips normally.
        if [ -f "${params.dir.snpEff}/.build_complete" ]; then
            echo "SNPEFF DB BUILD: Found a marker from a release that kept one marker for"
            echo "SNPEFF DB BUILD: the whole snpEff folder. It does not say which genome it"
            echo "SNPEFF DB BUILD: was built for, so ${params.snpEff.db} is being rebuilt once."
        fi
        ( buildSnpEffDb && touch "\$BUILD_COMPLETE" ) || exit 1
        atomic_mv.sh \$BUILD_COMPLETE ${build_verify_path}
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
    verify
    main:
    UngzipReference(verify)
    CreateBwaIndex(UngzipReference.out.reference)
    CreateSamtoolsFaiIndex(UngzipReference.out.reference)
    //BuildSnpEffDb(verify)
    if (params.annotate) {
        BuildSnpEffDb(verify)
    }
    emit:
    reference         = UngzipReference.out.reference
    bwa_index         = CreateBwaIndex.out.bwa_index
    fai_index         = CreateSamtoolsFaiIndex.out.fai_index
    snpeff_db_verify  = params.annotate ? BuildSnpEffDb.out.snpeff_db_verify : channel.empty()
}
