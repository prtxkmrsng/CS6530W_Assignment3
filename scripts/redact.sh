#!/usr/bin/env bash
# Filter: redact cryptographic key bytes from `ip xfrm` output.
sed -E 's/0x[0-9a-fA-F]{20,}/0x<REDACTED>/g'
