// The PDF a published analysis carries: every result in the folder, each under its own file
// name.
//
// A FRAME CAPABILITY, not a module's: it is built from the same output declarations as the README,
// so a module writes nothing to get one.
//
// Knitted by knitr and turned into a PDF by pandoc with typst as the engine. Not
// rmarkdown::pdf_document, which is bound to LaTeX and ignores the engine it is given.

nextflow.enable.dsl=2

include { installDir; frameVersion } from './paths.nf'
include { moduleEntry } from './modules.nf'
include { moduleOutputs; frameOutputs } from './outputs.nf'

def reportName() {
    return 'report.pdf'
}

def reportTemplate() {
    return "${installDir()}/analysis/lib/rmd/report.Rmd".toString()
}

// What the template renders from: where the folder is, what made it, and every file the module
// declared with the summary it declared. `report.pdf` itself is left out.
def reportSpec(String module, Map target, String folder) {
    def entry = moduleEntry(module)
    def outputs = (moduleOutputs(module) + frameOutputs())
        .findAll { output -> "${output.file}" != reportName() }
        .collect { output -> [ file: "${output.file}".toString(),
                               summary: "${output.summary ?: ''}".toString() ] }
    return groovy.json.JsonOutput.toJson([
        label  : "${target.label}".toString(),
        module : module,
        version: "${entry.version}".toString(),
        release: "${workflow.manifest.version ?: 'unknown'}".toString(),
        frame  : frameVersion(),
        source : "${target.dir}".toString(),
        folder : folder,
        outputs: outputs ])
}

// The shell that writes the report into `dest`.
//
// It does not fail the publish, and prints the reason when it cannot build one.
def reportShell(String module, Map target, String dest) {
    def spec = reportSpec(module, target, dest).replace("'", "'\\''")
    def lines = []
    lines << "printf '%s' '${spec}' > report_spec.json"
    lines << "POOLSEQFLOW_REPORT_SPEC=\"\$PWD/report_spec.json\" \\"
    lines << "    Rscript --vanilla -e 'knitr::knit(commandArgs(TRUE)[1], \"report.md\", quiet = TRUE)' \\"
    lines << "    '${reportTemplate()}' > report_knit.log 2>&1 \\"
    lines << " && pandoc report.md -o \"${dest}/${reportName()}\" --pdf-engine=typst \\"
    lines << "    >> report_knit.log 2>&1 \\"
    lines << " || {"
    lines << "    echo \"PUBLISHING ${target.label}: the PDF report could not be built. The analysis\" >&2"
    lines << "    echo \"PUBLISHING ${target.label}: is published without it; every number in it is a file\" >&2"
    lines << "    echo \"PUBLISHING ${target.label}: in the folder already.\" >&2"
    lines << "    sed 's/^/PUBLISHING ${target.label}:   /' report_knit.log >&2 || true"
    lines << "  }"
    return lines.join('\n    ')
}
