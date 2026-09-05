// A published file and the section of the manual that says how to read it.
//
// Every module declares an anchor per output in its manifest, and the frame renders one README
// from all of them into the folder it publishes.
//
// An `anchor` names a heading of the manual this release ships, by the slug build_docs.py
// generates the site from, and one no heading answers to is refused. A module published
// separately has nowhere in that manual to point, and gives a `url` instead.

nextflow.enable.dsl=2

include { installDir; verificationRecordName } from './paths.nf'
include { moduleEntry } from './modules.nf'

// The manual this release ships, installed beside the code. Authoritative for this release; the
// site publishes the same text for whichever release is current.
def manualFile() {
    return "${installDir()}/manual/PoolSeqFlow-manual.md".toString()
}

// Mirrored by the URL in parameters.config.template and analysis.config.template.
def manualSite() {
    return 'https://ozankiratli.github.io/PoolSeqFlow/'
}

// What every published analysis carries whichever module produced it.
def frameOutputs() {
    return [
        [ file   : verificationRecordName(),
          summary: 'the checks that cleared this folder, and what they were run against',
          anchor : 'verification' ],
        [ file   : 'CITATIONS.md',
          summary: 'the software this analysis used, for a methods section',
          anchor : 'citing-the-tools-it-runs' ],
        [ file   : 'references.bib',
          summary: 'the same list as BibTeX',
          anchor : 'citing-the-tools-it-runs' ],
        [ file    : 'report.pdf',
          summary : 'every result in this folder in one document, each under its own file name',
          anchor  : 'analysis-report',
          optional: true ],
    ]
}

