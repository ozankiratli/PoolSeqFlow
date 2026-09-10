#!/usr/bin/env bash
#
# Machinery shared by the PoolSeqFlow wrapper and the installation checks.
#
# SOURCED, never run. The wrapper reads it once INSTALL is resolved, which nf_config_value
# needs.
#
# Reads five things from the environment: INSTALL, POOLSEQFLOW_INSTALLED_HOME and
# POOLSEQFLOW_PREFIX from the caller, ENV_FILE for analysis_r_packages, and
# POOLSEQFLOW_MODULE_INDEX where the user overrides the catalogue location.

# Where installations live: POOLSEQFLOW_PREFIX, else an installed wrapper's own location,
# else ~/.local.
install_prefix() {
    if [ -n "${POOLSEQFLOW_PREFIX:-}" ]; then
        printf '%s' "$POOLSEQFLOW_PREFIX"
    elif [ -n "$POOLSEQFLOW_INSTALLED_HOME" ]; then
        printf '%s' "$(dirname "$(dirname "$POOLSEQFLOW_INSTALLED_HOME")")"
    else
        printf '%s' "$HOME/.local"
    fi
}

# Every version installed under a prefix, sorted by version, oldest first.
installed_payload_versions() {
    local prefix="$1" d
    for d in "$prefix"/opt/PoolSeqFlow-*; do
        [ -d "$d" ] || continue
        printf '%s\n' "${d##*/PoolSeqFlow-}"
    done | sort -V
}

newest_installed_version() {
    installed_payload_versions "$1" | tail -1
}

# Whether an environment of this exact name exists. `conda env list` prints the path too,
# so only the name column is compared, whole and literally.
env_exists() {
    conda env list | awk '{print $1}' | grep -qxF "$1"
}

# Every PoolSeqFlow environment on this machine, versioned or legacy. `|| true` because
# grep exits 1 on no match and this runs under `set -e`.
poolseqflow_envs() {
    conda env list | awk '{print $1}' | grep -E '^PoolSeqFlow(-.+)?$' | sort || true
}

# Resolves one setting through Nextflow, which interpolates it. Needs the environment active,
# and the installation named, because nextflow.config lives there.
nf_config_value() {
    nextflow config -flat "$INSTALL" 2>/dev/null | sed -n "s|^$1 = ||p" | head -1 | tr -d "'\""
}

# Zenodo all-versions DOI. A release's own DOI is reached through it. Also recorded in
# citations/citations.json, which the per-run CITATIONS.md is built from.
CONCEPT_DOI="10.5281/zenodo.19245611"

# The catalogue of modules that can be installed. It is export-ignored, so a release carries no
# copy and this URL is the only source.
#
# THE SITE AND NOT THE REPOSITORY, so that the catalogue and the tarballs it points at are
# published in one deploy: a row can never advertise a download that is not there yet. Every
# release compiles this address in and asks for it for as long as it is installed, so moving it
# means serving both forever.
MODULE_INDEX_URL="https://ozankiratli.github.io/PoolSeqFlow/modules-repo/index.tsv"

# The catalogue column layout this release can read. Columns are matched by NAME, so this is
# not bumped for a new one - only for a change no older release could read at all.
MODULE_INDEX_FORMAT="1"

# Where to read the index from. POOLSEQFLOW_MODULE_INDEX overrides it with a URL or a local
# path.
module_index_source() {
    printf '%s' "${POOLSEQFLOW_MODULE_INDEX:-$MODULE_INDEX_URL}"
}

# One `#!key: value` header out of a catalogue, or nothing. They are comments, so the row
# reader already skips them.
module_index_header() {
    sed -n "s|^#![[:space:]]*$2:[[:space:]]*\(.*\)$|\1|p" "$1" 2>/dev/null | head -1 | tr -d ' '
}

# Copies a URL or a path to a local file. Returns non-zero and says nothing on failure; the
# caller has the context to explain it.
fetch_url() {
    local src="$1" dest="$2"
    case $src in
        file://*) src="${src#file://}" ;;
    esac
    case $src in
        /*|./*|../*)
            [ -f "$src" ] || return 1
            cp "$src" "$dest"
            return 0
            ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 "$src" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$src"
    else
        return 127
    fi
}

# The published-table contract this release speaks, read out of the analysis layer, which is
# where the value lives. A module declaring a different one reads the tables differently.
module_contract() {
    sed -n "/^def contractVersion()/,/^}/s/.*return '\(.*\)'.*/\1/p" \
        "$INSTALL/analysis/lib/nf/modules.nf" 2>/dev/null | head -1
}

