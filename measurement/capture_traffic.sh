#!/usr/bin/env bash
# capture_traffic.sh - capture ISO 15118 traffic on one testbed interface.
# Usage: sudo ./capture_traffic.sh <iface> <out.pcapng> [seconds]
set -euo pipefail

IFACE="${1:?iface, e.g. br-pnc-a}"
OUT="${2:?output pcapng path}"
SECS="${3:-0}"

# SDP is UDP/15118 (multicast ff02::1); the V2G TCP port is chosen by the SECC
# and announced in the SDP response, so capture all IPv6 TCP as well.
FILTER='ip6 and (udp port 15118 or tcp)'
if [[ "$SECS" == "0" ]]; then
  tcpdump -i "$IFACE" -w "$OUT" -U $FILTER
else
  timeout "$SECS" tcpdump -i "$IFACE" -w "$OUT" -U $FILTER || true
fi
echo "capture written: $OUT"
echo "Decode V2GTP/EXI in Wireshark with the dsV2Gshark dissector (github.com/chargebyte/dsV2Gshark)"
echo "and the TLS key log written next to the attacking processes (ssl-keylog.txt)."
