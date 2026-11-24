#!/usr/bin/env bash
# 60-netem-plc.sh - apply a network-emulation profile to the testbed
# interfaces with tc netem. The freshness check (defense part 2) is only as
# honest as the latency model underneath it, so every defended-mode run in
# scripts/80-run-experiment-matrix.sh sweeps these profiles.
#
# Usage:
#   sudo ./60-netem-plc.sh --profile plc-typical                 # both bridges
#   sudo ./60-netem-plc.sh --profile relay-cellular --relay-only # backchannel leg
#   sudo ./60-netem-plc.sh --profile off
set -euo pipefail

SCAFFOLD="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES="$SCAFFOLD/configs/plc-latency-profiles.json"

PROFILE=""
RELAY_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --relay-only) RELAY_ONLY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[[ -n "$PROFILE" ]] || { echo "need --profile ($(jq -r '.profiles|keys|join("|")' "$PROFILES"))"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Needs root for tc." >&2; exit 1; }

read -r DELAY JITTER LOSS RATE < <(jq -r ".profiles[\"$PROFILE\"] | \"\(.delay_ms) \(.jitter_ms) \(.loss_pct) \(.rate_mbit)\"" "$PROFILES")
[[ "$DELAY" != "null" ]] || { echo "unknown profile $PROFILE"; exit 1; }

apply() { # iface
  local DEV="$1"
  tc qdisc del dev "$DEV" root 2>/dev/null || true
  [[ "$PROFILE" == "off" ]] && return 0
  local ARGS="delay ${DELAY}ms ${JITTER}ms distribution normal loss random ${LOSS}%"
  [[ "$RATE" != "0" ]] && ARGS="$ARGS rate ${RATE}mbit"
  tc qdisc add dev "$DEV" root netem $ARGS
  echo "$DEV: netem $ARGS"
}

# br-pnc-b carries victim<->fake-station and the shared-dir relay exchange
# happens on the filesystem, so the relay leg's delay is emulated on br-pnc-b
# in relay-only mode; in full mode both segments get the PLC profile.
if [[ $RELAY_ONLY -eq 1 ]]; then
  apply br-pnc-b
else
  apply br-pnc-a
  apply br-pnc-b
fi
