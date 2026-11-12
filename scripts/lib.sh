#!/usr/bin/env bash
# Sourced by all scripts.
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$LIB_DIR")"
CONN="cs6530-site-to-site"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config.env}"

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "run with sudo"; }
need_role(){ [[ "${ROLE:-}" == "$1" ]] || die "run on Gateway $1 (role=${ROLE:-unset})"; }

[[ -f "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE (cp config.env.example config.env)"
# shellcheck disable=SC1090
source "$CONFIG_FILE"
ROLLNO="${ROLLNO^^}"
ROLL_GREP="${ROLLNO:0:16}"
WAN_PREFIX="${WAN_PREFIX:-24}"
PSK_BASE="${ROLLNO}CS6530W-IPsec-A3-2026"
PAYLOAD_HEX="$(printf '%s' "$ROLLNO" | od -An -tx1 | tr -d ' \n' | cut -c1-32)"

ROLE="${ROLE:-$(cat "$ROOT/.role" 2>/dev/null || true)}"
case "$ROLE" in
  A) LOCAL_WAN=$SITE_A_WAN_IP; PEER_WAN=$SITE_B_WAN_IP; LOCAL_NET=$SITE_A_NET; PEER_NET=$SITE_B_NET
     GW_LAN=$SITE_A_GW_LAN; HOST_IP=$SITE_A_HOST; PEER_HOST=$SITE_B_HOST
     HOST_NS=hostA; VETH_GW=vethA-gw; VETH_H=vethA-h ;;
  B) LOCAL_WAN=$SITE_B_WAN_IP; PEER_WAN=$SITE_A_WAN_IP; LOCAL_NET=$SITE_B_NET; PEER_NET=$SITE_A_NET
     GW_LAN=$SITE_B_GW_LAN; HOST_IP=$SITE_B_HOST; PEER_HOST=$SITE_A_HOST
     HOST_NS=hostB; VETH_GW=vethB-gw; VETH_H=vethB-h ;;
  "") : ;;
  *) die "bad ROLE '$ROLE'" ;;
esac
WAN_IF="${WAN_IF:-}"
if [[ -n "$ROLE" && -z "$WAN_IF" ]]; then
  WAN_IF="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$LOCAL_WAN" '{split($4,a,"/"); if(a[1]==ip){print $2; exit}}')"
fi

# ---------- evidence helpers ----------
LOG=/dev/null; EV=/tmp; RC=0; CAP_PIDS=()
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
XS="ip xfrm state | \"$ROOT/scripts/redact.sh\""
XP="ip xfrm policy"

ev_init(){ TR="$1"; EV="$ROOT/evidence/$TR"; mkdir -p "$EV"; LOG="$EV/${TR}_gw${ROLE}.log"; : >"$LOG"; }
say(){ echo "$*" | tee -a "$LOG"; }
result(){ echo "RESULT [$1] $2" | tee -a "$LOG"; }
runsh(){
  echo "[GW-$ROLE $(date -Is)] \$ $1" | tee -a "$LOG"
  RC=0; bash -c "$1" >"$TMP" 2>&1 || RC=$?
  tee -a "$LOG" <"$TMP"; [[ $RC -ne 0 ]] && echo "(exit $RC)" | tee -a "$LOG"
  echo | tee -a "$LOG"
}
flow_cmd(){ echo "ip netns exec $HOST_NS ping -c ${1:-5} -i 0.5 -s 56 -p $PAYLOAD_HEX $PEER_HOST"; }
ike_logs_cmd(){ echo "journalctl -t charon --since -${1:-10}min --no-pager | tail -n 150"; }

# ---------- capture helpers ----------
cap_start(){ local f="$1" i="$2"; shift 2; tcpdump -i "$i" -n -s 0 -U -Z root -w "$f" $* >/dev/null 2>&1 & CAP_PIDS+=($!); sleep 1; }
cap_stop(){ sleep 1; for p in "${CAP_PIDS[@]:-}"; do [[ -n "$p" ]] && kill -INT "$p" 2>/dev/null; done; wait 2>/dev/null; CAP_PIDS=(); }
pk(){ local f="$1"; shift; tcpdump -nn -r "$f" $* 2>/dev/null | wc -l; }
payload_hits(){ tcpdump -nn -A -r "$1" 2>/dev/null | grep -c -- "$ROLL_GREP"; }

# ---------- strongSwan helpers ----------
ipsec_restart(){ systemctl restart strongswan-starter 2>/dev/null || ipsec restart >/dev/null 2>&1; sleep 3; }
ike_up(){ ipsec statusall 2>/dev/null | grep -q ESTABLISHED; }
child_up(){ ipsec statusall 2>/dev/null | grep -q INSTALLED; }
wait_up(){ local i; for ((i=0;i<${1:-15};i++)); do ike_up && child_up && return 0; sleep 1; done; return 1; }
bring_up(){ timeout 60 ipsec up "$CONN" >/dev/null 2>&1; wait_up 10; }

verify_protected(){
  local tag="$1" pc="$EV/$1.pcap" prc esp nat icmp ph ik=0 ch=0
  ike_up || bring_up
  cap_start "$pc" "$WAN_IF" esp or udp port 4500 or udp port 500 or icmp
  runsh "$(flow_cmd 5)"; prc=$RC
  cap_stop
  esp=$(pk "$pc" esp); nat=$(pk "$pc" udp port 4500); icmp=$(pk "$pc" icmp); ph=$(payload_hits "$pc")
  ike_up && ik=1; child_up && ch=1
  runsh "ipsec statusall"; runsh "$XS"; runsh "$XP"
  say "verify[$tag]: ping_rc=$prc native_esp=$esp udp4500=$nat plaintext_icmp_on_wan=$icmp payload_hits_on_wan=$ph ike_established=$ik child_installed=$ch"
  if (( prc==0 && esp+nat>0 && icmp==0 && ph==0 && ik && ch )); then result PASS "tunnel healthy and protected ($tag)"; return 0; fi
  result FAIL "tunnel not healthy/protected ($tag)"; return 1
}
