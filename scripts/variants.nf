// Where the runs diverge, and therefore what work is shared.
//
// The unit flowing through the pipeline is a VARIANT: a parameter set one or more runs share at a
// step, and a node of the divergence tree. Its members are those runs.

nextflow.enable.dsl=2

include { metadataProjection; metadataOrder; metadataColumnsPerStep } from './metadata.nf'

def sharingEnabled() {
    return true
}

// What each step reads, and whether it affects the artifact the step passes on. Authored, not
// derived. `artifact` refines the partition permanently; `publish` splits only that step's own
// side outputs.
def stepParameterMap() {
    return [
        2: [ artifact: ['reads', 'trim_galore.options', 'cutadapt.options',
                        'cutadapt.at_gc_error',
                        'dir.subpath.trimmed', 'dir.subpath.report.fastqc'],
             // FastQC over the CLIPPED reads. Trim Galore's own takes --fastqc_args instead.
             publish : ['fastqc.options'] ],

        3: [ artifact: ['bwa.options', 'dir.subpath.aligned'], publish: [] ],

        4: [ artifact: ['cleanBAM.filter', 'cleanBAM.required', 'cleanBAM.mapq',
                        'dir.subpath.ready'],
             publish : [] ],

        // Step 5 decides each sample's depth cap, so the cap setting refines what it passes on.
        // histogramMax changes nothing it writes or passes on; declaring it makes runs that
        // share the step agree on it, and one too low for a sample fails all of them.
        5: [ artifact: ['capBAM.maxDepth'], publish: ['capBAM.histogramMax'] ],

        6: [ artifact: ['variantCall.mpileupOptions', 'variantCall.callOptions', 'vcf.fileName',
                        'dir.subpath.vcf'],
             publish : [] ],

        // `diploidy` is read directly: the filter computes each pool's own threshold from it.
        7: [ artifact: ['vcffilter.minDP', 'vcffilter.minQUAL',
                        'filterFalsePositives.sensitivity',
                        'filterFalsePositives.sampleThreshold',
                        'diploidy',
                        'vcf.fileName', 'dir.subpath.vcf', 'dir.subpath.freq'],
             publish : [] ],

        // `annotate` decides whether the step runs at all, so it belongs to step 8's identity.
        8: [ artifact: ['snpEff.runOptions', 'snpEff.config', 'dir.subpath.vcf', 'annotate'],
             publish : [] ],
    ]
}

// The subdirectories each step fills, for the line that says what is in a shared directory.
// Wider than stepParameterMap(): this also names side outputs nothing consumes.
def stepFolders() {
    return [
        2: ['dir.subpath.trimmed', 'dir.subpath.unpaired',
            'dir.subpath.report.fastqc', 'dir.subpath.report.trim'],
        3: ['dir.subpath.aligned'],
        4: ['dir.subpath.ready'],
        // Every step 5 report is published by absolute path, so none of these is a declared
        // process output.
        5: ['dir.subpath.report.align', 'dir.subpath.report.coverage', 'dir.subpath.report.depth'],
        6: ['dir.subpath.vcf'],
        7: ['dir.subpath.vcf', 'dir.subpath.freq'],
        // Step 8 publishes snpEff's summary and gene table into Reports/.
        8: ['dir.subpath.vcf', 'dir.subpath.reports'],
    ]
}

// A run id as a channel key. A null key matches nothing silently, so a single run travels as '-'.
def runToken(Object runId) {
    return runId == null ? '-' : runId.toString()
}

// Reads a dotted name out of a parameter map; null for a name that is not there.
def dig(Map p, String dotted) {
    def cur = p
    // `.each` with a reassigned capture: the strict parser rejects a `for` loop here.
    dotted.tokenize('.').each { part -> cur = (cur instanceof Map) ? cur[part] : null }
    return cur
}

// What the chain needs from step 1 is the identity of the artifact it will FIND, not of the
// inputs that built it. Split in two: steps 3 and 6 read the FASTA and its indices, step 8 reads
// the snpEff database.
def referenceIdentity(Map run) {
    return ["${run.dir.dictionaries}", "${run.referenceFa}"]
}

def snpEffIdentity(Map run) {
    return ["${run.dir.snpEff}", "${run.snpEff.db}"]
}

