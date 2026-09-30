#!/bin/bash
#
# Judge a resolved parameter set, one finding per line.
#
#   nextflow config -flat <install> | check_parameters.sh
#
# Reads flattened parameter assignments on stdin, in either of the two forms its callers hold
# them in, and writes one tab-separated finding per rule that has something to say:
#
#   LEVEL <TAB> label <TAB> verdict <TAB> detail <TAB> explanation
#
# LEVEL is FAIL, WARN or NOTE. Every caller formats those itself; nothing here prints color or
# indentation. Exit status is 1 when any finding is a FAIL, 0 otherwise, so a caller may use the
# status alone and read nothing.
#
# Silence is the answer for a parameter set with nothing wrong with it.
#
# WHAT BELONGS HERE: a setting that makes the run produce NOTHING, or that silently changes what
# a published number means. What does not: a setting that merely produces fewer sites. minDP 20
# against minDP 5 is a scientific choice and this has no opinion on it.
#
# VALUES ARE READ FROM THE COMPOSED OPTION STRINGS WHERE THERE IS ONE. A project may pin
# variantCall.mpileupOptions by hand, which makes scaleMapQ and varQualMin inert, so judging the
# settings it was not built from would report a problem that does not exist. An option string
# carrying neither flag is reported as unjudged rather than guessed at.

set -uo pipefail

FAILED=0

# One finding. Tabs are the separator, so no field may contain one.
say() {   # level label verdict detail explanation
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}"
    [ "$1" = "FAIL" ] && FAILED=1
    return 0
}

# Every assignment, flattened, with surrounding quotes removed. TWO FORMS ARE READ, because the
# two callers have the values in different shapes and neither should have to reformat: `nextflow
# config -flat` writes `params.<key> = <value>`, and step 0 already holds the same set as
# `<key>=<value>` from analysisParams().
declare -A P=()
while IFS= read -r line; do
    case $line in
        params.*' = '*) key=${line%% = *}; key=${key#params.}; value=${line#* = } ;;
        *=*)            key=${line%%=*};   value=${line#*=} ;;
        *) continue ;;
    esac
    value=${value#\'}; value=${value%\'}
    value=${value#\"}; value=${value%\"}
    P["$key"]=$value
done

get() { printf '%s' "${P[$1]:-}"; }

# True when the value is a whole number, so a rule can decline to judge a blank or an expression
# it cannot evaluate rather than comparing a string to a number.
is_int() { case ${1:-} in ''|*[!0-9-]*) return 1 ;; *) return 0 ;; esac; }
# True for a decimal, which sampleThreshold is. Deliberately plain: it rejects an empty value and
# anything carrying a character that is not a digit, a dot or a minus, and leaves the arithmetic to
# awk. An earlier version tried to reject a lone "." as well and was too clever to read.
is_num() { case ${1:-} in ''|*[!0-9.-]*) return 1 ;; *) return 0 ;; esac; }

# ------------------------------------------------------------- the pileup pair --
#
# -C caps every read's adjusted mapping quality near its own value and -q then rejects anything
# below the minimum, so a -C under -q leaves bcftools call nothing and it writes a header with no
# records. Measured on real pools at six values of -q (12, 15, 20, 30, 40, 50): -C one below -q
# returned zero sites every time, -C equal to it returned sites every time.
mpileup=$(get variantCall.mpileupOptions)
scale=$(printf '%s\n' "$mpileup" | grep -o -- '-C [0-9][0-9]*' | head -1 | awk '{print $2}')
minq=$(printf '%s\n' "$mpileup" | grep -o -- '-q [0-9][0-9]*' | head -1 | awk '{print $2}')

if ! is_int "$scale" || ! is_int "$minq"; then
    say NOTE "variantCall.scaleMapQ" "NOT CHECKED" "no -C or -q in mpileupOptions" \
        "The option string was pinned by hand and carries no mapping-quality pair to judge."
elif [ "$scale" -eq 0 ]; then
    say NOTE "variantCall.scaleMapQ" "OFF" "no mapping-quality adjustment" ""
elif [ "$scale" -le 10 ]; then
    say WARN "variantCall.scaleMapQ" "INERT AT $scale" "10 and below changes nothing" \
        "bcftools applies no adjustment at all below 11, so this run is the same as scaleMapQ 0. Write 0 if that is what you meant."
elif [ "$scale" -lt "$minq" ]; then
    say FAIL "variantCall.scaleMapQ" "DISCARDS EVERY READ" "$scale is below varQualMin $minq" \
        "-C caps every read's mapping quality near $scale and -q then rejects anything under $minq, so the pileup reaches bcftools call empty and the run produces no variants at all. Raise scaleMapQ above varQualMin, or lower varQualMin below scaleMapQ."
