#!/bin/bash
# SecretRef exec provider for OpenClaw + 1Password.
# Reads op:// references via JSON protocol (stdin) and resolves them
# using the 1Password CLI with a file-backed service account token.
#
# ADAPT THESE PATHS to your system:
#   OP_CMD  - absolute path to the 1Password CLI binary
#   JQ_CMD  - absolute path to jq
#   TOKEN   - path to the service account token file
#
# Find your paths:
#   which op    -> /opt/homebrew/bin/op (macOS) or /usr/local/bin/op (Linux)
#   which jq    -> /opt/homebrew/bin/jq (macOS) or /usr/bin/jq (Linux)

set -euo pipefail

# --- ADAPT THESE ---
OP_CMD="/opt/homebrew/bin/op"
JQ_CMD="/opt/homebrew/bin/jq"
TOKEN_FILE="$HOME/.openclaw/.op-token"
# -------------------

export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$TOKEN_FILE")"
export OP_BIOMETRIC_UNLOCK_ENABLED=false

REQUEST="$(cat)"
IDS=($(echo "$REQUEST" | "$JQ_CMD" -r '.ids[]'))

VALUES="{"
FIRST=true
for ID in "${IDS[@]}"; do
  VALUE="$("$OP_CMD" read "$ID" 2>/dev/null)"
  VALUE="$(echo -n "$VALUE" | "$JQ_CMD" -Rs '.')"
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    VALUES="$VALUES,"
  fi
  VALUES="$VALUES$(echo -n "$ID" | "$JQ_CMD" -Rs '.'):$VALUE"
done
VALUES="$VALUES}"

echo "{\"protocolVersion\":1,\"values\":$VALUES}"
