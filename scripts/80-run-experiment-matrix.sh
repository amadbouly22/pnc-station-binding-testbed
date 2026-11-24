#!/usr/bin/env bash
# 80-run-experiment-matrix.sh - the measurement harness. For every combination
# of MODE x SCENARIO it runs N Plug&Charge handshakes and stores logs + pcaps
# in results/, then produces the CSVs the paper's evaluation section needs.
#
#   MODE      baseline  : unmodified josev pair (direct connection)
#             attack    : relay attack running (scripts/40 topology)
#             defended  : josev pair with the defense prototype applied
#                         (defense/README.md describes the patch application)
#   SCENARIO  one of the netem profiles in configs/plc-latency-profiles.json
#
# Usage: sudo ./80-run-experiment-matrix.sh [--runs 50] [--modes baseline,defended] [--scenarios plc-clean,plc-typical,plc-noisy]
#
# Per-run bound: each handshake gets at most RUN_TIMEOUT seconds (default 90)
# before both processes are killed, so a hung run can never stall the matrix.
set -euo pipefail

SCAFFOLD="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=50
MODES="baseline,defended"
SCENARIOS="plc-clean,plc-typical,plc-noisy"
RUN_TIMEOUT="${RUN_TIMEOUT:-90}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2;;
    --modes) MODES="$2"; shift 2;;
    --scenarios) SCENARIOS="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 1;;
  esac
done

OUT="$SCAFFOLD/results/matrix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

WORK="${PNC_RELAY_DIR:-$HOME/pnc-relay}"
HONEST="$WORK/honest"
PY="$WORK/venv-honest/bin/python"
PKI_PATH_VALUE="$HONEST/iso15118/shared/pki"

# One direct SECC/EVCC handshake, bounded. The SECC server never exits on its
# own after one session, so it is killed once the EVCC session finishes
# (PowerDelivery/SessionStop seen, or the EVCC exits) or RUN_TIMEOUT hits.
run_pair() {
  local run_dir="$1" defended="$2"
  (
    cd "$HONEST"
    export PKI_PATH="$PKI_PATH_VALUE"
    export DEFENDED="$defended"
    NETWORK_INTERFACE=br-pnc-a AUTH_MODES=PNC \
      "$PY" iso15118/secc/main.py > "$run_dir/secc.log" 2>&1 &
    local secc_pid=$!
    sleep 2
    NETWORK_INTERFACE=br-pnc-a \
      EVCC_CONFIG_PATH="$HONEST/evcc_config_pnc.json" \
      "$PY" iso15118/evcc/main.py > "$run_dir/evcc.log" 2>&1 &
    local evcc_pid=$!

    local elapsed=0
    while (( elapsed < RUN_TIMEOUT )); do
      if ! kill -0 "$evcc_pid" 2>/dev/null; then
        break   # EVCC exited on its own
      fi
      if grep -q 'PowerDeliveryRes\|SessionStopRes' "$run_dir/evcc.log" 2>/dev/null; then
        sleep 1   # let the log flush
        break
      fi
      sleep 1
      (( elapsed += 1 ))
    done
    (( elapsed >= RUN_TIMEOUT )) && \
      echo "run hit the ${RUN_TIMEOUT}s bound, processes killed" >> "$run_dir/evcc.log"

    kill "$evcc_pid" "$secc_pid" 2>/dev/null || true
    wait "$evcc_pid" 2>/dev/null || true
    wait "$secc_pid" 2>/dev/null || true
  )
}

IFS=',' read -ra MODE_ARR <<< "$MODES"
IFS=',' read -ra SCEN_ARR <<< "$SCENARIOS"

for MODE in "${MODE_ARR[@]}"; do
  for SCEN in "${SCEN_ARR[@]}"; do
    echo "=== mode=$MODE scenario=$SCEN runs=$RUNS"
    "$SCAFFOLD/scripts/60-netem-plc.sh" --profile "$SCEN"
    for i in $(seq 1 "$RUNS"); do
      RUN_DIR="$OUT/$MODE/$SCEN/run-$i"
      mkdir -p "$RUN_DIR"
      case "$MODE" in
        baseline|defended)
          DEFENDED_VAL=0
          [[ "$MODE" == defended ]] && DEFENDED_VAL=1
          # The defense patch is gated on the DEFENDED env var (see
          # defense/README.md), so the same honest stack serves both modes.
          run_pair "$RUN_DIR" "$DEFENDED_VAL"
          ;;
        attack)
          "$SCAFFOLD/scripts/40-relay-attack-josev.sh" "$WORK" > "$RUN_DIR/attack.log" 2>&1 || true
          cp -r "$WORK/shared"/* "$RUN_DIR/" 2>/dev/null || true
          ;;
      esac
      [[ $((i % 10)) -eq 0 ]] && echo "  ... $i/$RUNS"
    done
  done
done

"$SCAFFOLD/scripts/60-netem-plc.sh" --profile off
python3 "$SCAFFOLD/measurement/parse_logs.py" --matrix "$OUT" --csv "$OUT/summary.csv"
python3 "$SCAFFOLD/measurement/latency_analysis.py" --csv "$OUT/summary.csv" --out "$OUT/report"
echo "Matrix complete: $OUT (summary.csv + report/)"
