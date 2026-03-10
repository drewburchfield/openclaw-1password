#!/bin/bash
# openclaw-1p-setup.sh - Durable 1Password integration for OpenClaw
# Sets up per-secret direct-op SecretRef providers so secrets never touch disk.
#
# Usage:
#   ./openclaw-1p-setup.sh setup     Full onboarding (interactive)
#   ./openclaw-1p-setup.sh repair    Fix plist after openclaw gateway install
#   ./openclaw-1p-setup.sh verify    Check everything is working
#
# By Drew Burchfield

set -euo pipefail

# --- Configuration -----------------------------------------------------------

OPENCLAW_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"
ENV_FILE="$OPENCLAW_DIR/.env"
TOKEN_FILE="$OPENCLAW_DIR/.op-token"  # legacy, still checked for migration
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

  # Check for existing token in .env or legacy .op-token
  local existing_token=""
  if [ -f "$ENV_FILE" ]; then
    existing_token="$(grep '^OP_SERVICE_ACCOUNT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  elif [ -f "$TOKEN_FILE" ]; then
    existing_token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  fi

  if [ -n "$existing_token" ]; then
    # Verify existing token works
    if OP_SERVICE_ACCOUNT_TOKEN="$existing_token" OP_BIOMETRIC_UNLOCK_ENABLED=false \
       OP_NO_AUTO_SIGNIN=true OP_LOAD_DESKTOP_APP_SETTINGS=false \
       "$OP_BIN" vault list --format=json 2>/dev/null | "$JQ_BIN" -e '.[0]' &>/dev/null; then
      ok "Existing service account token is valid"
      # Ensure .env file exists with all 4 vars
      create_env_file "$existing_token"
      return 0
    else
      warn "Existing token is invalid or expired"
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
     OP_NO_AUTO_SIGNIN=true OP_LOAD_DESKTOP_APP_SETTINGS=false \
     "$OP_BIN" vault list --format=json 2>/dev/null | "$JQ_BIN" -e '.[0]' &>/dev/null; then
    ok "Token is valid"
  else
    err "Token verification failed. Check that it has vault access."
    exit 1
  fi

  # Create .env file
  create_env_file "$token"
}

create_env_file() {
  local token="$1"

  mkdir -p "$OPENCLAW_DIR"
  cat > "$ENV_FILE" << EOF
OP_SERVICE_ACCOUNT_TOKEN=$token
OP_BIOMETRIC_UNLOCK_ENABLED=false
OP_NO_AUTO_SIGNIN=true
OP_LOAD_DESKTOP_APP_SETTINGS=false
EOF
  chmod 600 "$ENV_FILE"
  ok "Env file created at $ENV_FILE (chmod 600)"
}

# Load env vars from .env file into current shell
load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
  elif [ -f "$TOKEN_FILE" ]; then
    export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$TOKEN_FILE")"
    export OP_BIOMETRIC_UNLOCK_ENABLED=false
    export OP_NO_AUTO_SIGNIN=true
    export OP_LOAD_DESKTOP_APP_SETTINGS=false
  fi
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

  load_env

  # Check if item already exists
  if "$OP_BIN" item get "$item_name" --vault "$vault_name" &>/dev/null; then
    ok "Item '$item_name' already exists in vault"
    return 0
  fi

  # Create item
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
    load_env
    val="$("$OP_BIN" run --env-file="$OPENCLAW_DIR/secrets.env" -- printenv "$varname" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      echo "$val"
      return 0
    fi
  fi
  return 1
}

# --- Config Migration ---------------------------------------------------------

# Build the provider JSON for a given op:// path and provider name
provider_json() {
  local provider_name="$1"
  local op_ref="$2"

  "$JQ_BIN" -n \
    --arg cmd "$OP_BIN" \
    --arg ref "$op_ref" \
    '{
      source: "exec",
      command: $cmd,
      args: ["read", $ref, "--no-newline"],
      allowSymlinkCommand: true,
      trustedDirs: ["/opt/homebrew"],
      passEnv: [
        "OP_SERVICE_ACCOUNT_TOKEN",
        "OP_BIOMETRIC_UNLOCK_ENABLED",
        "OP_NO_AUTO_SIGNIN",
        "OP_LOAD_DESKTOP_APP_SETTINGS"
      ],
      jsonOnly: false,
      timeoutMs: 15000
    }'
}

