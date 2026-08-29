// WHERE THE RUNS DIVERGE, and therefore what work is shared.
//
// A multi-run table usually describes runs that differ in a few late parameters - one
// reference at three filtering settings, say - and running each one from the reads costs
// hours to produce byte-identical intermediates. This file works out, once and before
// anything runs, which runs agree up to which step.
//
// THE UNIT THAT FLOWS THROUGH THE PIPELINE IS A VARIANT, NOT A RUN. A variant is a parameter
// set that one or more runs share at a given step - a node of the divergence tree. It carries
// exactly what a process needs, so a process still takes `tuple val(x), ...` and reads
// `x.dir.*` exactly as it did when `x` was a run; only what `x` MEANS changes. A run is then
// simply a path from the root of the tree to a leaf, and runs appear only at the edges: step 0
// validates each run's own configuration, and publishing sends a variant's outputs to each of
// its member runs.
//
// WHY THIS IS AN ANALYSIS AND NOT A DEDUPLICATION (Z, 2026-08-26). The obvious alternative is
// to hash each step's inputs and group by the digest. It produces the same partition, but it
// makes the digest do two jobs - identity AND location - and the second is where the cost is:
// hashes in paths, a content hash that races step 0's own CRLF repair, GString-vs-String key
// mismatches, and a "leader" that moves when the CSV is reordered. Comparing parameter values
// for EQUALITY needs none of that. There is no hash anywhere in this file.
//
// SHARING IS ON. `sharingEnabled()` decides it, and it was false for two stages on purpose:
// the whole rewiring was built and proven inert first - old and new code over one fixture,
// nothing moved - so that when task counts finally DID change, that change was unambiguously
// this one line and not the refactor underneath it.

nextflow.enable.dsl=2

// The sample metadata file's schema and its projections. Nothing in here parses that file:
// resolveParameters() has already put the parsed rows in every run map.
include { metadataProjection; metadataOrder; metadataColumnsPerStep } from './metadata.nf'

def sharingEnabled() {
    return true
}

// WHAT EACH STEP READS, and whether it affects the artifact the step passes on.
//
// This map is the whole correctness risk of sharing: name too few parameters and two runs
// share an artifact one of them did not ask for - reads trimmed to someone else's settings,
// with nothing downstream able to tell. It is AUTHORED rather than derived, because it has to
// be reviewable, and a case in test/suites/00_static.sh re-extracts it from the source and
// fails if any step reads a parameter its entry does not declare. Authoring alone drifts;
// extraction alone is fragile, since a regex cannot see an indirect read. Both.
//
// `artifact` refines the partition permanently: once what a step passes on differs, everything
// after it differs. `publish` affects only what that step writes for you to look at, so it
// splits that step's own side outputs and the branch rejoins immediately.
//
// The families `analysisParams()` excludes - `dir.` apart from `subpath`, `cores.`, `software.`,
// `java.`, `runId` - are absent here for the same reasons, with one deliberate difference:
// `dir.subpath.*` IS included, because it is half of an artifact's identity even though it
// cannot invalidate a result. The two lists answer different questions ("what invalidates a
// result" versus "what makes two results the same"), so they are allowed to disagree - but
// only on purpose.
def stepParameterMap() {
    return [
        2: [ artifact: ['reads', 'trim_galore.options', 'cutadapt.options',
                        'cutadapt.at_gc_error',
                        'dir.subpath.trimmed', 'dir.subpath.report.fastqc'],
             // FastQC over the CLIPPED reads, run after cutadapt has already produced them,
             // for a report nothing consumes. Trim Galore's own FastQC - whose zips ClipReads
             // really does read - takes --fastqc_args instead, so this parameter cannot reach
             // the artifact that flows on.
             publish : ['fastqc.options'] ],

        3: [ artifact: ['bwa.options', 'dir.subpath.aligned'], publish: [] ],

        // `threads` is read here (`4_clean.nf`, samtools fixmate) and is deliberately NOT an
        // identity: it is a resource, it does not change a byte of the output, and including
        // it would redo an entire analysis because someone asked for more cores.
        4: [ artifact: ['samtools.filter', 'samtools.required', 'samtools.mapq',
                        'dir.subpath.ready'],
             publish : [] ],

        // Step 5 reads no analysis parameter at all, so it can never be a branch point: two
        // runs that share step 4 necessarily share both reports.
        5: [ artifact: [], publish: [] ],

        6: [ artifact: ['bcftools.mpileupOptions', 'bcftools.callOptions', 'vcf.fileName',
                        'dir.subpath.vcf'],
             publish : [] ],

        // `diploidy` is read directly here, not only through the derived sensitivity: with
        // per-pool sizes the filter computes each pool's own threshold from it, so a run that
        // changed ploidy alone would otherwise be told it could reuse the filtered VCF.
        7: [ artifact: ['vcffilter.minDP', 'vcffilter.minQUAL',
                        'filterFalsePositives.sensitivity',
                        'filterFalsePositives.sampleThreshold',
                        'diploidy',
                        'vcf.fileName', 'dir.subpath.vcf', 'dir.subpath.freq'],
             publish : [] ],

        // `annotate` is here even though 8_annotate_variants.nf never reads it - it is read in
        // poolseqflow.nf, which filters the step out entirely. It belongs to step 8's identity
        // because it decides whether the step runs AT ALL, and a variant that serves one run
        // which annotates and one which does not would have to be both. Step 1 is the opposite
        // case and deliberately so: one database serves both, so dictionaryRuns MERGES runs
        // that disagree here.
        8: [ artifact: ['snpEff.runOptions', 'snpEff.config', 'dir.subpath.vcf', 'annotate'],
             publish : [] ],
    ]
}

