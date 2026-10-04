#!/usr/bin/env bash
#
# Prepare the tool set for a release: update every package, prove the pipeline still works,
# then record what was proven.
#
# Usage:  dev/scripts/prep-version.sh <new-version> [--no-cleanup]       e.g. 2.3.0
#
# A release ships two environments and both are prepared here: the one the pipeline runs in,
# and the one an analysis module runs in.
#
# BUILT FROM THE SHIPPED FILES, NOT CLONED FROM AN INSTALLATION. install/environment.yml and
# install/environment-analysis.yml are what a user installs from, so they are what this starts
# from. An installed environment was the wrong baseline twice over, and this script carried a
# guard against each: an installed module puts its own packages into the shared analysis
# environment, and an environment built before a line was added to the file does not hold that
# package, so cloning carried the gap into the export and the package left the release with
# nothing saying so. Neither can arise from a fresh solve of the file itself.
#
# What it does, in order:
#
#   1. Solves both shipped files into scratch environments, PoolSeqFlow-update and
#      PoolSeqFlow-update-analysis, recording what each file resolves to today, then runs
#      `conda update --all` in each, so the tools move as one mutually consistent set rather
#      than one package at a time.
#   2. Moves any module package pin the update left behind, and bumps that module's version with
#      it. A pin may name exactly one version - whatever the shared analysis environment holds -
#      so the update decides it, and before the suite, so the suite runs on what will ship.
#   3. Runs the full test suite against both at once.
#   4. Only if that passes: reads what each environment requires of its host, then exports them
#      to install/environment.yml and install/environment-analysis.yml.
#   5. Proves the two files it just wrote, which is a different question from the environments
#      above: check-exported-floor.sh solves each from nothing and reads its floor, and
#      check-module-packages.sh puts the modules' pins through a baseline built from the new file.
#   6. Removes the scratch environments.
#
# Nothing is exported when the tests fail. Output lands in dev/logs/prep-<version>-<timestamp>/,
# including a table per environment of which packages moved.
#
# The conda package cache is left alone. `conda clean` reaches the packages every other
# environment on this machine shares, which is a decision about the whole machine.
#
# This does not bump the release version or touch the CHANGELOG - run dev/scripts/bump-version.sh
# afterwards. It commits nothing: the two exported files, and any manifest whose pin moved, are
# left in the tree to be reviewed and committed with the release.

set -euo pipefail

NEW="${1-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <new-version> [--no-cleanup]   (e.g. 2.3.0)" >&2
    exit 1
fi
shift

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PIPELINE_FILE="install/environment.yml"
ANALYSIS_FILE="install/environment-analysis.yml"
for f in "$PIPELINE_FILE" "$ANALYSIS_FILE"; do
    [ -f "$f" ] || { echo "ERROR: $f is missing, so there is nothing to prepare from" >&2; exit 1; }
done

# env_exists, store_packages and conda_conflicting_packages. INSTALL is what wrapper_lib
# resolves its own paths from; nothing here runs the wrapper.
INSTALL="$ROOT"
POOLSEQFLOW_INSTALLED_HOME="${POOLSEQFLOW_INSTALLED_HOME:-}"
# shellcheck source=../../lib/wrapper_lib.sh
. "$ROOT/lib/wrapper_lib.sh"

# WHAT THIS SCRIPT NEEDS FROM THERE, NAMED, so a function that moves stops the run in its first
# second. conda_conflicting_packages is called at [2/6], on the far side of the solve and the
# update, so otherwise a rename would surface an hour in.
WRAPPER_LIB_NEEDS="env_exists store_packages module_packages conda_conflicting_packages"
for fn in $WRAPPER_LIB_NEEDS; do
    declare -F "$fn" > /dev/null \
        || { echo "ERROR: lib/wrapper_lib.sh defines no $fn(), which this script calls." >&2
             exit 1; }
done

NO_CLEANUP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-cleanup) NO_CLEANUP=1 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# The scratch environments this run created, and only those. A conda environment outlives the
# process, so every exit path has to remove them or the next run finds them and refuses.
CREATED=""

# Manifests this run rewrote. A conda environment is removed on the way out; a file edit is not,
# and after a failure these pin versions no export ever shipped - so they are named rather than
# reverted. Reverting would mean a git operation on files the maintainer may have edited too.
TOUCHED_MANIFESTS=""

