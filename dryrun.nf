#!/usr/bin/env nextflow

// A dry run: verifies the project, then creates the empty tree a run would write. The tree is
// assembled from the plan and nothing else.

nextflow.enable.dsl=2

include { resolveParameters; runDefinitions } from './scripts/resolve_parameters.nf'
include { variantPlan } from './scripts/variants.nf'
include { sharingReportLines; publishConflictLines } from './scripts/variants.nf'
include { runToken; sharingGroups; sharedMemberFiles; stepFolders; dig } from './scripts/variants.nf'
include { VerifyEnvironment } from './scripts/0_verify_environment.nf'

// Every directory the run would create, each with the line that says what it is for. The results
// tree is enumerated in full; the working volume and the logs are one entry per directory.
def plannedDirectories(Map plan, List runDefs) {
    def entries = []

    // A table may set any parameter, so the union is taken over the runs, not read from params.
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

    // One per variant: where it works on the volume, and where it logs. Both named for the group
    // rather than for a run.
    plan.steps.each { step ->
        plan.variants[step].each { variant ->
            if (!variant.executes) return
            entries << [path: "${variant.dir.utilized}".toString(),
                        what: 'outputs waiting to move to permanent storage - mirrors the results tree']
            entries << [path: "${variant.dir.logs}".toString(),
                        what: "logs for ${membersOf(variant.members)}"]
        }
    }

    // The results tree, from the same function step 0 reports the partition from.
    sharingGroups(plan).each { group ->
        def who = membersOf(group.members)
        entries << [path: "${group.dir}".toString(),
                    what: group.members.size() > 1 ? "results shared by ${who}" : "results for ${who}"]
    }

    // The directories belonging to the invocation rather than to any variant.
    entries << [path: "${params.dir.allOutputs}".toString(),
                what: 'the work every run shares']
    entries << [path: "${params.dir.allLogs}".toString(),
                what: 'logs for the work every run shares - step 0 and step 1']
    entries << [path: "${params.dir.sessionReports}".toString(),
                what: "Nextflow's dag, trace and timeline, and the summaries the steps write"]

    // Each folder labelled with the steps that fill it. A folder can belong to several, so they
    // accumulate rather than being taken from the first seen.
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

    // First description wins, so a general entry cannot overwrite a folder's own line.
    def seen = [:]
    entries.each { entry -> if (!seen.containsKey(entry.path)) seen[entry.path] = entry }
    return seen.values().toList().sort { a, b -> a.path <=> b.path }
}

// A member list as prose. A single run has no id.
def membersOf(List members) {
    def named = members.findAll { m -> m != null }.collect { m -> runToken(m) }
    return named.isEmpty() ? 'this run' : named.join(', ')
}

// A storage root as one directory name.
def flattenRoot(String root) {
    def flat = root.replaceAll('^/+', '').replaceAll('/+$', '').replaceAll('/', '_')
    return flat ? flat : 'root'
}

// The preview: directories to make, and a legend saying what each stands for. A path belongs to
// the DEEPEST root containing it, since mainDir and storageDir are allowed to nest.
def dryRunTree(Map plan, List runDefs, List sharing) {
    def dryDir = "${params.dryRunDir}".toString()

    def rootPaths = (runDefs.collect { r -> "${r.mainDir}".toString() } +
                     runDefs.collect { r -> "${r.storageDir}".toString() }).unique()
    def deepestFirst = rootPaths.sort(false) { a, b -> b.length() <=> a.length() ?: a <=> b }

    // Named in path order so the legend is stable. Flattening is not injective, so the count of
    // roots already sharing a base name becomes the suffix.
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
        // A '.' rather than an empty string: the listing reads these back with IFS set to a tab,
        // and consecutive tabs collapse.
        return [path: entry.path, what: entry.what, root: root, rel: rest ? rest : '.',
                label: label, preview: "${dryDir}/${label}".toString()]
    }

    // The members file goes into the preview too: it says which runs a Shared_<N> holds.
    def members = sharedMemberFiles(plan).collect { entry ->
        def found = entries.find { e -> e.path == entry.dir }
        return [preview: found == null ? null : found.preview, members: entry.members]
    }.findAll { entry -> entry.preview != null }

    // The roots in the order the listing walks them, each carrying its own entry's description.
    def roots = names.collect { path, name ->
        def own = entries.find { e -> e.path == path }
        return [name: name, path: path, what: own == null ? '' : own.what]
    }.sort { a, b -> a.path <=> b.path }

    return [dir: dryDir, roots: roots, entries: entries, members: members,
            sharing: sharing.collect { line -> line.replaceFirst('^SHARING CHECK:', '') }]
}

// One task, after step 0 has passed.
process DryRunTree {
    input:
    val tree
    val gate   // ordering barrier; never read

    output:
    path 'dryrun_preview.txt', emit: report

    script:
    dryDir = tree.dir
    release = workflow.manifest.version ?: 'unknown'
    stamp = "${params.storageDir}/Output/.poolseqflow_version"
    // Tab separated: descriptions and paths may contain spaces and commas.
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
        # Unquoted: the names split back onto one line each.
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
        # Whether the project has run before - the one thing the tree cannot show.
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
        # The inner loop redirects its own stdin, so it cannot consume the outer one's.
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

    mkdir -p ${params.dir.allLogs}/dryrun
    {
        echo ""
        echo "===== run=${workflow.runName} | session=${workflow.sessionId} | attempt=${task.attempt} | \$(date -Is) ====="
        cat .command.log
    } >> ${params.dir.allLogs}/dryrun/0_DryRunTree_nextflow.log
    """
}

workflow {
    if (!params.dryRun) {
        throw new IllegalStateException(
            "dryrun.nf was run without --dryRun, so step 0 would record a baseline for results " +
            "that are never going to be produced. Use './PoolSeqFlow dryrun', which sets it.")
    }

    // Same order as poolseqflow.nf, and for the same reason.
    def run_defs = runDefinitions()
    resolveParameters()
    plan = variantPlan(run_defs)

    // No members files: the preview writes its own inside the tree it makes.
    VerifyEnvironment(
        channel.value([plan: plan, runs: run_defs]),
        channel.value(tuple(
            sharingReportLines(plan, run_defs),
            publishConflictLines(plan, run_defs),
            [])))

    // After every run's report, and only then.
    DryRunTree(
        channel.value(dryRunTree(plan, run_defs, sharingReportLines(plan, run_defs))),
        VerifyEnvironment.out.count())
}