// THE SUBDIRECTORIES EACH STEP FILLS, for the line that says what is in a shared directory.
//
// Authored, and deliberately WIDER than stepParameterMap(): that map names the folders holding
// the artifact a step passes on, because those are half of its identity, while this also names
// the side outputs nothing consumes - the unpaired reads, the trim reports, step 5's coverage.
// Someone opening Shared_1 sees all of them, so the report has to say all of them.
//
// A case in test/suites/00_static.sh checks it against stepParameterMap(), so it can never
// declare fewer folders than the step's own identity already names.
def stepFolders() {
    return [
        2: ['dir.subpath.trimmed', 'dir.subpath.unpaired',
            'dir.subpath.report.fastqc', 'dir.subpath.report.trim'],
        3: ['dir.subpath.aligned'],
        4: ['dir.subpath.ready'],
        // Step 5 declares no output at all - both reports are written by absolute path - so it
        // is invisible to stepParameterMap() and would be invisible here too if this were
        // derived from it.
        5: ['dir.subpath.report.align', 'dir.subpath.report.coverage'],
        6: ['dir.subpath.vcf'],
        7: ['dir.subpath.vcf', 'dir.subpath.freq'],
        // snpEff writes its summary straight into Reports/.
        8: ['dir.subpath.vcf', 'dir.subpath.reports'],
    ]
}

// A run id as a channel key. Single run has no id at all (settled rule 3), and a null used as
// a key matches nothing - silently - so it travels as a literal instead.
def runToken(Object runId) {
    return runId == null ? '-' : runId.toString()
}

// Read a dotted name out of a parameter map. Returns null for a name that is not there, which
// is not an error: derived parameters are filled in by resolveParameters() and a run map is
// always complete by the time this is called.
def dig(Map p, String dotted) {
    def cur = p
    // `.each` with a reassigned capture, not a `for` loop: the strict parser rejects both the
    // C-style and the `for (x in y)` forms.
    dotted.tokenize('.').each { part -> cur = (cur instanceof Map) ? cur[part] : null }
    return cur
}

