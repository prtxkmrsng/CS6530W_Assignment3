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

# Disable or complain AppArmor profile for tcpdump to prevent crashes and file-access denials
if [[ $EUID -eq 0 ]]; then
  if command -v apparmor_parser >/dev/null 2>&1 && [[ -f /etc/apparmor.d/usr.sbin.tcpdump ]]; then
    mkdir -p /etc/apparmor.d/disable 2>/dev/null || true
    ln -sf /etc/apparmor.d/usr.sbin.tcpdump /etc/apparmor.d/disable/ 2>/dev/null || true
    apparmor_parser -R /etc/apparmor.d/usr.sbin.tcpdump >/dev/null 2>&1 || true
  fi
  if command -v aa-disable >/dev/null 2>&1; then
    aa-disable /usr/sbin/tcpdump >/dev/null 2>&1 || true
  elif command -v aa-complain >/dev/null 2>&1; then
    aa-complain /usr/sbin/tcpdump >/dev/null 2>&1 || true
  fi
fi

# Auto-create config.env from example if missing
if [[ ! -f "$CONFIG_FILE" && -f "$ROOT/config.env.example" ]]; then
  cp "$ROOT/config.env.example" "$CONFIG_FILE"
  echo "note: created $CONFIG_FILE from config.env.example" >&2
