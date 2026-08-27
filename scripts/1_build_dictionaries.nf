include { deepCopy } from './resolve_parameters.nf'

// WHICH DICTIONARY SET A RUN USES: the paths step 1 writes, and nothing else.
//
// Dictionaries live under mainDir/Reference/Dictionaries by settled rule 4, and runs SHARE
// mainDir - so two runs naming the same reference resolve to exactly the same output paths.
// Left alone under multiRun they would both build it, at the same time, into one place; and
// atomic_mv.sh has no locking, so that is a race rather than merely duplicated work.
//
// This is therefore not an optimisation and does not belong to E1v's sharing work: step 1 is
// the one step whose artifacts were already shared before multi-run existed, so threading
// runs through it without grouping would BREAK something that works today.
def dictionaryKey(Map run) {
    return [run.dir.dictionaries, run.referenceFa, run.dir.snpEff, run.snpEff.db]
        .collect { part -> "${part}" }
        .join(' | ')
}

// What step 1 reads apart from those paths. Two runs that land on the same key must agree on
// all of it: "build it once" would otherwise hand one of them a dictionary built to the
// other's settings, which is the silent-wrong-result failure this project keeps finding.
//
// Reported rather than resolved. Which of two conflicting settings should win is the user's
// decision and there is no safe default - see the working agreement about not automating a
// decision away.
//
// Resource settings are deliberately absent: heap size and core counts change how long the
// build takes, not what it produces, and a dictionary is shared so it cannot have per-run
// resources anyway.
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
//
// Single run in, single entry out, identical to the run itself apart from the two fields
// noted below - both of which are already what a single run holds, so nothing moves.
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
        // Shared work, so its log belongs to the project rather than to whichever run happens
        // to be listed first. For a single run this IS that run's own Logs directory, so the
        // line changes nothing outside multiRun.
        dict.dir.logs = "${params.dir.logs}"
        // Built when ANY member wants it: one database serves them all, and a run that does
        // not annotate is not harmed by its existence.
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
    dir_log = "${run.dir.logs}/1_build_dictionaries/s1_UngzipReference"

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
        echo "UNGZIP ${run.referenceFile}:             Unzipping reference file..."
        gunzip -c ${refIn} > ${run.referenceFa}
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
    dir_log = "${run.dir.logs}/1_build_dictionaries/s2_1_CreateBwaIndex"

    """
    set -eo pipefail

    echo "BWA INDEX ${run.referenceFile}:          Start building BWA index..."
    # Test the exact five files the symlinks below point at, one test each. The previous
    # form counted output lines from `ls ${referenceDir}/*.bwt` and friends chained with
    # &&, which was wrong twice over: an unmatched glob makes ls exit non-zero, so on a
    # first run the whole substitution fails and takes the task with it once pipefail is
    # on; and *.bwt matches an index built for a differently named reference, so the
    # check could pass while the `ln -s` below still had nothing to point at.
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
    dir_log = "${run.dir.logs}/1_build_dictionaries/s2_2_CreateSamtoolsFaiIndex"

    """
    set -eo pipefail

    echo "SAMTOOLS INDEX ${run.referenceFile}:     Start building samtools fai index..."
    # The exact file the symlink below points at, rather than counting any *.fai in the
    # directory - see the note in CreateBwaIndex for why the ls|wc form had to go.
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
    // The marker lives inside the genome's own database directory, not at the top of the
    // snpEff folder. One snpEff folder serves every reference a project has built, so a
    // single top-level marker answered "has any database been built here?" when the
    // question is "has THIS genome's database been built?". Building against a second
    // reference found the marker, skipped the build, and inherited the first genome's
    // database - and the failure did not surface until step 8, after alignment and
    // calling, as "Genome download failed!" (snpEff falls through to -download when the
    // config names a database it cannot find). Every index file in this step was already
    // keyed by reference name; this was the one artifact that was not.
    build_verify_path = "${run.dir.snpEff}/data/${run.snpEff.db}/.build_complete"
    dir_log = "${run.dir.logs}/1_build_dictionaries/s2_3_BuildSnpEffDb"

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
        # -c names the config explicitly. Without it snpEff only finds a config in the
        # working directory when it is called exactly 'snpEff.config', and otherwise
        # silently falls back to the one bundled with the install - which has no entry
        # for this genome, so the build dies with "Property: '<db>.genome' not found".
        # That made params.snpEff.config a parameter that broke the run if it was ever
        # changed from its default.
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
            echo "SNPEFF DB BUILD:    Copying database to ${run.dir.snpEff}"
            mkdir -p ${run.dir.snpEff} || return 1
            # cp -r merges rather than nests when the destination already has a data/
            # directory, so a second genome lands alongside the first instead of at
            # data/data/ (verified).
            cp -r data ${run.dir.snpEff}/ || return 1
            # Merge this genome's line into the shared config instead of replacing the
            # file. The config sits next to the shared data/ directory and snpEff reads
            # every entry in it, so it has to name every genome built here - a plain cp
            # left it holding only the most recently built one, which made every earlier
            # genome unannotatable even though its database was still on disk.
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
        # A project built by an earlier release has its marker at the top of the snpEff
        # folder rather than inside the genome's database directory, so the first run
        # after upgrading rebuilds once. Deliberate: the old marker records that *a*
        # database was built, not which genome it was for, so it cannot be adopted
        # without guessing. The rebuild lands in the same place and merges its config
        # line, and every run after it skips normally.
        if [ -f "${run.dir.snpEff}/.build_complete" ]; then
            echo "SNPEFF DB BUILD: Found a marker from a release that kept one marker for"
            echo "SNPEFF DB BUILD: the whole snpEff folder. It does not say which genome it"
            echo "SNPEFF DB BUILD: was built for, so ${run.snpEff.db} is being rebuilt once."
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
    // One entry per distinct dictionary set, from dictionaryRuns() - NOT one per run. See
    // dictionaryKey above for why the two are not the same thing.
    dictionary_runs
    // Every run's step 0 having passed, as one signal. A pure ordering barrier: nothing in
    // this step reads it, and it is `val` rather than `path` because N runs each publish a
    // report called 0_verify_environment.txt and staging N files of one name is a collision
    // for no purpose.
    verify

    main:
    ready = dictionary_runs.combine(verify)

    UngzipReference(ready)
    CreateBwaIndex(UngzipReference.out.reference)
    CreateSamtoolsFaiIndex(UngzipReference.out.reference)

    // `annotate` is a per-run parameter, so which references need a snpEff database is a
    // property of the data rather than of the script. Filtering the channel says that
    // directly; the `if (params.annotate)` this replaces could only ever read the base
    // config, and would have built for every reference or none.
    BuildSnpEffDb(ready.filter { run, _verify -> run.annotate })

    emit:
    reference         = UngzipReference.out.reference
    bwa_index         = CreateBwaIndex.out.bwa_index
    fai_index         = CreateSamtoolsFaiIndex.out.fai_index
    snpeff_db_verify  = BuildSnpEffDb.out.snpeff_db_verify
}
