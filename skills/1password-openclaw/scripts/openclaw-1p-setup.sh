#!/bin/bash
# openclaw-1p-setup.sh - Durable 1Password integration for OpenClaw
# Sets up SecretRef exec providers so secrets never touch disk.
#
# Usage:
#   ./openclaw-1p-setup.sh setup     Full onboarding (interactive)
#   ./openclaw-1p-setup.sh repair    Fix plist after openclaw gateway install
#   ./openclaw-1p-setup.sh verify    Check everything is working
#   ./openclaw-1p-setup.sh migrate   Convert ${VAR} refs to SecretRef (non-destructive)
#
# By Drew Burchfield

set -euo pipefail

# --- Configuration -----------------------------------------------------------

OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_BIN="$OPENCLAW_DIR/bin"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
TOKEN_FILE="$OPENCLAW_DIR/.op-token"
RESOLVER_SCRIPT="$OPENCLAW_BIN/op-resolver.sh"
LAUNCHER_SCRIPT="$OPENCLAW_BIN/launch-gateway.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
SYSTEMD_UNIT="openclaw-gateway.service"

# Detect platform
case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *)      PLATFORM="unknown" ;;
esac

# Detect op and jq paths (prefer absolute for portability)
OP_BIN=""
JQ_BIN=""

# --- Colors and Output -------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()  { echo -e "${BLUE}>>>${RESET} $1"; }
ok()    { echo -e "${GREEN} ok${RESET} $1"; }
warn()  { echo -e "${YELLOW} !!${RESET} $1"; }
err()   { echo -e "${RED}ERR${RESET} $1"; }
step()  { echo -e "\n${BOLD}[$1]${RESET} $2"; }
dim()   { echo -e "${DIM}    $1${RESET}"; }

ask() {
  local prompt="$1" default="${2:-}"
  if [ -n "$default" ]; then
    echo -en "${BLUE} ?${RESET} ${prompt} [${default}]: "
    read -r answer
    echo "${answer:-$default}"
  else
    echo -en "${BLUE} ?${RESET} ${prompt}: "
    read -r answer
    echo "$answer"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-y}"
  local yn
  if [ "$default" = "y" ]; then
    echo -en "${BLUE} ?${RESET} ${prompt} [Y/n]: "
  else
    echo -en "${BLUE} ?${RESET} ${prompt} [y/N]: "
  fi
  read -r yn
  yn="${yn:-$default}"
  [[ "$yn" =~ ^[Yy] ]]
}

ask_secret() {
  local prompt="$1"
  echo -en "${BLUE} ?${RESET} ${prompt}: "
  read -rs answer
  echo
  echo "$answer"
}

# --- Prerequisites -----------------------------------------------------------

find_binary() {
  local name="$1"
  local path
  # Check common locations
  for dir in /opt/homebrew/bin /usr/local/bin /usr/bin /snap/bin "$HOME/.local/bin"; do
    if [ -x "$dir/$name" ]; then
      echo "$dir/$name"
      return 0
    fi
  done
  # Fall back to which
  path="$(which "$name" 2>/dev/null || true)"
  if [ -n "$path" ]; then
    echo "$path"
    return 0
  fi
  return 1
}

check_prerequisites() {
  step "1/3" "Checking prerequisites"
  local missing=0

  # OpenClaw
  if command -v openclaw &>/dev/null; then
    local oc_version
    oc_version="$(openclaw --version 2>/dev/null || echo "unknown")"
    ok "OpenClaw $oc_version"
    # Check minimum version
    if [[ "$oc_version" < "2026.3.2" ]] && [[ "$oc_version" != "unknown" ]]; then
      warn "OpenClaw 2026.3.2+ recommended for full SecretRef support (you have $oc_version)"
      if ask_yn "Update now?"; then
        info "Updating OpenClaw..."
        npm install -g openclaw@latest 2>&1 | tail -3
        oc_version="$(openclaw --version 2>/dev/null)"
        ok "Updated to $oc_version"
      fi
    fi
  else
    err "OpenClaw not found. Install it first: npm install -g openclaw"
    missing=1
  fi

  # 1Password CLI
  if OP_BIN="$(find_binary op)"; then
    local op_version
    op_version="$("$OP_BIN" --version 2>/dev/null || echo "unknown")"
    ok "1Password CLI $op_version ($OP_BIN)"
  else
    err "1Password CLI (op) not found. Install: https://developer.1password.com/docs/cli/get-started/"
    missing=1
  fi

  # jq
  if JQ_BIN="$(find_binary jq)"; then
    ok "jq ($JQ_BIN)"
  else
    err "jq not found. Install: brew install jq (macOS) or apt install jq (Linux)"
    missing=1
  fi

  # OpenClaw config
  if [ -f "$OPENCLAW_CONFIG" ]; then
    ok "Config exists at $OPENCLAW_CONFIG"
  else
    err "No openclaw.json found at $OPENCLAW_CONFIG. Run openclaw first to generate it."
    missing=1
  fi

  if [ "$missing" -gt 0 ]; then
    err "Missing prerequisites. Install them and re-run."
    exit 1
  fi
}

