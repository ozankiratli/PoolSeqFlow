// The roots a skip check searches. Under sharing an artifact this step reads may have
// been produced by a variant with a coarser working root than its own, so the list comes
// from the divergence analysis rather than being spelled out here.
include { searchRoots } from './variants.nf'

process VariantCall {
    tag { run.runId ? "${run.runId}:calling_variants" : "calling_variants" }

    input:
    // The fai index travels with the cohort rather than as a second input, for the reason
    // given on Align: separate inputs are matched positionally, and with N runs in flight
    // that would hand a run the wrong reference index.
    tuple val(run), path(ready_bams), path(fai_index)

    output:
    tuple val(run), path("${run.vcf.fileName}.vcf"), emit: vcf_file

    script:
    reference = run.reference
    vcf_file = "${run.vcf.fileName}.vcf"
    // Read by step 7 always, and by step 8 whenever annotation is on, so it stays on the
    // working volume until both have finished - the only VCF here that is promoted rather
    // than consumed and deleted.
    search_roots = searchRoots(run)
    rel_vcf = "${run.dir.subpath.vcf}"
    target_vcf_folder = "${run.dir.utilized}/${rel_vcf}"
    target_vcf_file = "${target_vcf_folder}/${vcf_file}"
    dir_log = "${run.dir.logs}/6_variant_call"

    """
    set -eo pipefail

    # Either volume: still here while step 7 or step 8 may read it, in permanent storage
    # once both are done.
    vcf_at=\$(find_artifact.sh "${rel_vcf}/${vcf_file}" ${search_roots} || true)

    echo "VARIANT CALL ${vcf_file}: Variant calling started..."
    if [ -n "\$vcf_at" ]; then
        echo "VARIANT CALL ${vcf_file}: Found existing VCF file"
        echo "VARIANT CALL ${vcf_file}: Found: \$vcf_at"
        echo "VARIANT CALL ${vcf_file}: Creating symbolic link..."
        ln -s "\$vcf_at" .
        echo "VARIANT CALL ${vcf_file}: COMPLETED"
    else
        echo "VARIANT CALL ${vcf_file}: Creating VCF file..."
        ${run.software.bcftools} mpileup ${run.bcftools.mpileupOptions} \
        -f ${reference} ${ready_bams} | \
        ${run.software.bcftools} call ${run.bcftools.callOptions} \
        -o ${vcf_file}

        echo "VARIANT CALL ${vcf_file}: Fixing minor header issue..."
        sed -i 's/##INFO=<ID=MQ,Number=1,Type=Integer/##INFO=<ID=MQ,Number=1,Type=Float/' ${vcf_file}
        echo "VARIANT CALL ${vcf_file}: Type of MQ changed from Integer to Float..."

        echo "VARIANT CALL ${vcf_file}: Moving ${vcf_file} to ${target_vcf_folder}..."
        mkdir -p ${run.dir.output.vcf}
        atomic_mv.sh ${vcf_file} ${target_vcf_file}
        echo "VARIANT CALL ${vcf_file}: Creating symbolic link..."
        ln -s ${target_vcf_file} .
        echo "VARIANT CALL ${vcf_file}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/6_VariantCall_${run.vcf.fileName}_nextflow.log
    """
}

// Read the sample order out of the RGTags file: ID column values in the order their rows
// appear. Returns an empty map if the file is missing or malformed - this runs while the
// workflow is being built, which is before step 0 has had a chance to report on it, so it
// must not throw. Step 0 fails the run on a missing file, a missing ID column or a sample
// that has no RGTags row, and its message is far more useful than a Groovy stack trace.
//
// Takes the path rather than reading params.rgTagsPath, because rgTagsFile is a parameter
// like any other and a multi-run table may give two runs two different tables.
def rgTagsOrder(String rgTagsPath) {
    def order = [:]
    def rgFile = file(rgTagsPath)

    if (!rgFile.exists()) {
        return order
    }

    def lines = rgFile.readLines().findAll { line -> line.trim() }

    if (lines.size() < 2) {
        return order
    }

    def header = lines[0].split(',', -1).collect { field -> field.trim() }
    def idCol = header.indexOf('ID')

    if (idCol < 0) {
        return order
    }

    lines.tail().each { line ->
        def fields = line.split(',', -1)
        if (fields.size() > idCol) {
            def id = fields[idCol].trim()
            if (id && !order.containsKey(id)) {
                order[id] = order.size()
            }
        }
    }

    return order
}

workflow VariantCalling {
    take:
    out_ready_bams   // [run, pair_id, ready_bam]
    fai_index        // [run, fai] - one per run
    expected         // [run, how many samples that run started with]

    main:
    // THE GATHER POINT. Everything above this line is per sample; below it, one task per run
    // over that run's whole cohort. groupTuple waits for the channel to close, so what
    // arrives is every ready BAM the run produced - which is the right thing to gather and
    // the wrong thing to trust blindly, hence the count check below.
    cohorts = out_ready_bams.groupTuple(by: 0)
        .join(expected, by: 0)
        .map { run, pair_ids, bams, n_expected ->
            // A SHORT COHORT IS A SILENT WRONG ANSWER, not a failure. bcftools calls whatever
            // samples it is given and writes a VCF that looks entirely normal with five
            // columns where there should be six - and every frequency downstream of it is
            // then computed over the wrong denominator. Nothing later can detect that, so it
            // is checked here, where the number that was expected is still known.
            //
            // errorStrategy 'finish' already stops a run whose step 2 failed, so this is
            // belt and braces for that path. What it also covers is a channel wired wrongly
            // during a refactor, which no error strategy can see.
            if (pair_ids.size() != n_expected) {
                throw new IllegalStateException(
                    "variant calling for run '${run.runId ?: 'single'}' received " +
                    "${pair_ids.size()} ready BAM(s) but the run started with ${n_expected} " +
                    "sample(s): ${(pair_ids as List).sort().join(', ')}.\n" +
                    "Calling a subset would publish a VCF that looks complete and is not, so " +
                    "the run is stopped instead.")
            }

            // Order the BAMs before handing them to bcftools. Arrival order is
            // task-completion order, so whichever sample finishes first would land first on
            // the command line and bcftools would order the VCF sample columns to match -
            // two runs on the same input would give frequency tables with differently
            // ordered columns.
            //
            // The order to use is the RGTags row order, so the columns come out the way the
            // user laid their samples out rather than however they happen to sort as
            // strings. Sorting has to key on the sample id, not the file path: the paths
            // begin with Nextflow's random work-directory hash, so sorting those is no
            // better than chance.
            //
            // Anything the RGTags file does not list sorts after everything it does,
            // alphabetically among itself. Step 0 already refuses to run with an unlisted
            // sample, so this only keeps the comparator well defined.
            def rgOrder = rgTagsOrder("${run.rgTagsPath}")
            def ordered = [pair_ids as List, bams as List].transpose().sort { a, b ->
                def rowA = rgOrder.getOrDefault(a[0], rgOrder.size())
                def rowB = rgOrder.getOrDefault(b[0], rgOrder.size())
                rowA != rowB ? rowA <=> rowB : a[0] <=> b[0]
            }
            return tuple(run, ordered.collect { row -> row[1] })
        }

    VariantCall(cohorts.join(fai_index, by: 0))

    emit:
    VariantCall.out.vcf_file
}