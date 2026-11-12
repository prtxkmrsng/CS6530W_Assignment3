#!/usr/bin/env bash
# usage: sudo scripts/01_setup_gateway.sh <A|B>
ROLE="${1:?usage: $0 <A|B>}"
[[ "$ROLE" == A || "$ROLE" == B ]] || { echo "role must be A or B"; exit 1; }
source "$(dirname "$0")/lib.sh"; need_root
echo "$ROLE" >"$ROOT/.role"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y strongswan strongswan-starter tcpdump iproute2 iptables >/dev/null || die "apt install failed"
apt-get install -y tshark >/dev/null 2>&1 || echo "note: tshark not installed (optional)"
systemctl disable --now strongswan >/dev/null 2>&1 || true   # swanctl/charon-systemd must not run alongside starter
systemctl enable --now strongswan-starter >/dev/null 2>&1 || true

if [[ -z "${WAN_IF:-}" ]]; then
  [[ -n "${WAN_IF_ASSIGN:-}" ]] || die "WAN IP $LOCAL_WAN not on any interface; set WAN_IF_ASSIGN in config.env"
  ip addr add "$LOCAL_WAN/$WAN_PREFIX" dev "$WAN_IF_ASSIGN"; ip link set "$WAN_IF_ASSIGN" up; WAN_IF="$WAN_IF_ASSIGN"
fi

ip netns list | grep -qw "$HOST_NS" || ip netns add "$HOST_NS"
if ! ip link show "$VETH_GW" >/dev/null 2>&1; then
  ip link add "$VETH_GW" type veth peer name "$VETH_H"
  ip link set "$VETH_H" netns "$HOST_NS"
fi
ip addr replace "$GW_LAN/24" dev "$VETH_GW"; ip link set "$VETH_GW" up
ip netns exec "$HOST_NS" ip addr replace "$HOST_IP/24" dev "$VETH_H"
ip netns exec "$HOST_NS" ip link set lo up
ip netns exec "$HOST_NS" ip link set "$VETH_H" up
ip netns exec "$HOST_NS" ip route replace default via "$GW_LAN"

cat >/etc/sysctl.d/99-cs6530w.conf <<SYS
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=2
SYS
sysctl --system >/dev/null

# plaintext route to peer protected subnet (TR-1 baseline); XFRM policy overrides it once IPsec is up
ip route replace "$PEER_NET" via "$PEER_WAN" dev "$WAN_IF"

if command -v iptables >/dev/null; then
  while read -r r; do iptables -C $r 2>/dev/null || iptables -I $r; done <<RULES
INPUT -p udp --dport 500 -j ACCEPT
INPUT -p udp --dport 4500 -j ACCEPT
INPUT -p esp -j ACCEPT
FORWARD -s $PEER_NET -d $LOCAL_NET -j ACCEPT
FORWARD -s $LOCAL_NET -d $PEER_NET -j ACCEPT
RULES
fi

"$ROOT/scripts/render_config.sh" && ipsec_restart
echo "--- GW-$ROLE ready: WAN_IF=$WAN_IF"
ip -br addr; ip route; ip netns exec "$HOST_NS" ip -br addr
ip netns exec "$HOST_NS" ping -c1 -W1 "$GW_LAN" >/dev/null && echo "host->gateway OK"
ipsec statusall | head -n 12
