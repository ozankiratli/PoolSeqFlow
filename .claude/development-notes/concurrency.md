# Concurrency: two analysis modules deriving one intermediate

**Written 2026-09-01, describing work committed 48 minutes later in `77fdbd7`** — so the overhaul below is in that commit, not in the tree the note was written against. Both items under *Still owed before release* have been done since. Suite numbers are updated to the post-split names; the case names never changed.

The analysis layer shares intermediates across **separate Nextflow invocations**. `Analysis/Main` is skip-by-existence: a module checks whether a derivation is already there, and builds it if not. Two modules started at the same time therefore race for the same output path, and nothing in Nextflow arbitrates between two processes it did not start.

Until 2026-08-31 the plan recorded this as *"reasoned safe (.part then mv), NOT measured. Worst case is duplicated work, not corruption."* **That reasoning was wrong**, and the measurement is below. The defect is fixed; this note is why the fix is shaped the way it is.

## What was measured

`dev/`-free probes in a session scratchpad, against `bin/atomic_mv.sh` as it stands: 8 concurrent callers, one destination, 64 MB each, over 5–8 rounds. Two filesystem cases, because `mv` is a different operation in each — `rename(2)` within one filesystem, copy-then-unlink across two. Each caller wrote a file of one repeated byte, so a destination holding more than one distinct byte would be proof of interleaving rather than an inference from timing. A second probe ran a watcher sampling the destination's size throughout the race.

| | as it stands | with the fix below |
|---|---|---|
| callers that failed | **5–8 of 8, every round** | 0 of 8, every round |
| destination absent after all callers finished | **1 of 5 cross-filesystem rounds** | 0 |
| destination present and **incomplete**, seen by a watcher | **10 sightings across 5 rounds**, sizes from 49 MB of 64 | 0 across 8 rounds |
| content interleaved (two bytes in one file) | never observed | never observed |
| `.part` files left behind | none | none |

## Why

`atomic_mv.sh` stages through `${DEST}.part` — a name derived **only from the destination**, so every concurrent caller uses the same temp file — and installs `trap 'rm -rf -- "${DEST}.part"' EXIT`.

Two consequences, both measured:

1. **Any caller's exit deletes the temp file every other caller is using.** That is the 5-of-8 failure rate, and the round where all eight failed and no destination existed at the end. Under the analysis layer's `errorStrategy = 'finish'` this fails the run.
2. **A partial file becomes visible under the destination's own name.** Caller A finishes its cross-device copy and renames `${DEST}.part` to `DEST` while caller B is still writing into that same inode; `rename(2)` moves the name, not the file, so B's writes continue into what is now `DEST`. A third invocation doing skip-by-existence sees the file, calls the derivation done, and reads a truncated intermediate.

The second is the dangerous one. It is silent, it produces a wrong number rather than an error, and the artifact it leaves behind is wrong for good.

None of this contradicts the script's own docstring: *"NO LOCKING. The caller is responsible for one task per artifact path."* Within the pipeline Nextflow guarantees that. **The analysis layer's cross-invocation sharing does not**, which is the gap — the script is being asked for something it never promised.

## The fix, and what it is worth

Give each caller a staging area of its own.

```bash
STAGE=$(mktemp -d "$(dirname "$DEST")/.atomic_mv.XXXXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
mv "$SRC" "$STAGE/item"
mv "$STAGE/item" "$DEST"
```

Measured against the same probes: **0 failures out of 8 callers, 0 partial sightings across 8 rounds, no leftovers.** Every caller copies to a name nobody else touches, and the final `rename(2)` is atomic within the destination filesystem, so the destination is only ever absent or complete.

**Landed 2026-08-31**, ahead of E6 — Z lifted the freeze for it, because it blocks the intermediates E4b-mod is about to build.

**`mktemp` and not `$$`.** A PID is unique among live processes on one machine, and two nodes of a cluster sharing `mainDir` can hold the same one. A guarantee was available, so a near-certainty was not worth taking.

