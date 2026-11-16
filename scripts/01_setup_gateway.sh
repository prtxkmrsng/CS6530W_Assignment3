#!/usr/bin/env bash
# usage: sudo scripts/01_setup_gateway.sh <A|B>
set -uo pipefail

ROLE="${1:-}"
[[ "$ROLE" == "A" || "$ROLE" == "B" ]] || {
  echo "Usage: sudo $0 <A|B>"
  echo "  A = Setup as Gateway A (VM 1)"
  echo "  B = Setup as Gateway B (VM 2)"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
echo "$ROLE" > "$ROOT/.role"

source "$SCRIPT_DIR/lib.sh"
need_root

echo "=========================================================="
echo " Setting up Gateway $ROLE ($( [[ "$ROLE" == A ]] && echo "Site A / VM 1" || echo "Site B / VM 2" ))"
echo "=========================================================="

# 1. Wait for any existing apt/dpkg locks to clear (e.g. unattended-upgrades)
wait_for_apt_lock() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "Waiting for background package manager lock... ($i/60s)"
    sleep 2
    ((i+=2))
    [[ $i -ge 60 ]] && break
  done
}
wait_for_apt_lock

export DEBIAN_FRONTEND=noninteractive
echo "[1/7] Updating package index and installing dependencies..."
apt-get update -y >/dev/null 2>&1 || true

# Pre-seed debconf for wireshark-common so tshark installs without prompting
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections 2>/dev/null || true

PACKAGES=(
  strongswan
  strongswan-starter
  strongswan-pki
  libstrongswan-extra-plugins
  libcharon-extra-plugins
  tcpdump
  iproute2
  iptables
  zip
  net-tools
)

for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || apt-get install -y -o DPkg::Lock::Timeout=60 "$pkg" >/dev/null 2>&1 || {
    echo "Warning: package $pkg failed to install. Continuing..."
  }
done

dpkg -s tshark >/dev/null 2>&1 || apt-get install -y -o DPkg::Lock::Timeout=60 tshark >/dev/null 2>&1 || {
  echo "note: tshark not installed (optional)"
}

# 2. Detect / Configure transit interface for VMware Workstation Pro
echo "[2/7] Detecting transit network interface..."
FOUND_WAN_IF=""

# Check if an interface already has LOCAL_WAN assigned
ASSIGNED_IF="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$LOCAL_WAN" '{split($4,a,"/"); if(a[1]==ip){print $2; exit}}')"
if [[ -n "$ASSIGNED_IF" ]]; then
  FOUND_WAN_IF="$ASSIGNED_IF"
fi

# Check if WAN_IF is explicitly specified
if [[ -z "$FOUND_WAN_IF" && -n "${WAN_IF:-}" ]] && ip link show "$WAN_IF" >/dev/null 2>&1; then
  FOUND_WAN_IF="$WAN_IF"
fi

# Check if WAN_IF_ASSIGN is explicitly specified
if [[ -z "$FOUND_WAN_IF" && -n "${WAN_IF_ASSIGN:-}" ]] && ip link show "$WAN_IF_ASSIGN" >/dev/null 2>&1; then
  FOUND_WAN_IF="$WAN_IF_ASSIGN"
fi

