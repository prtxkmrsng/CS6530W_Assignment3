#!/usr/bin/env bash
# usage: sudo scripts/fault.sh <ike|psk|esp|ts> [--no-pause]    (Gateway A only; Gateway B stays healthy)
#   ike = TR-4 A:ike=aes128-sha256-modp2048!   psk = TR-5 A:PSK+"-FAULT"
#   esp = TR-6 A:esp=aes128-sha1!              ts  = TR-7 A:rightsubnet=10.3.0.0/24
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; need_role A

TARGET="${1:-}"
case "$TARGET" in
  ike) TR=TR-4; FAULT_DESC="IKE proposal mismatch"; FAULT_VAR="IKE_PROP=aes128-sha256-modp2048!";;
  psk) TR=TR-5; FAULT_DESC="PSK secret mismatch";   FAULT_VAR="PSK_SUFFIX=-FAULT";;
  esp) TR=TR-6; FAULT_DESC="ESP proposal mismatch"; FAULT_VAR="ESP_PROP=aes128-sha1!";;
  ts)  TR=TR-7; FAULT_DESC="Traffic selector (subnet) mismatch"; FAULT_VAR="REMOTE_SUBNET=10.3.0.0/24";;
  *) die "usage: $0 <ike|psk|esp|ts> [--no-pause]";;
esac

PAUSE=1
[[ "${2:-}" == "--no-pause" ]] && PAUSE=0
ev_init "$TR"
f="${TR//-/}"
f="${f,,}"

say "=========================================================="
say " Starting $TR: $FAULT_DESC"
say "=========================================================="

say "##### PHASE 1: healthy baseline verification"
"$ROOT/scripts/render_config.sh"
ipsec_restart
bring_up || true

if ! verify_protected "${f}_pre_healthy"; then
  say "ERROR: Baseline healthy tunnel verification failed before fault injection."
  say "Troubleshooting tips:"
  say "  1. Ensure Gateway B is running and healthy: run 'sudo scripts/restore.sh' on Gateway B."
  say "  2. Test transit ping to Gateway B: ping -c 2 $PEER_WAN"
  say "  3. Check charon status on Gateway B: sudo ipsec statusall"
  die "baseline not healthy; fix before fault injection"
fi

runsh "ipsec down $CONN"
sleep 2

say "##### PHASE 2: inject fault on GW-A only ($FAULT_VAR)"
eval "export $FAULT_VAR"
"$ROOT/scripts/render_config.sh"
unset "${FAULT_VAR%%=*}"

runsh "grep -E 'ike=|esp=|leftsubnet|rightsubnet' /etc/ipsec.conf"
ipsec_restart

P="$EV/${f}_fault.pcap"
cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
runsh "timeout 60 ipsec up $CONN" || true
sleep 3

runsh "ipsec statusall"
runsh "$XS"
runsh "$XP"
runsh "$(flow_cmd 5)"; prc=$RC
runsh "$(ike_logs_cmd 3)"
cap_stop

runsh "tcpdump -nn -# -v -r $P"

ik=0; ch=0
ike_up && ik=1
child_up && ch=1

esp=$(pk "$P" esp)
nat=$(pk "$P" udp port 4500)
icmp=$(pk "$P" icmp)
ph=$(payload_hits "$P")

say "SUMMARY[$TR]: IKE_SA_established=$ik CHILD_SA_installed=$ch ping_rc=$prc native_esp=$esp udp4500=$nat plaintext_icmp_on_wan=$icmp payload_hits_on_wan=$ph"
say "connectivity=$([[ $prc -eq 0 ]] && echo reachable || echo unreachable)  protection=$([[ $((esp+nat)) -gt 0 && $icmp -eq 0 ]] && echo ESP-protected || echo NOT-protected)"

echo
say ">>> Peer evidence step:"
say "    Now run on Gateway B:  sudo scripts/collect_peer.sh $TR"
if (( PAUSE )); then
  read -rp "Press Enter after Gateway B evidence is collected to restore healthy configuration... " _
fi

say "##### PHASE 3: restore known-good configuration + verify"
"$ROOT/scripts/render_config.sh"
ipsec_restart
bring_up || true
verify_protected "${f}_restored"
