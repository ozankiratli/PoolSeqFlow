process VariantCall {
    tag { "calling_variants" }

    input:
    path ready_bams
    path fai_index

    output:
    path "${params.vcf.fileName}.vcf", emit: vcf_file

    script:
    reference = params.reference
    vcf_file = "${params.vcf.fileName}.vcf"
    target_vcf_folder = "${params.dir.output.vcf}"
    target_vcf_file = "${target_vcf_folder}/${vcf_file}"
    dir_log = "${params.dir.logs}/6_variant_call"

    """
    set -eo pipefail
    echo "VARIANT CALL ${vcf_file}: Variant calling started..."
    if [ -f ${target_vcf_file} ]; then
        echo "VARIANT CALL ${vcf_file}: Found existing VCF file" 
        echo "VARIANT CALL ${vcf_file}: Found: ${target_vcf_file}"
        echo "VARIANT CALL ${vcf_file}: Creating symbolic link..."
        ln -s ${target_vcf_file} .
        echo "VARIANT CALL ${vcf_file}: COMPLETED"
    else
        echo "VARIANT CALL ${vcf_file}: Creating VCF file..."
        ${params.software.bcftools} mpileup ${params.bcftools.mpileupOptions} \
        -f ${reference} ${ready_bams} | \
        ${params.software.bcftools} call ${params.bcftools.callOptions} \
        -o ${vcf_file}

        echo "VARIANT CALL ${vcf_file}: Fixing minor header issue..."
        sed -i 's/##INFO=<ID=MQ,Number=1,Type=Integer/##INFO=<ID=MQ,Number=1,Type=Float/' ${vcf_file}
        echo "VARIANT CALL ${vcf_file}: Type of MQ changed from Integer to Float..."

        echo "VARIANT CALL ${vcf_file}: Moving ${vcf_file} to ${target_vcf_folder}..."
        mkdir -p ${params.dir.output.vcf}
        atomic_mv.sh ${vcf_file} ${target_vcf_file}
        echo "VARIANT CALL ${vcf_file}: Creating symbolic link..."
        ln -s ${target_vcf_file} .
        echo "VARIANT CALL ${vcf_file}: COMPLETED"
    fi

    mkdir -p ${dir_log}
    cp .command.log ${dir_log}/6_VariantCall_${params.vcf.fileName}.log
    cp .command.err ${dir_log}/6_VariantCall_${params.vcf.fileName}.err
    """
}

// Read the sample order out of the RGTags file: ID column values in the order their rows
// appear. Returns an empty map if the file is missing or malformed - this runs while the
// workflow is being built, which is before step 0 has had a chance to report on it, so it
// must not throw. Step 0 fails the run on a missing file, a missing ID column or a sample
// that has no RGTags row, and its message is far more useful than a Groovy stack trace.
def rgTagsOrder() {
    def order = [:]
    def rgFile = file(params.rgTagsPath)

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
    out_ready_bams
    fai_index

    main:
    // Order the BAMs before handing them to bcftools. collect() alone emits in
    // task-completion order, so whichever sample finishes first lands first on the command
    // line and bcftools orders the VCF sample columns to match - two runs on the same
    // input would give frequency tables with differently ordered columns.
    //
    // The order to use is the RGTags row order, so the columns come out the way the user
    // laid their samples out rather than however they happen to sort as strings. Sorting
    // has to key on the sample id, not the file path: the paths begin with Nextflow's
    // random work-directory hash, so sorting those is no better than chance.
    //
    // Anything the RGTags file does not list sorts after everything it does, alphabetically
    // among itself. Step 0 already refuses to run with an unlisted sample, so this only
    // keeps the comparator well defined.
    def rgOrder = rgTagsOrder()

    ready_bams = out_ready_bams
            .toSortedList { a, b ->
                def rowA = rgOrder.getOrDefault(a[0], rgOrder.size())
                def rowB = rgOrder.getOrDefault(b[0], rgOrder.size())
                rowA != rowB ? rowA <=> rowB : a[0] <=> b[0]
            }
            .map { rows -> rows.collect { row -> row[1] } }

    VariantCall(ready_bams,fai_index)

    emit:
    vcf = VariantCall.out.vcf_file
}