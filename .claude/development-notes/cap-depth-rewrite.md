# Capping, made about seven times faster on real data

**Written 2026-09-29, against the tree at `772db1f` plus uncommitted work.** Picked up from `cap-bam-cost.md`, which measured the problem on 2026-09-28 and shelved it. That note's diagnosis was wrong on both counts and this one replaces it; it is kept because its timings are the record of what the step used to cost.

## What the old note got wrong

It said: *"Neither `samtools view` is threaded. No `-@`, so both the decompression and the recompression are serial. That alone accounts for much of the gap between 110% and 400%."*

Measured, on 1M synthetic reads:

| stage | time |
|---|---|
| decompress, `-@ 0` | 0 s |
| decompress, `-@ 3` | 0 s |
| gawk pass-through, `{print}` | 1 s |
| **`cap_depth.awk`** | **46 s** |
| recompress, `-@ 0` | 3 s |
| recompress, `-@ 3` | 1 s |
| full pipe as shipped | 47 s |
| full pipe with `-@ 3` on both ends | **48 s** |

The two `samtools` ends cost about two seconds in forty-seven, and threading them made it marginally *slower*. **The whole cost is the awk**, and the old note's second proposal -- parallelising by chromosome -- would have been real work aimed at the right bottleneck with the wrong instrument.

The tell was available and was not read: `gawk '{print}'` over the same file is 1 second. The script was running at 1/33rd of awk's own throughput, which is a statement about the script, not about awk.

## Three redundancies, each removed

### The check loop never needed more than one position

```awk
end = pos + span - 1
for (p = pos; p <= end; p++) {
    if (depth[p] + 0 >= cap) { dropped++; next }
}
```

The stream is coordinate-sorted, so every read already processed starts at or before `pos`. Such a read covers position `p >= pos` if and only if its end reaches `p`. So

    depth[p] = #{ kept reads S : end_S >= p }

which is **non-increasing in p**. The maximum over `[pos, end]` is therefore always `depth[pos]`, and 150 lookups collapse to one.

The proof needs all four of: the sorted input, the trim-from-behind that never deletes a position at or above `pos`, the bypass for reads consuming no reference, and the reset at a new sequence. All four were already there.

### The increment loop never needed to touch every position

A difference array records `+1` at the read's first position and `-1` one past its last, and a running total carried along the leading edge gives `depth[pos]` for nothing. O(span) becomes O(1) per read, with one sweep step per reference position.

### The sweep was creating the elements it then deleted

```awk
while (low < pos) { low++; cur += diff[low]; delete diff[low] }
```

**Referencing `diff[low]` in awk creates that element.** Most reference positions hold no entry, so this created and destroyed one array element per position of the genome. Guarding with `if (low in diff)`, which does not create, took the sweep-dominated synthetic case from 14 s to 6 s on its own -- more than the difference array had bought there.

## Measured, on Z's own *D. melanogaster* pools

Whole BAMs, at the caps those runs actually chose, output hashed end to end:

| sample | reads | cap | before | after | | md5 |
|---|---|---|---|---|---|---|
| Sample1 | 8,632,916 | 563 | 686 s | 93 s | 7.4x | identical |
| Sample2 | 6,243,115 | 502 | 493 s | 74 s | 6.7x | identical |
| Sample3 | 6,543,737 | 502 | 540 s | 82 s | 6.6x | identical |

**28.6 minutes to 4.1 across the cohort.** Every kept/dropped tally matches to the record: `kept 8632916, dropped 60297` and so on, identical on both sides.

Note how little is dropped -- 0.7%, 0.65%, 0.55%. Almost every read passes, so the old check loop almost never exited early and ran its full span on nearly every read. That is why real data lands near 7x where the dense synthetic reached 11x.

## What this does to the pipeline's shape

From the trace that started the investigation:

| process | was | now |
|---|---|---|
| `AlignReads:Align` | 14.9 min | 14.9 min |
| **`VariantCalling:CapBAM`** | **10.6 min** | **~1.6 min** |
| `SortCleanBams:SortCleanBam` | 6.7 min | 6.7 min |
| `BuildDictionaries:BuildSnpEffDb` | 4.4 min | 4.4 min |

**Capping goes from the second most expensive step to near the cheapest**, which removes the case for the two things the old note pointed at. Parallelising by chromosome is unnecessary. So is reaching for a tool outside awk: the BAM to SAM to BAM round trip is still there, and about three quarters of every line is `SEQ` and `QUAL` that the decision never reads, but a dependency bought to save another minute on a step that no longer costs one is a bad trade.

## Coverage, which did not exist

**`cap_depth.awk` shipped from 1.0 with no unit coverage at all.** The rewrite was verified against three real BAMs before a single case existed. Seven now sit in `03_helpers` (static, no JVM).

**They assert the contract, not the implementation.** The first recomputes per-position depth from the *output* and requires that no position exceeds the cap -- which is what the helper promises and holds however the inside is written. Checked both ways: all seven pass against the old implementation and the new one, and each fails when the guard it covers is broken (off-by-one on the cap, a CIGAR walk that ignores `D`, the sequence reset, the header bypass, the no-reference-consuming bypass).

Two cases were passing for the wrong reason first time round and both are recorded where they sit:

- The fixture was built by concatenating `$(...)` substitutions, which **strip trailing newlines**, gluing the last record of one stack onto the first of the next. It is appended to a file now.
- The no-reference-consuming case put an unmapped record *between* the stack and the soft-clipped read. An unmapped record's `RNAME` is `*`, which triggers a new-sequence reset and clears the depth before the soft-clipped read is judged -- so the case passed with the guard deleted outright. The unmapped record is last now, where a sorted BAM puts it anyway.

## Still open

- **The input is never checked for being sorted.** Both the old code and the new go silently wrong on an unsorted stream, and the new one goes wrong differently: `while (low < pos)` simply does not run, leaving a stale total. `if (pos < low)` is one integer comparison per read and turns a silent wrong answer into a loud failure. Not built; not asked for.
- **`#!/usr/bin/awk -f` hardcodes the system awk.** On the machine these numbers came from that is gawk 5.4.1. The release's conda environment ships its own `awk` and it is never used, so this step's speed is set by whatever the host provides -- mawk on Debian-family hosts, gawk on RHEL -- and sits outside the pinned environment. A cluster may be getting quite different performance from anything measured here.
- **`reflen()` walks the CIGAR one character per read.** CIGAR strings repeat enormously, so memoizing by string would replace the loop with one lookup. Pure awk, no dependency, unmeasured.
