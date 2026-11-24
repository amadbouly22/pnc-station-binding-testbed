#!/usr/bin/env bash
# 20-start-infra.sh - start the helper services every EVerest SIL run needs:
# MQTT broker (mosquitto) and the OCPP CSMS used by the PnC tutorial
# (github.com/EVerest/ocpp-csms, websocket endpoint localhost:9000).
# The CSMS needs the EVerest test PKI to answer ISO15118 CertificateInstallation
# requests, so run 15-build-everest-native.sh (or the docker build) first.
set -euo pipefail

WORK="${EVEREST_WORK:-$HOME/everest-workspace}"
CERTS="${EVEREST_CERTS:-$WORK/build/dist/etc/everest/certs}"

# Shared docker network, per the EVerest quick start guide (IPv6 enabled).
if ! docker network inspect infranet_network &>/dev/null; then
  docker network create --driver bridge --ipv6 --subnet fd00::/80 infranet_network --attachable
fi

# MQTT broker
if ! docker ps --format '{{.Names}}' | grep -q '^mqtt-server$'; then
  docker run -d --name mqtt-server --network infranet_network \
    -p 1883:1883 -p 9001:9001 \
    ghcr.io/everest/everest-dev-environment/mosquitto:docker-images-v0.2.0
fi

# OCPP CSMS (simple central system based on the mobilityhouse/ocpp Python package).
# NOTE: clone with --recurse-submodules - it vendors Josev to build the
# CertificateInstallationResponse.
mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d ocpp-csms/.git ]]; then
  git clone --recurse-submodules https://github.com/EVerest/ocpp-csms.git
fi
cd ocpp-csms
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  ./.venv/bin/pip install -r requirements.txt
fi
if pgrep -f 'central_system.py' >/dev/null; then
  echo "CSMS already running"
else
  nohup ./.venv/bin/python central_system.py --certs "$CERTS" > /tmp/ocpp-csms.log 2>&1 &
  echo "CSMS started on ws://localhost:9000 (certs: $CERTS, log: /tmp/ocpp-csms.log)"
fi

echo "Infra up. MQTT: localhost:1883, CSMS: localhost:9000."
echo "Node-RED: ./run-scripts/nodered-sil.sh from the EVerest build dir (UI http://localhost:1880/ui)."
