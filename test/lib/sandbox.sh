#!/bin/bash
# Isolated working areas for the test suite.
#
# Every test that runs the pipeline or the launcher does so against a throwaway copy under
# TEST_TMPDIR. Nothing in here may write inside the repository, and nothing may point the
# pipeline at a real project directory - guard_path below refuses both.

# Refuse any path that is not inside the suite's own temporary area. The pipeline deletes
# and overwrites whatever mainDir/projectDir point at, and a real project holds sequencing
# data that took days to produce, so this is checked rather than assumed.
guard_path() {
    local path="$1" resolved
    resolved=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")
    case "$resolved" in
        "$TEST_TMPDIR"/*) ;;
        *)
            echo "test harness: refusing to use '$resolved' - outside TEST_TMPDIR" >&2
            exit 1
            ;;
    esac
    case "$resolved" in
        "$REPO_ROOT"/*)
            echo "test harness: refusing to use '$resolved' - inside the repository" >&2
            exit 1
            ;;
    esac
    printf '%s' "$resolved"
}

# A directory holding the pipeline code plus a project built from a committed fixture.
# Echoes the sandbox path. Optional second argument names the fixture (default: base).
make_pipeline_sandbox() {
    local name="$1" fixture="${2:-base}" sb
    sb=$(guard_path "$TEST_TMPDIR/$name")
    rm -rf "$sb"
    mkdir -p "$sb"
    cp -r "$REPO_ROOT"/scripts "$REPO_ROOT"/bin "$sb"/
    cp "$REPO_ROOT"/poolseqflow.nf "$REPO_ROOT"/nextflow.config "$sb"/
    cp -r "$REPO_ROOT/test/data/$fixture" "$sb/proj"
    printf '%s' "$sb"
}

# Write a parameters.config into a sandbox, derived from the shipped template so the test
# exercises the real defaults. Extra `key=value` style sed expressions may follow.
write_sandbox_config() {
    local sb="$1"; shift
    local -a seds=(
        -e "s|^    mainDir .*|    mainDir         = \"$sb\"|"
        -e "s|^    projectDir .*|    projectDir      = \"$sb/proj\"|"
        -e "s|^    threads .*|    threads         = 4|"
        -e "s|^    memory .*|    memory          = '6 GB'|"
    )
    local expr
    for expr in "$@"; do
        seds+=(-e "$expr")
    done
    sed "${seds[@]}" "$REPO_ROOT/parameters.config.template" > "$sb/parameters.config"
    # The suite runs tools from the conda environment already on PATH rather than letting
    # Nextflow build one per process, which would dominate the runtime.
    echo "conda.enabled = false" >> "$sb/parameters.config"
}

# Run the pipeline inside a sandbox. Stores combined output in $sb/run.out and echoes the
# exit status. Any extra arguments are passed through to `nextflow run`.
run_pipeline() {
    local sb="$1"; shift
    (
        cd "$sb" || exit 1
        export JAVA_HOME="$TEST_CONDA_ENV" JAVA_CMD="$TEST_CONDA_ENV/bin/java"
        export PATH="$TEST_CONDA_ENV/bin:$PATH"
        export NXF_HOME="$sb/nxfhome" NXF_VER="${TEST_NXF_VER:-26.04.6}"
        nextflow -q run poolseqflow.nf "$@" > run.out 2>&1
    )
    printf '%s' "$?"
}

# A fake `conda` that answers from a canned environment list and records what it was asked
# to do. Launcher tests use this so they never create, activate or remove a real
# environment - a test suite must not be able to delete an operator's 1 GB install.
#
# `conda shell.bash hook` prints nothing, so the launcher's `eval` is a no-op and later
# `conda` calls resolve to this stub on PATH.
make_stub_conda() {
    local dir="$1"; shift
    mkdir -p "$dir/bin"
    : > "$dir/conda.log"
    {
        echo '#!/bin/bash'
        echo "LOG=\"$dir/conda.log\""
        echo 'echo "$*" >> "$LOG"'
        echo 'case "$1 $2" in'
        echo '    "shell.bash hook") exit 0 ;;'
        echo '    "env list")'
        echo '        echo "# conda environments:"'
        for env in "$@"; do
            printf '        echo "%-24s %s"\n' "$env" "/fake/envs/$env"
        done
        echo '        exit 0 ;;'
        echo '    "env create") exit 0 ;;'
        echo '    "env remove") exit 0 ;;'
        echo 'esac'
        echo 'exit 0'
    } > "$dir/bin/conda"
    chmod +x "$dir/bin/conda"
}

LAUNCHER_OUTPUT=""
LAUNCHER_STATUS=0
LAUNCHER_CONDA_LOG=""

# Run ./PoolSeqFlow against a stub conda, in a copy of the repository with the slow parts
# stubbed out. Results land in LAUNCHER_OUTPUT / LAUNCHER_STATUS / LAUNCHER_CONDA_LOG.
#
# Deliberately not written as `out=$(run_launcher_with_envs ...)`. A function called inside
# a command substitution runs in a subshell, so anything it assigns is lost when that
# subshell exits - the status would never reach the caller. Feed stdin with a herestring
# (`run_launcher_with_envs ... <<< y`) rather than a pipe, for the same reason: a pipeline
# puts the function in a subshell too.
run_launcher_with_envs() {
    local envs_spec="$1"; shift   # space-separated environment names, may be empty
    local sb
    sb=$(guard_path "$TEST_TMPDIR/launcher")
    rm -rf "$sb"
    mkdir -p "$sb/install" "$sb/bin"
    cp "$REPO_ROOT/PoolSeqFlow" "$sb/"
    # check_install.sh does real work against a real environment; these tests are about
    # environment selection, so it is stubbed to a success.
    printf '#!/bin/bash\necho "STUB check_install ran"\n' > "$sb/install/check_install.sh"
    printf 'name: stub\n' > "$sb/install/environment.yml"
    chmod +x "$sb/install/check_install.sh"
    # shellcheck disable=SC2086
    make_stub_conda "$sb" $envs_spec
    LAUNCHER_CONDA_LOG="$sb/conda.log"
    LAUNCHER_OUTPUT=$(cd "$sb" && PATH="$sb/bin:$PATH" ./PoolSeqFlow "$@" 2>&1)
    LAUNCHER_STATUS=$?
}