**A staging DIRECTORY and not a temp file, and this is the part that bit.** The first fix used `mktemp "${DEST}.part.XXXXXXXX"`, which passed every probe, every helper test and `--fast` — and then failed all 40 cases of `03_pipeline`, because **`atomic_mv.sh` also moves directories**: step 1 moves a whole snpEff database with it. `mv` refuses to overwrite a file with a directory, and the script's own usage line said `<source-file>`, which is how the assumption survived. The usage line now says the source may be either, and `test_atomic_mv_moves_a_directory` in `05_helpers` covers it.

The lesson is narrower than "run the tests": the probes and the unit tests were all built around **files**, because the bug being fixed was about files, and a fix verified only against the shape of its own bug report is a fix verified against half the callers.

`test_atomic_mv_survives_callers_racing_for_one_destination` in `05_helpers` guards it, and was checked against the unfixed script: it fails there and passes here.

## What the fix does not buy

- **Duplicated work stays.** Two modules deriving the same intermediate both derive it. That is accepted: the alternative is a lock, and a stale lock file is worse than a repeated computation.
- **Last writer wins.** Safe only because a shared derivation is byte-identical whoever produced it — which is exactly why the library takes decisions as required arguments and `Analysis/Main` keys the filename on them. `freqmatrix_pairwise.tsv` is safe to race for; `freqmatrix.tsv` would not be, because two modules could legitimately produce different bytes for one name. The naming rule and the concurrency guarantee are the same rule.
- **The measurement is local.** tmpfs against tmpfs, and tmpfs against tmpfs on another mount. `rename(2)` atomicity is a POSIX guarantee within one filesystem, but NFS and some network filesystems weaken it. A user running `mainDir` on NFS is outside what was measured, and nothing here detects that.

## Reproducing it

The probes were written in a session scratchpad and are not tracked; they are twenty lines each and the description above is enough to rebuild them. Two things they must do, because the first version of each missed one:

- **Distinguish the callers' content**, not just the size. A size check alone cannot tell a complete file from a complete file of the wrong provenance.
- **Sample the destination during the race, from a third process.** Checking the final state answers the wrong question: the final state was correct in every round, and the defect is entirely in the window.

---

## 2026-09-01 — a SECOND defect in the same file, and this one destroyed the source

Found while scoping `PoolSeqFlow analysis complete`, by an adversarial pass over the design rather than by a test. The August fix bought *"the destination is only ever absent or complete"* and its "What the fix does not buy" section never mentioned the source. It should have.

### The code

```bash
STAGE=$(mktemp -d "$(dirname "$DEST")/.atomic_mv.XXXXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
mv "$SRC" "$STAGE/item"      # <- source is GONE after this line
mv "$STAGE/item" "$DEST"
```

Between those two lines the staged copy is **the only copy**, and the `EXIT` trap deletes it.

### Measured, on this machine, `/dev/shm` → `/tmp` (two tmpfs mounts, so `mv` takes its cross-device path)

| probe | before | after |
|---|---|---|
| the final rename fails — **no signal, no race** | source GONE, destination GONE, exit 1 | source intact, destination absent |
| SIGTERM to the script, 900 MB tree, mid-copy | source **124 of 300 files**, destination GONE | source 300 of 300 |
| SIGTERM to the process group, same | source 300 (safe by luck: `mv` was killed too) | source 300 |
| SIGTERM to the script, 900 MB single file, ×5 | **2 of 5 TOTAL LOSS** | 0 of 5 |

**The no-signal case is the one that matters.** A destination that cannot be written when the rename runs — a full volume, a quota, a read-only mount — destroys the artifact and exits 1. Nothing about it is a race.

The signal cases have a mechanism worth recording: bash defers a trapped signal until the current foreground command returns, so a SIGTERM arriving during `mv "$SRC" "$STAGE/item"` **guarantees** that `mv` completes — source unlinked — before the `EXIT` trap runs and deletes the staged copy. Killing the whole process group is safer only because `mv` dies too.

### The fix, as first written — superseded the same day by the redesign below

The invariant is **the source is removed only once the destination exists, complete, under its final name.** Worst case is the artifact in **both** roots, which `find_artifact.sh` already reports and `PromoteArtifacts` already asserts against. That invariant survives into the final version; the machinery around it did not.

Two paths, and which one runs is asked of the kernel:

