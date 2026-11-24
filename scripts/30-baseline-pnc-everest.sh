#!/usr/bin/env bash
# 30-baseline-pnc-everest.sh - run the EVerest Plug&Charge software-in-the-loop
# baseline and capture clean traces (outline Phase 1).
#
# Follows the EVerest PnC tutorial (manual 2026.10.0-rc3):
#   ./run-scripts/run-sil-ocpp201-pnc.sh   (OCPP 2.0.1; endpoint localhost:9000)
#   or ./run-scripts/run-sil-ocpp-pnc.sh   (OCPP 1.6; point its config at 9000)
# then in Node-RED (http://localhost:1880/ui) choose "AC ISO 15118-2" in the Car
# Simulation dropdown and press "Car Plugin".
set -euo pipefail

WORK="${EVEREST_WORK:-$HOME/everest-workspace}"
BUILD="$WORK/build"
OUT="$(cd "$(dirname "$0")/.." && pwd)/results/baseline-everest/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

cd "$BUILD"
echo "==============================================================="
echo "IMPORTANT:"
echo "  * Do NOT press Enter in this window until the charging session"
echo "    has actually finished - pressing Enter stops EVerest and"
echo "    collects the artifacts immediately."
echo "  * Every command goes in this Linux/WSL window, never in"
echo "    PowerShell. If you are in PowerShell, type 'wsl' first."
echo "==============================================================="
echo "Starting EVerest SIL PnC (OCPP 2.0.1). Logs -> $OUT/everest.log"
script -q -c './run-scripts/run-sil-ocpp201-pnc.sh' "$OUT/everest.log" &
EV_PID=$!

sleep 10
echo
echo ">>> In a second terminal: cd $BUILD && ./run-scripts/nodered-sil.sh"
echo ">>> Open http://localhost:1880/ui, select 'AC ISO 15118-2' in the Car"
echo ">>> Simulation dropdown and click 'Car Plugin' to start Plug&Charge."
echo ">>> OCPP logs land in /tmp/everest_ocpp_logs, session XML logs in the path"
echo ">>> given by the config (default /tmp/everest-logs)."
echo
echo "Capture the HLC traffic in a third terminal:"
echo "  sudo ../path/to/pnc-testbed/measurement/capture_traffic.sh <iface> $OUT/baseline.pcapng"
echo
echo "Press Enter here ONLY AFTER the session finished (ChargeLoop reached) -"
echo "Enter stops EVerest and collects artifacts."
read -r
kill $EV_PID 2>/dev/null || true
pkill -f 'manager --conf' 2>/dev/null || true

# Collect logs
[[ -d /tmp/everest_ocpp_logs ]] && cp -r /tmp/everest_ocpp_logs "$OUT/" || true
[[ -d /tmp/everest-logs ]] && cp -r /tmp/everest-logs "$OUT/" || true
echo "Baseline artifacts collected in $OUT"
