#!/usr/bin/env bash
# TR-1 (Gateway A): plaintext baseline with IPsec inactive.
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; need_role A; ev_init TR-1

# Ensure IPsec is stopped and XFRM states/policies are cleared for pure plaintext baseline
runsh "ipsec down $CONN"
ip xfrm state flush >/dev/null 2>&1 || true
ip xfrm policy flush >/dev/null 2>&1 || true

# Ensure plaintext route to peer protected subnet is present
ip route replace "$PEER_NET" via "$PEER_WAN" dev "$WAN_IF" >/dev/null 2>&1 || true

runsh "ip -br addr"
runsh "ip route"
runsh "sysctl net.ipv4.ip_forward"
runsh "ip netns exec $HOST_NS ip -br addr"
runsh "$XS"
runsh "$XP"

P="$EV/tr1_plaintext.pcap"
say "WAN_IF=$WAN_IF payload_hex=$PAYLOAD_HEX"
cap_start "$P" "$WAN_IF" icmp
runsh "$(flow_cmd 5)"; prc=$RC
cap_stop

runsh "tcpdump -nn -# -r $P"
runsh "tcpdump -nn -A -r $P | grep -m3 -n -- $ROLL_GREP"

n=$(pk "$P" icmp)
h=$(payload_hits "$P")
x=$(ip xfrm state 2>/dev/null | grep -c '^src' || true)
inner=$(tcpdump -nn -r "$P" icmp 2>/dev/null | grep -c "$HOST_IP > $PEER_HOST" || true)

say "ping_rc=$prc icmp_pkts=$n inner_matches=$inner payload_hits=$h xfrm_states=$x"

if (( prc==0 && n>0 && inner>0 && h>0 && x==0 )); then
  result PASS "plaintext inner addrs+payload visible on transit; no XFRM state"
else
  if [[ $prc -ne 0 ]]; then
    say "DIAGNOSIS: Ping between hostA ($HOST_IP) and hostB ($PEER_HOST) failed."
    say "  Check if Gateway B ($PEER_WAN) is running and has run: sudo scripts/01_setup_gateway.sh B"
    say "  Check if Gateway A can ping Gateway B transit IP: ping -c 2 $PEER_WAN"
  fi
  result FAIL "see log"
fi
