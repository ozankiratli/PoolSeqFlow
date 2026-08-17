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
    echo "BWA INDEX ${params.referenceFile}:          Start building BWA index..."
    CT=\$( ( ls ${referenceDir}/*.bwt 2>/dev/null && ls ${referenceDir}/*.ann 2>/dev/null && ls ${referenceDir}/*.amb 2>/dev/null && ls ${referenceDir}/*.pac 2>/dev/null && ls ${referenceDir}/*.sa 2>/dev/null ) | wc -l)
    if [ \$CT -eq 5 ]; then
        echo "BWA INDEX ${params.referenceFile}:          Found \$CT existing index files"
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
    echo "SAMTOOLS INDEX ${params.referenceFile}:     Start building samtools fai index..."
    CT=\$(ls ${referenceDir}/*.fai 2>/dev/null | wc -l)
    if [ \$CT -eq 1 ]; then
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
    build_verify_path = "${params.dir.snpEff}/.build_complete"
    dir_log = "${params.dir.logs}/1_build_dictionaries/s2_3_BuildSnpEffDb"

    """
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
        echo "${params.snpEff.db}.genome : ${params.snpEff.db}" > ${params.snpEff.config}
        
        echo "SNPEFF DB BUILD:    Build database"
        ${params.software.snpEff} build ${params.snpEff.buildOptions} ${params.snpEff.db}

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
            cp -r data ${params.dir.snpEff}/ || return 1
            cp snpEff.config ${params.dir.snpEff}/ || return 1
            return 0
        fi
    }

    export _JAVA_OPTIONS="${params.java.heapSize} -XX:ParallelGCThreads=${task.cpus}"

    # First check existing database
    BUILD_COMPLETE=".build_complete"
    if [ -f ${build_verify_path} ]; then
        echo "SNPEFF DB BUILD: Existing database found, skipping..."
        ln -s ${build_verify_path} .
    else
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
    //snpeff_db_verify  = BuildSnpEffDb.out.snpeff_db_verify
    snpeff_db_verify  = params.annotate ? BuildSnpEffDb.out.snpeff_db_verify : Channel.empty()
}
