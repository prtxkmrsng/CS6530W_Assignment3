#!/usr/bin/env bash
# TR-8. Gateway A: sends flow, captures protected-side + WAN. Gateway B (optional): run FIRST with a duration, captures both interfaces.
#   A: sudo scripts/tr8_boundary.sh            B: sudo scripts/tr8_boundary.sh 40
source "$(dirname "$0")/lib.sh"; need_root; ev_init TR-8
LANP="$EV/tr8_gw${ROLE}_protected_side.pcap"; WANP="$EV/tr8_gw${ROLE}_transit.pcap"
if [[ "$ROLE" == A ]]; then
  ike_up && child_up || bring_up
  cap_start "$LANP" "$VETH_GW" icmp
  cap_start "$WANP" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  runsh "$(flow_cmd 5)"; prc=$RC
  cap_stop
else
  D="${1:-40}"
  cap_start "$LANP" "$VETH_GW" icmp
  cap_start "$WANP" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  say "capturing ${D}s on GW-B; start TR-8 on GW-A now"; sleep "$D"; cap_stop
fi
for X in "$LANP:protected-side($VETH_GW)" "$WANP:transit($WAN_IF)"; do
  f="${X%%:*}"; n="${X#*:}"
  say "===== $n  $f"
  runsh "tcpdump -nn -# -r $f"
  say "icmp_pkts=$(pk "$f" icmp) esp_pkts=$(pk "$f" esp) udp4500=$(pk "$f" udp port 4500) payload_visible_hits=$(payload_hits "$f")"
done
runsh "ipsec statusall"
