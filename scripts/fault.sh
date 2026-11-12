#!/usr/bin/env bash
# usage: sudo scripts/fault.sh <ike|psk|esp|ts> [--no-pause]    (Gateway A only; Gateway B stays healthy)
#   ike = TR-4 A:ike=aes128-sha256-modp2048!   psk = TR-5 A:PSK+"-FAULT"
#   esp = TR-6 A:esp=aes128-sha1!              ts  = TR-7 A:rightsubnet=10.3.0.0/24
source "$(dirname "$0")/lib.sh"; need_root; need_role A
case "${1:-}" in
  ike) TR=TR-4; FV=("IKE_PROP=aes128-sha256-modp2048!");;
  psk) TR=TR-5; FV=("PSK_SUFFIX=-FAULT");;
  esp) TR=TR-6; FV=("ESP_PROP=aes128-sha1!");;
  ts)  TR=TR-7; FV=("REMOTE_SUBNET=10.3.0.0/24");;
  *) die "usage: $0 <ike|psk|esp|ts> [--no-pause]";;
esac
PAUSE=1; [[ "${2:-}" == "--no-pause" ]] && PAUSE=0
ev_init "$TR"; f="${TR//-/}"; f="${f,,}"

say "##### PHASE 1: healthy baseline"
runsh "$ROOT/scripts/render_config.sh"; ipsec_restart; bring_up
verify_protected "${f}_pre_healthy" || die "baseline not healthy; fix before fault injection"
runsh "ipsec down $CONN"; sleep 2

say "##### PHASE 2: inject fault on GW-A only: ${FV[*]}"
runsh "env ${FV[*]@Q} $ROOT/scripts/render_config.sh"
runsh "grep -E 'ike=|esp=|leftsubnet|rightsubnet' /etc/ipsec.conf"
ipsec_restart
P="$EV/${f}_fault.pcap"
cap_start "$P" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
runsh "timeout 60 ipsec up $CONN"; sleep 3
runsh "ipsec statusall"; runsh "$XS"; runsh "$XP"
runsh "$(flow_cmd 5)"; prc=$RC
runsh "$(ike_logs_cmd 3)"
cap_stop
runsh "tcpdump -nn -# -v -r $P"
ik=0; ch=0; ike_up && ik=1; child_up && ch=1
esp=$(pk "$P" esp); nat=$(pk "$P" udp port 4500); icmp=$(pk "$P" icmp); ph=$(payload_hits "$P")
say "SUMMARY[$TR]: IKE_SA_established=$ik CHILD_SA_installed=$ch ping_rc=$prc native_esp=$esp udp4500=$nat plaintext_icmp_on_wan=$icmp payload_hits_on_wan=$ph"
say "connectivity=$([[ $prc -eq 0 ]] && echo reachable || echo unreachable)  protection=$([[ $((esp+nat)) -gt 0 && $icmp -eq 0 ]] && echo ESP-protected || echo NOT-protected)"
say "Now run on Gateway B:  sudo scripts/collect_peer.sh $TR"
(( PAUSE )) && read -rp "Press Enter after Gateway B evidence is collected to restore... " _

say "##### PHASE 3: restore known-good + verify"
runsh "$ROOT/scripts/render_config.sh"; ipsec_restart; bring_up
verify_protected "${f}_restored"
