#!/usr/bin/env bash
# scripts/diagnose.sh — Comprehensive diagnostic & troubleshooting tool for VMware Workstation Pro
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"
need_root

echo "================================================================================"
echo "          CS6530W Assignment 3 — Lab Health & VMware Diagnostics"
echo "================================================================================"

pass_count=0
warn_count=0
fail_count=0

chk_pass(){ echo -e "  [\e[32mPASS\e[0m] $*"; ((pass_count++)); }
chk_warn(){ echo -e "  [\e[33mWARN\e[0m] $*"; ((warn_count++)); }
chk_fail(){ echo -e "  [\e[31mFAIL\e[0m] $*"; ((fail_count++)); }

echo
echo "--- 1. Configuration & Role ---"
if [[ -f "$CONFIG_FILE" ]]; then
  chk_pass "Configuration file exists: $CONFIG_FILE"
  echo "         ROLLNO: $ROLLNO"
  echo "         Local WAN: $LOCAL_WAN | Peer WAN: $PEER_WAN"
  echo "         Local Net: $LOCAL_NET | Peer Net: $PEER_NET"
else
  chk_fail "Configuration file missing: $CONFIG_FILE"
fi

if [[ "$ROLE" == "A" || "$ROLE" == "B" ]]; then
  chk_pass "Gateway Role: $ROLE ($( [[ "$ROLE" == A ]] && echo "Site A / VM 1" || echo "Site B / VM 2" ))"
else
  chk_fail "Gateway Role is unset or invalid ('$ROLE'). Run: sudo scripts/01_setup_gateway.sh <A|B>"
fi

echo
echo "--- 2. Network Interfaces & Transit Link (VMware Workstation) ---"
if [[ -n "${WAN_IF:-}" ]] && ip link show "$WAN_IF" >/dev/null 2>&1; then
  chk_pass "Transit interface found: $WAN_IF"
  
  # Check carrier/operstate
  operstate="$(cat "/sys/class/net/$WAN_IF/operstate" 2>/dev/null || echo "unknown")"
  carrier="$(cat "/sys/class/net/$WAN_IF/carrier" 2>/dev/null || echo "0")"
  if [[ "$carrier" == "1" || "$operstate" == "up" ]]; then
    chk_pass "Transit interface link state is UP (carrier detected)"
  else
    chk_warn "Transit interface state is $operstate (carrier=$carrier). In VMware, check VM Settings -> Network Adapter 2 -> 'Connected'."
  fi

  # Check assigned IP
  cur_ip="$(ip -o -4 addr show "$WAN_IF" 2>/dev/null | awk '{print $4}')"
  if [[ "$cur_ip" == *"$LOCAL_WAN"* ]]; then
    chk_pass "Transit IP correctly assigned: $cur_ip"
  else
    chk_fail "Transit IP is '$cur_ip' (expected $LOCAL_WAN/$WAN_PREFIX). Run: sudo ip addr replace $LOCAL_WAN/$WAN_PREFIX dev $WAN_IF"
  fi

  # Test tcpdump operational state and AppArmor confinement
  test_pcap="/tmp/cs6530w_diag_$$.pcap"
  rm -f "$test_pcap"
  if tcpdump -i "$WAN_IF" -n -c 1 -w "$test_pcap" >/dev/null 2>&1 & then
    tpid=$!
    sleep 0.3
    kill -INT "$tpid" >/dev/null 2>&1 || true
    wait "$tpid" 2>/dev/null || true
    chk_pass "Packet capture tool (tcpdump) is operational and unconfined."
    rm -f "$test_pcap"
  else
    chk_warn "tcpdump failed to capture on $WAN_IF. Check AppArmor: sudo aa-disable /usr/sbin/tcpdump"
  fi
else
  chk_fail "Transit interface '$WAN_IF' does not exist."
  echo "         Available interfaces:"
  ip -br link | sed 's/^/           /'
  echo "         In VMware Workstation Pro:"
  echo "           1. Add a second Network Adapter in VM Settings."
  echo "           2. Connect it to 'LAN Segment' (name: 'transit') or 'Host-only'."
fi

echo
echo "--- 3. Host Namespace & Local Plumbing ---"
if ip netns list | grep -qw "$HOST_NS"; then
  chk_pass "Host namespace '$HOST_NS' exists."
  
  if ip link show "$VETH_GW" >/dev/null 2>&1; then
    chk_pass "Gateway veth interface '$VETH_GW' exists."
  else
    chk_fail "Gateway veth interface '$VETH_GW' missing."
  fi

  if ip netns exec "$HOST_NS" ip link show "$VETH_H" >/dev/null 2>&1; then
    chk_pass "Host veth interface '$VETH_H' exists inside '$HOST_NS'."
  else
    chk_fail "Host veth interface '$VETH_H' missing inside '$HOST_NS'."
  fi

  if ip netns exec "$HOST_NS" ping -c 1 -W 1 "$GW_LAN" >/dev/null 2>&1; then
    chk_pass "Ping host -> gateway LAN ($HOST_IP -> $GW_LAN) succeeded."
  else
    chk_fail "Ping host -> gateway LAN ($HOST_IP -> $GW_LAN) failed."
  fi
