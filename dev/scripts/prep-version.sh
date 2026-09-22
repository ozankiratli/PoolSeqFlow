#!/usr/bin/env bash
#
# Prepare the tool set for a release: update every package, prove the pipeline still works,
# then record what was proven.
#
# Usage:  dev/scripts/prep-version.sh <new-version>          e.g. 2.3.0
#         dev/scripts/prep-version.sh <new-version> --from <env> --from-analysis <env>
#
# A release ships two environments and both are prepared here: the one the pipeline runs in,
# and the one an analysis module runs in.
#
# What it does, in order:
#
#   1. Clones both environments for the version this working copy currently declares into
#      scratch environments, PoolSeqFlow-update and PoolSeqFlow-update-analysis.
#   2. Runs `conda update --all` in each, so the tools move as one mutually consistent set
#      rather than one package at a time.
#   3. Runs the full test suite against both at once.
#   4. Only if that passes: exports them to install/environment.yml and
#      install/environment-analysis.yml, then removes them.
#
# Nothing is exported when the tests fail, and the scratch environments are left in place.
# Output lands in dev/logs/prep-<version>-<timestamp>/, including a table per environment of
# which packages moved.
#
# This does not bump the version or touch the CHANGELOG - run dev/scripts/bump-version.sh
# afterwards. It does not commit anything.

set -euo pipefail

NEW="${1-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <new-version> [--from <env>] [--from-analysis <env>]   (e.g. 2.3.0)" >&2
    exit 1
fi
shift

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

CURRENT="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' PoolSeqFlow | head -1)"
[ -n "$CURRENT" ] || { echo "ERROR: no VERSION= line in ./PoolSeqFlow" >&2; exit 1; }

SOURCE_ENV=""
SOURCE_ANALYSIS_ENV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) SOURCE_ENV="${2-}"; shift ;;
        --from-analysis) SOURCE_ANALYSIS_ENV="${2-}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

env_exists() {
    conda env list | awk '{print $1}' | grep -qxF "$1"
}

# One fixed name each, not PoolSeqFlow-<new>. Neither outlives the run that made it. The
# analysis one ends in -analysis, which is what export-environment.sh reads to decide which
# file an environment belongs in.
UPDATE_ENV="PoolSeqFlow-update"
UPDATE_ANALYSIS_ENV="$UPDATE_ENV-analysis"

# A leftover means an earlier run failed and was not cleaned up.
LEFTOVER=""
for e in "$UPDATE_ENV" "$UPDATE_ANALYSIS_ENV"; do
    env_exists "$e" && LEFTOVER="$LEFTOVER $e"
done
if [ -n "$LEFTOVER" ]; then
    echo "ERROR: already present:$LEFTOVER" >&2
    echo "" >&2
    echo "Left over from an earlier preparation run, most likely one whose tests failed." >&2
    echo "Investigate or discard before starting again:" >&2
    for e in $LEFTOVER; do echo "    conda env remove -n $e" >&2; done
    exit 1
fi

# Which environment to start from: the version this copy declares, unless told otherwise. An
# unversioned environment from an older release is accepted with a note.
if [ -z "$SOURCE_ENV" ]; then
    if env_exists "PoolSeqFlow-$CURRENT"; then
        SOURCE_ENV="PoolSeqFlow-$CURRENT"
    elif env_exists "PoolSeqFlow"; then
        SOURCE_ENV="PoolSeqFlow"
        echo "Note: starting from the unversioned 'PoolSeqFlow' environment."
        echo "      That is an install from before environments were named per version."
        echo ""
    else
        echo "ERROR: no environment to start from." >&2
        echo "Looked for 'PoolSeqFlow-$CURRENT' and 'PoolSeqFlow'." >&2
        echo "Install one first:  ./PoolSeqFlow install" >&2
        exit 1
    fi
fi
env_exists "$SOURCE_ENV" || { echo "ERROR: no environment named '$SOURCE_ENV'" >&2; exit 1; }

