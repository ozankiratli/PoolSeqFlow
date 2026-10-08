# Names on mds.png: ggrepel, and a setting to leave them off

Written 2026-10-08, against `dev` at `d8b7cee` plus the uncommitted report work of that day (`module-reports.md`). Not updated to follow the code.

## The ask

The example reports showed `mds.png` with 24 long pool names printed over each other in every cluster, and the outermost names cut at the edge of the image. I asked whether to add `ggrepel`, label with short numbers and a key, or leave it. Z: *"add ggrepel + add disabling the names"*.

## What was built

- **`labels`**, a new mds setting, default `true`. `false` draws the points alone. mds.R refuses anything but true or false, because the string `'false'` would otherwise read as false and the names would vanish with nothing said, and it refuses `true` at start when `ggrepel` is not installed, before any work, naming the setting that avoids it.
- **`ggrepel::geom_text_repel`** in place of `geom_text`, with `seed = 1`, `max.overlaps = Inf`, `max.iter = 3e5` and `max.time = 60`. The labels-run-past-the-panel fix from earlier the same day (`coord_fixed(clip = "off")`) is gone; only the 12% the axes leave on each side remains.
- **`r-ggrepel=0.9.8`** in mds' `packages`, credited in `modules/mds/references.bib` as software with its version asked of R at run time, the way basicstats credits data.table.
- **The report's caption** for `mds.png` no longer says each point is labeled, since it may not be.
- **agree.R** runs mds with `labels = FALSE`: it compares tables, and it runs in association's suite, whose environment need not hold a package only mds declares.

## Facts, measured

- **conda-forge** has `r-ggrepel` 0.9.8 built for R 4.5 (`r45h3697838_0`), and 0.9.5 and 0.9.6 for older R. A dry-run install into `PoolSeqFlow-3.2.0-analysis` links that one package and changes nothing else: every dependency (ggplot2 >= 3.5.2, Rcpp, rlang >= 1.1.6, S7, scales >= 1.4.0, withr >= 3.0.2) is already in the baseline.
- **License GPL-3**, under which mds (GPL-3.0-or-later) is already published.
- **It is the first module package the analysis baseline does not carry.** Every package any module declared before this is in `install/environment-analysis.yml`, so the package manager had never installed anything for a user. `check-module-packages.sh` step 1 now does real work at a release.
- **Placement time grows with the square of the pool count**, and these names never settle early, so every run spends its whole iteration budget. Measured on this machine with `max.time` out of the way, 38-character names in four clusters, 3e5 iterations: 12 pools 2.0 s, 24 pools 6.4 s, 48 pools 34.7 s, 72 pools 66.8 s. For 24 pools: 1e4 iterations 0.7 s, 1e5 2.3 to 2.7 s, 3e5 6.6 to 9.5 s, 1e6 23 to 31 s.
- **The placement is byte-identical between runs when the iteration limit stops it** (two runs at each of five budgets gave the same md5) and differs when the time limit does, since a slower machine stops earlier. ggrepel's defaults (0.5 s, 1e4 iterations) are time-bound for a few dozen pools, so the seed alone does not make the plot reproducible. With 3e5 and 60 s, the time limit binds first at about 65 pools.
- **Quality**: at 1e5 iterations the 24-name plot still had a few names over each other, at 3e5 almost none in a full panel, and in mds.png's own panel, narrowed by two legends, a few collisions remain. The manual says so and points to `labels = false`.

## What the cases check, and that they bite

`the names can be left off the plot`: two runs with names draw identical PNGs, a run without differs, and the coordinates do not move. `a labels setting that is not true or false is refused`. Reverted in a scratch clone, each failed: the seed removed (two runs differ), the setting ignored, the type check removed. Without `ggrepel` on the library path, mds.R stops with its own message and publishes nothing; the frame case and every direct case need the package.

## How a module suite gets a package the baseline lacks

The mds cases first ran here with `R_LIBS` pointing at the package unpacked into the scratchpad from conda-forge's own archive. Z then installed `r-ggrepel` 0.9.8, the pinned build, into `PoolSeqFlow-3.2.0-analysis` the same day, so filtered runs have it. Three places need it, and as written only the first has it:

- a filtered run uses the installed `PoolSeqFlow-<version>-analysis`, which holds it only once mds is installed from a catalogue that declares it, or it is installed by hand;
- a full run builds a scratch environment from `install/environment-analysis.yml` alone;
- `prep-version.sh` hands its freshly built pair to the full run.

I proposed that the full run's scratch environment take every shipped module's packages after it is built, which is what a user has after `analysis modules install all`; `prep-version.sh`'s environment is the release's and the export refuses module packages in it. Z installed the package by hand, and deferred the full run until the shape of association's output was settled.

**Settled when the full run was due: `ggrepel` is in the baseline.** Z: *"add ggrepel to the environment file. scratch builds from environment right?"* It does: the full run and `prep-version.sh` both build from `install/environment-analysis.yml`. The line `r-ggrepel=0.9.8=r45h3697838_0` was written into that file by hand, against its header's "do not edit by hand", because the documented route cannot take it. `export-environment.sh` refuses an environment holding a package a module declares that the baseline lacks, which is the guard against folding a module's packages in by accident, and this was the same act done on purpose. With the line in place, `export-environment.sh --check PoolSeqFlow-3.2.0-analysis` accepts, so a later export reproduces it. So every package any shipped module declares is in the baseline again, and the question of how a suite gets one that is not did not have to be answered.
