#!/usr/bin/env python3
"""Generate the raw sequencing data the PoolSeqFlow test suite runs against.

This is a *development* tool, not part of the suite. Its output is committed under
test/data/, and the suite reads those committed files. Regenerating is a deliberate act:
run this, look at what changed, commit it. That keeps the reference outputs stable across
machines and Python versions, which they would not be if the data were rebuilt at test time.

What this script does NOT do is predict what the pipeline will make of the data. An earlier
version tried, and the attempt actively damaged the fixture: to make coverage exactly
countable it gave every fragment the same length, which left bwa with a zero-variance insert
size distribution, which meant every indel-bearing pair fell outside the proper-pair window
and was discarded by the 0x2 filter in step 4. Six planted deletions produced zero indel
calls, and the truth table cheerfully asserted they should be there.

So the division of labour is:

  * This script plants variants and records what it planted, in planted.tsv. That file is
    provenance - what went in - and is explicitly not an oracle for what should come out.
  * test/tools/filter_oracle.py reads the VCF the pipeline actually produced and predicts
    the frequency tables from it. Everything from the raw VCF onward is a deterministic
    function of AD/DP/QUAL, so that prediction is exact and needs no tolerance.

The read simulation therefore aims at being *representative* rather than predictable:
insert sizes are drawn from a distribution, mates overlap or leave a gap as they happen to,
and allele assignment is a per-read draw. Sites planted at 0.0 or 1.0 are still exact, since
no sampling can invent a contradicting read, and those are the cases that pin down the
filter chain's boundaries.
"""

import argparse
import gzip
import os
import random

BASES = "ACGT"
# A transition keeps the alternate allele unambiguous and never equal to the reference.
TRANSITION = {"A": "G", "G": "A", "C": "T", "T": "C"}
COMP = str.maketrans("ACGT", "TGCA")

# Per-sample allele-frequency patterns, written for six samples. These are planted to make
# sure the interesting regions of the space are populated - the suite classifies sites from
# the VCF afterwards rather than trusting these labels. Mixed in with random draws below.
PATTERNS = [
    (1.0, 0.0, 0.0, 0.0, 0.0, 0.0),   # one sample fixed against the rest
    (1.0, 1.0, 1.0, 0.0, 0.0, 0.0),   # clean split down the middle
    (1.0, 1.0, 1.0, 1.0, 1.0, 1.0),   # fixed everywhere: carries no information
    (0.0, 0.0, 0.0, 0.0, 0.0, 0.0),   # never varies: never called
    (0.5, 0.0, 0.0, 0.0, 0.0, 0.0),   # polymorphic in exactly one sample
    (0.5, 0.5, 0.0, 0.0, 0.0, 0.0),   # polymorphic in exactly two
    (0.02, 0.0, 0.0, 0.0, 0.0, 0.0),  # rare allele, near the low-count boundary
    (0.02, 0.02, 0.0, 0.0, 0.0, 0.0),  # rare in two samples
    (0.95, 0.05, 0.5, 0.5, 0.5, 0.5),  # major/minor flip between samples
    (0.5, 0.5, 0.5, 0.5, 0.5, 0.5),   # uniform intermediate
]


def build_genome(rng, length):
    return [rng.choice(BASES) for _ in range(length)]


def place_genes(genome, count, cds_len, margin):
    """Carve protein-coding genes into the genome so snpEff has a database to build.

    Each gene is forced to start ATG and end TGA with a length divisible by three. The
    pipeline builds with -noCheckCds -noCheckProtein, so internal stop codons are tolerated.
    Returns 0-based half-open spans.
    """
    span = (len(genome) - 2 * margin) // count
    genes = []
    for i in range(count):
        start = margin + i * span
        end = start + cds_len
        genome[start:start + 3] = list("ATG")
        genome[end - 3:end] = list("TGA")
        genes.append((start, end))
    return genes


def choose_positions(rng, genome_len, genes, counts, spacing, edge):
    """Pick well-separated variant positions, preferring gene interiors.

    Sites are kept `spacing` apart so bcftools calls them as separate records instead of
    merging neighbours into one multi-nucleotide record, and clear of the contig edges so
    whole fragments can reach them. Returns one sorted list per entry in `counts`.
    """
    taken = set()
    # The start and stop codons have to survive in the reference or the snpEff database is
    # meaningless, so fence them off.
    for start, end in genes:
        taken.update(range(start - spacing, start + 3 + spacing))
        taken.update(range(end - 3 - spacing, end + spacing))

    def claim(pos):
        if pos in taken:
            return False
        taken.update(range(pos - spacing, pos + spacing + 1))
        return True

    in_gene = [p for start, end in genes
               for p in range(start + spacing, end - spacing, spacing)]
    rng.shuffle(in_gene)

    out = []
    for want in counts:
        got = []
        while in_gene and len(got) < want:
            pos = in_gene.pop()
            if claim(pos):
                got.append(pos)
        while len(got) < want:
            pos = rng.randrange(edge, genome_len - edge)
            if claim(pos):
                got.append(pos)
        out.append(sorted(got))
    return out


