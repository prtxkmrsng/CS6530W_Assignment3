#!/usr/bin/env bash
# TR-3 (Gateway A): protected session + ESP SPI <-> XFRM state correlation. Same flow as TR-1.
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; need_role A; ev_init TR-3

ike_up && child_up || bring_up

P="$EV/tr3_protected.pcap"
runsh "ip -br addr"
cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500
runsh "$(flow_cmd 5)"; prc=$RC
cap_stop

runsh "ipsec statusall"
runsh "$XS"
runsh "$XP"
if [[ -f "$P" ]]; then
  chmod 666 "$P" 2>/dev/null || chmod 644 "$P" 2>/dev/null || true
fi

if [[ -s "$P" && -r "$P" ]]; then
  runsh "tcpdump -nn -# -r $P esp"
fi

native=$(pk "$P" esp)
nat=$(pk "$P" udp port 4500)
ph=$(payload_hits "$P")

say "encapsulation: native_ESP(proto50)=$native udp4500=$nat  -> $([[ $native -gt 0 ]] && echo 'native ESP' || echo 'UDP-encapsulated (NAT-T)')"
say "payload_hits_on_transit=$ph (expected 0: ESP encrypts inner packet)"
say "=== SPI correlation ==="

# Collect all SPIs from both captured packets and active XFRM states
if [[ -s "$P" && -r "$P" ]]; then
  SPIS=$( (tcpdump -nn -r "$P" "esp or udp port 4500" 2>/dev/null | grep -oEi 'spi=0x[0-9a-f]+' | cut -d= -f2; ip xfrm state 2>/dev/null | grep -oEi 'spi 0x[0-9a-f]+' | awk '{print $2}') | tr '[:upper:]' '[:lower:]' | sort -u )
else
  SPIS=$(ip xfrm state 2>/dev/null | grep -oEi 'spi 0x[0-9a-f]+' | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | sort -u)
fi

for spi in $SPIS; do
  [[ -n "$spi" ]] || continue
  say "--- SPI $spi"
  if [[ -s "$P" && -r "$P" ]]; then
    tcpdump -nn -r "$P" 2>/dev/null | grep -i "spi=$spi" | head -n 2 | tee -a "$LOG" || true
  fi
  ip xfrm state 2>/dev/null | awk -v s="$spi" 'BEGIN{IGNORECASE=1} /^src /{if(tolower(b) ~ ("spi " s)) printf "%s",b; b=""} {b=b $0 "\n"} END{if(tolower(b) ~ ("spi " s)) printf "%s",b}' | "$ROOT/scripts/redact.sh" | tee -a "$LOG"
done

if (( prc==0 && (native+nat)>0 && ph==0 )) && ike_up && child_up; then
  result PASS "protected flow; correlate SPIs above"
else
  result FAIL "see log"
fi
