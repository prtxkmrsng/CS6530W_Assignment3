#!/usr/bin/env bash
# Health check: IKE_SA ESTABLISHED, CHILD_SA INSTALLED, local-host -> peer-host ping protected (ESP on WAN, no plaintext).
set -uo pipefail
source "$(dirname "$0")/lib.sh"; need_root; ev_init "${1:-VERIFY}"

say "Running health check on GW-$ROLE..."
if verify_protected "verify_$(date +%H%M%S)"; then
  echo "✓ Gateway $ROLE health check PASSED."
else
  echo "✗ Gateway $ROLE health check FAILED. See details in $LOG"
  echo "  Run 'sudo scripts/diagnose.sh' for in-depth network and service analysis."
fi