# Auto-detect secondary network interface (VMware typically names it ens34, ens38, ens35, ens160, or eth1)
if [[ -z "$FOUND_WAN_IF" ]]; then
  DEF_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  CANDIDATES=()
  for cand in /sys/class/net/*; do
    cdev="$(basename "$cand")"
    [[ "$cdev" == "lo" || "$cdev" == "$DEF_IF" || "$cdev" == veth* || "$cdev" == docker* || "$cdev" == br-* || "$cdev" == virbr* ]] && continue
    if [[ -d "$cand" && ! -L "$cand/device/virtual" ]]; then
      CANDIDATES+=("$cdev")
    fi
  done

  if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    FOUND_WAN_IF="${CANDIDATES[0]}"
    echo "Auto-detected VMware transit interface: $FOUND_WAN_IF"
  elif [[ ${#CANDIDATES[@]} -gt 1 ]]; then
    FOUND_WAN_IF="${CANDIDATES[0]}"
    echo "Multiple secondary interfaces found (${CANDIDATES[*]}). Using: $FOUND_WAN_IF"
  fi
fi

if [[ -z "$FOUND_WAN_IF" ]]; then
  cat >&2 <<EOF
======================================================================
ERROR: Could not find a secondary network interface for the transit link!
Only primary interface ($DEF_IF) detected.

How to fix in VMware Workstation Pro:
1. Power off (or suspend) this VM.
2. Go to VM -> Settings -> Hardware -> Add... -> Network Adapter.
3. Network connection: Select 'LAN Segment' (create one named 'transit')
   OR select 'Host-only' (VMnet1).
4. Ensure 'Connected' and 'Connect at power on' are checked.
5. Power on this VM and re-run: sudo scripts/01_setup_gateway.sh $ROLE
======================================================================
EOF
  exit 1
fi

WAN_IF="$FOUND_WAN_IF"
echo "$WAN_IF" > "$ROOT/.wan_if"

# Assign transit IP and bring link up
ip addr replace "$LOCAL_WAN/$WAN_PREFIX" dev "$WAN_IF"
ip link set "$WAN_IF" up

# Make transit IP persistent across reboots via Netplan if Netplan is present
if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
  cat >/etc/netplan/99-cs6530w-transit.yaml <<NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $WAN_IF:
      dhcp4: false
      dhcp6: false
      addresses:
        - $LOCAL_WAN/$WAN_PREFIX
NETPLAN
  chmod 600 /etc/netplan/99-cs6530w-transit.yaml
  netplan apply >/dev/null 2>&1 || true
fi

# Update WAN_IF in config.env if it was empty
if grep -q '^WAN_IF=""' "$CONFIG_FILE" 2>/dev/null; then
  sed -i "s/^WAN_IF=\"\"/WAN_IF=\"$WAN_IF\"/" "$CONFIG_FILE"
fi

# 3. Setup host network namespace and veth link
echo "[3/7] Setting up host namespace ($HOST_NS) and veth link ($VETH_GW <-> $VETH_H)..."
ip netns list | grep -qw "$HOST_NS" || ip netns add "$HOST_NS"
if ! ip link show "$VETH_GW" >/dev/null 2>&1; then
  ip link add "$VETH_GW" type veth peer name "$VETH_H"
  ip link set "$VETH_H" netns "$HOST_NS"
fi
ip addr replace "$GW_LAN/24" dev "$VETH_GW"
ip link set "$VETH_GW" up
ip netns exec "$HOST_NS" ip addr replace "$HOST_IP/24" dev "$VETH_H"
ip netns exec "$HOST_NS" ip link set lo up
ip netns exec "$HOST_NS" ip link set "$VETH_H" up
ip netns exec "$HOST_NS" ip route replace default via "$GW_LAN"

# 4. Configure kernel forwarding, disable redirects and rp_filter
echo "[4/7] Applying sysctl routing settings..."
cat >/etc/sysctl.d/99-cs6530w.conf <<SYS
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYS
sysctl --system >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.$WAN_IF.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.$VETH_GW.rp_filter=0" >/dev/null 2>&1 || true

# 5. Plaintext route to peer protected subnet (baseline for TR-1)
echo "[5/7] Adding baseline plaintext route for $PEER_NET via $PEER_WAN..."
ip route replace "$PEER_NET" via "$PEER_WAN" dev "$WAN_IF" 2>/dev/null || true

# 6. Firewall & iptables configuration
echo "[6/7] Configuring firewall rules..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow in on "$WAN_IF" >/dev/null 2>&1 || true
  ufw allow in on "$VETH_GW" >/dev/null 2>&1 || true
  ufw route allow in on "$VETH_GW" out on "$WAN_IF" >/dev/null 2>&1 || true
  ufw route allow in on "$WAN_IF" out on "$VETH_GW" >/dev/null 2>&1 || true
fi

if command -v iptables >/dev/null 2>&1; then
  iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
  iptables -P INPUT ACCEPT >/dev/null 2>&1 || true
  while read -r r; do
    [[ -n "$r" ]] && (iptables -C $r 2>/dev/null || iptables -I $r 2>/dev/null || true)
  done <<RULES
INPUT -i $WAN_IF -p icmp -j ACCEPT
INPUT -i $VETH_GW -j ACCEPT
INPUT -p udp --dport 500 -j ACCEPT
INPUT -p udp --dport 4500 -j ACCEPT
INPUT -p esp -j ACCEPT
FORWARD -s $PEER_NET -d $LOCAL_NET -j ACCEPT
FORWARD -s $LOCAL_NET -d $PEER_NET -j ACCEPT
RULES
fi

# 7. Render strongSwan config and start service
echo "[7/7] Rendering strongSwan configuration and starting service..."
systemctl stop strongswan 2>/dev/null || true
systemctl disable strongswan 2>/dev/null || true
systemctl enable strongswan-starter 2>/dev/null || true
"$ROOT/scripts/render_config.sh"
ipsec_restart

# Preflight verification
echo "=========================================================="
echo " Gateway $ROLE Setup Complete!"
echo " Transit Interface: $WAN_IF ($LOCAL_WAN/$WAN_PREFIX)"
echo " Protected Host:    $HOST_NS ($HOST_IP/24 via $GW_LAN)"
echo "=========================================================="

if ip netns exec "$HOST_NS" ping -c 1 -W 1 "$GW_LAN" >/dev/null 2>&1; then
  echo "✓ Host -> Gateway link OK ($HOST_IP -> $GW_LAN)"
else
  echo "✗ Host -> Gateway link failed"
fi

if ping -c 1 -W 2 "$PEER_WAN" >/dev/null 2>&1; then
  echo "✓ Transit link to peer OK ($LOCAL_WAN -> $PEER_WAN)"
else
  echo "ℹ Note: Peer gateway $PEER_WAN is not yet responding to ping."
  echo "  -> If you haven't run setup on the other VM yet, run: sudo scripts/01_setup_gateway.sh $( [[ "$ROLE" == A ]] && echo "B" || echo "A" ) on that VM."
  echo "  -> In VMware Workstation, ensure both VMs have Network Adapter 2 set to the SAME LAN Segment or VMnet."
fi

echo
ipsec statusall 2>/dev/null | head -n 12 || echo "strongSwan loaded"
