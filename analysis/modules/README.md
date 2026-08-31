# Installed modules

One directory per module, named exactly as the module is named. Each holds at least:

| File | What |
|---|---|
| `manifest.json` | `name`, `version`, `contract`, `summary`, and optionally `needs` and `gates` |
| `main.nf` | the module's own Nextflow pipeline |

A module is a pipeline in its own right. It imports what it wants from `analysis/lib` by relative
path and is launched directly; nothing in the frame includes it, so a module that is absent, or
one whose directory has been removed, costs the others nothing.

**Import only the workflows you call.** An import you never use still couples you to it — a
library workflow that is renamed or removed breaks every module naming it, called or not.

This directory is empty in a fresh installation. Modules are installed separately from the
pipeline, into this release's own installation, so a module installed for one release is never
picked up by another.
