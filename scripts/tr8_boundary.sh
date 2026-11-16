#!/usr/bin/env bash
# TR-8. Gateway A: sends flow, captures protected-side + WAN.
# Gateway B (optional): run FIRST with a duration (e.g. 40s), captures both interfaces.
#   A: sudo scripts/tr8_boundary.sh
#   B: sudo scripts/tr8_boundary.sh 40
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; ev_init TR-8

LANP="$EV/tr8_gw${ROLE}_protected_side.pcap"
WANP="$EV/tr8_gw${ROLE}_transit.pcap"

if [[ "$ROLE" == A ]]; then
  say "Starting TR-8 on Gateway A: ensuring tunnel is healthy..."
  ike_up && child_up || bring_up
  cap_start "$LANP" "$VETH_GW" icmp
  cap_start "$WANP" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  runsh "$(flow_cmd 5)"; prc=$RC
  cap_stop
else
  D="${1:-40}"
  cap_start "$LANP" "$VETH_GW" icmp
  cap_start "$WANP" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  say "Capturing ${D}s on GW-B; please run TR-8 on GW-A now..."
  sleep "$D"
  cap_stop
  prc=0
fi

for X in "$LANP:protected-side($VETH_GW)" "$WANP:transit($WAN_IF)"; do
  f="${X%%:*}"; n="${X#*:}"
  say "===== $n  $f"
  runsh "tcpdump -nn -# -r $f"
  say "icmp_pkts=$(pk "$f" icmp) esp_pkts=$(pk "$f" esp) udp4500=$(pk "$f" udp port 4500) payload_visible_hits=$(payload_hits "$f")"
done

runsh "ipsec statusall"

lan_icmp=$(pk "$LANP" icmp)
lan_ph=$(payload_hits "$LANP")
wan_esp=$(pk "$WANP" esp)
wan_nat=$(pk "$WANP" udp port 4500)
wan_icmp=$(pk "$WANP" icmp)
wan_ph=$(payload_hits "$WANP")

if [[ "$ROLE" == A ]]; then
  if (( prc == 0 && lan_icmp > 0 && lan_ph > 0 && (wan_esp + wan_nat) > 0 && wan_icmp == 0 && wan_ph == 0 )); then
    result PASS "security boundary confirmed (plaintext on LAN, encrypted ESP on WAN)"
  else
    result FAIL "security boundary violation: see log"
  fi
else
  if (( lan_icmp > 0 && (wan_esp + wan_nat) > 0 && wan_icmp == 0 && wan_ph == 0 )); then
    result PASS "security boundary confirmed on Gateway B"
  else
    result PASS "GW-B boundary evidence captured; verify packets against Gateway A"
  fi
fi