// What decides the artifact step k passes on: its own parameters, plus what it consumes.
// Anything read by absolute path has to appear here - Nextflow's graph cannot see those reads.
def stepIdentity(Map run, int step) {
    def entry = stepParameterMap()[step]
    if (entry == null) {
        throw new IllegalArgumentException(
            "no parameter map for step ${step}. Add one to stepParameterMap() in " +
            "scripts/variants.nf, or correct the step number at the call site.")
    }

    def parts = entry.artifact.collect { name -> "${name}=${dig(run, name)}" }

    // Steps 2, 4, 5 and 7 take metadata column values; step 6 takes the row ORDER, which decides
    // the VCF's sample columns.
    if (step == 2) parts += metadataProjection(run, metadataColumnsPerStep()[2]).collect { r -> "metadata=${r}" }
    if (step == 3) parts += referenceIdentity(run).collect { p -> "reference=${p}" }
    if (step == 4) parts += metadataProjection(run, metadataColumnsPerStep()[4]).collect { r -> "metadata=${r}" }
    if (step == 5) parts += metadataProjection(run, metadataColumnsPerStep()[5]).collect { r -> "metadata=${r}" }
    if (step == 6) {
        parts += referenceIdentity(run).collect { p -> "reference=${p}" }
        parts += metadataOrder(run).collect { r -> "sampleorder=${r}" }
    }
    if (step == 7) parts += metadataProjection(run, metadataColumnsPerStep()[7]).collect { r -> "metadata=${r}" }
    if (step == 8) parts += snpEffIdentity(run).collect { p -> "snpeffdb=${p}" }

    return parts.collect { p -> p.toString() }
}

// Which step's output each step consumes. Not simply "the one before it": the pipeline branches
// after calling, and step 8 reads step 6's VCF exactly as step 7 does.
def stepDependencies() {
    return [ 2: [], 3: [2], 4: [3], 5: [4], 6: [5], 7: [6], 8: [6] ]
}

// Everything deciding what a run has produced by the end of step k, cumulative, which is what
// makes divergence permanent. Plain Strings throughout: a GString and a String on the two sides
// of a channel operator match nothing, silently.
def identityThrough(Map run, int step) {
    def parts = []
    // Recursion, not a self-referencing closure: the strict parser rejects `def f; f = {...}`.
    stepDependencies()[step].each { dep -> parts.addAll(identityThrough(run, dep)) }
    parts.addAll(stepIdentity(run, step).collect { p -> "${step}:${p}".toString() })
    return parts.unique()
}

// Every step this one depends on, transitively, furthest first.
def ancestorSteps(int step) {
    def out = []
    stepDependencies()[step].each { dep ->
        out.addAll(ancestorSteps(dep))
        out << dep
    }
    return out.unique()
}

// The key two runs must share to share step k's work. The storage root is part of it - two runs
// with different storageDirs have no directory to share - and with sharing off, so is the run id.
def variantKey(Map run, int step) {
    def parts = ["store=${run.storageDir}".toString()] + identityThrough(run, step)
    if (!sharingEnabled()) parts = ["run=${run.runId}".toString()] + parts
    return parts.join(' | ').toString()
}

// The variants at step k: one per distinct key, each serving the runs that share it. The lead
// member is the lowest RunID, so reordering the table cannot change whose map a variant carries.
def variantsAt(List runDefs, int step) {
    def groups = [:]
    runDefs.each { run ->
        def key = variantKey(run, step)
        if (!groups.containsKey(key)) groups[key] = []
        groups[key] << run
    }

    return groups.collect { key, members ->
        def ordered = members.sort { a, b -> "${a.runId}" <=> "${b.runId}" }
        def lead = ordered[0]
        def variant = deepCopyVariant(lead)
        variant.variantKey = key
        variant.variantStep = step
        variant.members = ordered.collect { m -> m.runId }
        variant.dir.utilized = variantUtilized(variant)
        // Step 8 is the only step a variant can decline to run, and the gates count consumers.
        variant.executes = (step != 8) || (variant.annotate as boolean)
        return variant
    }
}

// A variant carries its lead member's parameters, which its members all agreed on.
def deepCopyVariant(Map run) {
    def copy = [:]
    run.each { k, v -> copy[k] = deepCopyValue(v) }
    return copy
}