# The order this release reads a catalogue row in, whatever order the file writes them in.
MODULE_INDEX_COLUMNS="name kind version contract frame environment url sha256 summary"

# What separates the fields of a normalized row, and it is NOT the tab the file uses.
#
# A tab is IFS whitespace, so `IFS=$'\t' read` collapses a run of them into one delimiter and
# an empty field simply disappears - every later field then lands in the wrong variable. A row
# leaving `frame` and `environment` empty would have had its url read as its frame and its
# checksum as its environment, and the install would have fetched a checksum. A unit separator
# is not whitespace, so each one delimits and empty fields survive.
MODULE_INDEX_SEP=$'\037'

# The analysis frame version this installation carries, from the file that is its only home.
# A module's row says the oldest frame it runs on, and this is what that is compared against.
installed_frame_version() {
    grep -vE '^[[:space:]]*(#|$)' "$INSTALL/analysis/frame.version" 2>/dev/null \
        | head -1 | tr -d ' '
}

# The index's data rows, each with its fields put in MODULE_INDEX_COLUMNS order.
#
# THE COLUMNS ARE MATCHED BY NAME, from the header row - the first line that is neither a
# comment nor blank. A catalogue carrying a column this release has never heard of is read
# correctly and the extra dropped; one missing a column this release knows yields an empty
# field for it. That is what lets a later release add a column without stranding every release
# published before it, and it is why the layout number is reserved for a change that is
# genuinely incompatible - a required column renamed, or one whose meaning changed.
module_index_rows() {
    awk -F'\t' -v want="$MODULE_INDEX_COLUMNS" -v sep="$MODULE_INDEX_SEP" '
        /^[[:space:]]*(#|$)/ { next }
        !header { header = 1; for (i = 1; i <= NF; i++) at[$i] = i; next }
        {
            n = split(want, col, " ")
            line = ""
            for (c = 1; c <= n; c++) {
                i = at[col[c]]
                line = line (c > 1 ? sep : "") (i ? $i : "")
            }
            print line
        }' "$1" 2>/dev/null || true
}

# Whether the first dotted numeric version is no newer than the second. Both `YYYYMMDD.NNN`
# frames and `X.Y.Z` releases are compared the same way, componentwise, with a missing
# component counting as zero. An empty first argument is "no requirement" and passes.
version_at_most() {
    [ -n "${1:-}" ] || return 0
    [ -n "${2:-}" ] || return 1
    awk -v a="$1" -v b="$2" '
        BEGIN {
            n = split(a, x, "."); m = split(b, y, ".")
            for (i = 1; i <= (n > m ? n : m); i++) {
                p = (i <= n ? x[i] + 0 : 0); q = (i <= m ? y[i] + 0 : 0)
                if (p < q) exit 0
                if (p > q) exit 1
            }
            exit 0
        }'
}

# The checksum of a file, or nothing when no tool on this machine can produce one.
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# How to cite this release. Takes the version to name. Both `cite` arms print it; the analysis
# one follows it with R and the packages a module ran on.
poolseqflow_citation() {
    local version="$1"
    cat <<EOF
PoolSeqFlow v$version
Ozan L. Z. Kiratli

Cite the version you actually ran, not the newest one.
--------------------------------------------------------------------
Zenodo mints a separate DOI for every release, and results depend on
which release produced them - filters, defaults and parameter names
have all changed between versions. A paper that cites the current
release for numbers produced by an older one is describing a method
it did not use.

This copy is v$version. To get its DOI, open the all-versions record
below and pick v$version from the "Versions" list:

    https://doi.org/$CONCEPT_DOI

Then replace the DOI in the entries below with that one.

Reference
--------------------------------------------------------------------
Kiratli, O. L. Z. (2026). PoolSeqFlow: A Nextflow pipeline for allele
frequency analysis from pooled Illumina sequencing data (Version
v$version) [Computer software]. https://doi.org/$CONCEPT_DOI

BibTeX
--------------------------------------------------------------------
@software{kiratli_poolseqflow,
  author  = {Kiratli, Ozan L. Z.},
  title   = {PoolSeqFlow: A Nextflow pipeline for allele frequency
             analysis from pooled Illumina sequencing data},
  version = {v$version},
  year    = {2026},
  doi     = {$CONCEPT_DOI},
  url     = {https://github.com/ozankiratli/PoolSeqFlow}
}

$CONCEPT_DOI is the all-versions DOI: it always resolves to the
newest release. Use it when referring to the software in general, and
a version DOI when reporting results.
EOF
}

# The R packages this release pins, one per line, as conda spells them minus the r- prefix.
# Read out of the environment file, which is the only list of them. R's own name for a package
# differs in case for some - r-matrix is Matrix - so a caller matching it against what is
# installed must do so case-insensitively. Reads ENV_FILE, set by the caller.
analysis_r_packages() {
    sed -n 's/^ *- *r-\([^=]*\).*$/\1/p' "$ENV_FILE" | grep -vx base
}

# Every package the release's own analysis environment is built from, one name per line, with no
# version. This is the baseline: what `analysis install` creates before any module is installed.
#
# NOTHING HERE MAY BE REMOVED BY A MODULE UNINSTALL. A module declares what it needs whether or
# not the baseline already has it - that is what makes its manifest a true statement of its
# dependencies rather than a statement about one release's environment - so the set a module
# declares and the baseline overlap by design, and the overlap belongs to the release.
#
# Reads the shipped file rather than the live environment: the live one has whatever modules
# added merged into it and cannot say which packages are the release's own.
#
# Defined here and not only in the wrapper, because baseline_packages() reads it and every
# dev/ script that sources this file needs the same answer. An unset path makes the sed below
# silently produce nothing, which reads as "the baseline is empty" and subtracts nothing.
ANALYSIS_ENV_FILE="${ANALYSIS_ENV_FILE:-${INSTALL:-}/install/environment-analysis.yml}"

baseline_packages() {
    sed -n 's/^ *- *\([A-Za-z0-9][A-Za-z0-9._-]*\).*$/\1/p' "$ANALYSIS_ENV_FILE" 2>/dev/null \
        | grep -vx 'pip' | sort -u
}

# The shape a module's `packages` entry must have: a name, one `=`, an exact version. No build
# string, no range, no channel prefix. The analysis frame applies the same rule when a module
# runs; this is what refuses one before it is installed.
MODULE_SPEC_RE='^[a-z0-9][a-z0-9._-]*=[A-Za-z0-9][A-Za-z0-9._+]*$'

# The conda specs one module declares, one per line, read out of its manifest. `packages` is a
# flat array of quoted strings and the wrapper has no JSON parser, so it is read with sed; a
# manifest without the field yields nothing.
module_packages() {
    local manifest="$1"
    [ -f "$manifest" ] || return 0
    # awk for the last step and not sed: it terminates its final record. store_packages runs
    # this once per module and concatenates the results, so an unterminated last line arrives
    # joined to the next module's first one as a single token.
    tr '\n' ' ' < "$manifest" \
        | sed -n 's/.*"packages"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | tr ',' '\n' \
        | awk -F'"' 'NF > 1 { print $2 }'
}

# The libraries one module declares, one per line, read out of its manifest the same way as its
# packages. A module with no `libraries` field yields nothing.
module_libraries() {
    local manifest="$1"
    [ -f "$manifest" ] || return 0
    # awk for the last step and not sed, for the reason module_packages gives: store_libraries
    # concatenates one of these per module and an unterminated last line glues two names.
    tr '\n' ' ' < "$manifest" \
        | sed -n 's/.*"libraries"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | tr ',' '\n' \
        | awk -F'"' 'NF > 1 { print $2 }'
}

# Where installed libraries live: inside the module store, under a name no module may take.
# analysis/lib/nf/modules.nf resolves the same path when a module runs.
LIBRARY_DIR_NAME="lib"

library_store() {
    printf '%s' "$MODULE_STORE/$LIBRARY_DIR_NAME"
}

# Every library the modules in a store declare, sorted and deduplicated, optionally skipping one
# module by name. This is what says whether a library is still wanted after a module leaves.
store_libraries() {
    local store="$1" skip="${2:-}" dir name
    [ -d "$store" ] || return 0
    for dir in "$store"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        if [ "$name" = "$LIBRARY_DIR_NAME" ]; then continue; fi
        if [ -n "$skip" ] && [ "$name" = "$skip" ]; then continue; fi
        module_libraries "$dir/manifest.json"
    done | sort -u
}

# Every spec the modules in a store declare, sorted and deduplicated, optionally skipping one
# module by name. Two modules may pin the same package, and the same spec is one entry.
store_packages() {
    local store="$1" skip="${2:-}" dir name
    [ -d "$store" ] || return 0
    for dir in "$store"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        if [ "$name" = "$LIBRARY_DIR_NAME" ]; then continue; fi
        if [ -n "$skip" ] && [ "$name" = "$skip" ]; then continue; fi
        module_packages "$dir/manifest.json"
    done | sort -u
}

# The package names an environment holds, one per line.
conda_installed_packages() {
    conda list -n "$1" --export 2>/dev/null | sed -n 's/^\([^#=][^=]*\)=.*/\1/p'
}

# The specs an environment cannot take without moving a version it already holds, one line each
# as `<spec> (installed <version>)`. `--freeze-installed` covers what the solve reaches on its
# own and NOT what the command line names: conda installs a named pin at the version asked for,
# downgrading what is there. So a disagreement is caught here, before conda is asked.
conda_conflicting_packages() {
    local env="$1"; shift
    local held spec name want have
    held=$(conda list -n "$env" --export 2>/dev/null | grep -v '^#' || true)
    for spec in "$@"; do
        name="${spec%%=*}"
        want="${spec#*=}"
        have=$(printf '%s\n' "$held" \
               | sed -n "s/^$(printf '%s' "$name" | sed 's/[.]/\\./g')=\([^=]*\).*/\1/p" | head -1)
        [ -n "$have" ] || continue
        [ "$have" = "$want" ] && continue
        printf '%s (installed %s)\n' "$spec" "$have"
    done
}

# Installs the named specs into an environment, or fails having installed none of them.
# `--freeze-installed` lets the solver add these and whatever they need while refusing to change
# anything else that is already there.
conda_install_packages() {
    local env="$1"; shift
    [ "$#" -gt 0 ] || return 0
    local clash
    clash=$(conda_conflicting_packages "$env" "$@")
    if [ -n "$clash" ]; then
        echo "ERROR: these pins disagree with what '$env' already holds:" >&2
        printf '%s\n' "$clash" | sed 's/^/    /' >&2
        echo "" >&2
        echo "  One environment is shared by every module installed here. Installing a pin over" >&2
        echo "  a different version would change what the release itself, and every other module" >&2
        echo "  in it, computes. Nothing was installed." >&2
        return 1
    fi
    conda install -n "$env" --freeze-installed -y "$@"
}

# What removing the named packages would take out of an environment, one name per line.
# `conda remove` takes everything that depends on what it is given, so the plan is read first.
conda_removal_plan() {
    local env="$1"; shift
    conda remove -n "$env" --dry-run --json "$@" 2>/dev/null \
        | sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p' | sort -u
}

# Removes the named packages and nothing else. A name the plan adds beyond them depends on one
# of them, so it belongs to something still installed and the removal stops instead. An empty
# plan means none of them is there, which is not an error.
conda_remove_packages() {
    local env="$1"; shift
    [ "$#" -gt 0 ] || return 0
    local wanted plan extra
    wanted=$(printf '%s\n' "$@" | sort -u)
    plan=$(conda_removal_plan "$env" "$@")
    [ -n "$plan" ] || return 0
    extra=$(printf '%s\n' "$plan" | grep -vxF "$wanted" || true)
    if [ -n "$extra" ]; then
        echo "ERROR: removing those packages would take others with them:" >&2
        printf '%s\n' "$extra" | sed 's/^/    /' >&2
        echo "" >&2
        echo "  Each of those depends on one being removed and belongs to something still" >&2
        echo "  installed. Nothing was removed. Remove that first, or leave these in place." >&2
        return 1
    fi
    conda remove -n "$env" -y "$@"
}

# Is $1 a parameters.config written for THIS release? Every config for this release sets
# storageDir and no earlier one did, so that single key answers it.
#
# Shared because two callers ask the same question and must not drift: the wrapper refuses a
# stale config before any command that reads one, and `check project` reports it as a line.
config_is_current() {
    grep -qE '^[[:space:]]*storageDir[[:space:]]*=' "$1" 2>/dev/null
}

# The parameters this release renamed or removed that $1 still sets, space-separated. Advisory:
# it names an old file as recognized rather than damaged, and migrate_config reports the full set.
config_stale_parameters() {
    local old found=""
    for old in projectDir diploidy rgTagsFile rgTagsPath; do
        grep -qE "^[[:space:]]*${old}[[:space:]]*=" "$1" 2>/dev/null && found="$found $old"
    done
    printf '%s' "$found"
}
