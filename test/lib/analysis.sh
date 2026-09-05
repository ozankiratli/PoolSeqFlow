#!/bin/bash
# Fixtures and helpers shared by every analysis suite, and by the cases a module
# ships with itself. Sourced by run_tests.sh before any suite.
#
# The baselines here are built by a real step-0 run and then reused across cases:
# .poolseqflow_params holds the manifest exactly as the pipeline resolves it, and a
# hand-written copy would be a second definition of it.

#!/bin/bash
# The analysis layer: what it ships as, which results an invocation covers, and what it
# refuses before computing anything.
#
# THE PIPELINE IS ASSUMED TO WORK. That is 03_pipeline's business, and running it here would
# cost minutes to produce files this suite only ever counts. Published artifacts are planted
# instead; what cannot be planted is the identity record beside the results, because
# .poolseqflow_params holds the manifest exactly as the pipeline resolves it and a hand-written
# copy would be a second definition of it. Step 0 alone writes that record, once per project
# shape, and every case works from a copy.
#
# The static cases at the top are about the layer's SEPARATION from the pipeline - it may read
# the pipeline, the pipeline may never read it - and cost nothing at all.
ANALYSIS_SB=""

ANALYSIS_BASELINE_SINGLE=""

ANALYSIS_BASELINE_MULTI=""

# The multi-run table these cases use. lenient_a and lenient_b differ only in `annotate`,
# which belongs to step 8 alone, so they are one variant at step 7 and share a results
# directory. strict changes a step-7 filter and gets its own. That split is the whole point:
# selecting one run must reach a directory that also holds another run's results.
analysis_write_runs_table() {
    cat > "$1/main/runs.csv" <<'TABLE'
RunID,annotate,vcffilter.minDP
lenient_a,true,
lenient_b,false,
strict,true,40
TABLE
}

# A multi-run config. The two multiRun settings are part of the recorded manifest, so a copy
# of a baseline has to be rewritten with them or the parameter guard reports a change the
# test made rather than the one it is about.
analysis_write_multi_config() {
    write_sandbox_config "$1" \
        's|^    multiRun .*|    multiRun        = true|' \
        "s|^    multiRunFile .*|    multiRunFile    = 'runs.csv'|"
}

# The fixture's metadata carries exp_time, and a project with a time column has to say how to
# read it or every analysis refuses. So the baseline carries the analysis.config a real project of
# this shape would have, and EVERY helper that writes that file carries this block too - the file
# is written whole, so a helper that omitted it would leave the project unreadable. A case testing
# what happens without an analysis.config removes the time column as well.
ANALYSIS_TIME_BLOCK="        timeVar {

            kind  = 'categorical'

            order = ['T1', 'T2']

        }"

analysis_write_time_config() {
    printf 'params {\n    analysis {\n%s\n    }\n}\n' "$ANALYSIS_TIME_BLOCK" \
        > "$1/main/analysis.config"
}

# A single-run project whose identity the pipeline has recorded. Step 0 alone writes
# .poolseqflow_version and .poolseqflow_params, which is everything the identity check reads,
# and costs about a fifth of a full run.
analysis_baseline_single() {
    [ -n "$ANALYSIS_BASELINE_SINGLE" ] && return 0
    local sb status
    sb=$(make_pipeline_sandbox "analysis-single")
    write_sandbox_config "$sb"
    analysis_write_time_config "$sb"
    status=$(run_verify_only "$sb")
    [ "$status" = "0" ] || return 1
    ANALYSIS_BASELINE_SINGLE="$sb"
    return 0
}

# The same for three runs, which also records .multirun.csv.
analysis_baseline_multi() {
    [ -n "$ANALYSIS_BASELINE_MULTI" ] && return 0
    local sb status
    sb=$(make_pipeline_sandbox "analysis-multi")
    analysis_write_runs_table "$sb"
    analysis_write_multi_config "$sb"
    analysis_write_time_config "$sb"
    status=$(run_verify_only "$sb")
    [ "$status" = "0" ] || return 1
    ANALYSIS_BASELINE_MULTI="$sb"
    return 0
}

