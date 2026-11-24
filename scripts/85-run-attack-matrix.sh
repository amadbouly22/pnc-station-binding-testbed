#!/usr/bin/env bash
# 85-run-attack-matrix.sh - attack-scenario extension of 80-run-experiment-matrix.sh.
# For every MODE x SCENARIO it runs N relay-attack attempts using the exact
# scripts/40 topology (four processes, two bridges) and stores the four
# participant logs per run.
#
#   MODE      baseline : DEFENDED=0 (patched honest stack, defense off).
#                        The relay attack should succeed.
#             defended : DEFENDED=1. The honest station should reject the
#                        relayed signature (FAILED_SignatureError, digest
#                        mismatch on 'stationBinding').
#   SCENARIO  one of the netem profiles in configs/plc-latency-profiles.json
#
# Per-run outcome is classified from the logs by pnc_reparse.py:
#   attack_succeeded  attacker EVCC reached ChargeParameterDiscovery against
#                     the honest station (scripts/40's own success criterion)
#   attack_blocked    honest SECC rejected the relayed Authorization
#   incomplete        neither happened within the per-run time bound
#
# Usage: sudo scripts/85-run-attack-matrix.sh [--runs 50] [--timeout 45]
#           [--modes baseline,defended] [--scenarios plc-clean,plc-typical,plc-noisy]
#
# Prereqs (already done on this machine if the single attack runs worked):
#   * scripts/40-relay-attack-josev.sh has run at least once (stacks, venvs
#     and the test PKI exist under /root/pnc-relay when invoked with sudo,
#     or under $PNC_RELAY_DIR)
#   * sudo scripts/05-setup-veth.sh has created br-pnc-a and br-pnc-b
#
# Launch lines mirror scripts/40 EXACTLY, including per-side PKI_PATH: the
# venv-installed package's default PKI_PATH points into site-packages where
# no certificates exist, and without it the honest SECC silently falls back
# to plain TCP, refuses PNC, and every run ends with no outcome.
set -euo pipefail

SCAFFOLD="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=50
MODES="baseline,defended"
SCENARIOS="plc-clean,plc-typical,plc-noisy"
TIMEOUT="${ATTACK_TIMEOUT:-45}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2;;
    --modes) MODES="$2"; shift 2;;
    --scenarios) SCENARIOS="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo (tc netem and the root-owned workdir need root)." >&2; exit 1; }

WORK="${PNC_RELAY_DIR:-$HOME/pnc-relay}"
[[ -x "$WORK/venv-honest/bin/python" && -x "$WORK/venv-poc/bin/python" ]] || {
  echo "Missing stacks under $WORK - run sudo scripts/40-relay-attack-josev.sh once first." >&2
  exit 1
}
ip link show br-pnc-a >/dev/null 2>&1 && ip link show br-pnc-b >/dev/null 2>&1 || {
  echo "Missing br-pnc-a/br-pnc-b - run sudo scripts/05-setup-veth.sh first." >&2
  exit 1
}

# Leftover SECC/EVCC processes from earlier sessions hold the bridge ports
# and silently break new runs. Clear any before starting (none should exist
# while no other testbed script is running).
pkill -f 'iso15118/secc/main.py' 2>/dev/null || true
pkill -f 'iso15118/evcc/main.py' 2>/dev/null || true
pkill -f 'iso15118\.secc\.main' 2>/dev/null || true
pkill -f 'iso15118\.evcc\.main' 2>/dev/null || true
sleep 1

OUT="$SCAFFOLD/results/matrix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
{
  echo "Attack matrix: $(date -Is)"
  echo "modes: baseline = DEFENDED=0, defended = DEFENDED=1"
  echo "       (same patched honest stack, josev 676b315 + stationBinding patch;"
  echo "        DEFENDED only gates the defense, as in scripts/80)"
  echo "runs per mode x scenario cell: $RUNS"
  echo "per-run time bound: ${TIMEOUT}s"
  echo "workdir: $WORK"
  echo "success criterion: attacker EVCC reaches ChargeParameterDiscovery"
  echo "(identical to scripts/40-relay-attack-josev.sh)"
} > "$OUT/README.txt"

cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
  "$SCAFFOLD/scripts/60-netem-plc.sh" --profile off >/dev/null 2>&1 || true
}
trap cleanup EXIT

# One relay-attack attempt, bounded. Launch commands mirror
# scripts/40-relay-attack-josev.sh exactly (same CWDs, same env); only the
# DEFENDED flag and the per-run log destination differ. DEFENDED is exported
# for the whole run, as in the validated single runs (sudo DEFENDED=1 ...).
PKI_HONEST="$WORK/honest/iso15118/shared/pki"
PKI_POC="$WORK/poc/iso15118/shared/pki"
[[ -f "$PKI_HONEST/iso15118_2/certs/v2gRootCACert.pem" || -d "$PKI_HONEST/iso15118_2" ]] || {
  echo "Missing test PKI under $PKI_HONEST - run sudo scripts/40-relay-attack-josev.sh once first." >&2
  exit 1
}

