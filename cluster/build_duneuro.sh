#!/usr/bin/env bash
# One-time DUNE 2.10 + duneuro + duneuro-py build, profile-driven.
# Run on a compute node (not login):
#   qrsh -pe smp 4 -l mem=8G,h_rt=2:00:00 -now no
#   cd <base>/code && CLUSTER_PROFILE=myriad bash cluster/build_duneuro.sh

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib.sh"
vagus_fm__init

BASE="${HOME}/Scratch/vagus_fm"
SRC="${BASE}/duneuro-src"
mkdir -p "${SRC}" "${BASE}"

vagus_fm__log "loading modules for ${PROFILE_NAME}"
vagus_fm__load_modules
export CC=gcc CXX=g++

# ── python venv with manylinux2014-friendly pins ───────────────────────────
if [[ ! -d "${BASE}/venv" ]]; then
    python3 -m venv "${BASE}/venv"
fi
# shellcheck disable=SC1091
source "${BASE}/venv/bin/activate"
pip install --upgrade pip wheel
pip install --only-binary=:all: -r "${HERE}/../requirements-cluster.txt"

# Install the vagus_fm package itself so cluster jobs can ``python -m vagus_fm.*``.
pip install --no-deps -e "${HERE}/.."

# ── DUNE 2.10 modules ──────────────────────────────────────────────────────
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
            vagus_fm__log "ERROR: could not clone DUNE module ${m} from any namespace"
            exit 1
        fi
    fi
done

# duneuro
[[ -d duneuro    ]] || git clone https://gitlab.dune-project.org/duneuro/duneuro.git
[[ -d duneuro-py ]] || git clone https://gitlab.dune-project.org/duneuro/duneuro-py.git

# Pin duneuro + apply Eigen-5 / DUNE-2.10 source patches (see scripts/patches/).
DUNEURO_COMMIT="8f344b4da9c128ddf3e47af5ec136d05a3aeb162"
DUNEURO_PATCH="${HERE}/../scripts/patches/duneuro-eigen5-dune210.patch"
git -C "${SRC}/duneuro" checkout -q "${DUNEURO_COMMIT}"
if git -C "${SRC}/duneuro" apply --reverse --check "${DUNEURO_PATCH}" 2>/dev/null; then
    vagus_fm__log "duneuro patch already applied — skipping"
else
    vagus_fm__log "applying duneuro patch"
    git -C "${SRC}/duneuro" apply "${DUNEURO_PATCH}"
fi

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

vagus_fm__log "running dunecontrol all (this is the long step)"
"${SRC}/dune-common/bin/dunecontrol" --opts="${SRC}/release.opts" all

# Install duneuro-py extension into the venv.
cd "${SRC}/duneuro-py"
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_STANDARD=20 \
      -DPython3_EXECUTABLE="${BASE}/venv/bin/python" \
      ..
make -j"${CORES_PER_TASK:-4}"
PYSITE="$(${BASE}/venv/bin/python -c 'import site; print(site.getsitepackages()[0])')"
cp -r src/duneuropy* "${PYSITE}/" 2>/dev/null || \
    find . -name 'duneuropy*.so' -exec cp {} "${PYSITE}/" \;

vagus_fm__log "verifying import"
"${BASE}/venv/bin/python" -c "import duneuropy as dp; print('duneuro OK:', dir(dp)[:5])"
vagus_fm__log "build complete"