# What a completed run would have left in a results directory.
#
# The frequency and depth tables carry test/tools/freq_corpus.py's analytic corpus, whose every
# count is checkable by hand; the frequency tables are derived from the depth tables by the
# pipeline's own bin/depth2freq.awk, so the pair cannot drift from the contract a module reads.
# The VCF and the BAMs stay empty: the analysis layer counts those and never opens them.
analysis_plant_results() {
    local out="$1" name
    mkdir -p "$out/Frequencies" "$out/VCF" "$out/Ready" "$out/Reports" "$out/Reports/Depth"
    CORPUS_DIR="$(dirname "$out")/corpus"
    python3 "$REPO_ROOT/test/tools/freq_corpus.py" "$out" "$CORPUS_DIR"
    for name in Test_snp Test_indel; do
        awk -f "$REPO_ROOT/bin/depth2freq.awk" "$out/Frequencies/${name}_depth.tsv" \
            > "$out/Frequencies/${name}_freq.tsv"
    done
    : > "$out/VCF/Test.vcf"
    for name in 1 2 3 4 5 6; do
        : > "$out/Ready/TestSample${name}_ready.bam"
        : > "$out/Ready/TestSample${name}_ready.bam.bai"
    done
}

# One of the corpus's expected values, by key, from the last plant.
corpus_expects() {
    sed -n "s|^$1	||p" "$CORPUS_DIR/expected.tsv"
}

# A published cell, by row and column name. The tables are small and this keeps a case reading
# as the arithmetic it checks rather than as an awk program.
published_cell() {
    local file="$1" key="$2" column="$3"
    awk -F'\t' -v key="$key" -v col="$column" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) want = i; next }
        $1 == key && want { print $want; exit }' "$file"
}

# The same, keyed on the first two columns - depth.tsv is one row per pool per sequence.
published_cell2() {
    local file="$1" key="$2" second="$3" column="$4"
    awk -F'\t' -v key="$key" -v two="$second" -v col="$column" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) want = i; next }
        $1 == key && $2 == two && want { print $want; exit }' "$file"
}

# Two numbers agreeing to the tolerance a published table's own precision allows.
assert_close() {
    local got="$1" want="$2" message="$3"
    if [ -z "$got" ] || [ -z "$want" ]; then
        fail_case "$message: expected '$want', got '$got'"
        return
    fi
    awk -v a="$got" -v b="$want" 'BEGIN { exit !(a - b < 1e-9 && b - a < 1e-9) }' \
        || fail_case "$message: expected $want, got $got"
}

# The four session files a pipeline run leaves in Output/Reports, with content of their own so
# that an analysis run landing on them is visible as a changed checksum rather than a changed
# timestamp.
analysis_plant_session_reports() {
    local reports="$1/Reports" name
    mkdir -p "$reports"
    for name in trace.txt report.html timeline.html dag.html; do
        printf 'the pipeline wrote this\n' > "$reports/PoolSeqFlow_pipeline_${name}"
    done
}

# A fresh copy of one baseline for a case to mutate.
analysis_ready() {
    local which="$1" baseline
    if ! have_tools; then skip_case "no conda environment"; return 1; fi
    if [ "${TEST_FAST:-0}" = "1" ]; then skip_case "--fast"; return 1; fi

    case "$which" in
        single) analysis_baseline_single && baseline="$ANALYSIS_BASELINE_SINGLE" ;;
        multi)  analysis_baseline_multi  && baseline="$ANALYSIS_BASELINE_MULTI" ;;
        *)      fail_case "unknown baseline '$which'"; return 1 ;;
    esac
    if [ -z "${baseline:-}" ]; then
        fail_case "the $which baseline could not be built; see $TEST_TMPDIR/analysis-$which/run.out"
        return 1
    fi

    ANALYSIS_SB=$(guard_path "$TEST_TMPDIR/analysis")
    rm -rf "$ANALYSIS_SB"
    cp -a "$baseline" "$ANALYSIS_SB"
    if [ "$which" = "multi" ]; then
        analysis_write_multi_config "$ANALYSIS_SB"
    else
        write_sandbox_config "$ANALYSIS_SB"
    fi
    return 0
}