# --- 1Password Vault ---------------------------------------------------------

setup_vault() {
  local vault_name="$1"

  step "2/3" "Setting up 1Password vault"

  # Check if vault exists
  if "$OP_BIN" vault get "$vault_name" &>/dev/null; then
    ok "Vault '$vault_name' already exists"
  else
    info "Creating vault '$vault_name'..."
    "$OP_BIN" vault create "$vault_name" &>/dev/null
    ok "Vault '$vault_name' created"
  fi
}

# --- Service Account ----------------------------------------------------------

setup_service_account() {
  local vault_name="$1"

  step "3/3" "Setting up service account"

  if [ -f "$TOKEN_FILE" ]; then
    # Verify existing token works
    local test_result
    if OP_SERVICE_ACCOUNT_TOKEN="$(cat "$TOKEN_FILE")" OP_BIOMETRIC_UNLOCK_ENABLED=false \
       "$OP_BIN" vault list --format=json 2>/dev/null | "$JQ_BIN" -e '.[0]' &>/dev/null; then
      ok "Existing service account token is valid"
      return 0
    else
      warn "Existing token at $TOKEN_FILE is invalid or expired"
    fi
  fi

  echo
  info "You need a 1Password service account token."
  info "If you already have one, paste it below."
  info "If not, create one at: https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount/"
  dim "Grant it 'read_items' access to the '$vault_name' vault."
  echo

  local token
  token="$(ask_secret "Service account token (starts with ops_)")"

  if [[ ! "$token" =~ ^ops_ ]]; then
    err "Token should start with 'ops_'. Check and try again."
    exit 1
  fi

  # Verify the token works
  info "Verifying token..."
  if OP_SERVICE_ACCOUNT_TOKEN="$token" OP_BIOMETRIC_UNLOCK_ENABLED=false \
     "$OP_BIN" vault list --format=json 2>/dev/null | "$JQ_BIN" -e '.[0]' &>/dev/null; then
    ok "Token is valid"
  else
    err "Token verification failed. Check that it has vault access."
    exit 1
  fi

  # Store token
  mkdir -p "$OPENCLAW_DIR"
  echo -n "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  ok "Token stored at $TOKEN_FILE (chmod 600)"
}

# --- Secret Discovery --------------------------------------------------------

# Scan openclaw.json for fields that look like secrets (plaintext or ${VAR})
discover_secrets() {
  local config="$1"
  # Known credential paths in openclaw.json
  # Returns: path|current_value|type (plaintext|envvar|secretref|empty)
  "$JQ_BIN" -r '
    def check_field(path):
      . as $val |
      if ($val | type) == "object" and ($val | has("source")) then
        [path, "secretref"]
      elif ($val | type) == "string" then
        if ($val | test("^\\$\\{[A-Z_]+\\}$")) then
          [path, ($val | gsub("[\\$\\{\\}]"; "")), "envvar"]
        elif ($val | length) > 0 then
          [path, "plaintext"]
        else
          empty
        fi
      else
        empty
      fi;

    # Check known credential locations
    (if .channels.discord.token then
      .channels.discord.token | check_field("channels.discord.token") else empty end),
    (if .channels.bluebubbles.password then
      .channels.bluebubbles.password | check_field("channels.bluebubbles.password") else empty end),
    (if .channels.telegram.token then
      .channels.telegram.token | check_field("channels.telegram.token") else empty end),
    (if .channels.slack.botToken then
      .channels.slack.botToken | check_field("channels.slack.botToken") else empty end),
    (if .gateway.auth.token then
      .gateway.auth.token | check_field("gateway.auth.token") else empty end),
    (if .agents.defaults.memorySearch.remote.apiKey then
      .agents.defaults.memorySearch.remote.apiKey | check_field("agents.defaults.memorySearch.remote.apiKey") else empty end),
    (if .messages.tts.openai.apiKey then
      .messages.tts.openai.apiKey | check_field("messages.tts.openai.apiKey") else empty end),
    (if .talk.apiKey then
      .talk.apiKey | check_field("talk.apiKey") else empty end),
    (if .tools.web.search.apiKey then
      .tools.web.search.apiKey | check_field("tools.web.search.apiKey") else empty end),
    (if .skills.entries then
      (.skills.entries | to_entries[] | select(.value.apiKey) |
        .value.apiKey | check_field("skills.entries.\(.key).apiKey")) else empty end)

    | @tsv
  ' "$config" 2>/dev/null || true
}

