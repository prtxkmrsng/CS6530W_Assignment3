#!/usr/bin/env bash
# TR-2 (Gateway A): fresh IKEv2 establishment capture. Gateway B must be running with auto=add (no initiation).
source "$(dirname "$0")/lib.sh"; need_root; need_role A; ev_init TR-2
P="$EV/tr2_ike_establish.pcap"
runsh "ipsec down $CONN"; sleep 2
runsh "ipsec statusall"
cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500
runsh "ipsec up $CONN"; sleep 2
runsh "$(flow_cmd 5)"
runsh "ipsec statusall"; runsh "$XS"; runsh "$XP"
runsh "$(ike_logs_cmd 3)"
cap_stop
runsh "tcpdump -nn -# -v -r $P"
if command -v tshark >/dev/null; then
  runsh "tshark -r $P -Y isakmp -T fields -E header=y -e frame.number -e frame.time_relative -e ip.src -e ip.dst -e isakmp.exchtype -e isakmp.messageid -e isakmp.flags"
  runsh "tshark -r $P -Y esp -T fields -E header=y -e frame.number -e ip.src -e ip.dst -e esp.spi -e esp.sequence"
fi
say "native_esp=$(pk "$P" esp) udp500=$(pk "$P" udp port 500) udp4500=$(pk "$P" udp port 4500)"
ike_up && child_up && result PASS "IKE_SA ESTABLISHED + CHILD_SA INSTALLED; cite packet numbers from log/pcap" || result FAIL "tunnel not up"