def deepCopyValue(Object value) {
    if (value instanceof Map) {
        def copy = [:]
        value.each { k, v -> copy[k] = deepCopyValue(v) }
        return copy
    }
    if (value instanceof List) return value.collect { item -> deepCopyValue(item) }
    return value
}

// The whole analysis, computed once at DAG-build time and then only read: the partition at every
// step, the edge to the step feeding it, and the paths. Nothing here consults the filesystem
// while tasks are in flight; every later question is a map lookup.
def variantPlan(List runDefs) {
    def steps = stepParameterMap().keySet().sort()

    def at = [:]
    steps.each { step -> at[step] = variantsAt(runDefs, step) }

    // Both ways round: children to expand into, parents to gather promotion signals onto.
    def parents = [:]
    def children = [:]
    steps.each { step ->
        def deps = stepDependencies()[step]
        if (deps.isEmpty()) return
        if (deps.size() != 1) {
            throw new IllegalStateException(
                "step ${step} declares ${deps.size()} dependencies. The expansion assumes one, " +
                "because a step reading two independent artifacts would have to JOIN them - and " +
                "a join dropping a key silently is exactly what this design exists to avoid.")
        }
        def up = deps[0]
        def byChild = [:]
        def byParent = [:]
        at[up].each { parent -> byParent[parent.variantKey] = [] }
        at[step].each { child ->
            // A child's members subset exactly one parent's: step k's identity contains step up's.
            def parent = at[up].find { cand -> cand.members.containsAll(child.members) }
            if (parent == null) {
                throw new IllegalStateException(
                    "the step ${step} variant serving ${child.members} has no ancestor among " +
                    "step ${up}'s variants. stepDependencies() and identityThrough() disagree " +
                    "about which step feeds step ${step}.")
            }
            byChild[child.variantKey] = parent
            byParent[parent.variantKey] << child
        }
        parents[step] = byChild
        children[step] = byParent
    }

    // Where a variant's results go. One results tree, and only divergence gets a name: All_Runs
    // at the top, Shared_<N> for some, a RunID for one. A single run keeps its plain tree. The
    // group number is per distinct MEMBER SET, so one set is one directory however many steps.
    def groupNumbers = [:]
    steps.each { step ->
        at[step].each { variant ->
            def owner = ''
            if (variant.runId != null) {
                if (variant.members.size() == runDefs.size())  owner = '/All_Runs'
                else if (variant.members.size() == 1)          owner = "/${runToken(variant.members[0])}"
                else {
                    def set = variant.members.collect { m -> runToken(m) }.join(',')
                    if (!groupNumbers.containsKey(set)) groupNumbers[set] = groupNumbers.size() + 1
                    owner = "/Shared_${groupNumbers[set]}"
                }
            }
            variant.dir.outputs = "${variant.storageDir}/Output${owner}".toString()
            variant.dir.logs    = "${variant.storageDir}/Logs${owner}".toString()
            variant.dir.subpath.each { name, value ->
                if (value instanceof Map) value.each { k, v -> variant.dir.output[name][k] = "${variant.dir.outputs}/${v}".toString() }
                else variant.dir.output[name] = "${variant.dir.outputs}/${value}".toString()
            }
        }
    }

    steps.each { step ->
        at[step].each { variant ->
            // Where a skip check looks, in priority order: permanent storage, this variant's own
            // working root, then its ancestors' nearest first - a shared artifact sits at its
            // producer's root, not at the reader's.
            def roots = [variant.dir.utilized]
            ancestorSteps(step).reverse().each { older ->
                def ancestor = at[older].find { cand -> cand.members.containsAll(variant.members) }
                if (ancestor != null) roots << ancestor.dir.utilized
            }
            variant.dir.search = (["${variant.dir.outputs}".toString()] +
                                  roots.collect { root -> root.toString() }).unique()
        }
    }

    return [steps: steps, variants: at, parents: parents, children: children]
}