# The analysis environment is named per version too. It arrived with the analysis layer, so
# there is no unversioned form to fall back to the way the pipeline one has.
SOURCE_ANALYSIS_ENV="${SOURCE_ANALYSIS_ENV:-PoolSeqFlow-$CURRENT-analysis}"
if ! env_exists "$SOURCE_ANALYSIS_ENV"; then
    echo "ERROR: no analysis environment named '$SOURCE_ANALYSIS_ENV'." >&2
    echo "" >&2
    echo "A release ships install/environment-analysis.yml as well, and it has to describe a" >&2
    echo "solve the suite passed against. Build one first:" >&2
    echo "    ./PoolSeqFlow analysis install" >&2
    echo "or name an existing one with --from-analysis <env>." >&2
    exit 1
fi

# Whether the analysis export would be accepted at all. An installed module puts its own
# packages into the shared analysis environment, and export-environment.sh refuses to fold
# those into the baseline every project installs from. Asked now: the clone inherits them, so
# the export below reaches the same answer, an hour of solving and testing later.
if ! CHECK_OUT=$(bash dev/scripts/export-environment.sh --check "$SOURCE_ANALYSIS_ENV" 2>&1); then
    if [ -n "$CHECK_OUT" ]; then
        printf '%s\n' "$CHECK_OUT" >&2
    else
        # It reads conda through a pipeline that discards conda's stderr, so a conda that
        # fails outright ends the script with a status and nothing to read.
        echo "ERROR: export-environment.sh --check '$SOURCE_ANALYSIS_ENV' failed silently." >&2
        echo "Run it by hand to see what conda says." >&2
    fi
    exit 1
fi

# Every package a shipped environment file names, as bare names. Only the dependencies: block,
# so the channel list is not read as packages, and only up to the first `=`, because a version
# is what the update is about to move.
spec_packages() {
    awk '/^dependencies:/ { d = 1; next }
         /^[a-z]/         { d = 0 }
         d && /^ *- / { sub(/^ *- */, ""); sub(/[=<> ].*/, ""); if ($0 != "") print }' "$1" | sort -u
}

# What an environment holds that its own shipped file does not name is fine - that is what the
# solver added. What the file names and the environment does NOT hold means the environment was
# built before that line existed. Cloning it then carries the gap into the export, and the
# package leaves the release without anything saying so.
missing_from_env() {
    local file="$1" env="$2" held pkg
    held=$(conda list -n "$env" --export 2>/dev/null | sed -n 's/^\([^#=][^=]*\)=.*/\1/p')
    while read -r pkg; do
        [ -n "$pkg" ] || continue
        printf '%s\n' "$held" | grep -qxF "$pkg" || printf '%s\n' "$pkg"
    done < <(spec_packages "$file")
}

STALE=""
for pair in "install/environment.yml:$SOURCE_ENV" \
            "install/environment-analysis.yml:$SOURCE_ANALYSIS_ENV"; do
    f="${pair%%:*}"; e="${pair#*:}"
    gone=$(missing_from_env "$f" "$e")
    [ -n "$gone" ] && STALE="$STALE$e is missing, of what $f names:"$'\n'"$(printf '%s' "$gone" | sed 's/^/    /')"$'\n'
done
if [ -n "$STALE" ]; then
    printf 'ERROR: a source environment is older than the file it was built from.\n\n' >&2
    printf '%s\n' "$STALE" >&2
    echo "Cloning it would carry that gap into the export, and the package would leave the" >&2
    echo "release with nothing saying so. Rebuild the environment before preparing a release:" >&2
    echo "    ./PoolSeqFlow analysis uninstall && ./PoolSeqFlow analysis install" >&2
    echo "or add what is missing to the environment by hand and run this again." >&2
    exit 1
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
LOGDIR="dev/logs/prep-$NEW-$STAMP"
mkdir -p "$LOGDIR"

say() { printf '%s\n' "$*" | tee -a "$LOGDIR/summary.txt"; }

