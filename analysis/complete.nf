// Moving finished analyses out of the working volume and into permanent storage.
//
// An entry script of its own, launched by `PoolSeqFlow analysis complete`, the way dryrun.nf
// and a module's main.nf are: `-entry` selects nothing under the strict parser.
//
// `Analysis/Main` and `Analysis/Results` move; `Analysis/Logs`, `Analysis/Session` and
// `Analysis/work` stay where they are. The same relative path is used under either volume,
// which is what lets RestoreIntermediates find an archived intermediate again.
//
// Everything is surveyed before anything is moved or discarded. A results folder whose name is
// already taken stops the command with nothing done; an intermediate already in permanent
// storage is the state a resume leaves behind, and the working copy is discarded instead.
// Interrupted, it can be run again: each item moves on its own and one already moved is
// reported rather than repeated.

nextflow.enable.dsl=2

include { analysisRoot; intermediatesDir; resultsDir; verificationRecordName } from './lib/paths.nf'
include { provenanceSuffix } from './lib/store.nf'

// Where the analysis layer keeps its own record, under mainDir.
def completeLogDir() {
    return "${analysisRoot()}/Logs/complete".toString()
}

process ArchiveAnalysis {
    // A move between volumes is the one thing here a user should see happen.
    debug true

    input:
    val context

    output:
    val true

    script:
    working = analysisRoot()
    permanent = "${params.storageDir}/${analysisRoot().substring("${params.mainDir}/".length())}".toString()
    keep = verificationRecordName()
    suffix = provenanceSuffix()
    // The two roots as the survey names them: relative, because the same name addresses either
    // volume and that is what an item in the lists below is.
    main_root = intermediatesDir().substring("${working}/".length())
    results_root = resultsDir().substring("${working}/".length())
    dir_log = completeLogDir()
    """
    set -eo pipefail

    WORKING="${working}"
    PERMANENT="${permanent}"

    echo "COMPLETE: from \$WORKING"
    echo "COMPLETE:   to \$PERMANENT"

    if [ ! -d "\$WORKING" ]; then
        echo "COMPLETE: there is no Analysis directory to move."
        exit 0
    fi

    # WHAT MOVES, one relative path per line. A list in a file rather than a variable: these
    # are paths, and word splitting is not how paths are read.
    : > items.txt

    # Every file under Main, which carries the provenance records along with the intermediates
    # they describe.
    if [ -d "\$WORKING/${main_root}" ]; then
        ( cd "\$WORKING" && find ${main_root} -type f ) | LC_ALL=C sort >> items.txt
    fi

    # Every directory under Results holding a verification record - that record is what marks
    # one published analysis. Pruned at the first one found, so a folderName that is a path
    # moves as one piece and can never be moved out from under its own parent.
    if [ -d "\$WORKING/${results_root}" ]; then
        ( cd "\$WORKING" && find ${results_root} -type d -exec test -e '{}/${keep}' ';' -print -prune ) \\
            | LC_ALL=C sort > candidates.txt
        while IFS= read -r rel; do
            [ -n "\$rel" ] || continue
            # A folder holding nothing but the record is a failed attempt, not an analysis:
            # archiving it would take the name into permanent storage and refuse the retry.
            held=\$(find "\$WORKING/\$rel" -mindepth 1 -maxdepth 1 ! -name '${keep}' | wc -l)
            if [ "\$held" -eq 0 ]; then
                echo "COMPLETE: \$rel  left behind - it holds a verification record and no analysis"
            else
                printf '%s\\n' "\$rel" >> items.txt
            fi
        done < candidates.txt
    fi

    # WHAT HAPPENS TO EACH ITEM. A name already in permanent storage means two different things
    # depending on which root it is under. Under Results it is two analyses under one name.
    # Under Main it is the state a resume leaves behind: the intermediate was COPIED back, so
    # permanent storage still holds it and the working copy is the duplicate.
    : > move.txt
    : > discard.txt
    : > taken.txt
    : > disagree.txt

    while IFS= read -r rel; do
        [ -n "\$rel" ] || continue
        if [ ! -e "\$PERMANENT/\$rel" ]; then
            printf '%s\\n' "\$rel" >> move.txt
            continue
        fi
        case "\$rel" in
            ${main_root}/*)
                # The provenance records decide, not the bytes. A record is its own provenance.
                case "\$rel" in
                    *'${suffix}') HERE="\$WORKING/\$rel"; THERE="\$PERMANENT/\$rel" ;;
                    *)            HERE="\$WORKING/\$rel${suffix}"; THERE="\$PERMANENT/\$rel${suffix}" ;;
                esac
                if [ ! -f "\$HERE" ] || [ ! -f "\$THERE" ]; then
                    printf '%s\\n' "\$rel  (one side has no provenance record)" >> disagree.txt
                elif diff -q "\$HERE" "\$THERE" > /dev/null 2>&1; then
                    printf '%s\\n' "\$rel" >> discard.txt
                else
                    printf '%s\\n' "\$rel  (the records differ)" >> disagree.txt
                fi
                ;;
            *)
                printf '%s\\n' "\$rel" >> taken.txt
                ;;
        esac
    done < items.txt

    if [ -s taken.txt ] || [ -s disagree.txt ]; then
        if [ -s taken.txt ]; then
            echo "COMPLETE: ERROR: already in permanent storage under the same name:" >&2
            while IFS= read -r line; do echo "COMPLETE:   \$line" >&2; done < taken.txt
            echo "COMPLETE: Move the copy in permanent storage out of the way, or rename this" >&2
            echo "COMPLETE: one in its config, and run this again." >&2
        fi
        if [ -s disagree.txt ]; then
            echo "COMPLETE: ERROR: an intermediate is in both places and they do not agree:" >&2
            while IFS= read -r line; do echo "COMPLETE:   \$line" >&2; done < disagree.txt
            echo "COMPLETE: One of the two was derived from results this project no longer holds." >&2
            echo "COMPLETE: An analysis already published may have come from either, so neither is" >&2
            echo "COMPLETE: removed for you. Delete the one you do not want and run this again." >&2
        fi
        echo "COMPLETE: Nothing was moved and nothing was discarded." >&2
        exit 1
    fi

    # THE DISCARD. Before the move, so an interrupted run has already reclaimed the duplicates.
    DISCARDED=0
    while IFS= read -r rel; do
        [ -n "\$rel" ] || continue
        rm -f "\$WORKING/\$rel"
        DISCARDED=\$(( DISCARDED + 1 ))
        echo "COMPLETE: \$rel  discarded - permanent storage has it"
    done < discard.txt

    # THE MOVE. One named item at a time, and the source asserted gone after each: a wholesale
    # directory move would carry off whatever else permanent storage holds beside them.
    MOVED=0
    while IFS= read -r rel; do
        [ -n "\$rel" ] || continue
        atomic_mv.sh "\$WORKING/\$rel" "\$PERMANENT/\$rel"
        if [ -e "\$WORKING/\$rel" ]; then
            echo "COMPLETE: ERROR: still there after the move: \$WORKING/\$rel" >&2
            exit 1
        fi
        MOVED=\$(( MOVED + 1 ))
        echo "COMPLETE: \$rel"
    done < move.txt

    # Only directories that are genuinely empty, deepest first.
    for root in ${main_root} ${results_root}; do
        [ -d "\$WORKING/\$root" ] || continue
        find "\$WORKING/\$root" -depth -type d -empty -delete 2>/dev/null || true
    done

    echo "COMPLETE: \$MOVED item(s) moved, \$DISCARDED already in permanent storage and discarded"
    echo "COMPLETE: Logs, Session and work stay on the working volume - Session is rewritten by"
    echo "COMPLETE: the next analysis and Logs is appended to by every one of them."

    mkdir -p ${dir_log}
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${dir_log}/complete_nextflow.log
    """
}

workflow {
    ArchiveAnalysis(channel.value(true))
}
