#!/usr/bin/env bash
# Build <ROLLNO>_CS6530W_Assignment3.zip (no root needed). Excludes config.env/.role.
cd "$(dirname "$0")/.." || exit 1
source ./config.env; R="${ROLLNO^^}"; O="../${R}_CS6530W_Assignment3.zip"
command -v zip >/dev/null || { echo "install zip"; exit 1; }
zip -r "$O" . -x 'config.env' '.role' '.git/*' '*.zip' >/dev/null && echo "wrote $O"