fi
[[ -f "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE (cp config.env.example config.env)"

# Load configuration and strip any Windows carriage returns (CRLF)
eval "$(tr -d '\r' < "$CONFIG_FILE")"

ROLLNO="${ROLLNO:-CS24M001}"
ROLLNO="${ROLLNO#"${ROLLNO%%[![:space:]]*}"}"
ROLLNO="${ROLLNO%"${ROLLNO##*[![:space:]]}"}"
ROLLNO="${ROLLNO^^}"
ROLL_GREP="${ROLLNO:0:16}"
WAN_PREFIX="${WAN_PREFIX:-24}"
PSK_BASE="${ROLLNO}CS6530W-IPsec-A3-2026"
PAYLOAD_HEX="$(printf '%s' "$ROLLNO" | od -An -tx1 | tr -d ' \n' | cut -c1-32)"

# Role resolution
ROLE="${ROLE:-$(cat "$ROOT/.role" 2>/dev/null | tr -d ' \r\n' || true)}"
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

# Auto-detect WAN interface if not explicitly configured
WAN_IF="${WAN_IF:-$(cat "$ROOT/.wan_if" 2>/dev/null | tr -d ' \r\n' || true)}"
if [[ -n "$ROLE" && -z "$WAN_IF" ]]; then
  # 1. Interface that already holds LOCAL_WAN IP
  WAN_IF="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$LOCAL_WAN" '{split($4,a,"/"); if(a[1]==ip){print $2; exit}}')"
fi
if [[ -n "$ROLE" && -z "$WAN_IF" && -n "${WAN_IF_ASSIGN:-}" ]]; then
  if ip link show "$WAN_IF_ASSIGN" >/dev/null 2>&1; then
    WAN_IF="$WAN_IF_ASSIGN"
  fi
fi
if [[ -n "$ROLE" && -z "$WAN_IF" ]]; then
  # 2. Try to auto-detect secondary interface (excluding loopback, default-route NIC, and virtual links)
  DEF_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  for cand in /sys/class/net/*; do
    cdev="$(basename "$cand")"
    [[ "$cdev" == "lo" || "$cdev" == "$DEF_IF" || "$cdev" == veth* || "$cdev" == docker* || "$cdev" == br-* || "$cdev" == virbr* ]] && continue
    if [[ -d "$cand" && ! -L "$cand/device/virtual" ]]; then
      WAN_IF="$cdev"
      break
    fi
  done
fi

# ---------- evidence helpers ----------
LOG=/dev/null; EV=/tmp; RC=0; CAP_PIDS=(); CAP_MAP=()
TMP="$(mktemp)"
cleanup(){
  rm -f "$TMP"
  for p in "${CAP_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill -INT "$p" 2>/dev/null || true
  done
  for m in "${CAP_MAP[@]:-}"; do
    src="${m%%:*}"
    dst="${m#*:}"
    if [[ -f "$src" && "$src" != "$dst" ]]; then
      mv -f "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst" 2>/dev/null || true
      rm -f "$src" 2>/dev/null || true
      chmod 666 "$dst" 2>/dev/null || chmod 644 "$dst" 2>/dev/null || true
      if [[ -n "${SUDO_USER:-}" ]]; then
        chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$dst" 2>/dev/null || true
      fi
    fi
  done
  if [[ -d "$ROOT/evidence" ]]; then
    chmod -R a+rwX "$ROOT/evidence" 2>/dev/null || true
    if [[ -n "${SUDO_USER:-}" ]]; then
      chown -R "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$ROOT/evidence" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT INT TERM
XS="ip xfrm state | \"$ROOT/scripts/redact.sh\""
XP="ip xfrm policy"

ev_init(){
  TR="$1"
  EV="$ROOT/evidence/$TR"
  mkdir -p "$EV"
  chmod 777 "$EV" 2>/dev/null || chmod 755 "$EV" 2>/dev/null || true
  LOG="$EV/${TR}_gw${ROLE}.log"
  [[ -f "$LOG" ]] || : >"$LOG"
  chmod 666 "$LOG" 2>/dev/null || chmod 644 "$LOG" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$EV" 2>/dev/null || true
  fi
}
say(){ echo "$*" | tee -a "$LOG"; }
result(){ echo "RESULT [$1] $2" | tee -a "$LOG"; }
runsh(){
  echo "[GW-$ROLE $(date -Is)] \$ $1" | tee -a "$LOG"
  RC=0; bash -c "$1" >"$TMP" 2>&1 || RC=$?
  tee -a "$LOG" <"$TMP"; [[ $RC -ne 0 ]] && echo "(exit $RC)" | tee -a "$LOG"
  echo | tee -a "$LOG"
}
flow_cmd(){ echo "ip netns exec $HOST_NS ping -c ${1:-5} -i 0.5 -W 2 -s 56 -p $PAYLOAD_HEX $PEER_HOST"; }
ike_logs_cmd(){
  echo "(journalctl -u strongswan-starter -u strongswan -t charon --since -${1:-10}min --no-pager 2>/dev/null || journalctl -t charon --since -${1:-10}min --no-pager 2>/dev/null || cat /var/log/charon.log 2>/dev/null || true) | tail -n 150"
}

# ---------- capture helpers ----------
cap_start(){
  local f="$1" i="$2"; shift 2
  if [[ -z "$i" ]]; then
    say "WARNING: cap_start called with empty interface; capture disabled for $f"
    return 1
  fi
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  chmod 777 "$(dirname "$f")" 2>/dev/null || chmod 755 "$(dirname "$f")" 2>/dev/null || true

  # Ensure destination placeholder exists and is accessible
  if [[ ! -f "$f" ]]; then
    : > "$f" 2>/dev/null || true
  fi
  chmod 666 "$f" 2>/dev/null || chmod 644 "$f" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$f" 2>/dev/null || true
  fi

  # Always capture initially to /tmp to prevent AppArmor confinement or directory access failures
  local tmp_cap="/tmp/cs6530w_cap_${$}_${#CAP_PIDS[@]}.pcap"
  rm -f "$tmp_cap"

  local dir_opt=()
  if [[ "${1:-}" == "-Q" ]]; then
    dir_opt=("-Q" "$2")
    shift 2
  elif [[ "${1:-}" == --direction=* ]]; then
    dir_opt=("$1")
    shift 1
  fi

  # Do NOT pass -Z root (causes segmentation fault / AppArmor abort on Ubuntu).
  # If -Q fails or segfaults on driver, fallback gracefully without direction option.
  tcpdump -i "$i" "${dir_opt[@]}" -n -s 0 -w "$tmp_cap" "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3

  if ! kill -0 "$pid" 2>/dev/null; then
    # Retry without direction flag in case interface driver rejects -Q
    tcpdump -i "$i" -n -s 0 -w "$tmp_cap" "$@" >/dev/null 2>&1 &
    pid=$!
    sleep 0.3
  fi

  CAP_PIDS+=("$pid")
  CAP_MAP+=("$tmp_cap:$f")
}

cap_stop(){
  sleep 1
  for p in "${CAP_PIDS[@]:-}"; do
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
      kill -INT "$p" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true

  for m in "${CAP_MAP[@]:-}"; do
    src="${m%%:*}"
    dst="${m#*:}"
    if [[ -f "$src" ]]; then
      mv -f "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst" 2>/dev/null || true
      rm -f "$src" 2>/dev/null || true
    elif [[ ! -f "$dst" ]]; then
      : > "$dst"
    fi
    if [[ -f "$dst" ]]; then
      chmod 666 "$dst" 2>/dev/null || chmod 644 "$dst" 2>/dev/null || true
      if [[ -n "${SUDO_USER:-}" ]]; then
        chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$dst" 2>/dev/null || true
      fi
    fi
  done

  CAP_PIDS=()
  CAP_MAP=()
}

pk(){
  local f="$1"; shift
  [[ -f "$f" && -r "$f" && -s "$f" ]] || { echo 0; return; }
  chmod 666 "$f" 2>/dev/null || chmod 644 "$f" 2>/dev/null || true
  tcpdump -nn -r "$f" "$@" 2>/dev/null | wc -l
}

payload_hits(){
  local f="$1"
  [[ -f "$f" && -r "$f" && -s "$f" ]] || { echo 0; return; }
  [[ -n "$ROLL_GREP" ]] || { echo 0; return; }
  chmod 666 "$f" 2>/dev/null || chmod 644 "$f" 2>/dev/null || true
  tcpdump -nn -A -r "$f" 2>/dev/null | grep -c -- "$ROLL_GREP" || true
}

# ---------- strongSwan helpers ----------
ipsec_restart(){
  if systemctl is-active --quiet strongswan-starter 2>/dev/null; then
    systemctl restart strongswan-starter 2>/dev/null || ipsec restart >/dev/null 2>&1 || true
  elif systemctl is-active --quiet strongswan 2>/dev/null; then
    systemctl restart strongswan 2>/dev/null || ipsec restart >/dev/null 2>&1 || true
  else
    systemctl start strongswan-starter 2>/dev/null || ipsec start >/dev/null 2>&1 || true
  fi
  sleep 3
}
ike_up(){ ipsec statusall 2>/dev/null | grep -q ESTABLISHED; }
child_up(){ ipsec statusall 2>/dev/null | grep -q INSTALLED; }
wait_up(){
  local i max="${1:-15}"
  for ((i=0; i<max; i++)); do
    ike_up && child_up && return 0
    sleep 1
  done
  return 1
}
bring_up(){
  local out
  out="$(timeout 60 ipsec up "$CONN" 2>&1)" || true
  echo "$out" >> "$LOG"
  if wait_up 10; then
    return 0
  fi
  say "NOTE: ipsec up '$CONN' negotiation output:"
  say "$out"
  return 1
}

verify_protected(){
  local tag="$1" pc="$EV/$1.pcap" prc esp nat icmp ph ik=0 ch=0 leak=0
  ike_up || bring_up
  cap_start "$pc" "$WAN_IF" -Q out esp or udp port 4500 or udp port 500 or icmp
  runsh "$(flow_cmd 5)"; prc=$RC
  cap_stop

  esp=$(pk "$pc" esp)
  nat=$(pk "$pc" udp port 4500)
  
  if [[ -s "$pc" ]]; then
    # Check for actual unencrypted outbound echo requests from hostA to hostB on transit
    leak=$(tcpdump -nn -r "$pc" "icmp and src $HOST_IP and dst $PEER_HOST" 2>/dev/null | wc -l)
    ph=$(tcpdump -nn -A -r "$pc" "icmp and src $HOST_IP and dst $PEER_HOST" 2>/dev/null | grep -c -- "$ROLL_GREP" || true)
  else
    leak=0
    ph=0
  fi
  icmp=$leak

  ike_up && ik=1
  child_up && ch=1

  runsh "ipsec statusall"
  runsh "$XS"
  runsh "$XP"

  say "verify[$tag]: ping_rc=$prc native_esp=$esp udp4500=$nat plaintext_icmp_on_wan=$icmp payload_hits_on_wan=$ph ike_established=$ik child_installed=$ch"
  if (( prc==0 && (esp+nat)>0 && icmp==0 && ph==0 && ik && ch )); then
    result PASS "tunnel healthy and protected ($tag)"
    return 0
  fi
  result FAIL "tunnel not healthy/protected ($tag)"
  return 1
}