# --- Secret Migration --------------------------------------------------------

migrate_secret_to_1password() {
  local vault_name="$1"
  local item_name="$2"
  local secret_value="$3"
  local token
  token="$(cat "$TOKEN_FILE")"

  # Check if item already exists
  if OP_SERVICE_ACCOUNT_TOKEN="$token" OP_BIOMETRIC_UNLOCK_ENABLED=false \
     "$OP_BIN" item get "$item_name" --vault "$vault_name" &>/dev/null; then
    ok "Item '$item_name' already exists in vault"
    return 0
  fi

  # Create item
  OP_SERVICE_ACCOUNT_TOKEN="$token" OP_BIOMETRIC_UNLOCK_ENABLED=false \
    "$OP_BIN" item create \
    --category "API Credential" \
    --title "$item_name" \
    --vault "$vault_name" \
    "credential=$secret_value" &>/dev/null

  ok "Created item '$item_name' in vault '$vault_name'"
}

resolve_envvar_value() {
  local varname="$1"
  # Try to resolve from current environment
  local val="${!varname:-}"
  if [ -n "$val" ]; then
    echo "$val"
    return 0
  fi
  # Try to resolve via op run if secrets.env exists
  if [ -f "$OPENCLAW_DIR/secrets.env" ]; then
    local token
    token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
    if [ -n "$token" ]; then
      val="$(OP_SERVICE_ACCOUNT_TOKEN="$token" OP_BIOMETRIC_UNLOCK_ENABLED=false \
        "$OP_BIN" run --env-file="$OPENCLAW_DIR/secrets.env" -- printenv "$varname" 2>/dev/null || true)"
      if [ -n "$val" ]; then
        echo "$val"
        return 0
      fi
    fi
  fi
  return 1
}

# --- File Generation ----------------------------------------------------------

generate_resolver_script() {
  mkdir -p "$OPENCLAW_BIN"
  cat > "$RESOLVER_SCRIPT" << SCRIPT
#!/bin/bash
# SecretRef exec provider for OpenClaw + 1Password.
# Reads op:// references via JSON protocol (stdin) and resolves them
# using the 1Password CLI with a file-backed service account token.
#
# Generated by openclaw-1p-setup.sh

set -euo pipefail

export OP_SERVICE_ACCOUNT_TOKEN="\$(cat "\$HOME/.openclaw/.op-token")"
export OP_BIOMETRIC_UNLOCK_ENABLED=false

REQUEST="\$(cat)"
IDS=(\$(echo "\$REQUEST" | $JQ_BIN -r '.ids[]'))

VALUES="{"
FIRST=true
for ID in "\${IDS[@]}"; do
  VALUE="\$($OP_BIN read "\$ID" 2>/dev/null)"
  VALUE="\$(echo -n "\$VALUE" | $JQ_BIN -Rs '.')"
  if [ "\$FIRST" = true ]; then
    FIRST=false
  else
    VALUES="\$VALUES,"
  fi
  VALUES="\$VALUES\$(echo -n "\$ID" | $JQ_BIN -Rs '.'):\$VALUE"
done
VALUES="\$VALUES}"

echo "{\"protocolVersion\":1,\"values\":\$VALUES}"
SCRIPT
  chmod +x "$RESOLVER_SCRIPT"
  ok "Resolver script created at $RESOLVER_SCRIPT"
}