// STEP 1 IS NOT PART OF THIS ANALYSIS, and folding it in would break it.
//
// Its artifacts are keyed by reference NAME and live under mainDir by settled rule 4, so that
// several genomes coexist and a later project reuses them - they are not keyed by what
// produced them. That is why `dictionaryKey` groups on output paths and `dictionarySettings`
// THROWS when two runs on one key disagree, rather than quietly splitting them. In particular
// `dictionaryRuns` deliberately MERGES runs that disagree about `annotate`, because one
// database serves both; splitting that group would have two of them build concurrently into
// one directory.
//
// So what the chain needs from step 1 is not an input digest but the IDENTITY OF THE ARTIFACT
// IT WILL FIND THERE - and split in two, because one identity over-splits. The FASTA and its
// indices are what steps 3 and 6 read; the snpEff database is what step 8 reads. Two runs
// differing only in `gffFile` must not redo alignment and calling.
def referenceIdentity(Map run) {
    return ["${run.dir.dictionaries}", "${run.referenceFa}"]
}

def snpEffIdentity(Map run) {
    return ["${run.dir.snpEff}", "${run.snpEff.db}"]
}

// What decides the artifact step k passes on: its own parameters, plus the reads or artifacts
// it consumes. Everything a process reads by an absolute path into a shared directory has to
// appear here, because Nextflow's own graph cannot see those reads.
def stepIdentity(Map run, int step) {
    def entry = stepParameterMap()[step]
    if (entry == null) {
        throw new IllegalArgumentException(
            "no parameter map for step ${step}. Add one to stepParameterMap() in " +
            "scripts/variants.nf, or correct the step number at the call site.")
    }

    def parts = entry.artifact.collect { name -> "${name}=${dig(run, name)}" }

    // The reads, the dictionaries and the sample metadata are reached by absolute path or
    // carried in the run map, not through a staged input, so Nextflow's own graph cannot see
    // any of them and they have to be named here.
    //
    // Step 2 takes the per-sample adapter overrides and step 4 the read group projection -
    // values only, so a permutation of the file does not split either. Step 6 takes the row
    // ORDER and nothing else, because that is what decides the VCF's sample columns. Two runs
    // whose files are permutations of each other therefore share step 4 and diverge at step 6.
    // Step 7 takes the pool sizes, which set the false-positive filter's per-column threshold:
    // without this, two runs pointing at metadata files that differ only in param_poolSize
    // would share one filtered VCF, and whichever ran first would decide both their results.
    if (step == 2) parts += metadataProjection(run, metadataColumnsPerStep()[2]).collect { r -> "metadata=${r}" }
    if (step == 3) parts += referenceIdentity(run).collect { p -> "reference=${p}" }
    if (step == 4) parts += metadataProjection(run, metadataColumnsPerStep()[4]).collect { r -> "metadata=${r}" }
    if (step == 6) {
        parts += referenceIdentity(run).collect { p -> "reference=${p}" }
        parts += metadataOrder(run).collect { r -> "sampleorder=${r}" }
    }
    if (step == 7) parts += metadataProjection(run, metadataColumnsPerStep()[7]).collect { r -> "metadata=${r}" }
    if (step == 8) parts += snpEffIdentity(run).collect { p -> "snpeffdb=${p}" }

    return parts.collect { p -> p.toString() }
}

// Everything that decides what a run has produced by the end of step k. Cumulative, because a
// step's output depends on its input as much as on its own settings - which is also what makes
// divergence permanent: once the artifact flowing on differs, it keeps differing.
//
// Plain Strings throughout, never GStrings. A key built as a GString on one side of a channel
// operator and a String on the other matches nothing, silently, and this project has been bitten
// by that before.
// Which step's output each step actually consumes.
//
// NOT simply "the one before it" - the pipeline branches after calling. Step 6 reads the ready
// BAMs from step 4, not step 5's reports; step 8 reads the called VCF from step 6, exactly as
// step 7 does, so a run that differs only in a step-7 filter still shares annotation. Walking
// 2..k linearly instead gets both of those wrong, which is how this was written first and what
// dumping the partition for a real table exposed.
def stepDependencies() {
    return [ 2: [], 3: [2], 4: [3], 5: [4], 6: [4], 7: [6], 8: [6] ]
}

