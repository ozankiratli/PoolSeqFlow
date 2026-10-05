// Writes the citations for the software a run invoked.

process WriteCitations {
    tag 'citations'

    input:
    val run
    val done   // ordering barrier; never read

    output:
    path 'citations.txt'

    script:
    outDir = "${run.storageDir}/Output"
    dir_log = "${params.dir.allLogs}/citations"
    // Every tool the pipeline can invoke, as name=command.
    probes = (run.software.collect { name, cmd -> "${name}=${cmd}" } +
              ["nextflow=nextflow", "python=python3"]).join(' ')
    """
    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
    } >> ${dir_log}/Citations_WriteCitations_nextflow.log
    # Written as it happens rather than copied at the end: a task killed by a signal leaves what
    # it had reached. stdbuf keeps tee line-buffered, so the last line is not held in a buffer.
    exec > >(stdbuf -oL tee -a ${dir_log}/Citations_WriteCitations_nextflow.log) 2>&1
    . ${run.dir.lib}/tool_version.sh

    versions=""
    for pair in ${probes}; do
        name="\${pair%%=*}"
        cmd="\${pair#*=}"
        # An absent tool is recorded without a version rather than failing.
        if command -v "\$cmd" >/dev/null 2>&1; then
            v=\$(tool_version "\$name" "\$cmd" 2>/dev/null || true)
        else
            v=""
        fi
        versions="\$versions \$name=\$v"
    done

    python3 ${run.dir.bin}/write_citations.py \\
        --data ${run.citationsData} \\
        --out-dir ${outDir} \\
        --pipeline-version '${workflow.manifest.version ?: 'unknown'}' \\
        --annotate '${run.annotate}' \\
        \$versions > citations.txt
    # Not piped into tee, which would make the exit status tee's.
    cat citations.txt

    """
}

workflow Citations {
    take:
    run
    done

    main:
    WriteCitations(run, done)

    emit:
    WriteCitations.out
}