cleanup() {
    local status=$? e log
    trap - EXIT
    if [ "$status" -ne 0 ] && [ -n "${TOUCHED_MANIFESTS:-}" ]; then
        printf '\n' >&2
        printf 'These manifests were rewritten before this failed, and still are:\n' >&2
        for e in $TOUCHED_MANIFESTS; do printf '    %s\n' "$e" >&2; done
        printf 'Each carries a moved package pin and the version bump that goes with it.\n' >&2
        printf 'Nothing was exported, so they now pin versions the shipped environment files\n' >&2
        printf 'do not hold. Keep them for the next attempt, or undo them:\n' >&2
        # shellcheck disable=SC2086
        printf '    git checkout --%s\n' "$(printf ' %s' $TOUCHED_MANIFESTS)" >&2
        printf '\n' >&2
    fi
    [ -n "$CREATED" ] || exit "$status"
    if [ "$NO_CLEANUP" -eq 1 ]; then
        printf 'Scratch environments kept, --no-cleanup:\n' >&2
        if [ -n "${ENV_PREFIX:-}" ] && [ -n "${ANALYSIS_PREFIX:-}" ]; then
            printf '    TEST_CONDA_ENV=%s \\\n' "$ENV_PREFIX" >&2
            printf '    TEST_ANALYSIS_ENV=%s \\\n' "$ANALYSIS_PREFIX" >&2
            printf '        ./test/run_tests.sh --suite <name>\n' >&2
            printf '\n' >&2
        fi
        printf 'Remove them when you are done:\n' >&2
        for e in $CREATED; do printf '    conda env remove -n %s\n' "$e" >&2; done
        exit "$status"
    fi
    log=/dev/null
    [ -n "${LOGDIR:-}" ] && [ -d "${LOGDIR:-}" ] && log="$LOGDIR/cleanup.log"
    for e in $CREATED; do
        conda env remove --name "$e" --yes >> "$log" 2>&1 \
            || printf "WARNING: could not remove scratch environment '%s'\n" "$e" >&2
    done
    exit "$status"
}
# INT and TERM route through EXIT rather than removing anything themselves, so there is one
# removal path whatever ends the run.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    echo "Left from an earlier run that used --no-cleanup, or one that was killed outright." >&2
    echo "Investigate or discard before starting again:" >&2
    for e in $LEFTOVER; do echo "    conda env remove -n $e" >&2; done
    exit 1
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
LOGDIR="dev/logs/prep-$NEW-$STAMP"
mkdir -p "$LOGDIR"

say() { printf '%s\n' "$*" | tee -a "$LOGDIR/summary.txt"; }

say "PoolSeqFlow release preparation"
say "  target version : $NEW"
say "  pipeline env   : $PIPELINE_FILE  ->  $UPDATE_ENV"
say "  analysis env   : $ANALYSIS_FILE  ->  $UPDATE_ANALYSIS_ENV"
say "  scratch envs   : removed on every exit, unless --no-cleanup"
say "  logs           : $LOGDIR"
say ""

