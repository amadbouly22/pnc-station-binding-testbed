#!/usr/bin/env bash
# 05-setup-veth.sh - create two isolated L2 segments on one Linux host so four
# ISO 15118 processes can run side by side, exactly like the relay PoC's
# "two network interfaces" setup:
#
#   br-pnc-a : honest charging station + attacker vehicle   (the "attack site")
#   br-pnc-b : fake charging station + victim vehicle        (the "victim site")
#
# Each bridge is its own IPv6 link-local multicast domain, which is what SDP
# (UDP 15118) needs. tc netem profiles (60-netem-plc.sh) attach to these.
#
# Usage: sudo ./05-setup-veth.sh [--teardown]
set -euo pipefail

BR_A=br-pnc-a
BR_B=br-pnc-b

if [[ "${1:-}" == "--teardown" ]]; then
  ip link del "$BR_A" 2>/dev/null || true
  ip link del "$BR_B" 2>/dev/null || true
  echo "Removed $BR_A and $BR_B"
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "Needs root (creates bridge devices). Re-run with sudo." >&2
  exit 1
fi

# Deterministic link-local address per bridge. A fresh bridge is supposed to
# autoconfigure one, but in practice it does not always happen (the victim
# EVCC died with "Interface br-pnc-b has no link-local address"), so assign
# them explicitly. `ip -6 addr replace` adds-or-replaces, so this is
# idempotent and safe to re-run.
declare -A LLA=( ["$BR_A"]="fe80::1" ["$BR_B"]="fe80::2" )
for BR in "$BR_A" "$BR_B"; do
  if ! ip link show "$BR" &>/dev/null; then
    ip link add name "$BR" type bridge
  fi
  # STP off, multicast on, link up.
  ip link set dev "$BR" type bridge stp_state 0
  ip link set dev "$BR" multicast on
  ip link set dev "$BR" up
  # Speed up IPv6 DAD so the link-local address is usable immediately.
  sysctl -q -w "net.ipv6.conf.$BR.accept_dad=0" || true
  ip -6 addr replace "${LLA[$BR]}/64" dev "$BR"
done

# ISO 15118 SDP uses UDP multicast to ff02::1 on port 15118; make sure the
# firewall does not drop it (this mirrors the EVerest PnC tutorial's fix).
ip6tables -C INPUT -i "$BR_A" -p udp --dport 15118 -j ACCEPT 2>/dev/null || \
  ip6tables -I INPUT -i "$BR_A" -p udp --dport 15118 -j ACCEPT
ip6tables -C INPUT -i "$BR_B" -p udp --dport 15118 -j ACCEPT 2>/dev/null || \
  ip6tables -I INPUT -i "$BR_B" -p udp --dport 15118 -j ACCEPT

echo "Interfaces ready:"
ip -6 addr show dev "$BR_A" | grep -E 'inet6|mtu'
ip -6 addr show dev "$BR_B" | grep -E 'inet6|mtu'
echo
echo "Next: scripts/40-relay-attack-josev.sh uses these as NETWORK_INTERFACE values."
