// Analysis/Main: what one module derives and every module after it reuses.
//
// Three things live here. Where an intermediate sits, given the results directory it was
// derived from; the record of which results those were; and how one is copied back when
// `PoolSeqFlow analysis complete` has archived it to permanent storage.

nextflow.enable.dsl=2

include { intermediatesDir } from './paths.nf'

// What a provenance record is called, beside the intermediate it describes.
def provenanceSuffix() {
    return '.provenance'
}

// Where a target's intermediates sit on the working volume.
def intermediateDir(Map target) {
    return "${intermediatesDir()}/${target.label}".toString()
}

// The same directory as a path relative to a volume root. mainDir and storageDir hold it under
// the identical name, which is what makes the lookup below a two-root search.
def intermediateSubpath(Map target) {
    return intermediateDir(target).substring("${params.mainDir}/".length())
}

// One intermediate, on the working volume.
def intermediateFile(Map target, String name) {
    return "${intermediateDir(target)}/${name}".toString()
}

// A record file's contents, condensed. `absent` and not an empty digest: a record that is not
// there and a record that is empty are different states.
def recordDigest(String path) {
    def record = file(path)
    if (!record.exists()) return 'absent'
    return java.security.MessageDigest.getInstance('SHA-256')
        .digest(record.bytes).encodeHex().toString()
}

// The results an intermediate was derived from, as the records the pipeline wrote beside them.
// Every one of these decides what a frequency means, so an intermediate carrying an older copy
// was derived from results that no longer exist.
def resultsIdentity() {
    def root = "${params.storageDir}/Output"
    def lines = ["release                ${workflow.manifest.version ?: 'unknown'}".toString()]
    ['.poolseqflow_version', '.poolseqflow_params', '.multirun.csv'].each { name ->
        lines << "${name.padRight(22)} ${recordDigest("${root}/${name}")}".toString()
    }
    return lines.join('\n')
}

// The shell that installs a derived intermediate: its provenance record first, then the file
// itself under its final name.
//
// That order is the invariant the restore below reads: an intermediate that is there is one
// whose provenance can be read. `atomic_mv.sh` for both, so neither is ever seen partial, and
// two modules deriving the same intermediate at once write the same bytes to both.
def publishIntermediate(Map target, String name, String source) {
    def dir = intermediateDir(target)
    def record = "${name}${provenanceSuffix()}"
    def lines = resultsIdentity().readLines().collect { line -> "'${line}'" }.join(' ')
    return "mkdir -p '${dir}' && printf '%s\\n' ${lines} > '${record}' && " +
           "atomic_mv.sh '${record}' '${dir}/${record}' && " +
           "atomic_mv.sh '${source}' '${dir}/${name}'"
}

// Whatever a module named that already exists, on the working volume and fresh.
//
// An intermediate that is not there anywhere is the ordinary answer on a first run and the
// module derives it. One that is stale fails the run, naming the file and what moved: it may be
// the input to an analysis that has already been published, so removing it is the user's call.
//
// An archived intermediate is COPIED back: permanent storage keeps its copy, and the next
// `complete` discards the working one.
process FetchIntermediates {
    tag { target.label }
    // A transfer between volumes is the one thing here a user should see happen.
    debug true

    input:
    tuple val(target), val(names)

    output:
    val target

    script:
    identity = resultsIdentity()
    rel      = intermediateSubpath(target)
    work     = intermediateDir(target)
    suffix   = provenanceSuffix()
    storage  = params.storageDir
    wanted   = names.collect { name -> "'${name}'" }.join(' ')
    """
    set -eo pipefail

    cat <<'IDENTITY' > identity.txt
${identity}
IDENTITY

    no_record() {
        echo "INTERMEDIATES ${target.label}: ERROR: \$1 has no provenance record beside it." >&2
        echo "INTERMEDIATES ${target.label}: \$1${suffix} says which results it was derived from, and without" >&2
        echo "INTERMEDIATES ${target.label}: it there is no telling whether it still describes them." >&2
        echo "INTERMEDIATES ${target.label}: Remove \$1 and the next run derives it again." >&2
        exit 1
    }

    # One named item from permanent storage onto the working volume, leaving the source where
    # it is: staged beside the destination, verified against the source, then renamed into
    # place. The stage sits in the destination directory, so the rename is a rename.
    copy_back() {
        local src dest stage landed
        src="\$1"
        dest="\$2"
        mkdir -p "\$(dirname "\$dest")"
        stage=\$(mktemp -d "\$(dirname "\$dest")/.restore.XXXXXXXX")
        landed="\$stage/\$(basename -- "\$src")"
        if ! rsync -a -- "\$src" "\$stage/"; then
            rm -rf -- "\$stage"
            echo "INTERMEDIATES ${target.label}: ERROR: could not copy \$src" >&2
            exit 1
        fi
        if ! diff -qr --no-dereference -- "\$src" "\$landed" > /dev/null 2>&1; then
            rm -rf -- "\$stage"
            echo "INTERMEDIATES ${target.label}: ERROR: the copy of \$src does not match it." >&2
            exit 1
        fi
        if ! atomic_mv.sh "\$landed" "\$dest"; then
            rm -rf -- "\$stage"
            exit 1
        fi
        rmdir "\$stage"
    }

    restore_one() {
        local name at record
        name="\$1"
        # The working volume by name, and permanent storage only if it is not there. After a
        # restore the intermediate is in BOTH roots, which is a state find_artifact.sh reports
        # as a promotion that did not finish.
        at="${work}/\$name"
        if [ ! -e "\$at" ]; then
            at=\$(find_artifact.sh "${rel}/\$name" "${storage}" || true)
        fi

        if [ -z "\$at" ]; then
            echo "INTERMEDIATES ${target.label}: \$name  not derived yet"
            return 0
        fi

        record="\$at${suffix}"
        [ -f "\$record" ] || no_record "\$at"

        if [ "\$at" != "${work}/\$name" ]; then
            # Named files, one at a time. A directory copy would bring back whatever else is in
            # permanent storage beside them.
            copy_back "\$record" "${work}/\$name${suffix}"
            copy_back "\$at" "${work}/\$name"
            record="${work}/\$name${suffix}"
            echo "INTERMEDIATES ${target.label}: \$name  copied back from permanent storage"
        else
            echo "INTERMEDIATES ${target.label}: \$name  on the working volume"
        fi

        if diff -q identity.txt "\$record" > /dev/null 2>&1; then
            return 0
        fi

        echo "INTERMEDIATES ${target.label}: ERROR: ${work}/\$name is STALE." >&2
        echo "INTERMEDIATES ${target.label}: It was derived from results this project no longer holds:" >&2
        # `|| true` is load-bearing: diff exits 1 on a difference, and the task runs under -e.
        { diff identity.txt "\$record" || true; } | while IFS= read -r line; do
            case "\$line" in
                '<'*) printf 'INTERMEDIATES ${target.label}:   now  %s\\n' "\${line#< }" >&2 ;;
                '>'*) printf 'INTERMEDIATES ${target.label}:   was  %s\\n' "\${line#> }" >&2 ;;
            esac
        done
        echo "INTERMEDIATES ${target.label}: An analysis already published may have been computed from it, so it" >&2
        echo "INTERMEDIATES ${target.label}: is not removed for you. Delete it and the next run derives it again." >&2
        exit 1
    }

    for name in ${wanted}; do
        restore_one "\$name"
    done
    """
}

// What a module calls before it reads or derives anything shared.
workflow RestoreIntermediates {
    take:
    wanted        // [ target, the intermediates it works from ]

    main:
    FetchIntermediates(wanted)

    emit:
    FetchIntermediates.out
}