generate_launcher_script() {
  local gateway_op_ref="$1"
  local node_bin
  node_bin="$(find_binary node)"

  mkdir -p "$OPENCLAW_BIN"
  cat > "$LAUNCHER_SCRIPT" << SCRIPT
#!/bin/bash
# Gateway launcher - resolves the one credential that can't use SecretRef
# (gateway.auth.token is out-of-scope for SecretRef exec providers).
# All other secrets are resolved by the gateway itself via SecretRef.
#
# Generated by openclaw-1p-setup.sh

set -euo pipefail

export OP_SERVICE_ACCOUNT_TOKEN="\$(cat "\$HOME/.openclaw/.op-token")"
export OP_BIOMETRIC_UNLOCK_ENABLED=false
export OPENCLAW_GATEWAY_TOKEN="\$($OP_BIN read "$gateway_op_ref")"

exec $node_bin \\
  \$(dirname \$(readlink -f "\$(which openclaw)" 2>/dev/null || echo "$node_bin"))/../../lib/node_modules/openclaw/dist/index.js \\
  gateway --port \${OPENCLAW_GATEWAY_PORT:-18789}
SCRIPT
  chmod +x "$LAUNCHER_SCRIPT"
  ok "Launcher script created at $LAUNCHER_SCRIPT"
}

# --- Config Migration ---------------------------------------------------------

# Build the SecretRef object for a given op:// path
secretref_json() {
  local op_ref="$1"
  "$JQ_BIN" -n --arg ref "$op_ref" '{
    source: "exec",
    provider: "onepassword",
    id: $ref
  }'
}

apply_secretref_to_config() {
  local config="$1"
  local json_path="$2"
  local op_ref="$3"

  local ref_obj
  ref_obj="$(secretref_json "$op_ref")"

  # Use jq to set the value at the given path
  # jq path format: .channels.discord.token
  local jq_path=".${json_path}"
  local tmp
  tmp="$(mktemp)"
  "$JQ_BIN" --argjson ref "$ref_obj" "$jq_path = \$ref" "$config" > "$tmp"
  mv "$tmp" "$config"
}

apply_envvar_to_config() {
  local config="$1"
  local json_path="$2"
  local varname="$3"

  local jq_path=".${json_path}"
  local value="\${${varname}}"
  local tmp
  tmp="$(mktemp)"
  "$JQ_BIN" --arg val "$value" "$jq_path = \$val" "$config" > "$tmp"
  mv "$tmp" "$config"
}

add_secrets_provider() {
  local config="$1"

  # Check if already present
  if "$JQ_BIN" -e '.secrets.providers.onepassword' "$config" &>/dev/null; then
    ok "SecretRef provider 'onepassword' already configured"
    return 0
  fi

  local provider
  provider="$("$JQ_BIN" -n \
    --arg cmd "$RESOLVER_SCRIPT" \
    --arg dir "$OPENCLAW_BIN" \
    '{
      secrets: {
        providers: {
          onepassword: {
            source: "exec",
            command: $cmd,
            allowSymlinkCommand: false,
            trustedDirs: [$dir],
            passEnv: ["HOME"],
            jsonOnly: true,
            timeoutMs: 15000
          }
        }
      }
    }')"

  local tmp
  tmp="$(mktemp)"
  "$JQ_BIN" --argjson provider "$provider" '. + $provider' "$config" > "$tmp"
  mv "$tmp" "$config"
  ok "SecretRef provider 'onepassword' added to config"
}

# --- LaunchAgent / systemd ----------------------------------------------------

repair_launchagent() {
  if [ ! -f "$PLIST_PATH" ]; then
    warn "LaunchAgent plist not found at $PLIST_PATH"
    return 1
  fi

  info "Updating LaunchAgent ProgramArguments..."

  # Replace ProgramArguments with launcher script
  /usr/libexec/PlistBuddy -c "Delete :ProgramArguments" "$PLIST_PATH" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $LAUNCHER_SCRIPT" "$PLIST_PATH"

  # Ensure HOME is set
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:HOME $HOME" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:HOME string $HOME" "$PLIST_PATH" 2>/dev/null || true

  ok "LaunchAgent plist updated"
}

bounce_gateway_macos() {
  info "Bouncing gateway..."
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  sleep 2
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null
  sleep 8
}

