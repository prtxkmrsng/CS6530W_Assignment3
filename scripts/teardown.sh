#!/usr/bin/env bash
# Manual-review gate: prints every command, runs only after typing REVIEWED.
source "$(dirname "$0")/lib.sh"; need_root
CMDS=(
  "ipsec stop"
  "ip netns del $HOST_NS"
  "ip link del $VETH_GW"
  "ip route del $PEER_NET"
  "rm -f /etc/sysctl.d/99-cs6530w.conf"
)
echo "=============== MANUAL REVIEW REQUIRED ==============="
printf '  %s\n' "${CMDS[@]}"
echo "======================================================="
read -rp "Type REVIEWED to execute: " a
[[ "$a" == REVIEWED ]] || { echo "aborted"; exit 1; }
for c in "${CMDS[@]}"; do echo "+ $c"; bash -c "$c" || true; done