// The anchors the shipped manual answers to: an attr_list id where a heading pins one, and the
// slug of the heading text where it does not. Mirrors slugify() in dev/scripts/build_docs.py.
def manualAnchors() {
    def source = file(manualFile())
    if (!source.exists()) {
        throw new IllegalStateException(
            "the manual this release ships is not installed:\n" +
            "    ${manualFile()}\n" +
            "A published analysis links every file it holds to the section that says how to read " +
            "it, and those links are checked against that file. Install this release again.")
    }
    def anchors = []
    source.readLines().each { line ->
        def heading = (line =~ /^#{1,6}\s+(.*)$/)
        if (!heading) return
        def title = "${heading[0][1]}".trim()
        def pinned = (title =~ /\{:?\s*#([\w-]+)\s*\}\s*$/)
        anchors << (pinned ? "${pinned[0][1]}".toString() : slugifyHeading(title))
    }
    return anchors
}

// A heading's text as Python-Markdown's toc slugifies it. Underscores are kept: `\w` keeps them,
// so an `RG_Sample` heading anchors as rg_sample.
def slugifyHeading(String title) {
    def text = title.replaceAll(/\{:?\s*#[\w-]+\s*\}\s*$/, '')
    text = text.replaceAll(/\[([^\]]*)\]\([^)]*\)/, '$1')
    text = text.replaceAll(/<[^>]+>/, '')
    text = text.replace('`', '').replace('*', '')
    text = java.text.Normalizer.normalize(text, java.text.Normalizer.Form.NFKD)
    text = text.replaceAll(/[^\p{ASCII}]/, '')
    text = text.replaceAll(/[^\w\s-]/, '').trim().toLowerCase()
    return text.replaceAll(/[-\s]+/, '-')
}

// The outputs a module declares, checked. Called while the DAG is built, so a manifest that
// promises a section the manual does not have stops before any compute.
def checkModuleOutputs(String module, List outputs) {
    def anchors = manualAnchors()
    outputs.eachWithIndex { entry, index ->
        if (!(entry instanceof Map) || !entry.file) {
            throw new IllegalArgumentException(
                "the module '${module}' declares an output with no 'file' (entry ${index + 1} of " +
                "its manifest's outputs). Each one names the file it publishes and the manual " +
                "section that says how to read it.")
        }
        if (!entry.anchor && !entry.url) {
            throw new IllegalArgumentException(
                "the module '${module}' declares '${entry.file}' with no 'anchor' and no 'url'.\n" +
                "An anchor names a heading of the manual this release ships; a url is for a " +
                "module published separately, whose section is not in it.")
        }
        if (entry.anchor && !anchors.contains("${entry.anchor}".toString())) {
            throw new IllegalArgumentException(
                "the module '${module}' says '${entry.file}' is explained at '#${entry.anchor}', " +
                "and no heading of\n" +
                "    ${manualFile()}\n" +
                "answers to that anchor. A link nobody can follow is worse than none: correct the " +
                "manifest, or give a full 'url' if the section is not in this manual.")
        }
    }
}

def moduleOutputs(String module) {
    def declared = moduleEntry(module).outputs
    return declared instanceof List ? declared : []
}

// Where one output's explanation is, as a README link.
def outputLink(Map entry) {
    if (entry.url) return "[${entry.url}](${entry.url})".toString()
    return "[#${entry.anchor}](${manualFile()}#${entry.anchor})".toString()
}

// How the design was read, for the published folder. The same list the verification report
// renders: a note that reaches only a console is lost by the time anyone reads the result.
def readmeDesignLines(Map target) {
    def design = target.design
    def lines = []
    if (design?.time != null) {
        def how = design.time.kind == 'datetime'
            ? "parsed as `${design.time.format}` under locale `${design.time.locale}`"
            : (design.time.kind == 'numerical' ? "numeric, in ${design.time.unit}s" : 'categorical, ordered as below')
        lines << ''
        lines << '## The time axis'
        lines << ''
        lines << "`${design.time.column}`, ${how}. The levels, in the order this analysis used them:"
        lines << ''
        lines << "    ${design.time.levels.collect { level -> level.shown }.join('  ')}"
    }
    if (design?.warnings) {
        lines << ''
        lines << '## Read these before the numbers'
        lines << ''
        design.warnings.each { note -> lines << "- ${note.detail.split('\n').join(' ')}".toString() }
    }
    return lines
}

// The README a published folder carries: every file in it, what it is, and where to read about
// it. Rendered from the module's declarations and the frame's own, so no module writes its own.
def readmeText(String module, Map target, List outputs) {
    def entry = moduleEntry(module)
    def lines = ["# ${target.label}: ${module}".toString(),
                 '',
                 "Produced by PoolSeqFlow ${workflow.manifest.version ?: 'unknown'}, module " +
                 "${module} v${entry.version}, reading".toString(),
                 '',
                 "    ${target.dir}".toString(),
                 '',
                 'What is in this folder, and where the manual explains it:',
                 '',
                 '| File | What it is | Explained at |',
                 '|---|---|---|']

    // An optional output is named whether or not this run produced one: a reader who finds no
    // plot here needs to know that a setting decides it, and a table listing only what happens
    // to be present cannot tell them.
    (outputs + frameOutputs()).each { output ->
        def what = "${output.summary ?: ''}${output.optional ? ' *(only when the setting that produces it is set)*' : ''}"
        lines << "| `${output.file}` | ${what} | ${outputLink(output)} |".toString()
    }

    lines.addAll(readmeDesignLines(target))

    lines << ''
    lines << 'The manual this release ships is the one linked above. The same text for whichever'
    lines << "release is current is at ${manualSite()}".toString()
    return lines.join('\n') + '\n'
}

// The shell that writes README.md into `dest`, and refuses a module that declared a file it did
// not publish. Rendered into the task's own script, the way citationShell() is.
def readmeShell(String module, Map target, String dest) {
    def outputs = moduleOutputs(module)
    def text = readmeText(module, target, outputs).replace("'", "'\\''")

    def lines = []
    outputs.each { output ->
        // An output a module produces only under a setting - a plot of the chromosomes you
        // named, and none when you named none. It is declared so the README can say what it
        // would be and when it appears, and its absence is not a broken module.
        if (output.optional) return
        // The declared name may be a glob, so the test counts what it matched.
        lines << "MATCHED=\$(find \"${dest}\" -maxdepth 1 -name '${output.file}' | wc -l)"
        lines << "if [ \"\$MATCHED\" -eq 0 ]; then"
        lines << "    echo \"PUBLISHING ${target.label}: ERROR: ${module} declares it publishes '${output.file}',\" >&2"
        lines << "    echo \"PUBLISHING ${target.label}: and this analysis produced nothing matching it.\" >&2"
        lines << "    echo \"PUBLISHING ${target.label}: What it produced:\" >&2"
        lines << "    find \"${dest}\" -mindepth 1 -maxdepth 1 | sed 's|.*/|  |' >&2"
        lines << "    echo \"PUBLISHING ${target.label}: Nothing was published and the folder is untouched.\" >&2"
        lines << "    exit 1"
        lines << "fi"
    }
    lines << "printf '%s' '${text}' > \"${dest}/README.md\""
    return lines.join('\n    ')
}
