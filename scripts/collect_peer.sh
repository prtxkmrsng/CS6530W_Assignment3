#!/usr/bin/env bash
# usage: sudo scripts/collect_peer.sh <TR-x> [capture_seconds]   (run on either gateway; typically B during a fault test)
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root

TR_NAME="${1:-}"
[[ -n "$TR_NAME" ]] || die "usage: $0 <TR-x> [capture_seconds]"

ev_init "$TR_NAME"
S="${2:-0}"

say "=========================================================="
say " Collecting peer evidence on GW-$ROLE for $TR_NAME"
say "=========================================================="

runsh "ip -br addr"
runsh "grep -E 'ike=|esp=|leftsubnet|rightsubnet|left=|right=' /etc/ipsec.conf"
runsh "ipsec statusall"
runsh "$XS"
runsh "$XP"
runsh "$(ike_logs_cmd 10)"

if (( S > 0 )); then
  P="$EV/${TR_NAME//-/}_gw${ROLE}_wan.pcap"
  say "Capturing $S seconds on $WAN_IF..."
  cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  sleep "$S"
  cap_stop
  if [[ -f "$P" ]]; then
    chmod 666 "$P" 2>/dev/null || chmod 644 "$P" 2>/dev/null || true
  fi
  if [[ -s "$P" && -r "$P" ]]; then
    runsh "tcpdump -nn -# -v -r $P"
  fi
fi

say "Peer evidence collected in $EV/${TR_NAME}_gw${ROLE}.log"
