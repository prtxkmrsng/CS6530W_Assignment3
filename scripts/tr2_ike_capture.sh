#!/usr/bin/env bash
# TR-2 (Gateway A): fresh IKEv2 establishment capture. Gateway B must be running with auto=add (no initiation).
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; need_role A; ev_init TR-2

P="$EV/tr2_ike_establish.pcap"

# Ensure fresh state
runsh "ipsec down $CONN"
sleep 2
ip xfrm state flush >/dev/null 2>&1 || true
runsh "ipsec statusall"

# Capture initiation and subsequent traffic
cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500
runsh "ipsec up $CONN"
sleep 2
runsh "$(flow_cmd 5)"
runsh "ipsec statusall"
runsh "$XS"
runsh "$XP"
runsh "$(ike_logs_cmd 3)"
cap_stop

if [[ -s "$P" ]]; then
  runsh "tcpdump -nn -# -v -r $P"
fi
if command -v tshark >/dev/null 2>&1; then
  runsh "tshark -r $P -Y isakmp -T fields -E header=y -e frame.number -e frame.time_relative -e ip.src -e ip.dst -e isakmp.exchtype -e isakmp.messageid -e isakmp.flags"
  runsh "tshark -r $P -Y esp -T fields -E header=y -e frame.number -e ip.src -e ip.dst -e esp.spi -e esp.sequence"
fi

say "native_esp=$(pk "$P" esp) udp500=$(pk "$P" udp port 500) udp4500=$(pk "$P" udp port 4500)"

if ike_up && child_up; then
  result PASS "IKE_SA ESTABLISHED + CHILD_SA INSTALLED; cite packet numbers from log/pcap"
else
  say "DIAGNOSIS: Tunnel failed to establish. Check charon logs above."
  say "  Ensure Gateway B is running: sudo ipsec statusall"
  result FAIL "tunnel not up"
fi
