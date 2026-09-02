# The shared R library

Decision-free R that more than one module wants: readers for the published tables, effective
sample size, harmonic means, per-pool sensitivity. A module's own analysis stays under
`analysis/modules/<name>/`.

Modules do not share an R *session*. They share these *source files*, sourced into a session
each module starts for itself.

## What belongs here

Only derivations that carry no decision. A derivation that needs a choice — a missing-site
policy, say — takes it as a required argument with no default, is declared in the calling
module's `gates`, and keys any intermediate's name on the value. That rule is in
`../../modules/README.md` and it is what stops one module handing the next its assumption.

## Two rules for the code itself

**Base R only.** These functions are unit-tested by a bare `Rscript`, against whatever R is on
the machine, so they must not need a package the analysis environment pins. A module's own R
may use `data.table` and `ggplot2` freely.

**One file per function.** A module declares which it sources, and the publish concatenates
exactly those into one file that ships beside the result — so a published folder carries the
code that computed its numbers, not a driver that refers to code the reader does not have.

## Versioning

Everything under `analysis/lib/` is covered by `analysis/frame.version`: a change here changes
what a derivation means, and every intermediate's provenance record carries that version.
