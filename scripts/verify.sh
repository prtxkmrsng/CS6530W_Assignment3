#!/usr/bin/env bash
# Health check: IKE_SA ESTABLISHED, CHILD_SA INSTALLED, local-host -> peer-host ping protected (ESP on WAN, no plaintext).
source "$(dirname "$0")/lib.sh"; need_root; ev_init "${1:-VERIFY}"
verify_protected "verify_$(date +%H%M%S)"
