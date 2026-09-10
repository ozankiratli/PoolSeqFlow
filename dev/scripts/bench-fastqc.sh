#!/usr/bin/env bash
#
# What does FastQC's -t actually buy, at the file counts this pipeline gives it?
#
# Usage:  dev/scripts/bench-fastqc.sh [reads-per-file] [outdir]
#         dev/scripts/bench-fastqc.sh 1000000
#
# RUN BY HAND. It generates data, runs FastQC ten times and takes minutes. Nothing in the test
# suite depends on it.
#
# THE QUESTION IT ANSWERS
# -----------------------
# `cores.fastqc` is computed in scripts/resolve_parameters.nf as `threads >= 2 ? 2 : 1` and read
# by nothing: FastQC is invoked inside TrimReads and ClipReads, and takes `-t ${task.cpus}` from
# whichever of those it is running in - so at threads = 8 it gets 8, not 2. Before deciding
# whether to wire the parameter up or delete it, measure whether 8 is worth anything over 2.
#
# FastQC's own help is the reason to doubt it:
#
#     -t --threads  Specifies the number of files which can be processed simultaneously.
#                   Each thread will be allocated 250MB of memory
#
# So -t is FILE parallelism, not per-file parallelism. Two files cannot use eight threads, and
# the pipeline hands it two: a trimmed pair in TrimReads, a clipped pair in ClipReads.
#
# WHAT IT MEASURES
# ----------------
# Wall time and peak resident memory at -t 1 2 4 6 8, over two file counts:
#
#   2 files   what the pipeline actually does
#   8 files   enough work for eight threads, to show the scaling shape and prove the -t
#             semantics rather than assuming them
#
# `--memory 2048` is passed throughout, because that is what the pipeline passes
# (params.fastqc.memory). It sets the JVM heap as a whole, so it may well flatten the per-thread
# allocation the help describes - which is exactly the kind of thing to measure rather than
# reason about.

set -euo pipefail

READS="${1:-500000}"
OUT="${2:-${TMPDIR:-/tmp}/fastqc-bench-$$}"
MEMORY=2048

command -v fastqc >/dev/null 2>&1 || {
    echo "fastqc not on PATH. Activate the pipeline environment first." >&2
    exit 1
}

mkdir -p "$OUT/data" "$OUT/reports"
trap 'rm -rf "$OUT/reports"' EXIT

echo "FastQC:  $(fastqc --version)"
echo "reads:   $READS per file, 150 bp"
echo "memory:  --memory $MEMORY (what the pipeline passes)"
echo "workdir: $OUT"
echo ""

# ---------------------------------------------------------------------------------------
# Data. One real pair, then hardlinks to make eight names: FastQC processes each file
# independently, so identical content measures throughput exactly as distinct content would and
# costs one generation instead of four.
if [ ! -f "$OUT/data/bench_R1.fq.gz" ]; then
    echo "Generating $READS reads per file..."
    python3 - "$READS" "$OUT/data" <<'PY'
import gzip, random, sys
n, out = int(sys.argv[1]), sys.argv[2]
random.seed(1)
bases = "ACGT"
# One pool of sequences reused with per-read quality jitter: generating 150 random bases a
# million times is the slow part, and the compressor sees realistic entropy either way.
pool = ["".join(random.choice(bases) for _ in range(150)) for _ in range(2000)]
for mate in (1, 2):
    with gzip.open(f"{out}/bench_R{mate}.fq.gz", "wt", compresslevel=1) as fh:
        for i in range(n):
            seq = pool[i % len(pool)]
            q = "".join(chr(33 + random.randint(20, 40)) for _ in range(10)) + "I" * 140
            fh.write(f"@read{i}/{mate}\n{seq}\n+\n{q}\n")
PY
fi
for i in 2 3 4; do
    for mate in 1 2; do
        [ -e "$OUT/data/copy${i}_R${mate}.fq.gz" ] || \
            ln "$OUT/data/bench_R${mate}.fq.gz" "$OUT/data/copy${i}_R${mate}.fq.gz"
    done
done
echo "  $(du -sh "$OUT/data" | cut -f1) of input"
echo ""

PAIR=("$OUT/data/bench_R1.fq.gz" "$OUT/data/bench_R2.fq.gz")
EIGHT=("$OUT/data"/*.fq.gz)

# Wall seconds and peak RSS in MB for one FastQC run. No GNU time here, so the peak is polled
# out of /proc; VmHWM is the kernel's own high-water mark, so the poll only has to catch the
# process alive at least once.
run_once() {
    local threads="$1"; shift
    local start end peak=0 hwm pid
    rm -rf "$OUT/reports"; mkdir -p "$OUT/reports"
    start=$(date +%s.%N)
    # FastQC writes the detected mime type of every input to stdout even under --quiet, and this
    # function's output is captured - left alone, those lines become the measurement.
    fastqc --quiet --threads "$threads" --memory "$MEMORY" \
           --outdir "$OUT/reports" "$@" > "$OUT/fastqc.log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        hwm=$(awk '/VmHWM/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
        [ -n "${hwm:-}" ] && [ "$hwm" -gt "$peak" ] 2>/dev/null && peak=$hwm
        sleep 0.1
    done
    wait "$pid"
    end=$(date +%s.%N)
    awk -v s="$start" -v e="$end" -v p="$peak" \
        'BEGIN { printf "%.1f\t%.0f", e - s, p / 1024 }'
}

bench() {
    local label="$1" count="$2"; shift 2
    echo "== $label ($count files)"
    printf '   %-4s %10s %10s %10s\n' "-t" "seconds" "peak MB" "vs -t 1"
    local base=""
    for t in 1 2 4 6 8; do
        local result secs mb
        result=$(run_once "$t" "$@")
        secs=${result%%$'\t'*}; mb=${result##*$'\t'}
        [ -n "$base" ] || base="$secs"
        printf '   %-4s %10s %10s %10s\n' "$t" "$secs" "$mb" \
            "$(awk -v b="$base" -v s="$secs" 'BEGIN { printf "%.2fx", b / s }')"
    done
    echo ""
}

bench "what the pipeline gives it" 2 "${PAIR[@]}"
bench "enough work for eight threads" "${#EIGHT[@]}" "${EIGHT[@]}"

echo "Input kept at $OUT/data - delete it when you are done, or pass the same outdir to reuse it."
