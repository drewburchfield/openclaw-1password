# Zero Plaintext Secrets in OpenClaw with 1Password Service Accounts

*By Drew Burchfield*

Right now, your OpenClaw secrets are probably sitting in `~/.openclaw/openclaw.json` as plaintext. Every API key, every bot token, every credential. Readable by any process on your machine. Visible in backups. Exposed if you ever share your config.

This guide fixes that. You'll move every secret into 1Password and have them resolved at runtime using OpenClaw's SecretRef exec provider system. Nothing sensitive ever touches disk. The config file contains structured references, the gateway resolves them on demand, and you get audit trails, rotation, and revocation for free.

**What you'll end up with:**

| Before | After |
|--------|-------|
| `"token": "xoxb-1234-real-token"` | `"token": { "source": "exec", "provider": "onepassword", "id": "op://..." }` |
| Secrets in plaintext JSON on disk | Secrets in 1Password, resolved at runtime |
| `openclaw update` can bake secrets into JSON | SecretRef objects survive config rewrites by design |
| LaunchAgent breaks after every update | LaunchAgent needs no special wrapping |
| No audit trail | Full access logs in 1Password |
| Revoking a key means editing files | Revoking a key means clicking a button |

**Time to complete:** 20-30 minutes (or 5 minutes with the setup script).

> **Want the fast path?** The companion setup script automates everything in this guide. Download [`openclaw-1p-setup.sh`](openclaw-1p-setup.sh) and run `./openclaw-1p-setup.sh setup`. After OpenClaw updates, run `./openclaw-1p-setup.sh repair` to fix the LaunchAgent.

---

## How It Works

OpenClaw has a native SecretRef system that calls external programs to resolve secrets at runtime. Instead of storing secrets as strings (or `${VAR}` environment variable references), you store structured JSON objects that tell OpenClaw how to fetch the secret.

The flow:

1. Gateway starts and reads `openclaw.json`
2. It encounters a SecretRef object: `{ "source": "exec", "provider": "onepassword", "id": "op://vault/item/field" }`
3. It calls your resolver script, passing the `op://` reference
4. The resolver script calls `op read` to fetch the actual value from 1Password
5. The gateway uses the resolved value in memory. It never writes it to disk.

The critical advantage over `${VAR}` environment variable interpolation: SecretRef objects are stored as structured JSON. OpenClaw's config write path treats them as opaque objects. When `openclaw doctor`, `openclaw update`, or `openclaw configure` rewrites the config file, the SecretRef objects survive intact. No more plaintext bake-back.

---

## Prerequisites