say "PoolSeqFlow release preparation"
say "  target version : $NEW"
say "  pipeline env   : $SOURCE_ENV  ->  $UPDATE_ENV"
say "  analysis env   : $SOURCE_ANALYSIS_ENV  ->  $UPDATE_ANALYSIS_ENV"
say "  scratch envs   : removed once both exports succeed"
say "  logs           : $LOGDIR"
say ""

# Clone one environment into a scratch copy, update everything in it, and print what moved.
# $3 is the suffix that keeps the two environments' log files apart; the pipeline's is empty,
# so its file names are unchanged.
prepare_env() {
    local source="$1" scratch="$2" tag="$3" changed prefix floor
    conda create --name "$scratch" --clone "$source" --yes > "$LOGDIR/clone$tag.log" 2>&1 \
        || { say "      FAILED to clone '$source' - see $LOGDIR/clone$tag.log"; exit 1; }

    # THE UPDATE IS TOLD THE HOST FLOOR BEFORE IT RUNS, NOT CORRECTED AFTERWARDS.
    #
    # `conda update --all` takes the newest build of everything this machine can install, and
    # sysroot_linux-64 is the package whose newest build encodes the glibc of whoever ran it.
    # Left alone it climbs to the maintainer's own glibc every release - which is how v3.1.1
    # shipped an analysis environment no cluster below glibc 2.39 could install.
    #
    # conda's own pinned-specs file is what states that up front, so the solver never proposes
    # the raise and there is nothing to undo. Correcting it after the fact would mean a second
    # solve that can itself fail, and would be automating away a decision rather than stating a
    # constraint: raising the floor drops machines and belongs to a person.
    #
    # Only where the package is already present. The pipeline environment has no sysroot and
    # must not gain one from a pin written on its behalf.
    floor=$(sed -n 's/^# host-glibc-floor: *\(.*\)$/\1/p' \
            install/environment-analysis.yml | head -1)
    prefix=$(conda env list | awk -v n="$scratch" '$1 == n {print $NF}')
    if [ -n "$floor" ] && [ -n "$prefix" ] && [ -d "$prefix/conda-meta" ] &&
       conda list --name "$scratch" 2>/dev/null | grep -q '^sysroot_linux-64 '; then
        say "      holding sysroot_linux-64 at <=$floor (the host floor)"
        echo "sysroot_linux-64 <=$floor" >> "$prefix/conda-meta/pinned"
    fi

    conda update --all --name "$scratch" --yes > "$LOGDIR/update$tag.log" 2>&1 \
        || { say "      FAILED to update '$scratch' - see $LOGDIR/update$tag.log"; exit 1; }
    conda list --name "$scratch" --export > "$LOGDIR/packages-after$tag.txt"

    # What actually moved: the release-note material, and the first thing to read on a failure.
    #
    # COMPARED ON version=build, NOT ON version ALONE. `conda list --export` prints
    # name=version=build, and comparing only the version hides a conda-forge rebuild - the same
    # version against a newer libgcc, which is a different binary and can behave differently.
    # RELEASING.md asks the reader to classify exactly that category, so a table that cannot
    # show it sends them looking for a cause it has hidden.
    #
    # Measured on the 3.1.2 attempt: this table reported 3 packages changed in the analysis
    # environment while the real diff was 26, the other 23 being build-string moves across the
    # whole gcc/libstdcxx/libgfortran/libblas stack.
    awk -F'=' '
        function spec(v, b) { return b == "" ? v : v "=" b }
        FNR == NR { if ($0 !~ /^#/ && NF >= 2) before[$1] = spec($2, $3); next }
        /^#/ || NF < 2 { next }
        {
            now = spec($2, $3)
            if (!($1 in before))        { printf "%s\t(new)\t%s\n", $1, now }
            else if (before[$1] != now) { printf "%s\t%s\t%s\n", $1, before[$1], now }
            seen[$1] = 1
        }
        END {
            for (p in before) if (!(p in seen)) printf "%s\t%s\t(removed)\n", p, before[p]
        }
    ' "$LOGDIR/packages-before$tag.txt" "$LOGDIR/packages-after$tag.txt" \
        | sort > "$LOGDIR/packages-changed$tag.tsv"

    changed=$(wc -l < "$LOGDIR/packages-changed$tag.tsv")
    say "      $scratch: $changed package(s) changed - see $LOGDIR/packages-changed$tag.tsv"
    if [ "$changed" -gt 0 ]; then
        say ""
        { printf 'PACKAGE\tBEFORE\tAFTER\n'; cat "$LOGDIR/packages-changed$tag.tsv"; } \
            | column -t -s $'\t' | sed 's/^/      /' | tee -a "$LOGDIR/summary.txt"
        say ""
    fi
}

# ---------------------------------------------------------------- snapshot and clone ----
say "[1/5] Recording the current tool sets..."
conda list --name "$SOURCE_ENV" --export > "$LOGDIR/packages-before.txt"
conda list --name "$SOURCE_ANALYSIS_ENV" --export > "$LOGDIR/packages-before-analysis.txt"
say "      $SOURCE_ENV: $(grep -c '^[^#]' "$LOGDIR/packages-before.txt") packages"
say "      $SOURCE_ANALYSIS_ENV: $(grep -c '^[^#]' "$LOGDIR/packages-before-analysis.txt") packages"

say "[2/5] Cloning both and updating everything..."
prepare_env "$SOURCE_ENV" "$UPDATE_ENV" ""
prepare_env "$SOURCE_ANALYSIS_ENV" "$UPDATE_ANALYSIS_ENV" "-analysis"

# Both environments carry Nextflow: the analysis layer is a pipeline of its own, and
# install/environment-analysis.yml says it carries the pipeline environment's version. Two
# independent solves can land either side of a release, so the claim is checked rather than
# assumed. A warning, because it is the suite that says whether the pair works.
NF_PIPELINE=$(sed -n 's/^nextflow=\([^=]*\)=.*/\1/p' "$LOGDIR/packages-after.txt" | head -1)
NF_ANALYSIS=$(sed -n 's/^nextflow=\([^=]*\)=.*/\1/p' "$LOGDIR/packages-after-analysis.txt" | head -1)
if [ "$NF_PIPELINE" != "$NF_ANALYSIS" ]; then
    say "      WARNING: nextflow is $NF_PIPELINE in '$UPDATE_ENV' and $NF_ANALYSIS in"
    say "               '$UPDATE_ANALYSIS_ENV'. Settle which version ships before freezing,"
    say "               or a user's analyses run on a different engine from their runs."
    say ""
fi

# ------------------------------------------------------------------------- test ---------
say "[3/5] Running the full test suite against both scratch environments..."
ENV_PREFIX="$(conda env list | awk -v n="$UPDATE_ENV" '$1 == n {print $NF}')"
if [ -z "$ENV_PREFIX" ] || [ ! -x "$ENV_PREFIX/bin/nextflow" ]; then
    say "      ERROR: '$UPDATE_ENV' has no usable nextflow at $ENV_PREFIX/bin/nextflow"
    exit 1
fi
ANALYSIS_PREFIX="$(conda env list | awk -v n="$UPDATE_ANALYSIS_ENV" '$1 == n {print $NF}')"
if [ -z "$ANALYSIS_PREFIX" ] || [ ! -x "$ANALYSIS_PREFIX/bin/Rscript" ]; then
    say "      ERROR: '$UPDATE_ANALYSIS_ENV' has no usable Rscript at $ANALYSIS_PREFIX/bin/Rscript"
    exit 1
fi

# Both named explicitly. The suite finds an analysis environment by globbing
# PoolSeqFlow-*-analysis and taking the first that has an Rscript, which is whichever name
# sorts first rather than the one being prepared.
set +e
TEST_CONDA_ENV="$ENV_PREFIX" TEST_ANALYSIS_ENV="$ANALYSIS_PREFIX" \
    ./test/run_tests.sh > "$LOGDIR/tests.log" 2>&1
TEST_STATUS=$?
set -e

tail -n 20 "$LOGDIR/tests.log" | sed 's/^/      /' | tee -a "$LOGDIR/summary.txt"
say ""

if [ "$TEST_STATUS" -ne 0 ]; then
    say "STOPPED: the test suite failed (status $TEST_STATUS). Nothing was exported."
    say ""
    say "      Both install/environment.yml and install/environment-analysis.yml are"
    say "      unchanged, so the current release still describes a tool set that works."
    say ""
    say "      Both scratch environments have been kept so the failure can be reproduced:"
    say "          TEST_CONDA_ENV=$ENV_PREFIX \\"
    say "          TEST_ANALYSIS_ENV=$ANALYSIS_PREFIX \\"
    say "              ./test/run_tests.sh --suite <name>"
    say ""
    say "      Start with $LOGDIR/packages-changed.tsv and"
    say "      $LOGDIR/packages-changed-analysis.tsv - the failure is"
    say "      almost certainly one of the packages listed there."
    say ""
    say "      Discard the attempt with:"
    say "          conda env remove -n $UPDATE_ENV"
    say "          conda env remove -n $UPDATE_ANALYSIS_ENV"
    exit 1
fi

# ----------------------------------------------------------------------- export ---------

# THE FLOOR IS CHECKED BEFORE THE EXPORT, AGAINST THE SCRATCH ENVIRONMENT ITSELF.
#
# `conda update --all` takes the newest build reachable on THIS host, and this host is whatever
# glibc the maintainer runs. The pin written in prepare_env holds sysroot_linux-64 down, and the
# export refuses a file whose sysroot breaks the floor - but both of those see one package,
# because sysroot is the only one whose VERSION is the glibc it targets. Every other package
# carries the bound in its conda metadata: rsync requires `__glibc >=2.28` and nothing in the
# string "3.4.4" says so.
#
# So an update can raise the real floor without either guard noticing, and the exported file
# would then carry a header promising a floor its own contents break. Checking the scratch
# environment here catches that while the solve is still in hand, instead of after the file is
# written and an install has been done from it.
say "[4/5] Tests passed. Checking what each environment requires of its host..."
for e in "$UPDATE_ENV" "$UPDATE_ANALYSIS_ENV"; do
    if ! FLOOR_OUT=$(bash dev/scripts/check-host-floor.sh "$e" 2>&1); then
        printf '%s\n' "$FLOOR_OUT" | tee -a "$LOGDIR/summary.txt" | sed 's/^/      /'
        say "      Nothing was exported. The update raised the floor above what this release"
        say "      promises, which drops machines and is a decision rather than a solve result."
        exit 1
    fi
    printf '%s\n' "$FLOOR_OUT" >> "$LOGDIR/summary.txt"
done

say "      Exporting both to install/environment*.yml..."
for e in "$UPDATE_ENV" "$UPDATE_ANALYSIS_ENV"; do
    bash dev/scripts/export-environment.sh "$e" >> "$LOGDIR/summary.txt" 2>&1 \
        || { say "      FAILED to export '$e' - see $LOGDIR/summary.txt"; exit 1; }
done

# Removed only after both exports have succeeded, so a failure there does not lose the solve.
say "[5/5] Removing the scratch environments..."
for e in "$UPDATE_ENV" "$UPDATE_ANALYSIS_ENV"; do
    conda env remove --name "$e" --yes >> "$LOGDIR/cleanup.log" 2>&1 \
        || say "      WARNING: could not remove '$e' - see $LOGDIR/cleanup.log"
done

say ""
say "Done. Next:"
say "    git diff install/environment.yml install/environment-analysis.yml"
say "    dev/scripts/bump-version.sh $NEW"
say "    ./PoolSeqFlow install                   # builds PoolSeqFlow-$NEW"
say "    ./PoolSeqFlow analysis install          # builds PoolSeqFlow-$NEW-analysis"
say "    ./PoolSeqFlow check install"
say ""
say "Both release environments are built by those installs, from the two exported files, so"
say "what ships and what was tested are the same set - and the files, not long-lived"
say "environments, are what carry them forward."