def identityThrough(Map run, int step) {
    def parts = []
    // Plain recursion over the dependency edges, not a self-referencing closure - the strict
    // parser rejects `def f; f = { ... f(...) }`.
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

// The key two runs must share to share step k's work.
//
// While sharing is off the run's own id is prepended, which makes every key unique and so
// forces the partition to singletons. That single line is the difference between this stage
// and the next.
def variantKey(Map run, int step) {
    // THE STORAGE ROOT IS PART OF EVERY KEY, and it is what removes the last case that would
    // have needed a list of destinations. Two runs whose storageDir columns differ have no
    // directory in common to put a shared result in, so they must not group - and prefixing the
    // key makes that automatic rather than a refusal or a warning. Verified: a table where one
    // run points elsewhere leaves it alone in its own tree at every step while the others share.
    def parts = ["store=${run.storageDir}".toString()] + identityThrough(run, step)
    if (!sharingEnabled()) parts = ["run=${run.runId}".toString()] + parts
    return parts.join(' | ').toString()
}

// The variants at step k: one per distinct key, each serving the runs that share it.
//
// The lead member is the lowest RunID rather than the first table row, so that reordering the
// CSV cannot change which run's map a shared variant carries - which would otherwise orphan
// the previous invocation's artifacts under a different root and recompute everything.
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
        // Where this variant does its working-volume work. One member is the ordinary case
        // and gives back exactly what the run itself had, which is what keeps this stage inert.
        variant.dir.utilized = variantUtilized(variant)
        // STEP 8 IS THE ONE STEP A VARIANT CAN DECLINE TO RUN. Everything else always executes;
        // annotation is switched off by a parameter, and because `annotate` is part of step 8's
        // identity a variant is never half-annotating. The promotion gates count consumers, so
        // they need to know which of them will actually emit a signal.
        variant.executes = (step != 8) || (variant.annotate as boolean)
        return variant
    }
}

// A variant carries its lead member's parameters. That is exact for everything the step reads,
// by construction - the members agreed on all of it, which is why they are in one group.
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