bounce_gateway_linux() {
  info "Restarting gateway..."
  systemctl --user restart "$SYSTEMD_UNIT" 2>/dev/null || true
  sleep 5
}

bounce_gateway() {
  if [ "$PLATFORM" = "macos" ]; then
    bounce_gateway_macos
  elif [ "$PLATFORM" = "linux" ]; then
    bounce_gateway_linux
  fi
}

# --- Verification -------------------------------------------------------------

verify() {
  local failures=0

  step "V" "Running verification"

  # 1. Token file
  if [ -f "$TOKEN_FILE" ]; then
    local perms
    if [ "$PLATFORM" = "macos" ]; then
      perms="$(stat -f '%Sp' "$TOKEN_FILE")"
    else
      perms="$(stat -c '%a' "$TOKEN_FILE")"
    fi
    if [[ "$perms" == "-rw-------" ]] || [[ "$perms" == "600" ]]; then
      ok "Token file exists with correct permissions"
    else
      warn "Token file permissions are $perms (should be 600)"
      failures=$((failures + 1))
    fi
  else
    err "Token file missing at $TOKEN_FILE"
    failures=$((failures + 1))
  fi

  # 2. Token is valid
  if [ -f "$TOKEN_FILE" ]; then
    if OP_SERVICE_ACCOUNT_TOKEN="$(cat "$TOKEN_FILE")" OP_BIOMETRIC_UNLOCK_ENABLED=false \
       "$OP_BIN" vault list --format=json 2>/dev/null | "$JQ_BIN" -e '.[0]' &>/dev/null; then
      ok "Service account token is valid"
    else
      err "Service account token is invalid or expired"
      failures=$((failures + 1))
    fi
  fi

  # 3. Resolver script
  if [ -x "$RESOLVER_SCRIPT" ]; then
    ok "Resolver script exists and is executable"
  else
    err "Resolver script missing or not executable at $RESOLVER_SCRIPT"
    failures=$((failures + 1))
  fi

  # 4. Launcher script
  if [ -x "$LAUNCHER_SCRIPT" ]; then
    ok "Launcher script exists and is executable"
  else
    err "Launcher script missing or not executable at $LAUNCHER_SCRIPT"
    failures=$((failures + 1))
  fi

  # 5. SecretRef provider in config
  if "$JQ_BIN" -e '.secrets.providers.onepassword' "$OPENCLAW_CONFIG" &>/dev/null; then
    ok "SecretRef provider 'onepassword' configured"
  else
    err "SecretRef provider 'onepassword' not found in config"
    failures=$((failures + 1))
  fi

  # 6. No plaintext secrets (check for common patterns)
  local plaintext_count
  plaintext_count="$(grep -cE '"(sk-|xox|ghp_|pa-|ops_)[a-zA-Z0-9]' "$OPENCLAW_CONFIG" 2>/dev/null || echo "0")"
  plaintext_count="$(echo "$plaintext_count" | tr -d '[:space:]')"
  if [ "$plaintext_count" -eq 0 ] 2>/dev/null; then
    ok "No plaintext secrets detected in config"
  else
    warn "$plaintext_count potential plaintext secret(s) in config"
    failures=$((failures + 1))
  fi

  # 7. Count remaining ${VAR} references (1 is expected for gateway.auth.token)
  local envvar_count
  envvar_count="$(grep -cE '"\$\{[A-Z_]+\}"' "$OPENCLAW_CONFIG" 2>/dev/null || echo 0)"
  if [ "$envvar_count" -le 1 ]; then
    ok "$envvar_count \${VAR} reference(s) remaining (1 expected for gateway.auth.token)"
  else
    warn "$envvar_count \${VAR} reference(s) remaining (expected 1)"
    failures=$((failures + 1))
  fi

  # 8. Gateway running
  if lsof -i :${OPENCLAW_GATEWAY_PORT:-18789} &>/dev/null; then
    ok "Gateway is listening on port ${OPENCLAW_GATEWAY_PORT:-18789}"
  else
    err "Gateway is not listening on port ${OPENCLAW_GATEWAY_PORT:-18789}"
    failures=$((failures + 1))
  fi

  # 9. Secrets audit (needs OPENCLAW_GATEWAY_TOKEN resolved for the one ${VAR} field)
  if command -v openclaw &>/dev/null && [ -f "$TOKEN_FILE" ] && [ -x "$LAUNCHER_SCRIPT" ]; then
    # Extract the op:// ref from the launcher script
    local gw_ref
    gw_ref="$(grep -oE 'op://[^ "]+' "$LAUNCHER_SCRIPT" 2>/dev/null | head -1)"
    local gateway_token=""
    if [ -n "$gw_ref" ]; then
      gateway_token="$(OP_SERVICE_ACCOUNT_TOKEN="$(cat "$TOKEN_FILE")" \
        OP_BIOMETRIC_UNLOCK_ENABLED=false \
        "$OP_BIN" read "$gw_ref" 2>/dev/null || true)"
    fi
    local audit_result
    audit_result="$(OPENCLAW_GATEWAY_TOKEN="${gateway_token}" \
      OP_SERVICE_ACCOUNT_TOKEN="$(cat "$TOKEN_FILE")" \
      OP_BIOMETRIC_UNLOCK_ENABLED=false \
      openclaw secrets audit --check 2>&1 || true)"
    local unresolved
    unresolved="$(echo "$audit_result" | sed -n 's/.*unresolved=\([0-9]*\).*/\1/p' | head -1)"
    unresolved="${unresolved:-?}"
    if [ "$unresolved" = "0" ]; then
      ok "Secrets audit: 0 unresolved references"
    else
      warn "Secrets audit: $unresolved unresolved reference(s)"
      dim "$audit_result"
    fi
  fi

  echo
  if [ "$failures" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All checks passed.${RESET}"
  else
    echo -e "${YELLOW}${BOLD}$failures issue(s) found.${RESET}"
  fi

  return "$failures"
}