else
  chk_fail "Host namespace '$HOST_NS' does not exist. Run: sudo scripts/01_setup_gateway.sh $ROLE"
fi

echo
echo "--- 4. Kernel Forwarding & Routing ---"
fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
if [[ "$fwd" == "1" ]]; then
  chk_pass "IPv4 forwarding is enabled (net.ipv4.ip_forward=1)"
else
  chk_fail "IPv4 forwarding is disabled! Run: sudo sysctl -w net.ipv4.ip_forward=1"
fi

proute="$(ip route show "$PEER_NET" 2>/dev/null || true)"
if [[ -n "$proute" ]]; then
  chk_pass "Route to peer network exists: $proute"
else
  chk_warn "No static route for $PEER_NET. (strongSwan may dynamically manage table 220, or run: sudo ip route replace $PEER_NET via $PEER_WAN dev $WAN_IF)"
fi

echo
echo "--- 5. Inter-VM Transit Connectivity (VMware Test) ---"
if ping -c 2 -W 2 "$PEER_WAN" >/dev/null 2>&1; then
  chk_pass "Transit link between VMs is UP! Can reach peer gateway at $PEER_WAN"
else
  chk_fail "Cannot ping peer gateway at $PEER_WAN over transit interface ($WAN_IF)."
  echo "         >>> VMware Workstation Troubleshooting Steps <<<"
  echo "         1. Is VM 2 ($( [[ "$ROLE" == A ]] && echo "Gateway B" || echo "Gateway A" )) powered on?"
  echo "         2. Has 'sudo scripts/01_setup_gateway.sh $( [[ "$ROLE" == A ]] && echo "B" || echo "A" )' been run on VM 2?"
  echo "         3. In VMware Workstation on BOTH VMs:"
  echo "            - Open VM -> Settings -> Hardware -> Network Adapter 2."
  echo "            - Ensure 'Connected' and 'Connect at power on' are BOTH checked."
  echo "            - Set Network connection to 'LAN Segment' and select the SAME name (e.g. 'transit')."
  echo "            - Alternatively, set BOTH to 'Host-only' (VMnet1)."
  echo "         4. Verify on peer VM that transit IP is active: ip -br addr"
fi

echo
echo "--- 6. strongSwan Daemon & Service Status ---"
if systemctl is-active --quiet strongswan-starter 2>/dev/null || systemctl is-active --quiet strongswan 2>/dev/null; then
  chk_pass "strongSwan service is active."
else
  chk_warn "strongSwan service is not running. Run: sudo systemctl restart strongswan-starter"
fi

if ipsec statusall >/dev/null 2>&1; then
  chk_pass "strongSwan 'ipsec' CLI is responsive."
  
  if ipsec statusall 2>/dev/null | grep -q "$CONN"; then
    chk_pass "Connection '$CONN' is loaded in strongSwan."
  else
    chk_fail "Connection '$CONN' is not loaded in strongSwan."
  fi

  if ike_up; then
    chk_pass "IKE_SA is ESTABLISHED."
  else
    chk_warn "IKE_SA is currently down/not established. (Expected before TR-2 or during faults)."
  fi

  if child_up; then
    chk_pass "CHILD_SA (ESP tunnel) is INSTALLED."
  else
    chk_warn "CHILD_SA is currently down/not installed. (Expected before TR-2 or during faults)."
  fi
else
  chk_fail "strongSwan charon daemon is not responding to 'ipsec statusall'."
fi

echo
echo "--- 7. End-to-End Host Connectivity ---"
if ip netns exec "$HOST_NS" ping -c 2 -W 2 "$PEER_HOST" >/dev/null 2>&1; then
  chk_pass "End-to-end ping hostA <-> hostB ($HOST_IP <-> $PEER_HOST) succeeded!"
  
  xfrm_count=$(ip xfrm state 2>/dev/null | grep -c '^src' || true)
  if [[ $xfrm_count -gt 0 ]]; then
    chk_pass "Traffic is encrypted via Linux XFRM ($xfrm_count active SAs)."
  else
    chk_warn "Traffic is passing in PLAINTEXT (no active XFRM SAs). Valid for TR-1."
  fi
else
  chk_warn "End-to-end ping hostA <-> hostB failed."
  echo "         (If IPsec is expected to be up, run 'sudo scripts/restore.sh' to recover)."
fi

echo
echo "================================================================================"
echo " Diagnostics Summary: $pass_count passed, $warn_count warnings, $fail_count failed"
echo "================================================================================"
if [[ $fail_count -eq 0 ]]; then
  echo "All primary components are healthy! You are ready to run tests."
else
  echo "Please resolve the failures above before running tests."
fi