# Install a module into the sandbox's own module store. Takes the name and the manifest body,
# so a case can write a malformed one on purpose, and optionally the main.nf a case needs the
# module to be.
#
# Nothing ships a module: the release carries the frame and an empty store, and a case that
# needs one makes it here.
analysis_install_module() {
    local name="$1" manifest="$2" dir
    dir="$ANALYSIS_SB/install/analysis/modules/$name"
    mkdir -p "$dir"
    printf '%s\n' "$manifest" > "$dir/manifest.json"
    if [ -n "${3:-}" ]; then
        printf '%s\n' "$3" > "$dir/main.nf"
    else
        printf '%s\n' 'nextflow.enable.dsl=2' 'workflow { println "module ran" }' > "$dir/main.nf"
    fi
    # Required of every module, so a fixture that omits it fails on that rather than on what
    # the case is about. A case testing its absence removes it again.
    printf '{}\n' > "$dir/citations.json"
}

# Write the project's analysis.config with one run selection in it.
analysis_select() {
    printf 'params {\n    analysis {\n        runs = %s\n%s\n    }\n}\n' "$1" "$ANALYSIS_TIME_BLOCK" \
        > "$ANALYSIS_SB/main/analysis.config"
}

# The same for the results folder name.
analysis_folder_name() {
    printf 'params {\n    analysis {\n        folderName = %s\n%s\n    }\n}\n' "$1" "$ANALYSIS_TIME_BLOCK" \
        > "$ANALYSIS_SB/main/analysis.config"
}

# What the last analysis invocation printed, refusals included. A refusal happens while the
# DAG is built, so no task runs and no report is written - only this has it.
analysis_output() {
    cat "$ANALYSIS_SB/run.out" 2>/dev/null
}

# ---------------------------------------------------------------------------------------
# The shared R library, called directly.
#
# A Nextflow run costs about 21 seconds of startup flat, so a statistic provable by calling the
# function is proved by calling the function. The expected values are hand-computed and live in
# test/tools/r_lib_tests.R beside the check that uses each.
# Run one section of the R unit tests. Stores the output and echoes the exit status.
R_LIB_OUTPUT=""

r_lib_section() {
    local out status=0
    out=$(Rscript --vanilla "$REPO_ROOT/test/tools/r_lib_tests.R" \
            "$REPO_ROOT/analysis/lib/R" "$1" 2>&1) || status=$?
    R_LIB_OUTPUT="$out"
    printf '%s' "$status"
}

# ---------------------------------------------------------------------------------------
# The experimental design, and the one thing the frame refuses about it.
# Writes a metadata file into a sandbox's project directory, replacing the fixture's.
analysis_write_metadata() {
    printf '%s\n' "$2" > "$1/main/metadata.csv"
}

# ---------------------------------------------------------------------------------------
# The time axis. Every failure here is silent when it is not caught: the plot renders, the
# slope has a sign, and nothing says the order was wrong.
# Replaces the baseline's analysis.config with an `analysis` scope of the case's own.
analysis_write_analysis_config() {
    cat > "$1/main/analysis.config" <<CFG
params {
    analysis {
$2
    }
}
CFG
}

# ---------------------------------------------------------------------------------------
# Biological and technical replicates. The two have OPPOSITE statistical standing - biological
# ones are independent and carry degrees of freedom, technical ones are the same material
# measured twice and carry none - so treating one as the other is pseudo-replication.
# Two conditions, two biological replicates each, and two technical dimensions crossed over
# them: 2 lanes x 2 sequencing runs = 4 series per unit, 16 series, 8 independent units.
ANALYSIS_REPLICATE_METADATA='SampleID,RG_Sample,exp_treatment,exp_rep,exp_lane,exp_seqrun,exp_time
S1,P1,control,1,L1,R1,T1
S2,P2,control,1,L1,R1,T2
S3,P3,control,1,L2,R1,T1
S4,P4,control,1,L2,R1,T2
S5,P5,control,1,L1,R2,T1
S6,P6,control,1,L1,R2,T2
S7,P7,control,1,L2,R2,T1
S8,P8,control,1,L2,R2,T2
S9,P9,control,2,L1,R1,T1
S10,P10,control,2,L1,R1,T2
S11,P11,control,2,L2,R1,T1
S12,P12,control,2,L2,R1,T2
S13,P13,control,2,L1,R2,T1
S14,P14,control,2,L1,R2,T2
S15,P15,control,2,L2,R2,T1
S16,P16,control,2,L2,R2,T2'

