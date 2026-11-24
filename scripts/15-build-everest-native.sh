#!/usr/bin/env bash
# 15-build-everest-native.sh - native EVerest build, following the current
# "Get started in Software" guide (manual 2026.10.0-rc3):
#   git clone; mkdir build; cmake ../EVerest/; make -j$(nproc) install
# A default build generates and installs the test PKI under
# dist/etc/everest/certs (CMake option ISO15118_2_GENERATE_AND_INSTALL_CERTIFICATES=ON),
# which the PnC simulation loads automatically.
set -euo pipefail

EVEREST_REF="${EVEREST_REF:-main}"
WORK="${EVEREST_WORK:-$HOME/everest-workspace}"

export CPM_SOURCE_CACHE="${CPM_SOURCE_CACHE:-$HOME/.cache/CPM}"
export PATH="$PATH:$HOME/.local/bin"

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d EVerest/.git ]]; then
  git clone https://github.com/EVerest/EVerest
fi
cd EVerest
git fetch --tags
git checkout "$EVEREST_REF"

mkdir -p "$WORK/build"
cd "$WORK/build"
cmake "$WORK/EVerest/"
make -j"$(nproc)" install

echo
echo "Build done. Quick smoke test:"
echo "  cd $WORK/build"
echo "  ./run-scripts/run-sil.sh        # terminal 1"
echo "  ./run-scripts/nodered-sil.sh    # terminal 2, UI at http://localhost:1880/ui"
echo "Test PKI: $WORK/build/dist/etc/everest/certs"