// THE WHOLE ANALYSIS, COMPUTED ONCE, BEFORE ANYTHING RUNS.
//
// The partition at every step, the edge between each step and the one that feeds it, and the
// two path facts a variant needs that only become knowable once the tree exists. Built at
// DAG-build time and then only read: nothing here consults the filesystem while tasks are in
// flight, which is the difference between arranging the workflow and racing it.
//
// It is also what makes the expansion cheap. Working the partition out per channel item would
// re-read the metadata table once per (sample, step); here it is read once, before the
// total and every later question is a map lookup.
def variantPlan(List runDefs) {
    def steps = stepParameterMap().keySet().sort()

    def at = [:]
    steps.each { step -> at[step] = variantsAt(runDefs, step) }

    // Each step's variants against its parent's, both ways round: children to expand into,
    // parents to gather promotion signals back onto.
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
            // A child's members are a subset of exactly one parent's: step k's identity
            // CONTAINS step up's, so its groups can only ever be finer. If that ever fails,
            // stepDependencies() and identityThrough() disagree about the shape of the DAG.
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

    // WHERE A VARIANT'S RESULTS GO. One results tree, and only divergence gets a name: work
    // every run shares at the top, work some of them share under Shared_<N>, work one run does
    // alone under its own RunID. A single run is none of these - nothing to be distinguished
    // from - so its tree stays exactly where it always was (settled rule 3).
    //
    // The group number is per distinct MEMBER SET, not per step. Groups nest or are disjoint -
    // a child's members are always a subset of one parent's - so one member set is one group
    // however many steps it owns, and Shared_1 holds everything that group produced rather than
    // one directory per artifact.
    //
    // Every member shares this directory, because they share a storage root: that is what the
    // `store=` prefix in variantKey guarantees. So a variant has ONE destination, always.
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
            // WHERE A SKIP CHECK LOOKS. Permanent storage first, so a promoted artifact
            // outranks a residue copy of it; then this variant's own working root; then its
            // ancestors', because a step that reads a SHARED artifact reads it from the root
            // of the variant that produced it, not from its own. Two runs sharing step 2 and
            // diverging at step 3 is the whole case: the trimmed reads are under the step-2
            // variant's root, which neither step-3 variant would otherwise search.
            //
            // Ancestors nearest first. With sharing off every root here is the same string and
            // unique() collapses them to the two the pipeline has always searched.
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

// The variants at `step` descended from `parent`: the runs it serves, regrouped by the finer
// key that `step` uses.
//
// This is what replaces a fan-back join. An expansion enumerates its children from the
// analysis, so the arity is decided before anything runs and nothing can be silently dropped;
// a join discards keys that fail to match and reports success. Every run that reached the
// parent reaches exactly one child.
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
//
// Used where a fact is established at one step and needed several steps down - the sample
// count step 2 fixes and step 6 checks its cohort against. Still an expansion, so it cannot
// drop anything; it just skips the intermediate hops.
def descendantVariants(Map plan, Map ancestor, int step) {
    return plan.variants[step].findAll { cand -> ancestor.members.containsAll(cand.members) }
}

// The variant a given run belongs to at `step`. Runs appear only at the edges of the DAG, so
// this is for step 0 and for reporting - never in the middle.
def variantForRun(Map plan, Map run, int step) {
    def found = plan.variants[step].find { cand -> cand.members.contains(run.runId) }
    if (found == null) {
        throw new IllegalStateException(
            "run '${runToken(run.runId)}' belongs to no step ${step} variant. Every run is in " +
            "exactly one group at every step, so the plan was built from a different run set.")
    }
    return found
}

// Every consuming work item's completion, gathered back onto the variant whose artifact they
// read - one signal per (producing variant, key).
//
// This is the whole of "the gate is keyed by the PRODUCING step's branch". Once a producer is
// shared its consumers may not be, so releasing on the first one to finish would delete a file
// another still needs.
//
// The count is arithmetic, not a runtime reference count: the structure is a tree, so a
// consuming step's variants partition their parent's members and how many there are is known
// before anything runs. groupKey carries that number with the key, so each group is released as
// soon as ITS consumers are in - waiting for the channel to close instead would hold every
// artifact on the working volume until the slowest run had finished, which is the opposite of
// what promotion is for.
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

// The roots a skip check searches, as a find_artifact.sh argument list. Quoted here rather
// than at each of the eleven call sites, which is also the only place that spacing is decided.
def searchRoots(Map variant) {
    return variant.dir.search.collect { root -> "\"${root}\"" }.join(' ')
}

// Where a variant does its working-volume work.
//
// One task per (variant, step) means nothing ever races for a path, which is what makes the
// lock-free atomic_mv.sh safe here - but the reason is the analysis fixing the shape up front,
// not a runtime check. Never make sharing depend on a check-then-act existence test.
//
// Single run keeps a plain `Utilized/`, unsuffixed, exactly as before multi-run existed:
// settled rule 3 says no synthetic key when there is only one run, and a variant name is the
// same kind of key.
def variantUtilized(Map variant) {
    if (variant.runId == null) return "${variant.mainDir}/Utilized".toString()
    return "${variant.mainDir}/Utilized_${variant.members.join('+')}".toString()
}

// EVERY RUN IN THE TABLE MUST REACH THE END, and nothing else in this pipeline counts runs.
//
// Every fan-back the expansions replaced was a join, and a join drops an unmatched key
// silently. The only cardinality check that existed sits INSIDE a `.map{}` reached only by
// keys which already survived one (scripts/6_variant_call.nf:120), so a run lost during
// fan-back produced no VCF, no tables, no promotion - and SUCCESS. An expansion cannot drop a
// run, which is the point of it; this asserts it rather than trusting it, because the failure
// it guards against is silent and the check costs nothing.
//
// THE MESSAGE IS PRINTED, NOT ONLY THROWN. An exception raised inside an operator's closure
// reaches Nextflow wrapped in an InvocationTargetException whose own message is null, and what
// the user sees is "Unexpected error" and a line number - verified, not assumed. So the
// diagnosis goes to stderr first and the throw is only there to make the run fail.
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

// THE GROUPS THIS INVOCATION WILL FORM, one entry per results directory.
//
// A member set is one group however many steps it owns, so this is keyed by directory rather
// than by step, and each entry carries the steps that land there. Used by step 0 to report the
// partition before any compute is spent, and to write the members file that says who a
// Shared_<N> directory belongs to.
def sharingGroups(Map plan) {
    def byDir = [:]
    plan.steps.each { step ->
        plan.variants[step].each { variant ->
            // A variant that never runs owns no directory. Only step 8 can be in that
            // position - `annotate` decides it - and listing it would tell you a run has
            // results from a step it deliberately skipped.
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

// What step 0 prints about it. A wrong parameter map is the failure this whole design risks, and
// it is silent - so the partition is stated before anything runs, where it can be disagreed
// with, rather than inferred afterwards from which directories happen to exist.
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

    // Two runs identical to the end share every step, which is a table mistake worth naming:
    // the second row costs a directory and buys nothing.
    def full = groups.findAll { group -> group.steps.size() == plan.steps.size() && group.members.size() > 1 }
    full.each { group ->
        lines << "SHARING CHECK:         these runs are identical at every step, so the table asks for"
        lines << "SHARING CHECK:         the same analysis more than once: ${group.members.collect { m -> runToken(m) }.join(', ')}"
    }
    return lines
}

// A PUBLISH-ONLY DISAGREEMENT INSIDE A GROUP IS REFUSED (Z, 2026-08-27).
//
// `publish` parameters affect only what a step writes for you to look at, not what it passes on
// - so they must not split the artifact partition. But they cannot split the step's own outputs
// either: two step-2 variants feeding one step-3 variant is a MERGE, and the expansion model
// exists precisely so that cannot happen. So a group whose members disagree about one is
// refused, with both values named - the same shape as dictionarySettings() throwing when two
// runs on one dictionary key disagree about how it is built.
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
                // toList() first: a Map's values() is an unmodifiable VIEW and unique() sorts
                // in place, so calling it directly throws UnsupportedOperationException.
                if (values.values().toList().unique().size() > 1) {
                    problems << [step: step, name: name, values: values]
                }
            }
        }
    }
    return problems
}

// The members files to write: one per SHARED directory. A run's own directory needs none - its
// name already says who it belongs to - and All_Runs gets one anyway, because "every run" is a
// list worth having on disk when the table is later edited.
//
// A RECORD, not a guard. What stops a table edit from mixing two groupings in one directory is
// the stored copy of the table itself (step 0's parameter check), which sees the edit directly
// rather than inferring it from a member list. This exists because Z asked for the grouping to
// be recoverable from the results themselves, and because the analysis layer will want it.
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
    lines << "SHARING CHECK:         A parameter like this changes only what the step writes for you"
    lines << "SHARING CHECK:         to look at, not what it passes on - so the runs still share the"
    lines << "SHARING CHECK:         artifact, and only one of these values can have produced the"
    lines << "SHARING CHECK:         report beside it. Make them agree, or vary something that makes"
    lines << "SHARING CHECK:         the runs diverge at this step."
    return lines
}
