#!/usr/bin/env nextflow

// A DRY RUN: verify the project, report where the work would go, and create the empty tree.
//
// Z, 2026-08-27: a subcommand that runs verify-environment, reports what the divergence
// analysis found, and creates the empty directory tree so the user can look at it and approve
// before any compute is spent. It replaces the "warn but allow" treatment of a run that points
// its own storageDir somewhere else, which said the right thing in the wrong place: a warning
// in a log describes a layout, while a directory tree IS one.
//
// A SEPARATE ENTRY POINT AND NOT A FLAG INSIDE poolseqflow.nf, because Nextflow's strict parser
// refuses `-entry` outright - "use a param to run a named workflow from the entry workflow" -
// and the alternative, wrapping the whole pipeline body in an `if`, would put the thing that
// decides whether hours of compute happen inside the file that describes it.
//
// The mode is still a param as well as an entry point, and both halves are needed: this file is
// what stops the pipeline from running, and `params.dryRun` is what tells step 0's stages to
// record nothing. Either alone would be a mode that half exists - an entry point without the
// flag would stamp the project's baseline from a preview, and the flag without the entry point
// would be a full run that lied about it.
//
// EVERYTHING THE DRY RUN IS LIVES IN THIS ONE FILE, process included, which is the one place
// the pipeline departs from "entry points at the top, processes in scripts/". That split exists
// so that several entry points can share a step; nothing else will ever include this process,
// and splitting it out bought a second file called dryrun.nf and no reader anything.
//
// The tree is assembled from the plan and from nothing else. Every path in it is a path a
// process will actually write to - `variant.dir.outputs`, `variant.dir.utilized`, the folders
// sharingGroups() already reports - so a preview cannot describe a layout the run will not
// produce.
//
// NO DIRECTORY IS MARKED AS ALREADY EXISTING, and that was tried first. By the time anything
// can look, Nextflow has made workDir and the session-reports directory for its own trace, and
// step 0 has published its report and written its logs - so a listing marked from the disk says
// that most of the tree is already there, when what put it there was the preview. The question
// a user actually has is whether this project has run before, and there is one file that
// answers that exactly: .poolseqflow_version, which a dry run never writes. So it is asked once,
// about the project, instead of thirty times about directories.
//
// WHY THE ROOTS ARE FLATTENED (Z, 2026-08-27). A preview of a project stored at
// /home/user/2026/experiments/pool/store would otherwise open onto seven directories of
// nothing before the first interesting one. Each storage root becomes a single name -
// home_user_2026_experiments_pool_store - and the tree below it is exactly the real tree. The
// flattening is not injective, so two roots CAN land on one name; that is a label collision
// and not a layout problem, so it is disambiguated with a suffix and both are named in the
// legend rather than refusing to preview the project at all.

nextflow.enable.dsl=2

include { resolveParameters; runDefinitions } from './scripts/resolve_parameters.nf'
include { variantPlan } from './scripts/variants.nf'
include { sharingReportLines; publishConflictLines } from './scripts/variants.nf'
// sharedMemberFiles is included rather than reimplemented so the preview writes exactly the
// members file a real run would write, in exactly the directories it would write it in.
include { runToken; sharingGroups; sharedMemberFiles; stepFolders; dig } from './scripts/variants.nf'
include { VerifyEnvironment } from './scripts/0_verify_environment.nf'

