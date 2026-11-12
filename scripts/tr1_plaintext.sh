#!/usr/bin/env bash
# TR-1 (Gateway A): plaintext baseline with IPsec inactive.
source "$(dirname "$0")/lib.sh"; need_root; need_role A; ev_init TR-1
runsh "ipsec down $CONN"
runsh "ip -br addr"
runsh "ip route"
runsh "sysctl net.ipv4.ip_forward"
runsh "ip netns exec $HOST_NS ip -br addr"
runsh "$XS"; runsh "$XP"
P="$EV/tr1_plaintext.pcap"
say "WAN_IF=$WAN_IF payload_hex=$PAYLOAD_HEX"
cap_start "$P" "$WAN_IF" icmp
runsh "$(flow_cmd 5)"; prc=$RC
cap_stop
runsh "tcpdump -nn -# -r $P"
runsh "tcpdump -nn -A -r $P | grep -m3 -n -- $ROLL_GREP"
n=$(pk "$P" icmp); h=$(payload_hits "$P"); x=$(ip xfrm state | grep -c '^src')
inner=$(tcpdump -nn -r "$P" icmp 2>/dev/null | grep -c "$HOST_IP > $PEER_HOST")
say "ping_rc=$prc icmp_pkts=$n inner_matches=$inner payload_hits=$h xfrm_states=$x"
(( prc==0 && n>0 && inner>0 && h>0 && x==0 )) && result PASS "plaintext inner addrs+payload visible on transit; no XFRM state" || result FAIL "see log"