- **OpenClaw 2026.3.2 or later.** Earlier versions have limited SecretRef credential surface. Run `openclaw --version` to check, and `npm install -g openclaw@latest` to update.
- **1Password CLI** (`op`) installed ([install guide](https://developer.1password.com/docs/cli/get-started/))
- **A paid 1Password account** (Teams, Business, or Enterprise). Service accounts require a paid plan.
- **jq** installed (`brew install jq` on macOS). Used by the resolver script.

Verify your tools:

```bash
openclaw --version   # 2026.3.2 or later
op --version         # 2.18.0 or later
jq --version         # any recent version
```

---

## Step 1: Create a Vault and Service Account

Service accounts are 1Password accounts designed for machines. They authenticate with a token instead of a password, and they can only access vaults you explicitly grant.

### Create a dedicated vault

Keep your OpenClaw secrets separate from personal passwords. This makes access control clean and lets you revoke everything at once if needed.

```bash
op vault create "OpenClaw Secrets"
```

### Create the service account

```bash
op service-account create "openclaw-gateway" \
  --vault "OpenClaw Secrets:read_items"
```

This outputs a token starting with `ops_`. **Copy it immediately.** You will never see it again. If you lose it, create a new service account.

Save the token in 1Password itself (yes, the recursion is intentional):

```bash
op item create \
  --category "Secure Note" \
  --title "OpenClaw Service Account Token" \
  --vault "Employee" \
  "token[password]=ops_eyJ...your-token-here..."
```

> **Why read_items only?** The gateway only needs to read secrets, never write them. Minimum permissions means minimum blast radius if the token is ever compromised.

---

## Step 2: Store Your Secrets in 1Password

For each secret in your `openclaw.json`, create an item in the vault. You can use the CLI or the 1Password app:

```bash
# Discord bot token
op item create \
  --category "API Credential" \
  --title "openclaw-discord" \
  --vault "OpenClaw Secrets" \
  "credential=your-discord-bot-token-here"

# Gateway token
op item create \
  --category "API Credential" \
  --title "openclaw-gateway" \
  --vault "OpenClaw Secrets" \
  "credential=your-gateway-token-here"

# Repeat for each secret: API keys, passwords, tokens
# Examples: openclaw-elevenlabs, openclaw-brave-search, openclaw-voyage,
# openclaw-openai-tts, openclaw-bluebubbles, openclaw-google-places
```

**Naming convention:** Prefix everything with `openclaw-` so you can find them easily. Use `credential` as the field name throughout for consistency.

---

## Step 3: Store the Service Account Token

The resolver script needs the service account token to authenticate with 1Password. Store it in a dedicated file with locked-down permissions:

```bash
echo -n "ops_eyJ...your-token-here..." > ~/.openclaw/.op-token
chmod 600 ~/.openclaw/.op-token
```

This file is the one secret that lives on disk. It's the bootstrap credential that unlocks everything else. Lock it down:

```bash
# Verify permissions
ls -la ~/.openclaw/.op-token
# Should show: -rw-------
```

> **Why a file instead of an environment variable?** Environment variables in a LaunchAgent plist get clobbered when `openclaw gateway install` regenerates the plist. A file is outside OpenClaw's config management. Nothing OpenClaw does can overwrite it.

---

## Step 4: Create the Resolver Script

This script is the bridge between OpenClaw's SecretRef system and 1Password. It receives secret requests via JSON on stdin and resolves them using `op read`.

```bash
mkdir -p ~/.openclaw/bin

cat > ~/.openclaw/bin/op-resolver.sh << 'SCRIPT'
#!/bin/bash
# SecretRef exec provider for OpenClaw + 1Password.
# Reads op:// references via JSON protocol (stdin) and resolves them
# using the 1Password CLI with a file-backed service account token.
#
# The service account token lives in ~/.openclaw/.op-token (chmod 600),
# so no environment variable injection is needed from the LaunchAgent.

set -euo pipefail

export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.openclaw/.op-token")"
export OP_BIOMETRIC_UNLOCK_ENABLED=false

REQUEST="$(cat)"
IDS=($(echo "$REQUEST" | /opt/homebrew/bin/jq -r '.ids[]'))

VALUES="{"
FIRST=true
for ID in "${IDS[@]}"; do
  VALUE="$(/opt/homebrew/bin/op read "$ID" 2>/dev/null)"
  VALUE="$(echo -n "$VALUE" | /opt/homebrew/bin/jq -Rs '.')"
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    VALUES="$VALUES,"
  fi
  VALUES="$VALUES$(echo -n "$ID" | /opt/homebrew/bin/jq -Rs '.'):$VALUE"
done
VALUES="$VALUES}"

echo "{\"protocolVersion\":1,\"values\":$VALUES}"
SCRIPT

chmod +x ~/.openclaw/bin/op-resolver.sh
```

> **Linux users:** Replace `/opt/homebrew/bin/jq` and `/opt/homebrew/bin/op` with the paths from `which jq` and `which op` on your system.

### Test the resolver

```bash
echo '{"protocolVersion":1,"provider":"onepassword","ids":["op://OpenClaw Secrets/openclaw-discord/credential"]}' \
  | ~/.openclaw/bin/op-resolver.sh | jq '.'
```

You should see your Discord token in the response. If it fails, verify `~/.openclaw/.op-token` contains the correct service account token and the vault/item names match.

---

## Step 5: Migrate openclaw.json to SecretRef

This is the core migration. You'll add the provider definition and replace each plaintext secret with a SecretRef object.

### Add the secrets provider

Add this block to `~/.openclaw/openclaw.json` as a top-level key:

```json
{
  "secrets": {
    "providers": {
      "onepassword": {
        "source": "exec",
        "command": "/Users/YOUR_USERNAME/.openclaw/bin/op-resolver.sh",
        "allowSymlinkCommand": false,
        "trustedDirs": ["/Users/YOUR_USERNAME/.openclaw/bin"],
        "passEnv": ["HOME"],
        "jsonOnly": true,
        "timeoutMs": 15000
      }
    }
  }
}
```

> Replace `YOUR_USERNAME` with your actual username. Use absolute paths.

### Replace secrets with SecretRef objects

For each secret in your config, replace the string value with a SecretRef object. The `id` field is the `op://` reference to the item in 1Password.

**Before:**

```json
"channels": {
  "discord": {
    "token": "MTQ3NjI4Mzg0My...real-token"
  }
},
"agents": {
  "defaults": {
    "memorySearch": {
      "remote": {
        "apiKey": "pa-abc123...real-key"
      }
    }
  }
}
```

**After:**

```json
"channels": {
  "discord": {
    "token": {
      "source": "exec",
      "provider": "onepassword",
      "id": "op://OpenClaw Secrets/openclaw-discord/credential"
    }
  }
},
"agents": {
  "defaults": {
    "memorySearch": {
      "remote": {
        "apiKey": {
          "source": "exec",
          "provider": "onepassword",
          "id": "op://OpenClaw Secrets/openclaw-voyage/credential"
        }
      }
    }
  }
}
```

Do this for every credential field: channel tokens, API keys, search keys, TTS keys, skill API keys, etc. The complete list of SecretRef-eligible fields is at [docs.openclaw.ai/reference/secretref-credential-surface](https://docs.openclaw.ai/reference/secretref-credential-surface).

### The one exception: gateway.auth.token

`gateway.auth.token` is excluded from SecretRef support (it's classified as session-bearing). For this one field, use the `${VAR}` environment variable approach:

```json
"gateway": {
  "auth": {
    "mode": "token",
    "token": "${OPENCLAW_GATEWAY_TOKEN}"
  }
}
```

This is the only `${VAR}` reference remaining in your config. We handle it via the gateway launcher script in the next step.

---

## Step 6: Set Up the Gateway Launcher

The gateway needs the `OPENCLAW_GATEWAY_TOKEN` env var for the one field that can't use SecretRef. Create a launcher script that resolves it from 1Password:

```bash
cat > ~/.openclaw/bin/launch-gateway.sh << 'SCRIPT'
#!/bin/bash
# Gateway launcher - resolves the one credential that can't use SecretRef
# (gateway.auth.token is out-of-scope for SecretRef exec providers).
# All other secrets are resolved by the gateway itself via SecretRef.

set -euo pipefail

export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.openclaw/.op-token")"
export OP_BIOMETRIC_UNLOCK_ENABLED=false
export OPENCLAW_GATEWAY_TOKEN="$(/opt/homebrew/bin/op read "op://OpenClaw Secrets/openclaw-gateway/credential")"

exec /opt/homebrew/Cellar/node/$(node -v | sed 's/v//')/bin/node \
  /opt/homebrew/lib/node_modules/openclaw/dist/index.js \
  gateway --port 18789
SCRIPT

chmod +x ~/.openclaw/bin/launch-gateway.sh
```

> **Linux users:** Replace the node path with your actual node binary path.

### Configure the LaunchAgent

Edit `~/Library/LaunchAgents/ai.openclaw.gateway.plist` and set `ProgramArguments` to call the launcher:

```xml
<key>ProgramArguments</key>
<array>
  <string>/Users/YOUR_USERNAME/.openclaw/bin/launch-gateway.sh</string>
</array>
```

Make sure the plist's `EnvironmentVariables` includes `HOME`:

```xml
<key>HOME</key>
<string>/Users/YOUR_USERNAME</string>
```

### Reload the LaunchAgent

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
sleep 2
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

Verify:

```bash
openclaw gateway status
# Should show: Runtime: running, RPC probe: ok
```

---

## Step 7: Shell Wrapper for CLI

When you run `openclaw` from the terminal, the CLI also needs the gateway token. The simplest approach is a shell wrapper. Add to `~/.zshrc` (or `~/.bashrc`):

```bash
# 1Password service account for headless op commands
export OP_SERVICE_ACCOUNT_TOKEN="ops_eyJ...your-token..."

# OpenClaw: resolve the one ${VAR} secret the CLI needs
openclaw() {
  OPENCLAW_GATEWAY_TOKEN="$(/opt/homebrew/bin/op read "op://OpenClaw Secrets/openclaw-gateway/credential")" \
    command openclaw "$@"
}
```

Note: unlike the old `op run --env-file` wrapper that resolved all secrets, this only resolves the one `${VAR}` reference. The gateway handles everything else via SecretRef.

Reload and test:

```bash
source ~/.zshrc
openclaw status
```

---

## Step 8: Fix the Mac App (Optional)

The Mac app connects to the gateway, and the gateway resolves its own secrets. If your Mac app is working after the gateway migration, you may not need a wrapper at all.

If the Mac app still needs environment variables (e.g., for local features that read the config directly), create a wrapper app:

```bash
mkdir -p "/Applications/OpenClaw (Safe).app/Contents/MacOS"
mkdir -p "/Applications/OpenClaw (Safe).app/Contents/Resources"

# Copy the icon
cp /Applications/OpenClaw.app/Contents/Resources/OpenClaw.icns \
   "/Applications/OpenClaw (Safe).app/Contents/Resources/AppIcon.icns"
```

Create the launcher:

```bash
cat > "/Applications/OpenClaw (Safe).app/Contents/MacOS/launch" << 'SCRIPT'
#!/bin/bash
export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.openclaw/.op-token")"
export OP_BIOMETRIC_UNLOCK_ENABLED=false
export OPENCLAW_GATEWAY_TOKEN="$(/opt/homebrew/bin/op read "op://OpenClaw Secrets/openclaw-gateway/credential")"
exec /Applications/OpenClaw.app/Contents/MacOS/OpenClaw
SCRIPT

chmod +x "/Applications/OpenClaw (Safe).app/Contents/MacOS/launch"
```

Create `Info.plist`:

```bash
cat > "/Applications/OpenClaw (Safe).app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launch</string>
    <key>CFBundleIdentifier</key>
    <string>ai.openclaw.mac.safe-launcher</string>
    <key>CFBundleName</key>
    <string>OpenClaw</string>
    <key>CFBundleDisplayName</key>
    <string>OpenClaw</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF
```

---

## Gotchas

### `openclaw gateway install` still clobbers the plist

When OpenClaw regenerates the plist, it resets `ProgramArguments` to call node directly. You'll need to re-point it to `launch-gateway.sh`. The good news: your `openclaw.json` SecretRef objects and your `~/.openclaw/bin/` scripts are untouched. The repair is one line in the plist.

### The biometric unlock prompt

If you see macOS prompting *"op would like to access data from other apps"*, you're missing `OP_BIOMETRIC_UNLOCK_ENABLED=false` in a context where `op` runs headlessly. This is already handled in the resolver script and launcher, but check any other places where you invoke `op`.

### Node path changes after Homebrew upgrades

If you update Node.js via Homebrew, the path in `launch-gateway.sh` needs updating. You can make it dynamic:

```bash
exec "$(brew --prefix node)/bin/node" \
  /opt/homebrew/lib/node_modules/openclaw/dist/index.js \
  gateway --port 18789
```

### `openclaw doctor` and the gateway token

`gateway.auth.token` still uses `${OPENCLAW_GATEWAY_TOKEN}`. If `openclaw doctor` runs and the gateway token is in the environment, it may bake the plaintext value into the config. Run `openclaw secrets audit --check` after any config-touching command and restore the `${VAR}` reference if needed.

### Out-of-scope SecretRef fields

Not all credential fields support SecretRef. The following are excluded: gateway access tokens, Matrix access tokens, OAuth refresh material, webhook tokens in thread bindings, and a few others. See the [SecretRef credential surface reference](https://docs.openclaw.ai/reference/secretref-credential-surface) for the full list.

---

## Verification Checklist

Run through this after completing the setup:

```bash
# 1. No plaintext secrets in the config
grep -E '"(sk-|xox|ghp_|pa-|ops_)[a-zA-Z0-9]' ~/.openclaw/openclaw.json
# Should return nothing

# 2. Only one ${VAR} reference remaining (gateway.auth.token)
grep -c '"\${' ~/.openclaw/openclaw.json
# Should return 1

# 3. SecretRef objects present
grep -c '"source" : "exec"' ~/.openclaw/openclaw.json
# Should match the number of secrets you migrated

# 4. Gateway running and reachable
openclaw gateway status
# Should show: RPC probe: ok

# 5. Secrets audit clean
openclaw secrets audit --check
# Should show 0 unresolved, 0 plaintext (except vibeproxy dummy key if applicable)

# 6. Resolver script works
echo '{"protocolVersion":1,"provider":"onepassword","ids":["op://OpenClaw Secrets/openclaw-discord/credential"]}' \
  | ~/.openclaw/bin/op-resolver.sh | jq '.values | keys | length'
# Should return 1

# 7. Token file permissions locked down
stat -f '%Sp' ~/.openclaw/.op-token
# Should show: -rw-------
```

---

## For Enterprise and Teams

This approach gives you properties that matter at organizational scale:

- **Centralized credential control.** All secrets live in a 1Password vault. Onboarding a new machine means granting vault access and copying the service account token file, not distributing individual secrets.
- **Instant revocation.** Disable the service account or remove vault access, and the gateway stops authenticating on next restart. No hunting through config files on individual machines.
- **Audit trail.** 1Password logs every `op read` call. You know exactly when each credential was accessed and by which service account.
- **Rotation without downtime.** Update a secret in 1Password, restart the gateway, done. No config file edits on any machine.
- **Separation of duties.** The person who manages 1Password vaults doesn't need SSH access to the OpenClaw host. The person who manages OpenClaw doesn't need to know actual secret values.
- **Config files are safe to share.** `openclaw.json` contains SecretRef objects with vault references, not secrets. You can check it into version control, share it in onboarding docs, or paste it in a support ticket.
- **Survives updates.** SecretRef objects persist through `openclaw update`, `openclaw doctor`, and config rewrites. The only manual step after an update is re-pointing the LaunchAgent plist to the launcher script.

---

## How This Compares to `${VAR}` + `op run`

If you've seen the older pattern of using `${VAR}` environment variable references with an `op run --env-file` wrapper, here's why SecretRef is better:

| | `${VAR}` + `op run` | SecretRef exec provider |
|---|---|---|
| **Secrets in config** | `${VAR}` strings (fragile) | Structured JSON objects (durable) |
| **Config rewrite safety** | `openclaw doctor` can bake plaintext back | SecretRef objects survive rewrites |
| **LaunchAgent** | Must wrap with `op run` (clobbered on update) | Launcher script resolves 1 token |
| **Number of env vars needed** | All secrets as env vars | Just `OPENCLAW_GATEWAY_TOKEN` |
| **Secret resolution** | At process start (all-or-nothing) | On demand (per-field, lazy) |
| **Portability** | Requires `secrets.env` + `op run` in every context | Resolver script works everywhere |

The `${VAR}` + `op run` approach still works and is simpler if you only have a few secrets. But for setups with many credentials, SecretRef is more durable and requires less maintenance after OpenClaw updates.

---

## Appendix: File Inventory

After setup, these are the files this guide creates or modifies:

| File | Purpose | Contains secrets? |
|------|---------|-------------------|
| `~/.openclaw/.op-token` | 1Password service account token | **Yes** (chmod 600) |
| `~/.openclaw/bin/op-resolver.sh` | SecretRef exec provider script | No |
| `~/.openclaw/bin/launch-gateway.sh` | Gateway launcher (resolves gateway token) | No |
| `~/.openclaw/openclaw.json` | OpenClaw config with SecretRef objects | No |
| `~/Library/LaunchAgents/ai.openclaw.gateway.plist` | macOS service definition | No |
| `~/.zshrc` (modified) | Shell wrapper for CLI | Token in export (see note) |

> **Note on ~/.zshrc:** The `OP_SERVICE_ACCOUNT_TOKEN` export in your shell profile is the one place the token appears in a non-600-permission file. If this concerns you, you can source it from the token file instead: `export OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.openclaw/.op-token)"`.

---

## Troubleshooting

**Gateway won't start after migration:**
Check `~/.openclaw/logs/gateway.err.log`. If you see "expected string, received object" for a field, that field doesn't support SecretRef. Revert it to a `${VAR}` reference and add it to your launcher script.

**"MissingEnvVarError" for OPENCLAW_GATEWAY_TOKEN:**
The launcher script isn't resolving the gateway token. Verify `~/.openclaw/.op-token` exists and contains the service account token, and test `op read` manually:

```bash
OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.openclaw/.op-token)" \
  OP_BIOMETRIC_UNLOCK_ENABLED=false \
  /opt/homebrew/bin/op read "op://OpenClaw Secrets/openclaw-gateway/credential"
```

**Resolver script fails with "No accounts configured":**
The `~/.openclaw/.op-token` file is missing, empty, or contains an invalid token. Regenerate it from Step 3.

**"op would like to access data from other apps":**
`OP_BIOMETRIC_UNLOCK_ENABLED=false` is missing in a headless context. The resolver script and launcher both set this, so check if `op` is being called from somewhere else.

**Gateway shows "unreachable" but LaunchAgent says "running":**
The process is crash-looping. Check the error log. With SecretRef, this usually means the resolver script can't reach 1Password (network issue or expired token).

**After `openclaw gateway install`, gateway breaks:**
The plist was regenerated. Re-edit `ProgramArguments` to point to `launch-gateway.sh`:

```xml
<key>ProgramArguments</key>
<array>
  <string>/Users/YOUR_USERNAME/.openclaw/bin/launch-gateway.sh</string>
</array>
```

Then reload the LaunchAgent.

**`openclaw secrets audit` shows plaintext findings:**
Check which field it flags. If it's `models.providers.vibeproxy.apiKey` with a value like `"dummy"`, that's fine (it's a local proxy with no real credential). For real secrets, migrate them to SecretRef following Step 5.
