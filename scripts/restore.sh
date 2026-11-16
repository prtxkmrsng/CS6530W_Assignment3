#!/usr/bin/env bash
# Restore known-good config on this gateway and verify (FR-8).
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; ev_init "${1:-RESTORE}"

say "Restoring known-good configuration on GW-$ROLE..."
"$ROOT/scripts/render_config.sh"

# Ensure kernel forwarding and rp_filter are active
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
[[ -n "$WAN_IF" ]] && sysctl -w "net.ipv4.conf.$WAN_IF.rp_filter=0" >/dev/null 2>&1 || true
[[ -n "$VETH_GW" ]] && sysctl -w "net.ipv4.conf.$VETH_GW.rp_filter=0" >/dev/null 2>&1 || true

# Ensure plaintext route to peer protected subnet is present
ip route replace "$PEER_NET" via "$PEER_WAN" dev "$WAN_IF" >/dev/null 2>&1 || true

ipsec_restart
bring_up || true

verify_protected "restore_$(date +%H%M%S)"
