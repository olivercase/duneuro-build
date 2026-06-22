#!/usr/bin/env bash
# Local (macOS / Apple Silicon) DUNE 2.10 + duneuro + duneuro-py build.
# Adapted from cluster/build_duneuro.sh for a no-module-system, Homebrew,
# Apple-clang, python3.11 environment.
#
#   bash scripts/build_duneuro_local.sh
#
# Resumable: existing clones / venv are reused. Logs to $BASE/build.log.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${DUNEURO_BASE:-/Volumes/UCL/duneuro_build}"
SRC="${BASE}/duneuro-src"
VENV="${BASE}/venv"
PY=/opt/homebrew/bin/python3.11
JOBS="$(sysctl -n hw.ncpu)"
BREW="$(brew --prefix)"
mkdir -p "${SRC}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── never prompt for git credentials (probing namespaces 404s → would hang on
#    a VS Code / macOS askpass prompt otherwise). Fail fast instead. ─────────
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true SSH_ASKPASS=/usr/bin/true
export GCM_INTERACTIVE=never
GIT_NOPROMPT=(-c credential.helper= -c core.askPass=)

# ── Apple clang, C++20; point CMake at Homebrew deps; CMake 4.x compat ──────
export CC=clang CXX=clang++
export CMAKE_PREFIX_PATH="${BREW}/opt/eigen:${BREW}/opt/gmp:${BREW}/opt/metis:${BREW}/opt/superlu:${BREW}"
export PKG_CONFIG_PATH="${BREW}/lib/pkgconfig:${BREW}/share/pkgconfig"

# ── python venv ─────────────────────────────────────────────────────────────
if [[ ! -d "${VENV}" ]]; then
    log "creating venv (python3.11)"
    "${PY}" -m venv "${VENV}"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
python -m pip install --upgrade pip wheel setuptools >/dev/null
log "installing python deps"
pip install numpy scipy h5py trimesh pyyaml scikit-image matplotlib >/dev/null
pip install --no-deps -e "${REPO}" >/dev/null

# ── DUNE 2.10 modules ──────────────────────────────────────────────────────
cd "${SRC}"
DUNE_MODS=(dune-common dune-geometry dune-grid dune-istl dune-localfunctions \
           dune-typetree dune-functions dune-uggrid dune-alugrid \
           dune-pdelab dune-subgrid)
