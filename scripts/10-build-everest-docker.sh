#!/usr/bin/env bash
# 10-build-everest-docker.sh - build a Docker image of EVerest with the SIL
# Plug&Charge config, using EVerest's own image builder
# (applications/utils/docker/everest-docker-image/build.sh).
#
# Verified against EVerest manual 2026.10.0-rc3 (everest.github.io) and the
# current EVerest monorepo layout (github.com/EVerest/EVerest).
set -euo pipefail

EVEREST_REF="${EVEREST_REF:-main}"          # pin e.g. a release tag for the paper
WORK="${EVEREST_WORK:-$HOME/everest-workspace}"
CONF_REL="config/config-sil-ocpp201-pnc.yaml" # SIL + OCPP 2.0.1 + Plug&Charge

mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d EVerest/.git ]]; then
  git clone https://github.com/EVerest/EVerest
fi
cd EVerest
git fetch --tags
git checkout "$EVEREST_REF"

IMG_DIR=applications/utils/docker/everest-docker-image
./"$IMG_DIR"/build.sh --conf "$(pwd)/$CONF_REL" --name everest-pnc

# build.sh drops <name>-<timestamp>.tar.gz in the image dir; load the newest
LATEST=$(ls -t "$IMG_DIR"/*.tar.gz | head -1)
docker load < "$LATEST"
echo "Loaded image: $LATEST"
echo "Run it with:  docker run --rm -it --network host everest-pnc:<tag printed by docker load>"
