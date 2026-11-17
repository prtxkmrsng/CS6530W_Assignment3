#!/usr/bin/env bash
# Build <ROLLNO>_CS6530W_Assignment3.zip. Excludes config.env/.role/.wan_if.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CONFIG_FILE="./config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: missing config.env"; exit 1; }

eval "$(tr -d '\r' < "$CONFIG_FILE")"
ROLLNO="${ROLLNO:-CS24M001}"
ROLLNO="${ROLLNO#"${ROLLNO%%[![:space:]]*}"}"
ROLLNO="${ROLLNO%"${ROLLNO##*[![:space:]]}"}"
R="${ROLLNO^^}"
O="../${R}_CS6530W_Assignment3.zip"

if ! command -v zip >/dev/null 2>&1; then
  echo "Package 'zip' not found. Attempting installation..."
  sudo apt-get install -y zip >/dev/null 2>&1 || { echo "ERROR: please run 'sudo apt install zip'"; exit 1; }
fi

# Ensure all evidence files are readable before archiving
chmod -R a+rX evidence/ 2>/dev/null || true

zip -r "$O" . -x 'config.env' '.role' '.wan_if' '.git/*' '*.zip' >/dev/null && echo "Successfully created submission archive: $O"