# --- Main Commands ------------------------------------------------------------

cmd_setup() {
  echo -e "${BOLD}OpenClaw + 1Password Setup${RESET}"
  echo -e "${DIM}SecretRef exec provider with file-backed service account${RESET}"
  echo

  check_prerequisites

  # Vault name
  local vault_name
  vault_name="$(ask "1Password vault name for OpenClaw secrets" "OpenClaw Secrets")"

  setup_vault "$vault_name"
  setup_service_account "$vault_name"

  # --- Discover and migrate secrets ---
  step "4" "Discovering secrets in openclaw.json"

  local secrets_found=()
  local secret_paths=()
  local secret_types=()

  while IFS=$'\t' read -r path type_or_var extra; do
    [ -z "$path" ] && continue
    secrets_found+=("$path")
    if [ "$extra" = "envvar" ]; then
      secret_types+=("envvar:$type_or_var")
    else
      secret_types+=("$type_or_var")
    fi
  done < <(discover_secrets "$OPENCLAW_CONFIG")

  if [ ${#secrets_found[@]} -eq 0 ]; then
    warn "No credential fields found in config. Is OpenClaw configured?"
    return 1
  fi

  echo
  info "Found ${#secrets_found[@]} credential field(s):"
  for i in "${!secrets_found[@]}"; do
    local path="${secrets_found[$i]}"
    local stype="${secret_types[$i]}"
    case "$stype" in
      secretref) dim "  $path -> already SecretRef (skipping)" ;;
      plaintext) warn "  $path -> plaintext (will migrate)" ;;
      envvar:*)  info "  $path -> \${${stype#envvar:}} (will migrate to SecretRef)" ;;
    esac
  done

  echo
  if ! ask_yn "Proceed with migration?"; then
    info "Aborted."
    exit 0
  fi

  # --- Naming convention ---
  step "5" "Migrating secrets to 1Password"

  # Map config paths to 1Password item names
  declare -A PATH_TO_ITEM_NAME=(
    ["channels.discord.token"]="openclaw-discord"
    ["channels.bluebubbles.password"]="openclaw-bluebubbles"
    ["channels.telegram.token"]="openclaw-telegram"
    ["channels.slack.botToken"]="openclaw-slack"
    ["gateway.auth.token"]="openclaw-gateway"
    ["agents.defaults.memorySearch.remote.apiKey"]="openclaw-voyage"
    ["messages.tts.openai.apiKey"]="openclaw-openai-tts"
    ["talk.apiKey"]="openclaw-elevenlabs"
    ["tools.web.search.apiKey"]="openclaw-brave-search"
  )

  local gateway_op_ref=""

  for i in "${!secrets_found[@]}"; do
    local path="${secrets_found[$i]}"
    local stype="${secret_types[$i]}"

    # Skip already-migrated
    [ "$stype" = "secretref" ] && continue

    # Determine item name
    local item_name="${PATH_TO_ITEM_NAME[$path]:-}"
    if [ -z "$item_name" ]; then
      # For dynamic paths like skills.entries.goplaces.apiKey
      local leaf
      leaf="$(echo "$path" | sed 's/.*entries\.\([^.]*\)\..*/openclaw-\1/')"
      item_name="$(ask "1Password item name for $path" "$leaf")"
    fi

    local op_ref="op://$vault_name/$item_name/credential"

    # Get current value if plaintext
    if [ "$stype" = "plaintext" ]; then
      local current_value
      current_value="$("$JQ_BIN" -r ".$path" "$OPENCLAW_CONFIG")"
      if [ -n "$current_value" ] && [ "$current_value" != "null" ]; then
        migrate_secret_to_1password "$vault_name" "$item_name" "$current_value"
      fi
    elif [[ "$stype" == envvar:* ]]; then
      local varname="${stype#envvar:}"
      local current_value
      if current_value="$(resolve_envvar_value "$varname")"; then
        migrate_secret_to_1password "$vault_name" "$item_name" "$current_value"
      else
        warn "Could not resolve \${$varname}. Create item '$item_name' manually in '$vault_name'."
      fi
    fi

    # Apply config change
    if [ "$path" = "gateway.auth.token" ]; then
      # gateway.auth.token can't use SecretRef, use ${VAR}
      apply_envvar_to_config "$OPENCLAW_CONFIG" "$path" "OPENCLAW_GATEWAY_TOKEN"
      gateway_op_ref="$op_ref"
      ok "$path -> \${OPENCLAW_GATEWAY_TOKEN} (SecretRef not supported for this field)"
    else
      apply_secretref_to_config "$OPENCLAW_CONFIG" "$path" "$op_ref"
      ok "$path -> SecretRef ($op_ref)"
    fi
  done

  # Add the provider block
  step "6" "Configuring SecretRef provider"
  generate_resolver_script
  add_secrets_provider "$OPENCLAW_CONFIG"

  # Test the resolver
  info "Testing resolver..."
  local test_ref
  for i in "${!secrets_found[@]}"; do
    local path="${secrets_found[$i]}"
    [ "$path" = "gateway.auth.token" ] && continue
    local stype="${secret_types[$i]}"
    [ "$stype" = "secretref" ] && continue
    local item_name="${PATH_TO_ITEM_NAME[$path]:-}"
    [ -z "$item_name" ] && continue
    test_ref="op://$vault_name/$item_name/credential"
    break
  done

  if [ -n "${test_ref:-}" ]; then
    local test_result
    test_result="$(echo "{\"protocolVersion\":1,\"provider\":\"onepassword\",\"ids\":[\"$test_ref\"]}" \
      | "$RESOLVER_SCRIPT" 2>/dev/null | "$JQ_BIN" -r '.values | keys | length' 2>/dev/null || echo "0")"
    if [ "$test_result" -gt 0 ]; then
      ok "Resolver successfully resolved a test secret"
    else
      err "Resolver test failed. Check $TOKEN_FILE and vault access."
    fi
  fi

  # Generate launcher and fix service
  step "7" "Setting up gateway launcher"

  if [ -z "$gateway_op_ref" ]; then
    gateway_op_ref="op://$vault_name/openclaw-gateway/credential"
  fi

  generate_launcher_script "$gateway_op_ref"

  if [ "$PLATFORM" = "macos" ] && [ -f "$PLIST_PATH" ]; then
    repair_launchagent
    bounce_gateway
  elif [ "$PLATFORM" = "linux" ]; then
    warn "Linux detected. You may need to update your systemd unit manually."
    dim "Set ExecStart=$LAUNCHER_SCRIPT in your service file."
  fi

  # Shell wrapper advice
  step "8" "Shell configuration"
  echo
  info "Add this to your ~/.zshrc (or ~/.bashrc):"
  echo
  echo -e "${DIM}  # 1Password service account for OpenClaw"
  echo "  export OP_SERVICE_ACCOUNT_TOKEN=\"\$(cat ~/.openclaw/.op-token)\""
  echo ""
  echo "  # Resolve gateway token for CLI"
  echo "  openclaw() {"
  echo "    OPENCLAW_GATEWAY_TOKEN=\"\$($OP_BIN read \"$gateway_op_ref\")\" \\"
  echo "      command openclaw \"\$@\""
  echo "  }"
  echo -e "${RESET}"

  # Verify
  verify || true

  echo
  echo -e "${BOLD}Setup complete.${RESET}"
  echo
  dim "After OpenClaw updates, run: $0 repair"
}

