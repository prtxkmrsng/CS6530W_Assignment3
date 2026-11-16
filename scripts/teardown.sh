#!/usr/bin/env bash
# Manual-review gate: prints every command, runs only after typing REVIEWED.
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root

CMDS=(
  "ipsec stop"
  "ip xfrm state flush"
  "ip xfrm policy flush"
  "ip netns del ${HOST_NS:-hostA}"
  "ip link del ${VETH_GW:-vethA-gw}"
  "ip route del ${PEER_NET:-10.2.0.0/24} dev ${WAN_IF:-eth0}"
  "rm -f /etc/sysctl.d/99-cs6530w.conf"
  "rm -f /etc/netplan/99-cs6530w-transit.yaml"
  "rm -f '$ROOT/.role' '$ROOT/.wan_if'"
)

echo "======================================================="
echo "               MANUAL REVIEW REQUIRED                  "
echo " The following commands will remove the lab setup:     "
echo "======================================================="
printf '  %s\n' "${CMDS[@]}"
echo "======================================================="
read -rp "Type REVIEWED to execute: " a
[[ "$a" == "REVIEWED" ]] || { echo "Aborted by user."; exit 1; }

for c in "${CMDS[@]}"; do
  echo "+ $c"
  eval "$c" >/dev/null 2>&1 || true
done
echo "Teardown complete."
