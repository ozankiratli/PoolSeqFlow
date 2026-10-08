// The PDF a published analysis carries. A module that declares a `report` in its manifest lays
// out its own results in it; any other module gets each table and figure it declared, under the
// file's name.
//
// Knitted by knitr and turned into a PDF by pandoc with typst as the engine. Not
// rmarkdown::pdf_document, which is bound to LaTeX and ignores the engine it is given.

nextflow.enable.dsl=2

include { installDir; frameVersion; releaseVersion } from './paths.nf'
include { moduleEntry } from './modules.nf'
include { moduleOutputs; frameOutputs } from './outputs.nf'

// The name the PDF is published under: the target's outputPrefix, the module, and `stamp`, the
// time it was built as yyyyMMdd-HHmmss.
def reportName(Map target, String stamp) {
    return "${target.prefix}_${target.module}_report_${stamp}.pdf".toString()
}

def reportTemplate() {
    return "${installDir()}/analysis/lib/rmd/report.Rmd".toString()
}

// The functions every report is drawn with, the frame's and a module's alike.
def reportLibrary() {
    return "${installDir()}/analysis/lib/rmd/report.R".toString()
}

// What the template renders from: what made the folder, the warnings its design carries, the
// module's own report if it declares one, and every file the module declared with the summary it
// declared, under the name the module wrote it. The report itself is left out. The folder is not in
// it: it exists only once the task runs, and reaches the template as POOLSEQFLOW_REPORT_FOLDER.
def reportSpec(String module, Map target, String report) {
    def entry = moduleEntry(module)
    def outputs = (moduleOutputs(module) + frameOutputs(report))
        .findAll { output -> "${output.file}" != report }
        .collect { output -> [ file: "${output.file}".toString(),
                               summary: "${output.summary ?: ''}".toString() ] }
    def child = entry.report ? "${entry.dir}/${entry.report}".toString() : ''
    def warnings = (target.design?.warnings ?: [])
        .collect { note -> "${note.detail}".split('\n').join(' ').toString() }
    return groovy.json.JsonOutput.toJson([
        label   : "${target.label}".toString(),
        module  : module,
        version : "${entry.version}".toString(),
        release : releaseVersion(),
        frame   : frameVersion(),
        source  : "${target.dir}".toString(),
        warnings: warnings,
        library : reportLibrary(),
        child   : child,
        outputs : outputs ])
}

// The shell that writes the report into `dest` as `report`. The files it reads are published
// under the target's outputPrefix, which reaches the template as POOLSEQFLOW_REPORT_PREFIX.
//
// It does not fail the publish, and prints the reason when it cannot build one. On stdout: the
// task succeeds, and Nextflow shows a successful task's stdout under `debug` and never its stderr.
def reportShell(String module, Map target, String dest, String report) {
    def spec = reportSpec(module, target, report).replace("'", "'\\''")
    def lines = []
    lines << "printf '%s' '${spec}' > report_spec.json"
    lines << "POOLSEQFLOW_REPORT_SPEC=\"\$PWD/report_spec.json\" POOLSEQFLOW_REPORT_FOLDER=\"${dest}\" \\"
    lines << "    POOLSEQFLOW_REPORT_PREFIX='${target.prefix}' \\"
    lines << "    Rscript --vanilla -e 'knitr::opts_knit\$set(root.dir = getwd()); knitr::knit(commandArgs(TRUE)[1], \"report.md\", quiet = TRUE)' \\"
    lines << "    '${reportTemplate()}' > report_knit.log 2>&1 \\"
    lines << " && pandoc report.md -o \"${dest}/${report}\" --pdf-engine=typst \\"
    lines << "    >> report_knit.log 2>&1 \\"
    lines << " || {"
    lines << "    echo \"PUBLISHING ${target.label}: the PDF report could not be built. The analysis\""
    lines << "    echo \"PUBLISHING ${target.label}: is published without it; every number in it is a file\""
    lines << "    echo \"PUBLISHING ${target.label}: in the folder already.\""
    lines << "    sed 's/^/PUBLISHING ${target.label}:   /' report_knit.log || true"
    lines << "  }"
    return lines.join('\n    ')
}
