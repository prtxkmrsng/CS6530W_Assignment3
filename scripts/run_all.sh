#!/usr/bin/env bash
# scripts/run_all.sh — Interactive lab test runner for CS6530W Assignment 3
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"
need_root

show_menu() {
  clear 2>/dev/null || true
  echo "================================================================================"
  echo "         CS6530W Assignment 3 — Lab Runner (Gateway $ROLE)"
  echo "================================================================================"
  echo "  1) Run Health Check & VMware Diagnostics (diagnose.sh)"
  echo "  2) Run TR-1: Plaintext Baseline"
  echo "  3) Run TR-2: Fresh IKEv2 Establishment Capture"
  echo "  4) Run TR-3: Protected Session & SPI Correlation"
  echo "  5) Run TR-4: Fault Injection — IKE Proposal Mismatch"
  echo "  6) Run TR-5: Fault Injection — PSK Mismatch"
  echo "  7) Run TR-6: Fault Injection — ESP Proposal Mismatch"
  echo "  8) Run TR-7: Fault Injection — Traffic Selector Mismatch"
  echo "  9) Run TR-8: Security Boundary Verification"
  echo " 10) Restore Known-Good Configuration (restore.sh)"
  echo " 11) Package Submission ZIP (package.sh)"
  echo "  0) Exit"
  echo "================================================================================"
  echo -n "Select an option [0-11]: "
}

press_enter() {
  echo
  read -rp "Press Enter to return to menu... " _
}

while true; do
  show_menu
  read -r choice
  case "$choice" in
    1)
      "$SCRIPT_DIR/diagnose.sh"
      press_enter
      ;;
    2)
      if [[ "$ROLE" != "A" ]]; then
        echo "TR-1 must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/tr1_plaintext.sh"
      fi
      press_enter
      ;;
    3)
      if [[ "$ROLE" != "A" ]]; then
        echo "TR-2 must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/tr2_ike_capture.sh"
      fi
      press_enter
      ;;
    4)
      if [[ "$ROLE" != "A" ]]; then
        echo "TR-3 must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/tr3_protected.sh"
      fi
      press_enter
      ;;
    5)
      if [[ "$ROLE" != "A" ]]; then
        echo "Fault tests must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/fault.sh" ike
      fi
      press_enter
      ;;
    6)
      if [[ "$ROLE" != "A" ]]; then
        echo "Fault tests must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/fault.sh" psk
      fi
      press_enter
      ;;
    7)
      if [[ "$ROLE" != "A" ]]; then
        echo "Fault tests must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/fault.sh" esp
      fi
      press_enter
      ;;
    8)
      if [[ "$ROLE" != "A" ]]; then
        echo "Fault tests must be executed on Gateway A (Site A / VM 1)."
      else
        "$SCRIPT_DIR/fault.sh" ts
      fi
      press_enter
      ;;
    9)
      "$SCRIPT_DIR/tr8_boundary.sh"
      press_enter
      ;;
    10)
      "$SCRIPT_DIR/restore.sh"
      press_enter
      ;;
    11)
      "$SCRIPT_DIR/package.sh"
      press_enter
      ;;
    0)
      echo "Goodbye!"
      exit 0
      ;;
    *)
      echo "Invalid selection."
      sleep 1
      ;;
  esac
done