# ---------------------------------------------------------------------------------------
# The library a module imports.
#
# A module is its own pipeline, launched directly, and analysis/lib is what it reads the
# project through. These cases run a module for real - the second of the two invocations -
# against a store the case populates itself.
# The probe module: it computes what it would read and where it would write, and prints both.
# Nothing statistical, so the case measures the library and not an analysis.
ANALYSIS_PROBE_MAIN='nextflow.enable.dsl=2

include { analysisPlan } from '"'"'../../lib/nf/plan.nf'"'"'

workflow {
    analysisPlan('"'"'probe'"'"').targets.each { target ->
        println "PROBE reads ${target.classes.frequencies.dir}"
        println "PROBE writes ${target.results}"
    }
}'

ANALYSIS_PROBE_MANIFEST='{ "name": "probe", "version": "0.1.0", "contract": "freq-1",
  "summary": "print what the library says this project holds", "needs": ["frequencies"] }'

# The histograms class is the only one that does not sit at a top-level dir.output key: it is
# reached through dir.output.report.depth.
ANALYSIS_HISTOGRAM_MAIN='nextflow.enable.dsl=2

include { analysisPlan } from '"'"'../../lib/nf/plan.nf'"'"'

workflow {
    analysisPlan('"'"'probe'"'"').targets.each { target ->
        println "PROBE histograms ${target.classes.histograms.dir}"
        println "PROBE frequencies ${target.classes.frequencies.dir}"
        println "PROBE required " + target.classes.findAll { k, v -> v.required }.keySet().sort().join(",")
    }
}'

# A module declares its whole scope's defaults in ONE call and gets the whole scope back. A
# per-call fallback could refuse nothing: `chromosome` for `chromosomes` would take the default,
# and the module would plot nothing with nothing said about it.
ANALYSIS_SETTINGS_MAIN='nextflow.enable.dsl=2

include { moduleSettings } from '"'"'../../lib/nf/paths.nf'"'"'

workflow {
    def settings = moduleSettings('"'"'probe'"'"', [chromosomes: [], minReads: 2])
    println "PROBE chromosomes ${settings.chromosomes}"
    println "PROBE minReads ${settings.minReads}"
}'

# ---------------------------------------------------------------------------------------
# What a module writes: its results, and the intermediates it derives on the way.
# A module that does the whole shape once - restore what is shared, derive it if it is not
# there, produce an analysis, publish it. Nothing statistical again; these cases measure the
# moves.
ANALYSIS_WRITER_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { intermediateFile; publishIntermediate; RestoreIntermediates } from '../../lib/nf/store.nf'
include { PublishResults } from '../../lib/nf/results.nf'

process Derive {
    debug true

    input:
    val target

    output:
    tuple val(target), path('result.*')

    script:
    matrix = intermediateFile(target, 'matrix.tsv')
    publish = publishIntermediate(target, 'matrix.tsv', 'staged.tsv')
    """
    if [ -f '${matrix}' ]; then
        echo "WRITER reused ${matrix}"
    else
        printf 'derived from %s\\n' '${target.label}' > staged.tsv
        ${publish}
        echo "WRITER derived ${matrix}"
    fi

    printf 'analysis of %s\\n' '${target.label}' > result.tsv
    printf 'the script that produced it\\n' > result.R
    """
}

workflow {
    def targets = channel.fromList(analysisPlan('writer').targets)
    RestoreIntermediates(targets.map { target -> tuple(target, ['matrix.tsv']) })
    PublishResults(Derive(RestoreIntermediates.out))
}
MODULE

)