cmd_repair() {
  echo -e "${BOLD}OpenClaw + 1Password Repair${RESET}"
  echo

  OP_BIN="$(find_binary op)" || { err "op not found"; exit 1; }
  JQ_BIN="$(find_binary jq)" || { err "jq not found"; exit 1; }

  # Verify scripts exist
  if [ ! -x "$RESOLVER_SCRIPT" ]; then
    err "Resolver script not found. Run '$0 setup' first."
    exit 1
  fi
  if [ ! -x "$LAUNCHER_SCRIPT" ]; then
    err "Launcher script not found. Run '$0 setup' first."
    exit 1
  fi

  # Check if SecretRef provider is still in config
  if ! "$JQ_BIN" -e '.secrets.providers.onepassword' "$OPENCLAW_CONFIG" &>/dev/null; then
    warn "SecretRef provider was removed from config. Re-adding..."
    add_secrets_provider "$OPENCLAW_CONFIG"
  else
    ok "SecretRef provider intact"
  fi

  # Fix plist
  if [ "$PLATFORM" = "macos" ] && [ -f "$PLIST_PATH" ]; then
    repair_launchagent
    bounce_gateway
  elif [ "$PLATFORM" = "linux" ]; then
    info "Linux: verify your systemd unit uses ExecStart=$LAUNCHER_SCRIPT"
  fi

  verify || true

  echo
  echo -e "${BOLD}Repair complete.${RESET}"
}

