// What an analysis run invoked, written into the folder it publishes.
//
// One published analysis carries the result, the script that produced it, the record that
// cleared the folder, and this: CITATIONS.md and references.bib for the software behind it.
// Everything a reader needs to regenerate and to credit it is in one directory.
//
// Three sources are merged: PoolSeqFlow and Nextflow from install/citations.json, so the
// release holds one copy of each; the analysis layer's own from analysis/citations.json; and
// the module's, from its own directory. A module is published separately, so its methods
// citations travel with it and the frame keeps no list of them.

nextflow.enable.dsl=2

include { installDir } from './paths.nf'
include { moduleStore } from './modules.nf'

// The entries install/citations.json holds that an ANALYSIS run also invokes. It lists every
// tool the pipeline can call, and an analysis calls almost none of them.
def sharedCitationKeys() {
    return ['poolseqflow', 'nextflow']
}

// One citations file, or an empty map. A module without one is the ordinary case.
def readCitations(String path) {
    def source = file(path)
    if (!source.exists()) return [:]
    try {
        return new groovy.json.JsonSlurper().parseText(source.text)
    }
    catch (Exception e) {
        throw new IllegalStateException(
            "${path} cannot be read: ${e.message}\n" +
            "A citations file is JSON, in the shape analysis/citations.json documents.")
    }
}

// Everything one invocation of `module` should cite, keyed as write_citations.py expects.
def mergedCitations(String module) {
    def merged = [:]
    readCitations("${installDir()}/install/citations.json").each { key, entry ->
        if (sharedCitationKeys().contains(key)) merged[key] = entry
    }
    merged.putAll(readCitations("${installDir()}/analysis/citations.json")
                      .findAll { key, _entry -> !key.startsWith("_") })
    merged.putAll(readCitations("${moduleStore()}/${module}/citations.json")
                      .findAll { key, _entry -> !key.startsWith("_") })
    return merged
}

// The shell that writes CITATIONS.md and references.bib into `dest`.
//
// The merged set is rendered here rather than assembled in the task, so no reader of three
// JSON files has to exist on the far side of a PATH. Versions are asked of what is installed:
// an entry naming an r_package is asked of R, and one that cannot be answered is recorded
// without a version, which the writer already handles.
def citationShell(String module, String dest) {
    def merged = mergedCitations(module)
    // printf and not a heredoc: this whole block is interpolated into an indented script, and
    // a heredoc terminator that is not at column 0 never terminates.
    def json = groovy.json.JsonOutput.toJson(merged).replace("'", "'\\''")
    def packages = merged.findAll { _key, entry -> entry instanceof Map && entry.r_package }
                         .collect { key, entry -> "${key}=${entry.r_package}" }
    def release = "${workflow.manifest.version ?: ''}"
    def nextflowVersion = "${workflow.nextflow.version ?: ''}"

    def lines = []
    lines << "printf '%s' '${json}' > analysis_citations.json"
    lines << "VERSIONS=\"poolseqflow=${release} nextflow=${nextflowVersion}\""
    lines << "if command -v Rscript > /dev/null 2>&1; then"
    lines << "    RVER=\$(Rscript --vanilla -e 'cat(paste(R.version\$major, R.version\$minor, sep=\".\"))' 2>/dev/null || true)"
    lines << "    VERSIONS=\"\$VERSIONS r=\$RVER\""
    packages.each { pair ->
        def key = pair.split('=')[0]
        def pkg = pair.split('=')[1]
        lines << "    PV=\$(Rscript --vanilla -e 'cat(as.character(packageVersion(\"${pkg}\")))' 2>/dev/null || true)"
        lines << "    VERSIONS=\"\$VERSIONS ${key}=\$PV\""
    }
    lines << "fi"
    // Non-fatal: a published analysis without its citation list is worse than one whose
    // citation list could not be built, and the result itself is already correct.
    lines << "python3 ${installDir()}/bin/write_citations.py \\"
    lines << "    --data analysis_citations.json --out-dir \"${dest}\" \\"
    lines << "    --pipeline-version '${release}' \$VERSIONS > citations.txt 2>&1 || {"
    lines << "        echo \"CITATIONS: could not be written for ${module}:\" >&2"
    lines << "        cat citations.txt >&2"
    lines << "    }"
    return lines.join('\n    ')
}
