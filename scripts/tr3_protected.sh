#!/usr/bin/env bash
# TR-3 (Gateway A): protected session + ESP SPI <-> XFRM state correlation. Same flow as TR-1.
source "$(dirname "$0")/lib.sh"; need_root; need_role A; ev_init TR-3
ike_up && child_up || bring_up
P="$EV/tr3_protected.pcap"
runsh "ip -br addr"
cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500
runsh "$(flow_cmd 5)"; prc=$RC
cap_stop
runsh "ipsec statusall"; runsh "$XS"; runsh "$XP"
runsh "tcpdump -nn -# -r $P esp"
native=$(pk "$P" esp); nat=$(pk "$P" udp port 4500)
say "encapsulation: native_ESP(proto50)=$native udp4500=$nat  -> $([[ $native -gt 0 ]] && echo 'native ESP' || echo 'UDP-encapsulated (NAT-T)')"
say "payload_hits_on_transit=$(payload_hits "$P") (expected 0: ESP encrypts inner packet)"
say "=== SPI correlation ==="
for spi in $(tcpdump -nn -r "$P" esp 2>/dev/null | grep -oE 'spi=0x[0-9a-f]+' | sort -u | cut -d= -f2); do
  say "--- captured SPI $spi"
  tcpdump -nn -r "$P" esp 2>/dev/null | grep "spi=$spi" | head -n 2 | tee -a "$LOG"
  ip xfrm state | awk -v s="$spi" '/^src /{if(b~("spi " s))printf "%s",b; b=""} {b=b $0 "\n"} END{if(b~("spi " s))printf "%s",b}' | "$ROOT/scripts/redact.sh" | tee -a "$LOG"
done
(( prc==0 && native+nat>0 )) && ike_up && child_up && result PASS "protected flow; correlate SPIs above" || result FAIL "see log"