# Build the SecretRef object for a given provider name
secretref_json() {
  local provider_name="$1"
  "$JQ_BIN" -n --arg prov "$provider_name" '{
    source: "exec",
    provider: $prov,
    id: $prov
  }'
}

add_provider_to_config() {
  local config="$1"
  local provider_name="$2"
  local op_ref="$3"

  # Check if this provider already exists
  if "$JQ_BIN" -e ".secrets.providers[\"$provider_name\"]" "$config" &>/dev/null; then
    ok "Provider '$provider_name' already configured"
    return 0
  fi

  local prov
  prov="$(provider_json "$provider_name" "$op_ref")"

  local tmp
  tmp="$(mktemp)"

  # Ensure secrets.providers exists, then add the provider
  "$JQ_BIN" --arg name "$provider_name" --argjson prov "$prov" '
    .secrets.providers[$name] = $prov
  ' "$config" > "$tmp"
  mv "$tmp" "$config"
}

apply_secretref_to_config() {
  local config="$1"
  local json_path="$2"
  local provider_name="$3"

  local ref_obj
  ref_obj="$(secretref_json "$provider_name")"

  # Use jq to set the value at the given path
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

ensure_secrets_providers_block() {
  local config="$1"

  if ! "$JQ_BIN" -e '.secrets.providers' "$config" &>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    "$JQ_BIN" '. + {secrets: {providers: {}}}' "$config" > "$tmp"
    mv "$tmp" "$config"
    ok "Created secrets.providers block in config"
  fi
}

# Remove old resolver-based provider if it exists
remove_legacy_provider() {
  local config="$1"

  if "$JQ_BIN" -e '.secrets.providers.onepassword' "$config" &>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    "$JQ_BIN" 'del(.secrets.providers.onepassword)' "$config" > "$tmp"
    mv "$tmp" "$config"
    ok "Removed legacy 'onepassword' resolver-based provider"
  fi
}

# --- LaunchAgent / systemd ----------------------------------------------------

repair_launchagent() {
  if [ ! -f "$PLIST_PATH" ]; then
    warn "LaunchAgent plist not found at $PLIST_PATH"
    return 1
  fi

  local node_bin="/opt/homebrew/opt/node/bin/node"
  local changes=0

  # Fix node path: replace versioned Cellar path with stable symlink
  if grep -q '/opt/homebrew/Cellar/node/' "$PLIST_PATH"; then
    sed -i '' "s|/opt/homebrew/Cellar/node/[^<]*/bin/node|$node_bin|g" "$PLIST_PATH"
    ok "Fixed node path -> $node_bin"
    changes=$((changes + 1))
  else
    ok "Node path already stable"
  fi

  # Fix ThrottleInterval using PlistBuddy
  local current_throttle
  current_throttle="$(/usr/libexec/PlistBuddy -c "Print :ThrottleInterval" "$PLIST_PATH" 2>/dev/null || echo "0")"
  if [ "$current_throttle" -lt 30 ] 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Set :ThrottleInterval 30" "$PLIST_PATH" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 30" "$PLIST_PATH" 2>/dev/null || true
    ok "Fixed ThrottleInterval -> 30"
    changes=$((changes + 1))
  else
    ok "ThrottleInterval already >= 30"
  fi

  # Load env vars
  load_env

  # Ensure OP_SERVICE_ACCOUNT_TOKEN in plist
  local current_val
  current_val="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:OP_SERVICE_ACCOUNT_TOKEN" "$PLIST_PATH" 2>/dev/null || echo "")"
  if [ -z "$current_val" ]; then
    local token="${OP_SERVICE_ACCOUNT_TOKEN:-}"
    if [ -n "$token" ]; then
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OP_SERVICE_ACCOUNT_TOKEN string $token" "$PLIST_PATH" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OP_SERVICE_ACCOUNT_TOKEN $token" "$PLIST_PATH" 2>/dev/null || true
      ok "Added OP_SERVICE_ACCOUNT_TOKEN to plist"
      changes=$((changes + 1))
    else
      warn "Could not find OP_SERVICE_ACCOUNT_TOKEN. Add it to plist manually."
    fi
  else
    ok "OP_SERVICE_ACCOUNT_TOKEN present in plist"
  fi

  # Ensure OP_BIOMETRIC_UNLOCK_ENABLED=false in plist
  ensure_plist_env_var "OP_BIOMETRIC_UNLOCK_ENABLED" "false"
  changes=$((changes + $?))

  # Ensure OP_NO_AUTO_SIGNIN=true in plist
  ensure_plist_env_var "OP_NO_AUTO_SIGNIN" "true"
  changes=$((changes + $?))

  # Ensure OP_LOAD_DESKTOP_APP_SETTINGS=false in plist
  ensure_plist_env_var "OP_LOAD_DESKTOP_APP_SETTINGS" "false"
  changes=$((changes + $?))

  # Resolve and ensure OPENCLAW_GATEWAY_TOKEN in plist
  if ! /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:OPENCLAW_GATEWAY_TOKEN" "$PLIST_PATH" &>/dev/null; then
    local gateway_token=""
    gateway_token="$(resolve_gateway_token)"
    if [ -n "$gateway_token" ]; then
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OPENCLAW_GATEWAY_TOKEN string $gateway_token" "$PLIST_PATH" 2>/dev/null || true
      ok "Added OPENCLAW_GATEWAY_TOKEN to plist"
      changes=$((changes + 1))
    else
      warn "Could not resolve gateway token. Add OPENCLAW_GATEWAY_TOKEN to plist manually."
    fi
  else
    ok "OPENCLAW_GATEWAY_TOKEN present in plist"
  fi

  # Ensure HOME is set
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:HOME $HOME" "$PLIST_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:HOME string $HOME" "$PLIST_PATH" 2>/dev/null || true

  if [ "$changes" -gt 0 ]; then
    ok "LaunchAgent plist updated ($changes fix(es) applied)"
  else
    ok "LaunchAgent plist already correct"
  fi
}

