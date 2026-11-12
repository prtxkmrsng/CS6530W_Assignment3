#!/usr/bin/env bash
# Restore known-good config on this gateway and verify (FR-8).
source "$(dirname "$0")/lib.sh"; need_root; ev_init "${1:-RESTORE}"
runsh "$ROOT/scripts/render_config.sh"
ipsec_restart; bring_up
verify_protected "restore_$(date +%H%M%S)"