- **Within one filesystem** — a single `rename(2)`. The artifact keeps its inode and acquires the new name, so no second copy exists that could be wrong and there is nothing to verify. Confirmed by inode: 50 MB in 10 ms, unchanged inode, nothing staged.
- **Across filesystems** — `cp -a` into the caller's own staging directory, **both sides hashed and compared**, rename into place, `trap - EXIT`, then the source.

**`mv` is not used for either.** Given two names on different filesystems `mv` answers by copying **onto the destination's own name**, and an interrupted write there is a partial file every skip check reads as finished — the August bug, reintroduced through the back door. The first version of this fix predicted the filesystem with `stat -c %d` and then called `mv`, which is a guess about what the kernel will do; `os.rename` raises `EXDEV` and never falls back, so the fast path is taken only when it is genuinely a rename.

**The hash comparison is Z's, 2026-09-01**, on the grounds that data integrity is worth the cost. Its reach is narrower than it looks and worth stating: `cp` already fails loudly on ENOSPC, so `set -e` catches a full volume before the hash runs, and reading the copy back immediately usually comes from page cache rather than the platter — so this does not certify storage. What it does catch, reproduced: **a source that changed while it was being copied** (exit 1, destination never written, source intact), and a `cp` that returns 0 with wrong bytes. A directory is reduced to one digest over every entry's type and path, every symlink's target and every file's contents, so a dropped empty directory and a truncated member are both differences.

**The cost is real and was accepted deliberately.** A cross-filesystem move now makes four passes over the data — read source, write copy, read source again, read copy — where `mv` made two. Same-filesystem promotion is unaffected, which is why the rename path is worth keeping rather than folding into one uniform code path: a rename creates no copy, so verification there would compare a file with itself.

The same commit closes a second hole in the same file: the trailing-slash form resolved `dst/` to `dst/<basename>` and never re-tested it, so an existing directory of that name swallowed the source as `dst/<basename>/item` — exit 0, source gone, artifact under a name no skip check looks for. The `-d` refusal now runs after the resolution, so both spellings reach it.

### Why no test covers the cross-device path

`TEST_TMPDIR` is a single filesystem and `guard_path` refuses anything outside it, so the suite can only reach the same-filesystem path. The two new `05_helpers` cases cover what is reachable: the directory-destination refusal (deterministic, and it loses the source on the old code) and the inode assertion that the same-filesystem path is a rename. **The cross-device evidence is the table above and nothing in CI reproduces it.** Closing that needs either a second mount point in the harness or a documented `guard_path` exception — a decision, not an oversight.

### The method note, which is the same one as last time

August measured the destination because the bug report was about the destination. This defect was in the same four lines the whole time. *"A fix verified only against the shape of its own bug report is verified against half the callers"* — and the half that went unexamined was the half where the data comes from.

---

## 2026-09-01, later — the overhaul, and the diagnosis that made it small

Z stopped the patching: *"I believe the script is prone for errors… we are now patching it for every edge case. This means the main logic does not cover edge cases… When this happens, I overhaul the whole script. Simplicity is the key."*

Three guards had accreted in two days: a destination that is already a directory, a directory source onto a file destination, and the trailing-slash form resolving a destination without re-testing it.

### The cause was not the contract

My diagnosis was that the destination argument was ambiguous — file or directory to move into — and that the ambiguity generated the guards. That is the symptom. **The cause is that two different things wrote the destination name:** `rename(2)` on the fast path, and `mv` on the staged one. `mv` carries a userspace convention the kernel does not — *a destination that is a directory means put the source inside it* — and every guard was a hand-rolled re-implementation of a rule the kernel already enforces.

Measured, with both sides checked afterwards:

| | `rename(2)` | `mv` |
|---|---|---|
| file → existing file | replaces | replaces |
| file → existing directory | **EISDIR**, both sides untouched | nests it inside, exit 0 |
| directory → existing file | **ENOTDIR**, both sides untouched | refuses |
| directory → existing non-empty directory | **ENOTEMPTY**, both sides untouched | refuses |
| directory → existing empty directory | replaces | refuses |