# Helper: ensure a specific env var exists in plist with correct value
ensure_plist_env_var() {
  local varname="$1"
  local expected="$2"

  local current
  current="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$varname" "$PLIST_PATH" 2>/dev/null || echo "")"
  if [ "$current" != "$expected" ]; then
    if [ -n "$current" ]; then
      /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:$varname $expected" "$PLIST_PATH" 2>/dev/null || true
    else
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:$varname string $expected" "$PLIST_PATH" 2>/dev/null || true
    fi
    ok "$varname set to $expected in plist"
    return 1  # 1 change made
  else
    ok "$varname already correct in plist"
    return 0
  fi
}

# Resolve gateway token from 1Password
resolve_gateway_token() {
  load_env

  # Try to find the op:// reference from config (check common provider names)
  local vault_name=""
  for name in "op-gateway" "gateway-token"; do
    vault_name="$("$JQ_BIN" -r ".secrets.providers[\"$name\"].args[] | select(startswith(\"op://\"))" "$OPENCLAW_CONFIG" 2>/dev/null || true)"
    [ -n "$vault_name" ] && break
  done

  if [ -z "$vault_name" ]; then
    # Fall back to default reference
    vault_name="op://OpenClaw Secrets/openclaw-gateway/credential"
  fi

  local token
  token="$("$OP_BIN" read "$vault_name" 2>/dev/null || true)"
  echo "$token"
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

  # 1. Env file
  if [ -f "$ENV_FILE" ]; then
    local perms
    if [ "$PLATFORM" = "macos" ]; then
      perms="$(stat -f '%Sp' "$ENV_FILE")"
    else
      perms="$(stat -c '%a' "$ENV_FILE")"
    fi
    if [[ "$perms" == "-rw-------" ]] || [[ "$perms" == "600" ]]; then
      ok "Env file exists with correct permissions"
    else
      warn "Env file permissions are $perms (should be 600)"
      failures=$((failures + 1))
    fi
  else
    err "Env file missing at $ENV_FILE"
    failures=$((failures + 1))
  fi

  # 2. Token is valid
  load_env
  if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    if "$OP_BIN" vault list --format=json 2>/dev/null | "$JQ_BIN" -e '.[0]' &>/dev/null; then
      ok "Service account token is valid"
    else
      err "Service account token is invalid or expired"
      failures=$((failures + 1))
    fi
  else
    err "OP_SERVICE_ACCOUNT_TOKEN not found in env"
    failures=$((failures + 1))
  fi

  # 3. SecretRef providers in config
  local provider_count
  provider_count="$("$JQ_BIN" -r '.secrets.providers | keys | length' "$OPENCLAW_CONFIG" 2>/dev/null || echo "0")"
  if [ "$provider_count" -gt 0 ]; then
    ok "$provider_count SecretRef provider(s) configured"
  else
    err "No SecretRef providers found in config"
    failures=$((failures + 1))
  fi

  # 4. No plaintext secrets (check for common patterns)
  local plaintext_count
  plaintext_count="$(grep -cE '"(sk-|xox|ghp_|pa-|ops_)[a-zA-Z0-9]' "$OPENCLAW_CONFIG" 2>/dev/null || echo "0")"
  plaintext_count="$(echo "$plaintext_count" | tr -d '[:space:]')"
  if [ "$plaintext_count" -eq 0 ] 2>/dev/null; then
    ok "No plaintext secrets detected in config"
  else
    warn "$plaintext_count potential plaintext secret(s) in config"
    failures=$((failures + 1))
  fi

  # 5. Count remaining ${VAR} references (1 is expected for gateway.auth.token)
  local envvar_count
  envvar_count="$(grep -cE '"\$\{[A-Z_]+\}"' "$OPENCLAW_CONFIG" 2>/dev/null || echo 0)"
  if [ "$envvar_count" -le 1 ]; then
    ok "$envvar_count \${VAR} reference(s) remaining (1 expected for gateway.auth.token)"
  else
    warn "$envvar_count \${VAR} reference(s) remaining (expected 1)"
    failures=$((failures + 1))
  fi

  # 6. 1Password env vars in plist (macOS only)
  if [ "$PLATFORM" = "macos" ] && [ -f "$PLIST_PATH" ]; then
    local plist_ok=true
    for varname in OP_SERVICE_ACCOUNT_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED OP_NO_AUTO_SIGNIN OP_LOAD_DESKTOP_APP_SETTINGS OPENCLAW_GATEWAY_TOKEN; do
      if ! /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$varname" "$PLIST_PATH" &>/dev/null; then
        warn "$varname missing from plist EnvironmentVariables"
        plist_ok=false
        failures=$((failures + 1))
      fi
    done
    if $plist_ok; then
      ok "All required env vars present in plist"
    fi
  fi

  # 7. Gateway running
  if lsof -i :${OPENCLAW_GATEWAY_PORT:-18789} &>/dev/null; then
    ok "Gateway is listening on port ${OPENCLAW_GATEWAY_PORT:-18789}"
  else
    err "Gateway is not listening on port ${OPENCLAW_GATEWAY_PORT:-18789}"
    failures=$((failures + 1))
  fi

  # 8. Secrets audit
  if command -v openclaw &>/dev/null; then
    local gateway_token
    gateway_token="$(resolve_gateway_token)"
    local audit_result
    audit_result="$(OPENCLAW_GATEWAY_TOKEN="${gateway_token}" \
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
  echo -e "${DIM}Direct-op SecretRef providers with TCC prevention${RESET}"
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

  # Map config paths to 1Password item names and provider names
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

  declare -A PATH_TO_PROVIDER_NAME=(
    ["channels.discord.token"]="discord-token"
    ["channels.bluebubbles.password"]="bluebubbles-password"
    ["channels.telegram.token"]="telegram-token"
    ["channels.slack.botToken"]="slack-token"
    ["gateway.auth.token"]="gateway-token"
    ["agents.defaults.memorySearch.remote.apiKey"]="voyage-api-key"
    ["messages.tts.openai.apiKey"]="openai-tts-key"
    ["talk.apiKey"]="elevenlabs-key"
    ["tools.web.search.apiKey"]="brave-search-key"
  )

  load_env

  # Ensure secrets.providers block exists and remove legacy provider
  ensure_secrets_providers_block "$OPENCLAW_CONFIG"
  remove_legacy_provider "$OPENCLAW_CONFIG"

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

    # Determine provider name
    local provider_name="${PATH_TO_PROVIDER_NAME[$path]:-}"
    if [ -z "$provider_name" ]; then
      # Derive from item name
      provider_name="$(echo "$item_name" | sed 's/^openclaw-//')-key"
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
      # But still add a provider so repair can resolve the token
      add_provider_to_config "$OPENCLAW_CONFIG" "$provider_name" "$op_ref"
      apply_envvar_to_config "$OPENCLAW_CONFIG" "$path" "OPENCLAW_GATEWAY_TOKEN"
      ok "$path -> \${OPENCLAW_GATEWAY_TOKEN} (SecretRef blocked by #29183)"
    else
      add_provider_to_config "$OPENCLAW_CONFIG" "$provider_name" "$op_ref"
      apply_secretref_to_config "$OPENCLAW_CONFIG" "$path" "$provider_name"
      ok "$path -> SecretRef (provider: $provider_name)"
    fi
  done

  # Test op read
  step "6" "Testing 1Password access"
  info "Testing op read..."
  local test_ref=""
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
    test_result="$("$OP_BIN" read "$test_ref" 2>/dev/null | head -c 10 || echo "")"
    if [ -n "$test_result" ]; then
      ok "op read successfully resolved a test secret"
    else
      err "op read test failed. Check $ENV_FILE and vault access."
    fi
  fi

  # Fix service
  step "7" "Configuring gateway service"

  if [ "$PLATFORM" = "macos" ] && [ -f "$PLIST_PATH" ]; then
    repair_launchagent
    bounce_gateway
  elif [ "$PLATFORM" = "linux" ]; then
    warn "Linux detected. Add 1Password env vars and OPENCLAW_GATEWAY_TOKEN to your systemd unit."
    dim "Set Environment= directives in your service file."
  fi

  # Shell wrapper advice
  step "8" "Shell configuration"
  echo
  info "Add this to your ~/.zshrc (or ~/.bashrc):"
  echo
  echo -e "${DIM}  # 1Password env vars for OpenClaw"
  echo "  source ~/.openclaw/.env"
  echo ""
  echo "  # Resolve gateway token for CLI"
  echo "  openclaw() {"
  echo "    OPENCLAW_GATEWAY_TOKEN=\"\$($OP_BIN read \"op://$vault_name/openclaw-gateway/credential\")\" \\"
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

  # Ensure .env file exists (migrate from legacy .op-token if needed)
  if [ ! -f "$ENV_FILE" ] && [ -f "$TOKEN_FILE" ]; then
    info "Migrating from legacy .op-token to .env..."
    local token
    token="$(cat "$TOKEN_FILE")"
    create_env_file "$token"
  fi

  load_env

  # Check if SecretRef providers are still in config
  local provider_count
  provider_count="$("$JQ_BIN" -r '.secrets.providers | keys | length' "$OPENCLAW_CONFIG" 2>/dev/null || echo "0")"
  if [ "$provider_count" -gt 0 ]; then
    ok "SecretRef providers intact ($provider_count provider(s))"
  else
    warn "SecretRef providers were removed from config. Re-run '$0 setup' to restore them."
  fi

  # Fix plist (node path, throttle interval, env vars, gateway token)
  if [ "$PLATFORM" = "macos" ] && [ -f "$PLIST_PATH" ]; then
    repair_launchagent
    bounce_gateway
  elif [ "$PLATFORM" = "linux" ]; then
    info "Linux: verify your systemd unit has 1Password env vars and OPENCLAW_GATEWAY_TOKEN."
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

# --- Entry Point --------------------------------------------------------------

case "${1:-help}" in
  setup)   cmd_setup ;;
  repair)  cmd_repair ;;
  verify)  cmd_verify ;;
  help|--help|-h)
    echo "Usage: $0 <command>"
    echo
    echo "Commands:"
    echo "  setup     Full onboarding (interactive)"
    echo "  repair    Fix plist/service after openclaw gateway install"
    echo "  verify    Check everything is working"
    echo
    echo "After OpenClaw updates, run: $0 repair"
    ;;
  *)
    err "Unknown command: $1"
    echo "Run '$0 help' for usage."
    exit 1
    ;;
esac
