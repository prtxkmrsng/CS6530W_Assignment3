#!/usr/bin/env bash
# usage: sudo scripts/collect_peer.sh <TR-x> [capture_seconds]   (run on either gateway; typically B during a fault test)
source "$(dirname "$0")/lib.sh"; need_root; ev_init "${1:?usage: $0 <TR-x> [seconds]}"
S="${2:-0}"
runsh "ip -br addr"
runsh "grep -E 'ike=|esp=|leftsubnet|rightsubnet|left=|right=' /etc/ipsec.conf"
runsh "ipsec statusall"; runsh "$XS"; runsh "$XP"
runsh "$(ike_logs_cmd 10)"
if (( S>0 )); then
  P="$EV/${1//-/}_gw${ROLE}_wan.pcap"; cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  sleep "$S"; cap_stop; runsh "tcpdump -nn -# -v -r $P"
fi