// The variants at `step` descended from `parent`, regrouped by the finer key that `step` uses.
// Every run reaching the parent reaches exactly one child.
def childVariants(Map plan, Map parent, int step) {
    def expected = stepDependencies()[step]
    if (!expected.contains(parent.variantStep)) {
        throw new IllegalStateException(
            "step ${step} reads step ${expected.join(', ')}'s output, but it is being expanded " +
            "from a step ${parent.variantStep} variant. The call site has the wrong channel.")
    }
    def kids = plan.children[step][parent.variantKey]
    if (kids == null || kids.isEmpty()) {
        throw new IllegalStateException(
            "no step ${step} variant descends from the step ${parent.variantStep} variant " +
            "serving ${parent.members}. Every run that reached a step reaches exactly one " +
            "variant of the next, so this means the plan and the channel disagree.")
    }
    return kids
}

// The variant whose artifact `child` read.
def parentVariant(Map plan, Map child) {
    def byChild = plan.parents[child.variantStep]
    if (byChild == null) {
        throw new IllegalStateException(
            "step ${child.variantStep} reads no other step's output, so nothing produced what " +
            "it consumed. Only step 2 is in that position; this call site has the wrong step.")
    }
    return byChild[child.variantKey]
}

// Every variant at `step` descended from this one, however many edges away.
def descendantVariants(Map plan, Map ancestor, int step) {
    return plan.variants[step].findAll { cand -> ancestor.members.containsAll(cand.members) }
}

// The variant a given run belongs to at `step`. For step 0 and reporting, never in the middle.
def variantForRun(Map plan, Map run, int step) {
    def found = plan.variants[step].find { cand -> cand.members.contains(run.runId) }
    if (found == null) {
        throw new IllegalStateException(
            "run '${runToken(run.runId)}' belongs to no step ${step} variant. Every run is in " +
            "exactly one group at every step, so the plan was built from a different run set.")
    }
    return found
}

// Every consuming work item's completion, gathered onto the variant whose artifact they read -
// one signal per (producing variant, key). The expected count is arithmetic, carried by groupKey
// so each group releases as soon as its own consumers are in.
def gatherToProducer(Map plan, Object signals, int consumerStep) {
    return signals
        .map { variant, key ->
            def producer = parentVariant(plan, variant)
            def expected = plan.children[consumerStep][producer.variantKey]
                .findAll { child -> child.executes }
                .size()
            tuple(groupKey([producer.variantKey, "${key}".toString()], expected), producer, key)
        }
        .groupTuple(by: 0)
        .map { _gate, producers, keys -> tuple(producers[0], keys[0]) }
}

// The roots a skip check searches, as a quoted find_artifact.sh argument list.
def searchRoots(Map variant) {
    return variant.dir.search.collect { root -> "\"${root}\"" }.join(' ')
}

// Where a variant does its working-volume work. A single run keeps a plain `Utilized/`.
def variantUtilized(Map variant) {
    if (variant.runId == null) return "${variant.mainDir}/Utilized".toString()
    return "${variant.mainDir}/Utilized_${variant.members.join('+')}".toString()
}

// Every run in the table must reach the end. The message is printed as well as thrown: an
// exception from inside an operator closure reaches the user as "Unexpected error".
def assertEveryRunProduced(List expected, List produced) {
    def missing = expected.findAll { token -> !produced.contains(token) }
    if (missing.isEmpty()) return
    System.err.println ""
    System.err.println "PoolSeqFlow: the run produced no frequency tables for: ${missing.join(', ')}"
    System.err.println "PoolSeqFlow: every run in ${params.multiRunFile} must reach the end. A run that"
    System.err.println "PoolSeqFlow: vanishes part way through leaves an incomplete results directory"
    System.err.println "PoolSeqFlow: behind and would otherwise report success, so the run is failed here."
    System.err.println ""
    throw new IllegalStateException("incomplete run set: ${missing.join(', ')}")
}

