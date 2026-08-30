// The roots a skip check searches, from the divergence analysis.
include { searchRoots } from './variants.nf'
// The sample order, from the parsed rows. It decides the VCF's sample columns and therefore the
// frequency tables'.
include { metadataOrder } from './metadata.nf'

// Truncate one sample's BAM to the ceiling step 5 chose for it.
//
// The capped BAM is TRANSIENT: produced here, read by VariantCall, and written to neither root.
// It has no promotion row and is never skip-checked.
process CapBAM {
    tag { run.runId ? "${run.runId}:${pair_id}" : pair_id }

    input:
    tuple val(run), val(pair_id), path(ready_bam), path(ready_bai), val(cap)

    output:
    tuple val(run), val(pair_id), path("${pair_id}_capped.bam"), emit: capped_bam

    script:
    search_roots = searchRoots(run)
    rel_vcf = "${run.dir.subpath.vcf}"
    vcf_file = "${run.vcf.fileName}.vcf"
    dir_log = "${run.dir.logs}/6_variant_call"

    """
    set -eo pipefail

    # Nothing to do if the VCF this feeds already exists. A header-only BAM satisfies the output
    # declaration; VariantCall finds the VCF and never opens it.
    vcf_at=\$(find_artifact.sh "${rel_vcf}/${vcf_file}" ${search_roots} || true)
    if [ -n "\$vcf_at" ]; then
        echo "CAP BAM ${pair_id}: The VCF this feeds already exists"
        echo "CAP BAM ${pair_id}: Found: \$vcf_at"
        echo "CAP BAM ${pair_id}: Nothing to cap; SKIPPED"
        ${run.software.samtools} view -H -b -o ${pair_id}_capped.bam ${ready_bam}
    else
        echo "CAP BAM ${pair_id}: Capping at depth ${cap}..."
        ${run.software.samtools} view -h ${ready_bam} \
            | cap_depth.awk -v cap=${cap} \
            | ${run.software.samtools} view -b -o ${pair_id}_capped.bam -
        echo "CAP BAM ${pair_id}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/6_VariantCalling_s1_CapBAM_${pair_id}_nextflow.log
    """
}

process VariantCall {
    tag { run.runId ? "${run.runId}:calling_variants" : "calling_variants" }

    input:
    // The fai index travels with the cohort, matched to it by run.
    tuple val(run), path(ready_bams), path(fai_index)

    output:
    tuple val(run), path("${run.vcf.fileName}.vcf"), emit: vcf_file

    script:
    reference = run.reference
    vcf_file = "${run.vcf.fileName}.vcf"
    // Read by step 7 always and step 8 when annotation is on, so it stays on the working volume
    // until both have finished. The only VCF here that is promoted rather than deleted.
    search_roots = searchRoots(run)
    rel_vcf = "${run.dir.subpath.vcf}"
    target_vcf_folder = "${run.dir.utilized}/${rel_vcf}"
    target_vcf_file = "${target_vcf_folder}/${vcf_file}"
    dir_log = "${run.dir.logs}/6_variant_call"

    """
    set -eo pipefail

    # Either volume: still here while step 7 or 8 may read it, promoted once both are done.
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
        ${run.software.bcftools} mpileup ${run.variantCall.mpileupOptions} \
        -f ${reference} ${ready_bams} | \
        ${run.software.bcftools} call ${run.variantCall.callOptions} \
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

workflow VariantCalling {
    take:
    profiled         // [run, pair_id, ready_bam, ready_bai, cap file] - from step 5
    fai_index        // [run, fai] - one per run
    expected         // [run, how many samples that run started with]

    main:
    // The ceiling is computed by a task, so it arrives as a file. A sample whose ceiling is 0
    // is not sent to CapBAM at all.
    routed = profiled.branch { _run, _pair_id, _bam, _bai, cap_file ->
        capped  : cap_file.text.trim() != '0'
        uncapped: true
    }

    CapBAM(routed.capped.map { run, pair_id, bam, bai, cap_file ->
        tuple(run, pair_id, bam, bai, cap_file.text.trim()) })

    out_ready_bams = CapBAM.out.capped_bam
        .mix(routed.uncapped.map { run, pair_id, bam, _bai, _cap -> tuple(run, pair_id, bam) })

    // The gather point: per sample above, one task per run over its whole cohort below.
    cohorts = out_ready_bams.groupTuple(by: 0)
        .join(expected, by: 0)
        .map { run, pair_ids, bams, n_expected ->
            // A SHORT COHORT IS A SILENT WRONG ANSWER, and this is the last place the expected
            // number is known.
            if (pair_ids.size() != n_expected) {
                throw new IllegalStateException(
                    "variant calling for run '${run.runId ?: 'single'}' received " +
                    "${pair_ids.size()} ready BAM(s) but the run started with ${n_expected} " +
                    "sample(s): ${(pair_ids as List).sort().join(', ')}.\n" +
                    "Calling a subset would publish a VCF that looks complete and is not, so " +
                    "the run is stopped instead.")
            }

            // bcftools names the VCF's sample columns in the order it receives the BAMs, and
            // arrival order is task-completion order - so they are sorted into metadata row
            // order first. The key is the SAMPLE ID, never the path, which begins with
            // Nextflow's work-directory hash. Anything unlisted sorts last, alphabetically.
            //
            // This orders ROWS, not columns: two rows sharing an RG_Sample are two sequencing
            // runs of one pool, which bcftools merges into a single column.
            def order = metadataOrder(run)
            def ordered = [pair_ids as List, bams as List].transpose().sort { a, b ->
                def rowA = order.indexOf(a[0]) < 0 ? order.size() : order.indexOf(a[0])
                def rowB = order.indexOf(b[0]) < 0 ? order.size() : order.indexOf(b[0])
                rowA != rowB ? rowA <=> rowB : a[0] <=> b[0]
            }
            return tuple(run, ordered.collect { row -> row[1] })
        }

    VariantCall(cohorts.join(fai_index, by: 0))

    emit:
    VariantCall.out.vcf_file
}