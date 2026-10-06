#!/bin/bash
# The scratch conda environments of a full run: built from the files this release ships, removed
# on the way out, and swept up when an earlier run could not remove its own. Sourced by
# test/run_tests.sh, and by 00_static, which calls the same functions against a stub conda.
#
# A FULL RUN BUILDS A PAIR, PoolSeqFlow-suite-<pid> and PoolSeqFlow-suite-<pid>-analysis, where
# <pid> is the runner's own. test/run_tests.sh says why it may not use an installed release's.
#
# EVERY NAME IS RECORDED IN THIS SHELL, NEVER IN A SUBSHELL. From 2026-10-04 to 2026-10-06 the
# runner called build_scratch_env inside $(...) to capture the prefix it printed, so the name it
# appended to SCRATCH_ENVS was appended in a child shell and lost with it. The cleanup at exit then
# removed nothing and printed nothing, and every full run left its pair behind: five pairs by the
# time a run was read to its last line. The check written with the cleanup set SCRATCH_ENVS by
# hand, which proved the removal and never the recording. So build_scratch_env hands its prefix
# back in SCRATCH_PREFIX rather than on stdout, and nothing here is meant to be called in $(...).

# The environments this run built, and only those.
SCRATCH_ENVS=""
# The prefix of the environment build_scratch_env built last, empty when that build failed.
SCRATCH_PREFIX=""

build_scratch_env() {
    local label="$1" file="$2" suffix="$3" probe="$4" scratch
    SCRATCH_PREFIX=""
    scratch="PoolSeqFlow-suite-$$$suffix"
    if ! command -v conda > /dev/null 2>&1; then
        printf '%s%s: no conda, so no scratch environment can be built%s\n' \
            "${C_DIM:-}" "$label" "${C_OFF:-}" >&2
        return 1
    fi
    if [ ! -f "$REPO_ROOT/$file" ]; then
        printf '%s%s: %s is missing, so there is nothing to build from%s\n' \
            "${C_DIM:-}" "$label" "$file" "${C_OFF:-}" >&2
        return 1
    fi
    printf '%s%s: solving %s into %s. This takes minutes.%s\n' \
        "${C_DIM:-}" "$label" "$file" "$scratch" "${C_OFF:-}" >&2
    # Recorded before the status is judged: a solve that fails part way still leaves one behind.
    SCRATCH_ENVS="$SCRATCH_ENVS $scratch"
    if ! conda env create --name "$scratch" --file "$REPO_ROOT/$file" --yes \
            > "$TEST_TMPDIR/solve-$label.log" 2>&1; then
        printf 'ERROR: %s did not solve:\n' "$file" >&2
        tail -n 15 "$TEST_TMPDIR/solve-$label.log" >&2
        return 1
    fi
    SCRATCH_PREFIX=$(conda env list | awk -v n="$scratch" '$1 == n {print $NF}')
    if [ -z "$SCRATCH_PREFIX" ] || [ ! -x "$SCRATCH_PREFIX/bin/$probe" ]; then
        printf 'ERROR: %s was created but has no bin/%s\n' "$scratch" "$probe" >&2
        SCRATCH_PREFIX=""
        return 1
    fi
}

# Both environments, unless the caller named one: TEST_CONDA_ENV_GIVEN and
# TEST_ANALYSIS_ENV_GIVEN are the runner's record of that. A build that fails leaves its variable
# empty, and the cases that need it skip.
build_scratch_pair() {
    if [ "${TEST_CONDA_ENV_GIVEN:-0}" -ne 1 ]; then
        build_scratch_env tools install/environment.yml "" nextflow \
            && TEST_CONDA_ENV="$SCRATCH_PREFIX"
    fi
    if [ "${TEST_ANALYSIS_ENV_GIVEN:-0}" -ne 1 ]; then
        build_scratch_env analysis install/environment-analysis.yml -analysis Rscript \
            && TEST_ANALYSIS_ENV="$SCRATCH_PREFIX"
    fi
    return 0
}

# This run's environments, removed and named one by one.
remove_scratch_envs() {
    local env
    for env in ${SCRATCH_ENVS:-}; do
        printf '\nremoving the scratch environment %s\n' "$env"
        conda env remove --name "$env" --yes > /dev/null 2>&1 \
            || printf 'WARNING: could not remove %s\n' "$env" >&2
    done
}

# THE SWEEP, at the start of a full run. An exit trap cannot run when a run is killed outright, so
# an environment of this runner's naming whose run is gone - its pid no longer a running process -
# is removed here and named. A pid still running is left alone, which covers this run's own and a
# concurrent full run's. Nothing that is not PoolSeqFlow-suite-<digits>, with or without
# -analysis, is touched: the release environments, PoolSeqFlow-<version>, are what a user runs.
#
# `ps -p` rather than `kill -0`: kill -0 also fails for a live process of another user, and would
# read it as gone.
sweep_scratch_envs() {
    local name pid
    command -v conda > /dev/null 2>&1 || return 0
    while read -r name; do
        pid=${name#PoolSeqFlow-suite-}
        pid=${pid%-analysis}
        ps -p "$pid" > /dev/null 2>&1 && continue
        printf 'removing %s, left behind by a run that is no longer running\n' "$name"
        conda env remove --name "$name" --yes > /dev/null 2>&1 \
            || printf 'WARNING: could not remove %s\n' "$name" >&2
    done < <(conda env list 2>/dev/null \
                 | awk '$1 ~ /^PoolSeqFlow-suite-[0-9]+(-analysis)?$/ { print $1 }')
    return 0
}