// The groups this invocation will form, one entry per results directory. Keyed by directory,
// because a member set is one group however many steps it owns.
def sharingGroups(Map plan) {
    def byDir = [:]
    plan.steps.each { step ->
        plan.variants[step].each { variant ->
            // A variant that never runs owns no directory.
            if (!variant.executes) return
            def declared = stepFolders()[step]
            if (declared == null) {
                throw new IllegalStateException(
                    "no entry for step ${step} in stepFolders() (scripts/variants.nf). Every step " +
                    "has to say which subdirectories it fills, or step 0's report would tell a " +
                    "user that a shared directory holds nothing while that step writes into it.")
            }
            def folders = declared.collect { name -> "${dig(variant, name)}".toString() }
            def entry = byDir[variant.dir.outputs]
            if (entry == null) {
                byDir[variant.dir.outputs] = [dir: variant.dir.outputs, members: variant.members,
                                              steps: [step], folders: folders]
            }
            else {
                entry.steps << step
                folders.each { folder -> if (!entry.folders.contains(folder)) entry.folders << folder }
            }
        }
    }
    return byDir.values().toList()
}

// What step 0 prints about the partition.
def sharingReportLines(Map plan, List runDefs) {
    def lines = []
    if (runDefs.size() < 2) return lines
    def groups = sharingGroups(plan).sort { a, b -> b.members.size() <=> a.members.size() ?: a.dir <=> b.dir }
    lines << "SHARING CHECK:         ${groups.size()} results ${groups.size() == 1 ? 'directory' : 'directories'} for ${runDefs.size()} runs"
    groups.each { group ->
        def name = group.dir.tokenize('/').last()
        def who = group.members.collect { m -> runToken(m) }.join(', ')
        lines << (group.members.size() > 1
            ? "SHARING CHECK:             ${name} is a shared directory for ${who}"
            : "SHARING CHECK:             ${name} belongs to ${who} alone")
        lines << "SHARING CHECK:                 ${group.steps.size() > 1 ? 'steps' : 'step'} ${group.steps.sort().join(', ')}, holding ${group.folders.join(', ')}"
    }

    // Two runs identical to the end share every step: a table mistake worth naming.
    def full = groups.findAll { group -> group.steps.size() == plan.steps.size() && group.members.size() > 1 }
    full.each { group ->
        lines << "SHARING CHECK:         these runs are identical at every step, so the table asks for"
        lines << "SHARING CHECK:         the same analysis more than once: ${group.members.collect { m -> runToken(m) }.join(', ')}"
    }
    return lines
}

// Members of one group that disagree about a `publish` parameter. It must not split the artifact
// partition and cannot split the step's own outputs either, so the disagreement is refused.
def publishConflicts(Map plan, List runDefs) {
    def problems = []
    plan.steps.each { step ->
        def names = stepParameterMap()[step].publish
        if (names.isEmpty()) return
        plan.variants[step].each { variant ->
            if (variant.members.size() < 2) return
            def mine = runDefs.findAll { run -> variant.members.contains(run.runId) }
            names.each { name ->
                def values = mine.collectEntries { run -> [runToken(run.runId), "${dig(run, name)}".toString()] }
                // toList() first: values() is an unmodifiable view and unique() sorts in place.
                if (values.values().toList().unique().size() > 1) {
                    problems << [step: step, name: name, values: values]
                }
            }
        }
    }
    return problems
}

// The members files to write: one per SHARED directory. A record, not a guard - what stops a
// table edit mixing two groupings in one directory is the stored copy of the table.
def sharedMemberFiles(Map plan) {
    return sharingGroups(plan)
        .findAll { group -> group.members.size() > 1 }
        .collect { group -> [dir: group.dir, members: group.members.collect { m -> runToken(m) }.sort()] }
}

// publishConflicts(), rendered for step 0's report.
def publishConflictLines(Map plan, List runDefs) {
    def problems = publishConflicts(plan, runDefs)
    if (problems.isEmpty()) return []
    def lines = ["SHARING CHECK:         these runs share a step but disagree about what it PUBLISHES:"]
    problems.each { problem ->
        lines << "SHARING CHECK:             step ${problem.step}, ${problem.name}"
        problem.values.sort { a, b -> a.key <=> b.key }.each { who, value ->
            lines << "SHARING CHECK:                 ${who} = ${value}"
        }
    }
    lines << "SHARING CHECK:         A parameter like this does not change what the step passes on,"
    lines << "SHARING CHECK:         so the runs still share the artifact - but the step runs ONCE,"
    lines << "SHARING CHECK:         under one of these values, and every run sharing it gets that"
    lines << "SHARING CHECK:         one. Make them agree, or vary something that makes the runs"
    lines << "SHARING CHECK:         diverge at this step."
    return lines
}