// EVERY DIRECTORY THE RUN WOULD CREATE, each with the one line that says what it is for.
//
// The results tree is enumerated in full, because that is what the preview is for. Everything
// else - the working volume, the logs, the outputs waiting to be promoted - is one entry per
// directory rather than a mirror of its contents: those trees are built and emptied while the
// run is in flight, and expanding them here would double the preview to describe something
// nobody is being asked to approve.
def plannedDirectories(Map plan, List runDefs) {
    def entries = []

    // The working volume. One mainDir serves every run (settled rule 8), but a table may set
    // any parameter, so the union is taken over the runs rather than read from params.
    runDefs.each { run ->
        entries << [path: "${run.mainDir}".toString(),
                    what: 'mainDir - the fast volume the pipeline works on']
        entries << [path: "${run.mainDir}/work".toString(),
                    what: "Nextflow's task directories - removed by `clean`"]
        entries << [path: "${run.dir.data}".toString(),
                    what: 'your reads - you place these, the pipeline never moves them']
        entries << [path: "${run.dir.references}".toString(),
                    what: 'your reference and annotation - likewise']
        entries << [path: "${run.dir.dictionaries}".toString(),
                    what: 'step 1: the FASTA, indices and .fai built from your reference']
        entries << [path: "${run.dir.snpEff}".toString(),
                    what: 'step 1: the snpEff database']
        entries << [path: "${run.storageDir}".toString(),
                    what: 'storageDir - permanent storage']
        entries << [path: "${run.storageDir}/Output".toString(),
                    what: 'the results, and the .parameters.config and .multirun.csv recording them']
        entries << [path: "${run.storageDir}/Logs".toString(),
                    what: 'the logs']
        entries << [path: "${run.dir.outputs}".toString(),
                    what: "results for ${membersOf([run.runId])}"]
        entries << [path: "${run.dir.output.reports}".toString(),
                    what: "step 0: the verification report for ${membersOf([run.runId])}"]
    }

    // One per variant: where it does its working-volume work, and where it logs. Both are named
    // for the group rather than for a run, which is the fact a preview makes concrete.
    plan.steps.each { step ->
        plan.variants[step].each { variant ->
            if (!variant.executes) return
            entries << [path: "${variant.dir.utilized}".toString(),
                        what: 'outputs waiting to move to permanent storage - mirrors the results tree']
            entries << [path: "${variant.dir.logs}".toString(),
                        what: "logs for ${membersOf(variant.members)}"]
        }
    }

    // THE RESULTS TREE, from the same function step 0 reports the partition from - so the
    // preview and the report cannot describe different groupings.
    sharingGroups(plan).each { group ->
        def who = membersOf(group.members)
        entries << [path: "${group.dir}".toString(),
                    what: group.members.size() > 1 ? "results shared by ${who}" : "results for ${who}"]
    }

    // The two directories that belong to the INVOCATION rather than to any variant, and they
    // have to be named here because nothing in the plan produces them: step 0 and step 1 log
    // to allLogs whatever the partition turns out to be, and Nextflow writes its own trace
    // into allOutputs. Under a table where no group happens to contain every run, neither
    // appears anywhere else - and the preview would then be missing two directories the run
    // certainly creates.
    entries << [path: "${params.dir.allOutputs}".toString(),
                what: 'the work every run shares']
    entries << [path: "${params.dir.allLogs}".toString(),
                what: 'logs for the work every run shares - step 0 and step 1']
    entries << [path: "${params.dir.sessionReports}".toString(),
                what: "Nextflow's dag, trace and timeline, and the summaries the steps write"]

    // AND THE FOLDERS, EACH LABELLED WITH THE STEPS THAT FILL IT - not with its group's whole
    // step list, which would put "steps 2, 3, 4, 5, 6, 8" beside Aligned. A folder can belong
    // to several steps (VCF is written by 6, read and rewritten by 7, annotated by 8), so they
    // are accumulated rather than taken from the first one seen.
    def folderSteps = [:]
    plan.steps.each { step ->
        plan.variants[step].each { variant ->
            if (!variant.executes) return
            stepFolders()[step].each { name ->
                def path = "${variant.dir.outputs}/${dig(variant, name)}".toString()
                if (!folderSteps.containsKey(path)) folderSteps[path] = []
                if (!folderSteps[path].contains(step)) folderSteps[path] << step
            }
        }
    }
    folderSteps.each { path, steps ->
        entries << [path: path,
                    what: "${steps.size() > 1 ? 'steps' : 'step'} ${steps.sort().join(', ')}".toString()]
    }

    // First description wins, so the specific entries above override nothing and the general
    // ones do not overwrite a folder's own line.
    def seen = [:]
    entries.each { entry -> if (!seen.containsKey(entry.path)) seen[entry.path] = entry }
    return seen.values().toList().sort { a, b -> a.path <=> b.path }
}

// A member list as prose. A single run has no id at all (settled rule 3), so naming it '-'
// would put the channel-key placeholder in front of a user.
def membersOf(List members) {
    def named = members.findAll { m -> m != null }.collect { m -> runToken(m) }
    return named.isEmpty() ? 'this run' : named.join(', ')
}

// A storage root as one directory name.
def flattenRoot(String root) {
    def flat = root.replaceAll('^/+', '').replaceAll('/+$', '').replaceAll('/', '_')
    return flat ? flat : 'root'
}