clone_mod() {
    local m="$1"
    [[ -d "${m}" ]] && return 0
    for ns in core staging extensions pdelab; do
        if git "${GIT_NOPROMPT[@]}" clone -q -b releases/2.10 \
              "https://gitlab.dune-project.org/${ns}/${m}.git" 2>/dev/null; then
            log "cloned ${m} (${ns})"; return 0
        fi
    done
    log "ERROR: could not clone ${m}"; return 1
}
for m in "${DUNE_MODS[@]}"; do clone_mod "${m}"; done
[[ -d duneuro    ]] || { log "cloning duneuro";    git "${GIT_NOPROMPT[@]}" clone -q https://gitlab.dune-project.org/duneuro/duneuro.git; }
[[ -d duneuro-py ]] || { log "cloning duneuro-py"; git "${GIT_NOPROMPT[@]}" clone -q https://gitlab.dune-project.org/duneuro/duneuro-py.git; }

# ── pin duneuro + apply Eigen-5 / DUNE-2.10 source patches ──────────────────
# The build is reproducible only against the pinned commit; the patch (made
# against it) fixes a removed Eigen runtime-flag overload and DUNE 2.10's
# all-codim DiscreteCoordFunction::evaluate. See scripts/patches/.
DUNEURO_COMMIT="8f344b4da9c128ddf3e47af5ec136d05a3aeb162"
DUNEURO_PATCH="${REPO}/scripts/patches/duneuro-eigen5-dune210.patch"
git -C "${SRC}/duneuro" checkout -q "${DUNEURO_COMMIT}"
if git -C "${SRC}/duneuro" apply --reverse --check "${DUNEURO_PATCH}" 2>/dev/null; then
    log "duneuro patch already applied — skipping"
else
    log "applying duneuro patch"
    git -C "${SRC}/duneuro" apply "${DUNEURO_PATCH}"
fi

# ── build options ───────────────────────────────────────────────────────────
EIGEN_INC="${BREW}/opt/eigen/include/eigen3"
EIGEN_DIR="${BREW}/opt/eigen/share/eigen3/cmake"
# CMAKE_PREFIX_PATH must use semicolons (CMake list) when passed as a -D flag.
CMAKE_PREFIX_SEMICOLON="${BREW}/opt/eigen;${BREW}/opt/gmp;${BREW}/opt/metis;${BREW}/opt/superlu;${BREW}"
PY311_FWK="${BREW}/opt/python@3.11/Frameworks/Python.framework/Versions/3.11"
PY311_LIB="${PY311_FWK}/lib/libpython3.11.dylib"
PY311_INC="${PY311_FWK}/include/python3.11"
cat > "${SRC}/release.opts" <<OPTS
CMAKE_FLAGS="
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_CXX_STANDARD=20
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DCMAKE_PREFIX_PATH='${CMAKE_PREFIX_SEMICOLON}'
  -DEigen3_DIR='${EIGEN_DIR}'
  -DCMAKE_CXX_FLAGS='-O2 -DNDEBUG -fPIC -I${EIGEN_INC}'
  -DCMAKE_C_FLAGS='-O2 -DNDEBUG -fPIC'
  -DBUILD_SHARED_LIBS=ON
  -DDUNE_ENABLE_PYTHONBINDINGS=ON
  -DCMAKE_DISABLE_FIND_PACKAGE_MPI=ON
  -DCMAKE_DISABLE_FIND_PACKAGE_SuperLU=ON
  -DPython3_EXECUTABLE=${VENV}/bin/python
  -DPYTHON_EXECUTABLE=${VENV}/bin/python
  -DPYTHON_LIBRARY=${PY311_LIB}
  -DPYTHON_INCLUDE_DIR=${PY311_INC}
"
MAKE_FLAGS="-j${JOBS}"
OPTS

# Clear the duneuro-py cmake cache so the corrected Python paths are picked up.
rm -rf "${SRC}/duneuro-py/build-cmake/CMakeCache.txt" "${SRC}/duneuro-py/build-cmake/CMakeFiles"

log "running dunecontrol all (long step) — logging to ${BASE}/dunecontrol.log"
"${SRC}/dune-common/bin/dunecontrol" --opts="${SRC}/release.opts" all 2>&1 | tee "${BASE}/dunecontrol.log"

# ── install the duneuro-py extension into the venv ──────────────────────────
# dunecontrol (above) already builds duneuro-py via dune_enable_all_packages.
# On macOS the artefact is ``duneuropy.dylib``; Python needs it named ``.so``.
PYSITE="$(${VENV}/bin/python -c 'import site; print(site.getsitepackages()[0])')"
DUNEUROPY_LIB="$(find "${SRC}/duneuro-py/build-cmake" \
    -name 'duneuropy*.dylib' -o -name 'duneuropy*.so' | head -1)"
if [[ -z "${DUNEUROPY_LIB}" ]]; then
    log "ERROR: duneuropy extension not found under build-cmake"; exit 1
fi
log "installing ${DUNEUROPY_LIB} → ${PYSITE}/duneuropy.so"
cp "${DUNEUROPY_LIB}" "${PYSITE}/duneuropy.so"
# Pure-python helpers shipped alongside the extension (metadict.py etc.).
cp "${SRC}"/duneuro-py/build-cmake/src/*.py "${PYSITE}/" 2>/dev/null || true

log "verifying import"
"${VENV}/bin/python" -c "import duneuropy as dp; print('duneuro OK:', [x for x in dir(dp) if not x.startswith('_')][:6])"
log "build complete — venv at ${VENV}"
