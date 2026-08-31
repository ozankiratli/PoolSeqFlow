#!/usr/bin/env bash
#
# Machinery shared by the PoolSeqFlow wrappers and the installation checks.
#
# SOURCED, never run. Both wrappers read it once INSTALL is resolved, which nf_config_value
# needs.
#
# Reads four things the caller sets: INSTALL, POOLSEQFLOW_INSTALLED_HOME and POOLSEQFLOW_PREFIX
# from the environment, and ENV_FILE for analysis_r_packages.

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
# install/citations.json, which the per-run CITATIONS.md is built from.
CONCEPT_DOI="10.5281/zenodo.19245611"

# How to cite this release. Takes the version to name. Both wrappers print it; the analysis
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
