# `bin/` is what is run; `lib/` is what is sourced

**Written 2026-08-31, against the tree at `7d65893`.** Nothing here has moved since: the split, the two files in `lib/`, and the five harness sites are all as described.

Z, 2026-08-30: *"I think we should make a folder lib/ and move the scripts that are not designed to be executed under lib."*

`lib/` holds `tool_version.sh` and `wrapper_lib.sh`. Everything else stays in `bin/`.

## What the split buys

Before it, two separate verifiers each carried a hand-kept exclusion list:

```sh
SOURCED="tool_version.sh wrapper_lib.sh"
```

in `install/check_install.sh` and again in `dev/scripts/verify-archive.sh`, so that a sourced library was not failed for missing an executable bit. Two copies of the same list, in different files, updated by hand whenever a sourced file was added — and one of them had already been wrong once before (`verify-archive.sh` asserted a hardcoded module count that was wrong by five, failing every PR until 2026-08-30).

With the split the rule needs no list at all. **Every file in `bin/` must be executable, full stop**, and `lib/` is checked for presence instead. The directory a file is in states its contract, so there is nothing to keep in step.

## What it touched

`params.dir.lib` is new in the template beside `dir.bin`, and is deliberately **not** on `PATH` — `nextflow.config` prepends `dir.bin` so process scripts can call helpers by bare name, and a sourced library is never called that way. `scripts/citations.nf` sources `${run.dir.lib}/tool_version.sh`. `PAYLOAD_ITEMS` gained `lib`, so it deploys and ships.

## The trap it sprang, which is the part worth remembering

`test/lib/sandbox.sh`'s launcher stub fabricates its payload as **empty placeholder directories** — deliberately, because nothing in those cases runs Nextflow. That worked only while the wrapper needed no payload *contents*. The moment `PoolSeqFlow` began sourcing a file out of the payload, 18 of 22 launcher cases failed at once, on a message about an incomplete installation that had nothing to do with what any of them was testing.

That is the same failure mode the comment above that loop already warned about, from when `multi-run.csv.example` was added to the payload. The placeholder strategy is fine; what it cannot survive is a payload file the wrapper *reads*.

**Anything added to `lib/` in future must be copied into every harness site that fabricates an installation**, or every launcher case fails together and says nothing useful about why. There were two when this was written and there are five now — `grep -rn wrapper_lib test/` finds them, which is the check to run rather than trusting a count here.