ANALYSIS_WRITER_MANIFEST='{ "name": "writer", "version": "0.1.0", "contract": "freq-1",
  "summary": "derive one intermediate and publish one analysis", "needs": ["frequencies"] }'

# The same, minus everything shared: it produces its results and then fails, which is the state
# refuse-if-populated has to survive.
ANALYSIS_BREAKER_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { PublishResults } from '../../lib/nf/results.nf'

process Derive {
    input:
    val target

    output:
    tuple val(target), path('result.*')

    script:
    """
    printf 'analysis of %s\\n' '${target.label}' > result.tsv
    echo "BREAKER has its results and is about to fail" >&2
    exit 3
    """
}

workflow {
    PublishResults(Derive(channel.fromList(analysisPlan('breaker').targets)))
}
MODULE

)

ANALYSIS_BREAKER_MANIFEST='{ "name": "breaker", "version": "0.1.0", "contract": "freq-1",
  "summary": "fail after producing results", "needs": ["frequencies"] }'

# Produces a result and no script - the thing README rule 15 forbids and nothing used to catch.
ANALYSIS_MUTE_MAIN=$(cat <<'MODULE'
nextflow.enable.dsl=2

include { analysisPlan } from '../../lib/nf/plan.nf'
include { PublishResults } from '../../lib/nf/results.nf'

process Derive {
    input:
    val target

    output:
    tuple val(target), path('result.*')

    script:
    """
    printf 'analysis of %s\\n' '${target.label}' > result.tsv
    """
}

workflow {
    PublishResults(Derive(channel.fromList(analysisPlan('mute').targets)))
}
MODULE

)

ANALYSIS_MUTE_MANIFEST='{ "name": "mute", "version": "20260901.001", "contract": "freq-1",
  "summary": "produce a result and no script", "needs": ["frequencies"] }'

# Set up a single-run project with results planted and one module installed.
analysis_writer_ready() {
    analysis_ready single || return 1
    analysis_plant_results "$ANALYSIS_SB/store/Output"
    analysis_install_module writer "$ANALYSIS_WRITER_MANIFEST" "$ANALYSIS_WRITER_MAIN"
    return 0
}

# What Analysis/Main holds for the one results directory a single-run project has.
analysis_main_dir() {
    printf '%s\n' "$ANALYSIS_SB/main/Analysis/Main/Output"
}

# What `PoolSeqFlow analysis complete` will do: Analysis/Main moves to permanent storage. The
# command is not built yet and these cases must not wait for it - the move back is the half
# that carries the risk.
analysis_archive_main() {
    mkdir -p "$ANALYSIS_SB/store/Analysis"
    mv "$ANALYSIS_SB/main/Analysis/Main" "$ANALYSIS_SB/store/Analysis/Main"
}

# One analysis, start to finish: verify, then the module itself.
analysis_run_module() {
    local module="$1" status
    status=$(run_analysis "$ANALYSIS_SB" "$module")
    [ "$status" = "0" ] || { printf 'verify:%s\n' "$status"; return 0; }
    run_module "$ANALYSIS_SB" "$module"
}

# ---------------------------------------------------------------------------------------
# What a published folder says about how to read itself.
ANALYSIS_LINKED_MANIFEST='{ "name": "writer", "version": "0.1.0", "contract": "freq-1",
  "summary": "publish one analysis and say where it is explained", "needs": ["frequencies"],
  "outputs": [ { "file": "result.tsv", "summary": "the analysis",
                 "anchor": "output-layout" } ] }'

# ---------------------------------------------------------------------------------------
# `PoolSeqFlow analysis complete` - the move to permanent storage.
# Where an archived analysis lands. The same relative path under either volume, which is what
# lets a module find an intermediate again after this has run.
analysis_archived() {
    printf '%s\n' "$ANALYSIS_SB/store/Analysis"
}

# One analysis and one intermediate on the working volume, ready to be moved.
analysis_completable() {
    analysis_writer_ready || return 1
    local status; status=$(analysis_run_module writer)
    [ "$status" = "0" ] || { fail_case "the writer module should have run first"; return 1; }
    return 0
}