run_attack() {
  local run_dir="$1" defended="$2"
  local shared="$WORK/shared"
  rm -rf "$shared" && mkdir -p "$shared"
  export DEFENDED="$defended"

  ( cd "$WORK/honest" && exec env NETWORK_INTERFACE=br-pnc-a AUTH_MODES=PNC \
      PKI_PATH="$PKI_HONEST" \
      "$WORK/venv-honest/bin/python" iso15118/secc/main.py ) > "$run_dir/secc-honest.log" 2>&1 &
  local secc_honest_pid=$!
  ( cd "$shared" && exec env NETWORK_INTERFACE=br-pnc-b AUTH_MODES=PNC \
      PKI_PATH="$PKI_POC" \
      "$WORK/venv-poc/bin/python" -m iso15118.secc.main ) > "$run_dir/secc-fake.log" 2>&1 &
  local secc_fake_pid=$!
  sleep 3   # let both stations come up and start answering SDP
  ( cd "$WORK/honest" && exec env NETWORK_INTERFACE=br-pnc-b \
      EVCC_CONFIG_PATH="$WORK/honest/evcc_config_pnc.json" PKI_PATH="$PKI_HONEST" \
      "$WORK/venv-honest/bin/python" iso15118/evcc/main.py ) > "$run_dir/evcc-victim.log" 2>&1 &
  local evcc_victim_pid=$!
  ( cd "$shared" && exec env NETWORK_INTERFACE=br-pnc-a \
      EVCC_CONFIG_PATH="$WORK/poc/evcc_config_pnc.json" PKI_PATH="$PKI_POC" \
      "$WORK/venv-poc/bin/python" -m iso15118.evcc.main ) > "$run_dir/evcc-attacker.log" 2>&1 &
  local evcc_attacker_pid=$!

  local elapsed=0
  while (( elapsed < TIMEOUT )); do
    if grep -q 'ChargeParameterDiscovery\|PowerDeliveryReq' "$run_dir/evcc-attacker.log" 2>/dev/null; then
      sleep 2   # let the session logs flush
      break     # attacker reached a paid session
    fi
    if grep -q 'FAILED_SignatureError\|Digest mismatch' "$run_dir/secc-honest.log" 2>/dev/null; then
      sleep 5   # let the rejection flush to the logs
      break     # defense rejected the relayed signature
    fi
    sleep 1
    (( elapsed += 1 ))
  done
  (( elapsed >= TIMEOUT )) && \
    echo "run hit the ${TIMEOUT}s bound, processes killed" >> "$run_dir/evcc-attacker.log"

  kill "$evcc_attacker_pid" "$evcc_victim_pid" "$secc_fake_pid" "$secc_honest_pid" 2>/dev/null || true
  wait "$evcc_attacker_pid" "$evcc_victim_pid" "$secc_fake_pid" "$secc_honest_pid" 2>/dev/null || true
  sleep 2   # let sockets release before the next run
  unset DEFENDED

  if grep -q 'ChargeParameterDiscovery\|PowerDeliveryReq' "$run_dir/evcc-attacker.log" 2>/dev/null; then
    echo "    $(basename "$run_dir"): attack SUCCEEDED"
  elif grep -q 'FAILED_SignatureError\|Digest mismatch' "$run_dir/secc-honest.log" 2>/dev/null; then
    echo "    $(basename "$run_dir"): attack BLOCKED"
  else
    echo "    $(basename "$run_dir"): incomplete (no outcome within ${TIMEOUT}s)"
    local err
    err=$(grep -m1 -h 'Traceback\|ERROR' "$run_dir"/*.log 2>/dev/null | head -c 160)
    [[ -n "$err" ]] && echo "      first error: $err"
  fi
}

IFS=',' read -ra MODE_ARR <<< "$MODES"
IFS=',' read -ra SCEN_ARR <<< "$SCENARIOS"

echo "Attack matrix: $OUT"
for MODE in "${MODE_ARR[@]}"; do
  for SCEN in "${SCEN_ARR[@]}"; do
    DEFENDED_VAL=0
    [[ "$MODE" == defended ]] && DEFENDED_VAL=1
    echo "=== mode=$MODE (DEFENDED=$DEFENDED_VAL) scenario=$SCEN runs=$RUNS"
    "$SCAFFOLD/scripts/60-netem-plc.sh" --profile "$SCEN"
    for i in $(seq 1 "$RUNS"); do
      RUN_DIR="$OUT/$MODE/$SCEN/run-$i"
      mkdir -p "$RUN_DIR"
      run_attack "$RUN_DIR" "$DEFENDED_VAL"
    done
  done
done

"$SCAFFOLD/scripts/60-netem-plc.sh" --profile off
echo
echo "Matrix complete: $OUT"
echo "Next, build the report (copy this line exactly):"
echo "  sudo python3 /home/amadbouly/pnc_reparse.py $OUT"