cmd_verify() {
  OP_BIN="$(find_binary op)" || { err "op not found"; exit 1; }
  JQ_BIN="$(find_binary jq)" || { err "jq not found"; exit 1; }
  verify
}

cmd_migrate() {
  echo -e "${BOLD}OpenClaw Config Migration${RESET}"
  echo -e "${DIM}Convert \${VAR} references to SecretRef objects${RESET}"
  echo

  OP_BIN="$(find_binary op)" || { err "op not found"; exit 1; }
  JQ_BIN="$(find_binary jq)" || { err "jq not found"; exit 1; }

  # This reuses the setup flow but only for the config migration part
  if [ ! -f "$TOKEN_FILE" ]; then
    err "No token file found. Run '$0 setup' first."
    exit 1
  fi

  local vault_name
  vault_name="$(ask "1Password vault name" "OpenClaw Secrets")"

  step "1" "Discovering secrets"
  local has_envvars=false
  while IFS=$'\t' read -r path type_or_var extra; do
    [ -z "$path" ] && continue
    if [ "$extra" = "envvar" ]; then
      has_envvars=true
      info "  $path -> \${$type_or_var} (will convert to SecretRef)"
    fi
  done < <(discover_secrets "$OPENCLAW_CONFIG")

  if ! $has_envvars; then
    ok "No \${VAR} references to migrate. Config is already using SecretRef."
    return 0
  fi

  if ! ask_yn "Proceed?"; then
    info "Aborted."
    exit 0
  fi

  # Reuse the full setup logic with existing vault
  cmd_setup
}

# --- Entry Point --------------------------------------------------------------

case "${1:-help}" in
  setup)   cmd_setup ;;
  repair)  cmd_repair ;;
  verify)  cmd_verify ;;
  migrate) cmd_migrate ;;
  help|--help|-h)
    echo "Usage: $0 <command>"
    echo
    echo "Commands:"
    echo "  setup     Full onboarding (interactive)"
    echo "  repair    Fix plist/service after openclaw gateway install"
    echo "  verify    Check everything is working"
    echo "  migrate   Convert \${VAR} refs to SecretRef"
    echo
    echo "After OpenClaw updates, run: $0 repair"
    ;;
  *)
    err "Unknown command: $1"
    echo "Run '$0 help' for usage."
    exit 1
    ;;
esac