Make `rename(2)` the only writer and there is nothing left to enumerate. **The trailing-slash form was never the problem** — it was a guard sitting *below* the resolution. With no guard downstream, both spellings traverse identical code, which `test_atomic_mv_both_destination_spellings_agree` now asserts.

### What the file became

`place()` — `os.rename` via `python3`, exit 9 for EXDEV — is the only writer, used for the direct move and for the staged one. Across filesystems: `rsync -a` into the caller's own staging directory, `diff -qr --no-dereference` against the source, `place()` into the destination, then the source.

- **Destination or source type tests: 3 → 0.** Code lines 79 → 47.
- **Call sites changed: 0.** The trailing-slash form stays; Z's earlier decision to drop it was taken from the wrong diagnosis and reversed once the right one landed.
- **`trap - EXIT` and the paired `rmdir` are gone.** The trap now runs unconditionally, because after the final rename the staging directory is empty and removing it costs nothing. The arm/disarm coordination that hosted the September data-loss bug has no replacement rather than a safer version.
- **`digest()` is gone**, and with it a dependency on `findutils` (`find -printf`, `xargs`) that was never pinned, and a carried-over bug where a symlink source failed across filesystems because the digest followed the link. `test_atomic_mv_moves_a_symlink_across_filesystems` guards the fix.

### rsync, and what it is and is not doing

Z's call, measured before adopting. **rsync gives the verification and not the atomicity:**

- A single file: writes `.name.XXXXXX` and renames. Destination name never partial.
- **A directory: no whole-tree atomicity — 101 of 200 files were visible under the final path mid-transfer.** So the staging directory and the final rename stay. rsync writes into the stage, where partial state is invisible.
- **`--remove-source-files` must never be used.** It deletes the source when rsync's transfer succeeds, which is before the rename into place — exactly the September bug.

**RSYNC DOES NOT VERIFY, and I claimed it did.** The claim came from a probe that used `--remove-source-files`, where a source mutated mid-transfer produced exit 23 — that is rsync declining to *delete* a changed source, not detecting a bad transfer. Isolated afterwards, flag against version:

| | exit | copy vs source |
|---|---|---|
| `rsync -a`, 3.4.4 and 3.5.0 alike | **0, silent** | **DIFFERENT** |
| `rsync -a --remove-source-files`, both | 23 | DIFFERENT |

Plain `rsync -a` copies a source that is being written, reports success and says nothing. **So `diff -qr --no-dereference` is not a second opinion on top of rsync — it is the only verification there is**, and without it the source would be removed after an unchecked copy. Z asked for it on instinct; it is load-bearing. Measured to catch a changed file, a missing file, an extra file, a dropped empty directory and a retargeted symlink. It does not compare file modes, which `rsync -a` owns.

The general lesson is the one this note already carries twice: **a tool's exit code answers the question the tool was asked, not the question you had in mind.** The flag under test was not the flag whose behavior was being attributed.

### What it gives up

**Cross-filesystem type refusals now happen after the copy.** `EXDEV` outranks `EISDIR` in the kernel, so no trial rename can report the type problem first, and moving a directory onto a file across volumes copies the whole tree before failing. The outcome is identical — exit 1, source kept, destination untouched, nothing staged — only the wasted work differs, on a path that always aborts. `test_atomic_mv_refusals_reach_the_same_outcome_across_filesystems` pins it.

**A directory now replaces an existing EMPTY directory** instead of being refused. Nothing is lost and no caller reaches it, but it is a behavior change and `test_atomic_mv_replaces_an_empty_directory` asserts it rather than leaving it to be discovered.

### Still owed before release — both done since

- **`rsync` was in neither `install/environment.yml` nor `parameters.config.template`'s `software` block**, so step 0 did not verify it and a missing rsync failed deep in a task at promotion time rather than at step 0, which is what step 0 exists to prevent. It is pinned as `rsync=3.4.4=hffd6c76_1` now and has a `software` slot, so step 0 checks it.
- **`findutils` and `diffutils` were unpinned** while `coreutils`, `gawk`, `grep` and `sed` were. Both carry exact pins now. `diffutils` is the one that mattered: `diff` is load-bearing here and in the analysis layer's provenance check.