elif [ "$scale" -lt $(( minq * 2 )) ]; then
    say WARN "variantCall.scaleMapQ" "SEVERE AT $scale" "close to varQualMin $minq" \
        "It emits records, but only the best-placed reads clear -q. Measured on real pools: scaleMapQ equal to varQualMin kept 6% of the sites an unadjusted run called. Recovery is gradual and the manual has the curve."
fi

# ------------------------------------------------------- the cross-sample filter --
#
# sampleThreshold is the fraction of samples an allele must appear in. Above 1 that is more
# samples than exist, so every site goes: measured at 1.5 against the fixture VCF, 0 of 135
# survived.
threshold=$(get filterFalsePositives.sampleThreshold)
if is_num "$threshold"; then
    if awk -v t="$threshold" 'BEGIN { exit !(t > 1) }'; then
        say FAIL "filterFalsePositives.sampleThreshold" "REMOVES EVERY SITE" "$threshold is above 1" \
            "It is a fraction of your samples, so above 1 it asks for more samples than the run has and no site can satisfy it. Measured: 1.5 left 0 of 135 sites."
    elif awk -v t="$threshold" 'BEGIN { exit !(t <= 0) }'; then
        say WARN "filterFalsePositives.sampleThreshold" "INERT AT $threshold" "nothing is required" \
            "At or below 0 the cross-sample requirement asks for nothing, so the filter removes no allele on that clause."
    fi
fi

# ------------------------------------------------------------------- the pool --
#
# n_chrom is ploidy * poolSize and is what every effective size is computed from. Below 1 the
# detection limit is infinite or negative, which is broken. At exactly 1 the pipeline still runs
# and only diversity degrades, so that case is a warning and not a refusal.
ploidy=$(get ploidy)
poolsize=$(get poolSize)
if is_int "$ploidy" && [ "$ploidy" -lt 1 ]; then
    say FAIL "ploidy" "NOT A PLOIDY" "$ploidy" \
        "Every detection limit and every effective size is computed from ploidy times poolSize, so below 1 they are meaningless rather than merely small."
fi
if is_int "$poolsize" && [ "$poolsize" -lt 1 ]; then
    say FAIL "poolSize" "NOT A POOL" "$poolsize" \
        "Every detection limit and every effective size is computed from ploidy times poolSize, so below 1 they are meaningless rather than merely small."
fi
if is_int "$ploidy" && is_int "$poolsize" && [ "$ploidy" -ge 1 ] && [ "$poolsize" -ge 1 ] \
   && [ $(( ploidy * poolsize )) -lt 2 ]; then
    say WARN "poolSize" "ONE CHROMOSOME" "ploidy $ploidy times poolSize $poolsize" \
        "The pipeline runs and publishes frequencies, but every effective sample size is 1, so the unbiased diversity correction n_eff/(n_eff - 1) is infinite and any diversity an analysis computes over this pool is meaningless. A warning rather than a refusal because the pipeline itself is unaffected."
fi

# ---------------------------------------------------------- the two ceilings --
#
# capBAM.maxDepth -1 asks step 5 to measure a ceiling per sample from its own histogram. A
# positive variantCall.maxDepth then applies one flat number to every sample at pileup time, on
# top of that, so the smaller of the two wins and the measured ceilings stop deciding anything.
capmax=$(get capBAM.maxDepth)
vcmax=$(get variantCall.maxDepth)
if is_int "$capmax" && is_int "$vcmax" && [ "$capmax" -eq -1 ] && [ "$vcmax" -gt 0 ]; then
    say NOTE "variantCall.maxDepth" "OVERRIDES THE MEASURED CEILINGS" "$vcmax, with capBAM.maxDepth -1" \
        "Step 5 measures a ceiling for each sample and mpileup then caps every sample at $vcmax as well, so whichever is smaller decides. Set it to 0 to let the per-sample ceilings stand."
fi

# --------------------------------------------------------------- plain numbers --
#
# FastQC takes megabytes as a bare integer and rejects a size with a unit on it, which the
# template says and is easy to undo.
fqmem=$(get fastqc.memory)
if [ -n "$fqmem" ] && ! is_int "$fqmem"; then
    say FAIL "fastqc.memory" "NOT A PLAIN NUMBER" "$fqmem" \
        "FastQC takes megabytes as a bare integer and refuses a value carrying a unit, so write 2048 rather than 2G."
fi

exit "$FAILED"
