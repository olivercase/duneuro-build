# DUNEuro build patches

These patches are applied to the `duneuro` C++ source during the build
(`scripts/build_duneuro_local.sh` and `cluster/build_duneuro.sh`), pinned to
duneuro commit `8f344b4da9c128ddf3e47af5ec136d05a3aeb162`.

## `duneuro-eigen5-dune210.patch`

Two upstream-incompatibility fixes required to build against current
toolchains:

1. **`duneuro/common/geometry_adaption.hh`** — DUNE 2.10's
   `DiscreteCoordFunctionInterface::evaluate` is invoked for entities of *all*
   codimensions, not just vertices (`Codim<dim>`) and elements (`Codim<0>`).
   The two fixed-codim overloads are replaced by a single template overload
   using `subIndex(entity, corner, dim)`, which returns the global vertex
   index for any codimension.

2. **`duneuro/eeg/whitney_source_model.hh`** — the Eigen version pulled in by
   Homebrew at build time has *removed* the runtime-flag overload
   `jacobiSvd(unsigned int)`; switched to the `jacobiSvd<flags>()`
   template-parameter form instead, which that Eigen version requires.

The build scripts `git checkout` the pinned commit, then apply this patch
(idempotently — re-runs detect an already-patched tree via
`git apply --reverse --check`).