// THE PREVIEW, as a set of directories to make and a legend saying what each one stands for.
//
// A path belongs to the DEEPEST root that contains it, because containment between mainDir and
// storageDir is allowed - only identity is refused (settled rule 1) - and attributing a
// contained root's tree to the outer one would file the results under the working volume.
def dryRunTree(Map plan, List runDefs, List sharing) {
    def dryDir = "${params.dryRunDir}".toString()

    def rootPaths = (runDefs.collect { r -> "${r.mainDir}".toString() } +
                     runDefs.collect { r -> "${r.storageDir}".toString() }).unique()
    def deepestFirst = rootPaths.sort(false) { a, b -> b.length() <=> a.length() ?: a <=> b }

    // Named in path order so the legend is stable, and the disambiguating suffix goes to
    // whichever root sorts later rather than to whichever the run list happened to mention
    // first. No loop: the count of roots already sharing a base name IS the suffix.
    def names = [:]
    def usedBase = [:]
    rootPaths.sort(false) { a, b -> a <=> b }.each { root ->
        def base = flattenRoot(root)
        def n = (usedBase[base] ?: 0) + 1
        usedBase[base] = n
        names[root] = n == 1 ? base : "${base}-${n}".toString()
    }

    def entries = plannedDirectories(plan, runDefs).collect { entry ->
        def root = deepestFirst.find { r -> entry.path == r || entry.path.startsWith("${r}/") }
        if (root == null) {
            throw new IllegalStateException(
                "the run would create ${entry.path}, which is under neither mainDir nor any " +
                "storageDir. Every directory the pipeline makes hangs off one of its two " +
                "storage roots; a preview that quietly left this one out would show a layout " +
                "the run does not produce.")
        }
        def rest = entry.path.substring(root.length()).replaceAll('^/+', '')
        def label = rest ? "${names[root]}/${rest}".toString() : "${names[root]}".toString()
        // A '.' rather than an empty string for the root's own entry: the listing reads
        // these back with IFS set to a tab, and a tab is an IFS WHITESPACE character, so two
        // in a row collapse into one and every field after an empty one shifts left.
        return [path: entry.path, what: entry.what, root: root, rel: rest ? rest : '.',
                label: label, preview: "${dryDir}/${label}".toString()]
    }

    // The members file goes into the preview too. It is the answer to the question the preview
    // raises - which runs is Shared_1? - and putting it anywhere but inside that directory
    // would mean looking it up somewhere else.
    def members = sharedMemberFiles(plan).collect { entry ->
        def found = entries.find { e -> e.path == entry.dir }
        return [preview: found == null ? null : found.preview, members: entry.members]
    }.findAll { entry -> entry.preview != null }

    // The roots in the order the listing walks them, each carrying the description its own
    // entry gave it, so the heading says what the root IS and the lines under it say what is
    // going in it.
    def roots = names.collect { path, name ->
        def own = entries.find { e -> e.path == path }
        return [name: name, path: path, what: own == null ? '' : own.what]
    }.sort { a, b -> a.path <=> b.path }

    return [dir: dryDir, roots: roots, entries: entries, members: members,
            sharing: sharing.collect { line -> line.replaceFirst('^SHARING CHECK:', '') }]
}

