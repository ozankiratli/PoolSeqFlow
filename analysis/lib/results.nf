// Installing a module's finished analysis into the folder the verification cleared for it.
//
// Everything the module produced for one results directory is assembled beside the destination
// and moved in under its final name in a single rename, so the folder is only ever absent or
// complete.

nextflow.enable.dsl=2

include { verificationRecordName } from './paths.nf'
include { citationShell } from './citations.nf'

// What counts as the script that produced a result, by extension: R, and the shell, Python and
// Julia a module may drive it from.
def scriptSuffixes() {
    return ['R', 'r', 'Rmd', 'rmd', 'sh', 'py', 'jl']
}

// One results directory's analysis, moved into place.
process InstallResults {
    tag { target.label }
    // Where an analysis landed, and how much of it, on the console of the run that made it.
    debug true

    input:
    tuple val(target), path(produced, stageAs: 'produced/*')

    output:
    val target

    script:
    keep = verificationRecordName()
    // `find -name` tests, one per accepted extension, joined for a single walk of the stage.
    script_test = scriptSuffixes().collect { s -> "-name '*.${s}'" }.join(' -o ')
    script_list = scriptSuffixes().collect { s -> "*.${s}" }.join(', ')
    // Written into the STAGE, so the citations arrive in the same rename as the analysis.
    citations = citationShell("${target.module}", '$STAGE')
    """
    set -eo pipefail

    DEST="${target.results}"
    echo "PUBLISHING ${target.label}: \$DEST"

    mkdir -p "\$(dirname "\$DEST")"
    STAGE=\$(mktemp -d "\$(dirname "\$DEST")/.analysis_results.XXXXXXXX")
    trap 'rm -rf -- "\$STAGE"' EXIT

    # Copied through the links Nextflow stages inputs as: `cleanup = true` removes the work
    # directory a link points into, and a published result outlives the run that made it.
    if [ -d produced ]; then
        cp -RL produced/. "\$STAGE/"
    fi

    # The script that produced the result travels with it. Checked in the stage, so a module
    # that emits none stops before anything is published.
    SCRIPTS=\$(find "\$STAGE" -type f \\( ${script_test} \\) | wc -l)
    if [ "\$SCRIPTS" -eq 0 ]; then
        echo "PUBLISHING ${target.label}: ERROR: this analysis carries no script." >&2
        echo "PUBLISHING ${target.label}: What it produced:" >&2
        find "\$STAGE" -mindepth 1 | sed 's|.*/|  |' >&2
        echo "PUBLISHING ${target.label}: A published result has to ship the script that made it -" >&2
        echo "PUBLISHING ${target.label}: one of ${script_list} - or nobody can regenerate it." >&2
        echo "PUBLISHING ${target.label}: Nothing was published and the folder is untouched." >&2
        exit 1
    fi

    # What this analysis was produced with, beside the analysis itself.
    ${citations}

    if [ -d "\$DEST" ]; then
        HELD=\$(find "\$DEST" -mindepth 1 -maxdepth 1 ! -name '${keep}' | wc -l)
        if [ "\$HELD" -ne 0 ]; then
            if [ "\$HELD" -eq 1 ]; then WHAT="entry"; else WHAT="entries"; fi
            echo "PUBLISHING ${target.label}: ERROR: \$DEST holds \$HELD \$WHAT that this run did not put there." >&2
            find "\$DEST" -mindepth 1 -maxdepth 1 ! -name '${keep}' | sed 's|.*/|  |' >&2
            echo "PUBLISHING ${target.label}: The verification cleared this folder before the module started, so" >&2
            echo "PUBLISHING ${target.label}: something else has written into it since. Move it out of the way." >&2
            exit 1
        fi
        # The record the verification wrote travels with the analysis it cleared. Put back if
        # the folder turns out not to be empty after all: the EXIT trap set above removes the
        # staging directory, and the record would go with it.
        if [ -f "\$DEST/${keep}" ]; then mv "\$DEST/${keep}" "\$STAGE/"; fi
        if ! rmdir "\$DEST"; then
            if [ -f "\$STAGE/${keep}" ]; then mv "\$STAGE/${keep}" "\$DEST/"; fi
            echo "PUBLISHING ${target.label}: ERROR: \$DEST could not be emptied to move the analysis in." >&2
            exit 1
        fi
    fi

    mv "\$STAGE" "\$DEST"
    trap - EXIT

    echo "PUBLISHING ${target.label}: \$(find "\$DEST" -mindepth 1 | wc -l) item(s)"
    """
}

// What a module calls once it has everything it produced for one results directory.
workflow PublishResults {
    take:
    produced      // [ target, the files that make up its analysis ]

    main:
    InstallResults(produced)

    emit:
    InstallResults.out
}