# Solve one shipped file into a scratch environment, update everything in it, and print what
# moved. $3 is the suffix that keeps the two environments' log files apart; the pipeline's is
# empty, so its file names are unchanged.
prepare_env() {
    local file="$1" scratch="$2" tag="$3" changed prefix floor
    # Recorded before the status is judged: a solve that fails part way leaves an environment
    # behind, and the trap has to know about it either way.
    CREATED="$CREATED $scratch"
    # -n, not the file's own name: the exported files carry no `name:` key, which 00_static
    # asserts so that a user's install cannot be named by whoever ran the export.
    conda env create --name "$scratch" --file "$file" --yes > "$LOGDIR/solve$tag.log" 2>&1 \
        || { say "      FAILED to solve '$file' - see $LOGDIR/solve$tag.log"; exit 1; }

    # WHAT THE SHIPPED FILE RESOLVES TO TODAY, which is the baseline the update moves from.
    # Read out of this solve rather than out of an installed environment, so the table below
    # cannot report a drift that belongs to the maintainer's own machine.
    conda list --name "$scratch" --export > "$LOGDIR/packages-before$tag.txt"
    say "      $file solves to $(grep -c '^[^#]' "$LOGDIR/packages-before$tag.txt") packages"

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

# ------------------------------------------------------------------ solve and update ----
say "[1/6] Solving both shipped files, then updating everything in each..."
prepare_env "$PIPELINE_FILE" "$UPDATE_ENV" ""
prepare_env "$ANALYSIS_FILE" "$UPDATE_ANALYSIS_ENV" "-analysis"

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

# -------------------------------------------------------------------- module pins -------
#
# DONE HERE, BEFORE THE SUITE, BECAUSE THE MODULES MOVE WITH THE ENVIRONMENT.
#
# A module pin has to name the version the shared analysis environment holds. conda_install_
# packages refuses one that disagrees, because `--freeze-installed` does not cover a package
# NAMED ON THE COMMAND LINE: conda installs that at the version asked for and downgrades the
# baseline without a word. So an update that moves r-future leaves every module pinning the old
# one unable to install at all.
#
# WHICH MAKES THE NEW VALUE DERIVED RATHER THAN CHOSEN. There is exactly one version a pin may
# name, and the update has just decided it. Reporting that and stopping made every environment
# update a blocker on hand-editing manifests, so the pin is moved here and the module bumped with
# it, which is what makes the edit publishable. Both changes are left uncommitted, like the
# exported files, and each bumped module is republished at the end of the release.
#
# Before the suite, so the suite runs against the manifests that will ship.
say "[2/6] Checking the modules' pins against the updated baseline..."
pin_clashes() {
    local shipped
    shipped=$( { store_packages "$ROOT/modules"; store_packages "$ROOT/modules/lib"; } | sort -u )
    [ -n "$shipped" ] || return 0
    # shellcheck disable=SC2086
    conda_conflicting_packages "$UPDATE_ANALYSIS_ENV" $shipped
}

SHIPPED=$( { store_packages "$ROOT/modules"; store_packages "$ROOT/modules/lib"; } | sort -u )
if [ -z "$SHIPPED" ]; then
    say "      no module or library declares a package"
else
    # shellcheck disable=SC2086
    PIN_COUNT=$(printf '%s\n' $SHIPPED | wc -l | tr -d ' ')
    CLASH=$(pin_clashes)
    if [ -z "$CLASH" ]; then
        say "      all $PIN_COUNT pins agree with what the updated baseline holds"
    else
        say "      the update moved packages the modules pin. Moving each pin with it:"
        say ""
        MOVED=""
        while read -r line; do
            [ -n "$line" ] || continue
            # conda_conflicting_packages prints `r-future=1.75.0 (installed 1.76.0)`.
            OLD_SPEC="${line%% *}"
            PKG="${OLD_SPEC%%=*}"
            NOW=$(printf '%s' "$line" | sed -n 's/.*(installed \(.*\))$/\1/p')
            [ -n "$NOW" ] || { say "      could not read an installed version from: $line"; exit 1; }
            # A package name carries dots - r-data.table - so the pattern is escaped rather than
            # trusted to match itself.
            ESCAPED=$(printf '%s' "$OLD_SPEC" | sed 's/[].[^$*\\]/\\&/g')
            for manifest in "$ROOT"/modules/*/manifest.json "$ROOT"/modules/lib/*/manifest.json; do
                [ -f "$manifest" ] || continue
                module_packages "$manifest" | grep -qxF "$OLD_SPEC" || continue
                NAME=$(basename "$(dirname "$manifest")")
                sed -i "s|\"$ESCAPED\"|\"$PKG=$NOW\"|" "$manifest"
                module_packages "$manifest" | grep -qxF "$PKG=$NOW" \
                    || { say "      FAILED to rewrite $OLD_SPEC in ${manifest#"$ROOT"/}"; exit 1; }
                say "      $NAME: $OLD_SPEC -> $PKG=$NOW"
                case " $MOVED " in *" $NAME "*) ;; *) MOVED="$MOVED $NAME" ;; esac
                REL="${manifest#"$ROOT"/}"
                case " $TOUCHED_MANIFESTS " in
                    *" $REL "*) ;; *) TOUCHED_MANIFESTS="$TOUCHED_MANIFESTS $REL" ;;
                esac
            done
        done <<< "$CLASH"

        say ""
        for NAME in $MOVED; do
            BUMP_OUT=$(bash dev/scripts/bump-analysis-version.sh module "$NAME" 2>&1) \
                || { say "      FAILED to bump '$NAME':"
                     printf '%s\n' "$BUMP_OUT" | sed 's/^/        /' >&2; exit 1; }
            printf '%s\n' "$BUMP_OUT" | head -1 | sed 's/^      /      /;s/^/      /' \
                | tee -a "$LOGDIR/summary.txt"
        done

        # THAT THE REWRITE TOOK, asked of the manifests again rather than assumed from the sed
        # exiting 0. A pin left behind here is a module nobody can install, found at [5/6] after
        # the suite instead of now.
        CLASH=$(pin_clashes)
        if [ -n "$CLASH" ]; then
            say ""
            say "STOPPED: a pin still disagrees with the baseline after the rewrite."
            printf '%s\n' "$CLASH" | sed 's/^/        /' | tee -a "$LOGDIR/summary.txt"
            exit 1
        fi
        say ""
        say "      every pin now agrees with the baseline. The manifests are changed in the"
        say "      tree and uncommitted, like the exported files below."
    fi