def apply_mutations(genome, start, span, muts):
    """Return the fragment sequence for `span` bases from `start` with `muts` applied.

    Reads extra reference beyond the fragment so deletions can shorten the sequence without
    leaving it short, then truncates back. Indels are applied right to left so that earlier
    offsets stay valid while editing.
    """
    slack = 64
    seq = list(genome[start:start + span + slack])
    for pos, kind, payload in sorted(muts, reverse=True):
        off = pos - start
        if kind == "snp":
            seq[off] = payload
        elif kind == "del":
            del seq[off:off + payload]
        elif kind == "ins":
            seq[off:off] = list(payload)
    return "".join(seq[:span])


def write_gz(path, text):
    """Write gzip with a fixed mtime so identical input yields an identical file."""
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as fh:
            fh.write(text.encode())


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="directory to write the fixture into")
    ap.add_argument("--seed", type=int, default=20260821)
    ap.add_argument("--samples", type=int, default=6)
    ap.add_argument("--prefix", default="TestSample")
    ap.add_argument("--genome-size", type=int, default=20000)
    ap.add_argument("--pairs", type=int, default=8000, help="read pairs per sample")
    ap.add_argument("--read-length", type=int, default=100)
    ap.add_argument("--insert-mean", type=int, default=300)
    ap.add_argument("--insert-sd", type=int, default=45)
    ap.add_argument("--patterned-sites", type=int, default=40)
    ap.add_argument("--random-sites", type=int, default=90)
    ap.add_argument("--deletions", type=int, default=8)
    ap.add_argument("--insertions", type=int, default=8)
    ap.add_argument("--genes", type=int, default=3)
    ap.add_argument("--cds-length", type=int, default=300)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    rlen = args.read_length
    n_s = args.samples

    genome = build_genome(rng, args.genome_size)
    genes = place_genes(genome, args.genes, args.cds_length, margin=args.insert_mean * 3)

    patterned, randomised, dels, inss = choose_positions(
        rng, args.genome_size, genes,
        counts=(args.patterned_sites, args.random_sites, args.deletions, args.insertions),
        spacing=rlen // 2, edge=args.insert_mean * 2,
    )

    def stretch(pattern):
        """Fit a six-sample pattern to the requested sample count."""
        return [pattern[i % len(pattern)] for i in range(n_s)]

    # pos -> (source, kind, payload, per-sample target frequencies)
    sites = {}
    for i, pos in enumerate(patterned):
        sites[pos] = ("patterned", "snp", TRANSITION[genome[pos]],
                      stretch(PATTERNS[i % len(PATTERNS)]))
    for pos in randomised:
        sites[pos] = ("random", "snp", TRANSITION[genome[pos]],
                      [round(rng.uniform(0.0, 1.0), 3) for _ in range(n_s)])
    for pos in dels:
        sites[pos] = ("random", "del", rng.choice((1, 2, 3, 6)),
                      [round(rng.uniform(0.3, 0.8), 3) for _ in range(n_s)])
    for pos in inss:
        sites[pos] = ("random", "ins", "".join(rng.choice(BASES) for _ in range(rng.choice((1, 3)))),
                      [round(rng.uniform(0.3, 0.8), 3) for _ in range(n_s)])

    site_positions = sorted(sites)

    # --- emit -----------------------------------------------------------------------------
    # The fixture is a mainDir: the layout a user prepares by hand before the first run -
    # reads under Data/, reference and annotation under Reference/, RGTags.csv alongside
    # them. storageDir starts empty and the pipeline fills it, so nothing here belongs to it.
    out = args.out
    os.makedirs(os.path.join(out, "Data"), exist_ok=True)
    os.makedirs(os.path.join(out, "Reference"), exist_ok=True)

    seq = "".join(genome)
    fasta = [">chr1"] + [seq[i:i + 80] for i in range(0, len(seq), 80)]
    write_gz(os.path.join(out, "Reference", "reference.fasta.gz"), "\n".join(fasta) + "\n")

    gff = ["##gff-version 3", f"##sequence-region chr1 1 {args.genome_size}"]
    for i, (start, end) in enumerate(genes, 1):
        # GFF is 1-based inclusive; the spans above are 0-based half-open.
        for feature, phase, attr in zip(
                ("gene", "mRNA", "exon", "CDS"),
                (".", ".", ".", "0"),
                (f"ID=gene{i};Name=gene{i}", f"ID=mrna{i};Parent=gene{i}",
                 f"ID=exon{i};Parent=mrna{i}", f"ID=cds{i};Parent=mrna{i}")):
            gff.append(f"chr1\ttest\t{feature}\t{start + 1}\t{end}\t.\t+\t{phase}\t{attr}")
    write_gz(os.path.join(out, "Reference", "reference.gff.gz"), "\n".join(gff) + "\n")

    qual = "I" * rlen
    max_start = args.genome_size - args.insert_mean - 4 * args.insert_sd
    for s in range(n_s):
        name = f"{args.prefix}{s + 1}"
        p1 = os.path.join(out, "Data", f"{name}_R1.fq.gz")
        p2 = os.path.join(out, "Data", f"{name}_R2.fq.gz")
        with open(p1, "wb") as f1, open(p2, "wb") as f2, \
                gzip.GzipFile(filename="", mode="wb", fileobj=f1, mtime=0) as r1, \
                gzip.GzipFile(filename="", mode="wb", fileobj=f2, mtime=0) as r2:
            for idx in range(args.pairs):
                # A spread of insert sizes, which is what lets bwa build a proper-pair window
                # with real width. A fixed insert size makes that window degenerate and every
                # indel-bearing pair is then flagged improper and filtered away.
                span = int(rng.gauss(args.insert_mean, args.insert_sd))
                span = max(rlen + 20, min(span, args.insert_mean + 4 * args.insert_sd))
                start = rng.randrange(0, max_start)

                # Only sites the mates actually sequence can carry an allele: with an insert
                # longer than two reads the middle of the fragment is never read.
                muts = []
                for pos in site_positions:
                    if pos < start:
                        continue
                    if pos >= start + span:
                        break
                    off = pos - start
                    if off >= rlen and off < span - rlen:
                        continue
                    _src, kind, payload, freqs = sites[pos]
                    if rng.random() < freqs[s]:
                        muts.append((pos, kind, payload))

                frag = apply_mutations(genome, start, span, muts)
                r1.write(f"@{name}f{idx}\n{frag[:rlen]}\n+\n{qual}\n".encode())
                rev = frag[-rlen:].translate(COMP)[::-1]
                r2.write(f"@{name}f{idx}\n{rev}\n+\n{qual}\n".encode())

    with open(os.path.join(out, "RGTags.csv"), "w") as fh:
        fh.write("ID,SM,LB,DS,FO,PL,PU\n")
        for s in range(n_s):
            name = f"{args.prefix}{s + 1}"
            pop, tp = s // 2 + 1, s % 2 + 1
            fh.write(f"{name},{name},Lib1,Pop{pop}_T{tp}_Rep1,FASTQ,ILLUMINA,Unit1\n")

    # planted.tsv is provenance: what this script put in. It is deliberately NOT an
    # expectation of what the pipeline should emit - trimming, clipping, the proper-pair
    # filter and the caller all stand between the two. Use it to explain a result, and
    # filter_oracle.py to assert one.
    with open(os.path.join(out, "planted.tsv"), "w") as fh:
        cols = ["pos", "source", "kind", "ref", "alt"]
        cols += [f"target_{args.prefix}{s + 1}" for s in range(n_s)]
        fh.write("\t".join(cols) + "\n")
        for pos in site_positions:
            source, kind, payload, freqs = sites[pos]
            if kind == "snp":
                ref, alt, vcf_pos = genome[pos], payload, pos + 1
            elif kind == "del":
                # bcftools anchors an indel on the preceding base.
                ref = "".join(genome[pos - 1:pos + payload])
                alt = genome[pos - 1]
                vcf_pos = pos
            else:
                ref = genome[pos - 1]
                alt = genome[pos - 1] + payload
                vcf_pos = pos
            fh.write("\t".join([str(vcf_pos), source, kind, ref, alt]
                               + [str(f) for f in freqs]) + "\n")

    depth = args.pairs * 2 * rlen // args.genome_size
    print(f"fixture written to {out}")
    print(f"  {n_s} samples x {args.pairs} pairs, {args.genome_size} bp, "
          f"{args.genes} genes, ~{depth}x")
    print(f"  planted: {len(patterned)} patterned SNPs, {len(randomised)} random SNPs, "
          f"{len(dels)} deletions, {len(inss)} insertions")
    print(f"  insert size {args.insert_mean} +/- {args.insert_sd}")
    print("  planted.tsv records what went in; it is not an expectation of what comes out")


if __name__ == "__main__":
    main()
