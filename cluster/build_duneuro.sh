#!/usr/bin/env bash
# One-time DUNE 2.10 + duneuro + duneuro-py build.
#
# Run on a compute node (not the login node), e.g. on Myriad:
#   qrsh -pe smp 4 -l mem=8G,h_rt=3:00:00 -now no
#   CLUSTER_PROFILE=myriad bash cluster/build_duneuro.sh
#
# Or submit as a batch job:
#   CLUSTER_PROFILE=myriad bash cluster/submit.sh build   # if using iNOB submit wrapper
#   qsub -pe smp 4 -l mem=8G,h_rt=3:00:00 cluster/build_duneuro.sh
#
# Required:
#   CLUSTER_PROFILE   myriad | kathleen  (selects module list + core count)
#
# Optional overrides:
#   DUNEURO_BASE      where to install venv + source (default: ~/Scratch/duneuro)
#   CORES_PER_TASK    parallel make jobs (default: set by profile)

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── profile: modules + resource shape ─────────────────────────────────────────
CLUSTER_PROFILE="${CLUSTER_PROFILE:-}"
if [[ -z "${CLUSTER_PROFILE}" ]]; then
    echo "[build_duneuro] ERROR: CLUSTER_PROFILE not set. Use: myriad | kathleen" >&2
    exit 1
fi

case "${CLUSTER_PROFILE}" in
    myriad)
        MODULES=(
            gcc-libs/10.2.0
            compilers/gnu/10.2.0
            cmake/3.21.1
            openblas/0.3.13-openmp/gnu-10.2.0
            eigen/3.4.0/gnu-10.2.0
            python/3.11.4-gnu-10.2.0
        )
        CORES_PER_TASK="${CORES_PER_TASK:-4}"
        ;;
    kathleen)
        MODULES=(
            gcc-libs/10.2.0
            compilers/gnu/10.2.0
            cmake/3.21.1
            openblas/0.3.13-openmp/gnu-10.2.0
            eigen/3.4.0/gnu-10.2.0
            python/3.11.4-gnu-10.2.0
        )
        CORES_PER_TASK="${CORES_PER_TASK:-80}"
        ;;
    *)
        echo "[build_duneuro] ERROR: unknown profile '${CLUSTER_PROFILE}'. Add a case block to this script for your cluster." >&2
        exit 1
        ;;
esac

# ── helpers ───────────────────────────────────────────────────────────────────
_log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${CLUSTER_PROFILE}] $*"; }

_load_modules() {
    if ! command -v module >/dev/null 2>&1; then
        # SGE body scripts run non-login; initialise the module system manually.
        for _init in "${MODULESHOME:-}/init/bash" /etc/profile.d/modules.sh; do
            [[ -n "${_init}" && -f "${_init}" ]] && { source "${_init}"; break; }
        done
    fi
    if ! command -v module >/dev/null 2>&1; then
        _log "WARNING: 'module' not available — skipping (dev machine?)"
        return 0
    fi
    module purge
    for m in "${MODULES[@]}"; do module load "${m}"; done
}

# ── paths ─────────────────────────────────────────────────────────────────────
BASE="${DUNEURO_BASE:-${HOME}/Scratch/duneuro}"
SRC="${BASE}/duneuro-src"
mkdir -p "${SRC}" "${BASE}"

_log "loading modules"
_load_modules
export CC=gcc CXX=g++
# Some cluster nodes default to C locale which makes pip choke on non-ASCII.
export PYTHONUTF8=1

# ── python venv ───────────────────────────────────────────────────────────────
[[ -d "${BASE}/venv" ]] || python3 -m venv "${BASE}/venv"
# shellcheck disable=SC1091
source "${BASE}/venv/bin/activate"
pip install --upgrade pip wheel
# Only what duneuropy itself needs at build + import time.
pip install --only-binary=:all: "numpy>=1.26,<2.0" pybind11

# ── DUNE 2.10 modules ─────────────────────────────────────────────────────────
cd "${SRC}"
DUNE_MODS=(dune-common dune-geometry dune-grid dune-istl dune-localfunctions \
           dune-typetree dune-functions dune-uggrid dune-alugrid \
           dune-pdelab dune-subgrid)
for m in "${DUNE_MODS[@]}"; do
    if [[ ! -d "${m}" ]]; then
        # Try each known DUNE namespace in priority order; fail loudly if none work.
        if   git clone -b releases/2.10 "https://gitlab.dune-project.org/core/${m}.git"        2>/dev/null; then :;
        elif git clone -b releases/2.10 "https://gitlab.dune-project.org/staging/${m}.git"     2>/dev/null; then :;
        elif git clone -b releases/2.10 "https://gitlab.dune-project.org/extensions/${m}.git"  2>/dev/null; then :;
        elif git clone -b releases/2.10 "https://gitlab.dune-project.org/pdelab/${m}.git"      2>/dev/null; then :;
        else
            _log "ERROR: could not clone DUNE module ${m} from any namespace"
            exit 1
        fi
    fi
done

[[ -d duneuro    ]] || git clone https://gitlab.dune-project.org/duneuro/duneuro.git
[[ -d duneuro-py ]] || git clone https://gitlab.dune-project.org/duneuro/duneuro-py.git

# Pin duneuro and apply Eigen-5 / DUNE-2.10 source patches (see scripts/patches/).
# Reset to the pinned commit and discard any prior edits so re-runs are idempotent.
DUNEURO_COMMIT="8f344b4da9c128ddf3e47af5ec136d05a3aeb162"
DUNEURO_PATCH="${HERE}/../scripts/patches/duneuro-eigen5-dune210.patch"
git -C "${SRC}/duneuro" reset --hard "${DUNEURO_COMMIT}" >/dev/null
git -C "${SRC}/duneuro" clean -fdq
_log "applying duneuro patch"
git -C "${SRC}/duneuro" apply "${DUNEURO_PATCH}"

cat > "${SRC}/release.opts" <<'OPTS'
CMAKE_FLAGS="
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_CXX_STANDARD=20
  -DCMAKE_CXX_FLAGS='-O3 -DNDEBUG -fPIC'
  -DCMAKE_C_FLAGS='-O3 -DNDEBUG -fPIC'
  -DBUILD_SHARED_LIBS=ON
  -DDUNE_ENABLE_PYTHONBINDINGS=ON
"
OPTS

_log "running dunecontrol all (this is the long step — expect 30-90 min)"
"${SRC}/dune-common/bin/dunecontrol" --opts="${SRC}/release.opts" all

# ── install duneuropy into the venv ──────────────────────────────────────────
cd "${SRC}/duneuro-py"
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_STANDARD=20 \
      -DPython3_EXECUTABLE="${BASE}/venv/bin/python" \
      ..
make -j"${CORES_PER_TASK}"
PYSITE="$(${BASE}/venv/bin/python -c 'import site; print(site.getsitepackages()[0])')"
cp -r src/duneuropy* "${PYSITE}/" 2>/dev/null || \
    find . -name 'duneuropy*.so' -exec cp {} "${PYSITE}/" \;

_log "verifying import"
"${BASE}/venv/bin/python" -c "import duneuropy as dp; print('duneuro OK:', dir(dp)[:5])"
_log "build complete — duneuropy venv: ${BASE}/venv"