fi
say ""

# ------------------------------------------------------------------------- test ---------
say "[3/6] Running the full test suite against both scratch environments..."
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

# What the machine looked like going in. A suite that passes by hand and fails here is a
# difference in the surroundings, and without this there is nothing to compare.
{
    echo "== before the suite =="
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    echo "-- memory --";  free -h 2>/dev/null
    echo "-- disk --";    df -h /tmp /dev/shm "${TMPDIR:-/tmp}" 2>/dev/null | sort -u
    echo "-- load --";    uptime 2>/dev/null
    echo "-- cpus --";    nproc 2>/dev/null
    echo "-- nextflow/java env --"; env | grep -E "^(NXF_|JAVA_|_JAVA|TMPDIR|CONDA_)" | sort
    echo "-- tty --";     tty 2>/dev/null || echo "not a tty"
} > "$LOGDIR/system-before.txt" 2>&1

# --keep so a failure leaves its sandboxes behind. run_tests.sh removes TEST_TMPDIR on exit
# otherwise, which throws away every run.out and .nextflow.log - the only record of what
# Nextflow actually did. Harvested below on failure and deleted on success.
#
# Both environments named explicitly. The suite finds an analysis environment by globbing
# PoolSeqFlow-*-analysis and taking the first that has an Rscript, which is whichever name
# sorts first rather than the one being prepared.
# Streamed rather than captured: the suite is the long step and watching it is how you notice
# a case hanging, or a wave of skips, while there is still time to stop. tee keeps the full log
# for the harvest below, and PIPESTATUS[0] reads the suite's own exit rather than tee's.
set +e
TEST_CONDA_ENV="$ENV_PREFIX" TEST_ANALYSIS_ENV="$ANALYSIS_PREFIX" \
    ./test/run_tests.sh --keep 2>&1 | tee "$LOGDIR/tests.log"
TEST_STATUS=${PIPESTATUS[0]}
set -e

{
    echo "== after the suite =="
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    echo "-- memory --"; free -h 2>/dev/null
    echo "-- disk --";   df -h /tmp /dev/shm "${TMPDIR:-/tmp}" 2>/dev/null | sort -u
    echo "-- load --";   uptime 2>/dev/null
} > "$LOGDIR/system-after.txt" 2>&1

# The paths --keep printed, so the artifacts can be collected and then removed.
KEPT_TMP=$(sed -n 's/^working directory kept at //p'  "$LOGDIR/tests.log" | tail -1)
KEPT_XDEV=$(sed -n 's/^second filesystem kept at //p' "$LOGDIR/tests.log" | tail -1)

harvest_artifacts() {
    # ABSOLUTE. $LOGDIR is relative to the repository root, and the copy loop below runs after a
    # cd into the sandbox - so a relative destination resolves under /tmp and the harvest writes
    # its entire output inside the very directory it is reading from. That is what happened on
    # the 3.1.2 attempt of 2026-09-22: 80 run.out files existed, 0 were collected, and the
    # summary reported "artifacts: 4.0K" because the empty directory had been created here.
    local dest="$ROOT/$LOGDIR/artifacts"
    [ -n "$KEPT_TMP" ] && [ -d "$KEPT_TMP" ] || return 0
    mkdir -p "$dest"
    # Every Nextflow run's captured output and its own log, under the sandbox it came from -
    # plus the per-task logs and report_knit.log, which is where the frame writes the reason a
    # PDF report could not be built. Reading run.out alone missed that on 2026-09-22.
    ( cd "$KEPT_TMP" && find . \( -name 'run*.out' -o -name '.nextflow.log*' \
                                  -o -name '.command.log' -o -name '.exitcode' \
                                  -o -name 'report_knit.log' \) -print0 \
        | while IFS= read -r -d '' f; do
              mkdir -p "$dest/$(dirname "$f")"
              cp "$f" "$dest/$f" 2>/dev/null
          done )
    du -sh "$dest" 2>/dev/null | awk '{print "      artifacts: " $1 " in '"${dest#"$ROOT"/}"'"}'
}

