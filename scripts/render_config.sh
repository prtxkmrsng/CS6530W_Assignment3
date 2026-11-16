#!/usr/bin/env bash
# Render ipsec.conf / ipsec.secrets for this gateway.
# Overrides (env): IKE_PROP ESP_PROP PSK_SUFFIX LOCAL_SUBNET REMOTE_SUBNET OUT_DIR
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT_DIR="${OUT_DIR:-/etc}"
[[ "$OUT_DIR" == /etc ]] && need_root
[[ -n "$ROLE" ]] || die "ROLE unset (run 01_setup_gateway.sh first or export ROLE=A|B)"

IKE="${IKE_PROP:-aes256-sha256-modp2048!}"
ESP="${ESP_PROP:-aes256-sha256!}"
PSK="${PSK_BASE}${PSK_SUFFIX:-}"
LSUB="${LOCAL_SUBNET:-$LOCAL_NET}"
RSUB="${REMOTE_SUBNET:-$PEER_NET}"

mkdir -p "$OUT_DIR"
[[ "$OUT_DIR" == /etc && -f /etc/ipsec.conf && ! -f /etc/ipsec.conf.orig ]] && cp /etc/ipsec.conf /etc/ipsec.conf.orig

cat >"$OUT_DIR/ipsec.conf" <<CONF
config setup
    uniqueids=yes
    charondebug="ike 2, cfg 2, knl 1, net 1"

conn $CONN
    keyexchange=ikev2
    type=tunnel
    left=$LOCAL_WAN
    leftid=$LOCAL_WAN
    leftsubnet=$LSUB
    leftauth=psk
    right=$PEER_WAN
    rightid=$PEER_WAN
    rightsubnet=$RSUB
    rightauth=psk
    ike=$IKE
    esp=$ESP
    keyingtries=1
    dpdaction=restart
    auto=add
CONF

umask 077
printf '%s %s : PSK "%s"\n' "$LOCAL_WAN" "$PEER_WAN" "$PSK" >"$OUT_DIR/ipsec.secrets"
chmod 600 "$OUT_DIR/ipsec.secrets"

if [[ "$OUT_DIR" == /etc ]]; then
  D="$ROOT/evidence/config_gw$ROLE"
  mkdir -p "$D"
  cp /etc/ipsec.conf "$D/ipsec.conf"
  sed -E 's/(PSK ")[^"]*"/\1<LAB-PSK-REDACTED>"/' /etc/ipsec.secrets >"$D/ipsec.secrets.redacted"
fi

echo "rendered GW-$ROLE: ike=$IKE esp=$ESP lsub=$LSUB rsub=$RSUB psk_suffix='${PSK_SUFFIX:-}'"