// MAKING IT. One task, after step 0 has passed: a preview built from a configuration that does
// not verify would show a layout no run can produce, and the verification report is the more
// urgent thing to read in that case anyway.
process DryRunTree {
    input:
    val tree
    // Every step 0 report, counted. Nothing reads the value; it is the ordering.
    val gate

    output:
    path 'dryrun_preview.txt', emit: report

    script:
    dryDir = tree.dir
    release = workflow.manifest.version ?: 'unknown'
    stamp = "${params.storageDir}/Output/.poolseqflow_version"
    // Tab separated and read back with IFS, because a description contains spaces and commas
    // and a path may contain either.
    entry_lines = tree.entries.collect { e -> "${e.preview}\t${e.root}\t${e.rel}\t${e.what}" }.join('\n')
    root_lines = tree.roots.collect { r -> "${r.path}\t${r.name}\t${r.what}" }.join('\n')
    member_lines = tree.members.collect { m -> "${m.preview}\t${m.members.join(' ')}" }.join('\n')
    sharing_lines = tree.sharing.join('\n')
    """
    set -e

    mkdir -p '${dryDir}'

    cat > entries.tsv <<'ENTRIES'
${entry_lines}
ENTRIES

    cat > roots.tsv <<'ROOTS'
${root_lines}
ROOTS

    cat > members.tsv <<'MEMBERS'
${member_lines}
MEMBERS

    cat > sharing.txt <<'SHARING'
${sharing_lines}
SHARING

    while IFS=\$'\\t' read -r preview root rel what; do
        [ -n "\$preview" ] || continue
        mkdir -p "\$preview"
    done < entries.tsv

    while IFS=\$'\\t' read -r dir who; do
        [ -n "\$dir" ] || continue
        # Unquoted on purpose: the names are split back onto one line each, which is the
        # format a real run writes and the analysis layer will read.
        printf '%s\\n' \$who > "\$dir/members.txt"
    done < members.tsv

    {
        echo "PoolSeqFlow ${release} - dry run preview"
        echo "Generated \$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""
        echo "NOTHING HERE IS REAL. Every directory below is empty, no analysis has been done,"
        echo "and your project is exactly as it was: no results were recorded, no baseline was"
        echo "written, and none of your own files were changed. This is what a run WOULD create,"
        echo "so that you can look at it before spending the compute."
        echo ""
        echo "    ./PoolSeqFlow dryclean     remove this preview"
        echo "    ./PoolSeqFlow run          do it for real"
        echo ""
        # The one thing worth knowing that the tree cannot show, and the one file that answers
        # it: a project belongs to one release, and this is where that is recorded.
        if [ -f "${stamp}" ]; then
            echo "This project has run before, under PoolSeqFlow \$(cut -f1 < "${stamp}") on \$(cut -f2 < "${stamp}")."
            echo "Some of the directories below therefore already hold results, and a real run"
            echo "would skip the steps that produced them."
        else
            echo "This project has not been run yet - everything below would be produced from"
            echo "scratch."
        fi
        if [ -s sharing.txt ]; then
            echo ""
            echo "WHAT THE RUNS SHARE"
            cat sharing.txt
        fi
        echo ""
        echo "WHERE IT ALL GOES"
        echo "    One heading per storage root. Each root becomes a single directory in the"
        echo "    preview, with its path flattened into the name, so that a deeply nested"
        echo "    project does not open onto ten levels of nothing."
        # Nested reads, each from its own file: the inner loop redirects its own stdin, so it
        # cannot consume the outer one's.
        while IFS=\$'\\t' read -r real name what; do
            [ -n "\$real" ] || continue
            echo ""
            printf '  %s\\n' "\$real"
            if [ -n "\$what" ]; then printf '      %s\\n' "\$what"; fi
            printf '      previewed here as %s/\\n' "\$name"
            echo ""
            while IFS=\$'\\t' read -r preview eroot rel ewhat; do
                [ "\$eroot" = "\$real" ] || continue
                [ "\$rel" != "." ] || continue
                printf '      %-46s %s\\n' "\$rel" "\$ewhat"
            done < entries.tsv
        done < roots.tsv
    } > dryrun_preview.txt

    cp dryrun_preview.txt '${dryDir}/README.txt'

    mkdir -p ${params.dir.allLogs}/0_verify_environment/s10_DryRunTree
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${params.dir.allLogs}/0_verify_environment/s10_DryRunTree/0_DryRunTree_nextflow.log
    """
}

workflow {
    // Refused rather than assumed. Reached directly - `nextflow run dryrun.nf` without the
    // flag - every check below would run in its recording mode and leave the project holding a
    // baseline that no result was ever produced under. ./PoolSeqFlow dryrun passes it.
    if (!params.dryRun) {
        throw new IllegalStateException(
            "dryrun.nf was run without --dryRun, so step 0 would record a baseline for results " +
            "that are never going to be produced. Use './PoolSeqFlow dryrun', which sets it.")
    }

    // Exactly as poolseqflow.nf does it, and in the same order for the same reason:
    // runDefinitions() has to see the runs while "absent" still means "the user did not set
    // this". A preview built from a different resolution would preview a different run.
    def run_defs = runDefinitions()
    resolveParameters()
    plan = variantPlan(run_defs)

    // No members files. They are a record of what a directory holds, and this directory holds
    // nothing yet - so under a dry run the empty list goes to CheckMultiRun and the preview
    // writes its own copies inside the tree it makes instead.
    VerifyEnvironment(
        channel.value([plan: plan, runs: run_defs]),
        channel.value(tuple(
            sharingReportLines(plan, run_defs),
            publishConflictLines(plan, run_defs),
            [])))

    // After every run's report, and only then. A tree built from a configuration that does not
    // verify would describe a layout no run can produce.
    DryRunTree(
        channel.value(dryRunTree(plan, run_defs, sharingReportLines(plan, run_defs))),
        VerifyEnvironment.out.count())
}