# Into the summary only. The suite has just printed itself in full, so repeating its tail here
# would say the same thing twice on the terminal.
tail -n 20 "$LOGDIR/tests.log" | sed 's/^/      /' >> "$LOGDIR/summary.txt"
say ""

if [ "$TEST_STATUS" -ne 0 ]; then
    say "STOPPED: the test suite failed (status $TEST_STATUS). Nothing was exported."
    say ""
    say "      Both install/environment.yml and install/environment-analysis.yml are"
    say "      unchanged, so the current release still describes a tool set that works."
    say ""
    say "      Collecting what the failing runs left behind..."
    harvest_artifacts | tee -a "$LOGDIR/summary.txt"
    say "      Each failing case's run.out is there, with the .nextflow.log beside it."
    say "      Read run.out first: it is what the case itself saw."
    say ""
    say "      Machine state either side of the run:"
    say "          $LOGDIR/system-before.txt"
    say "          $LOGDIR/system-after.txt"
    say ""
    say "      The sandboxes themselves are still at:"
    say "          $KEPT_TMP"
    [ -n "$KEPT_XDEV" ] && say "          $KEPT_XDEV"
    say "      Delete them when you are done - they are not small."
    say ""
    say "      $LOGDIR/tests.log is the run, and"
    say "      $LOGDIR/packages-changed.tsv and"
    say "      $LOGDIR/packages-changed-analysis.tsv say what moved, compared on"
    say "      version AND build."
    say ""
    say "      To reproduce against the environments themselves, run this again with"
    say "      --no-cleanup and use the TEST_CONDA_ENV / TEST_ANALYSIS_ENV it prints."
    exit 1
fi

# Nothing to diagnose, so nothing to keep. --keep left these behind unconditionally.
if [ -n "$KEPT_TMP" ] && [ -d "$KEPT_TMP" ]; then
    rm -rf "$KEPT_TMP"
fi
if [ -n "$KEPT_XDEV" ] && [ -d "$KEPT_XDEV" ]; then
    rm -rf "$KEPT_XDEV"
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
say "[4/6] Tests passed. Checking what each environment requires of its host..."
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

# -------------------------------------------------------- prove what was written --------
#
# EVERYTHING ABOVE THIS LINE REASONED ABOUT THE SCRATCH ENVIRONMENTS. These two read the FILES,
# which is a different question: an environment holds whatever solved into it once, while a file
# names constraints and lets the solver choose again, on a machine that is not this one.
#
# Both build environments of their own and remove them. Both are re-runnable on their own, which
# is what the failure messages below point at: the files are already written by this point, so a
# failure here does not cost the hour again.
say "[5/6] Proving the two files that were just written..."
say "      Solving each from nothing and reading its floor (minutes)..."
if ! bash dev/scripts/check-exported-floor.sh > "$LOGDIR/exported-floor.log" 2>&1; then
    tail -n 30 "$LOGDIR/exported-floor.log" | sed 's/^/      /' | tee -a "$LOGDIR/summary.txt"
    say ""
    say "      A file that does not solve from nothing, or whose floor is above what the"
    say "      release promises, is not shippable. Both files are written, so this is"
    say "      re-runnable on its own once the cause is fixed:"
    say "          dev/scripts/check-exported-floor.sh"
    exit 1
fi
tail -n 4 "$LOGDIR/exported-floor.log" | sed 's/^/      /' | tee -a "$LOGDIR/summary.txt"

say "      Putting the modules' pins through a baseline built from the new file (minutes)..."
if ! bash dev/scripts/check-module-packages.sh > "$LOGDIR/module-packages.log" 2>&1; then
    grep -E '^   (FAIL|ok)' "$LOGDIR/module-packages.log" | sed 's/^/   /' \
        | tee -a "$LOGDIR/summary.txt"
    say ""
    say "      Every check in it must say ok. The full run is in"
    say "          $LOGDIR/module-packages.log"
    say "      and it is re-runnable on its own:"
    say "          dev/scripts/check-module-packages.sh"
    exit 1
fi
say "      every check passed."

# The removal itself is the exit trap's, which runs on every path out of here.
say "[6/6] Removing the scratch environments..."

say ""
say "Done. Read $LOGDIR/summary.txt, then the environment diffs:"
say "    git diff install/environment.yml install/environment-analysis.yml"
say "The release steps are in dev/RELEASING.md."
