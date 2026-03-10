# Zero Plaintext Secrets in OpenClaw with 1Password Service Accounts

*By Drew Burchfield*

Right now, your OpenClaw secrets are probably sitting in `~/.openclaw/openclaw.json` as plaintext. Every API key, every bot token, every credential. Readable by any process on your machine. Visible in backups. Exposed if you ever share your config.

This guide fixes that. You'll move every secret into 1Password and have them resolved at runtime by calling `op` directly through OpenClaw's SecretRef exec provider system. Nothing sensitive ever touches disk. The config file contains structured references, the gateway resolves them on demand, and you get audit trails, rotation, and revocation for free.

**What you'll end up with:**

| Before | After |
|--------|-------|
| `"token": "xoxb-1234-real-token"` | `"token": { "source": "exec", "provider": "discord-token", "id": "discord-token" }` |
| Secrets in plaintext JSON on disk | Secrets in 1Password, resolved at runtime |
| `openclaw update` can bake secrets into JSON | SecretRef objects survive config rewrites by design |
| LaunchAgent breaks after every update | One repair command fixes it |
| No audit trail | Full access logs in 1Password |

**Time to complete:** 20-30 minutes (or 5 minutes with the setup script).

> **Want the fast path?** The companion setup script automates everything in this guide. Download [`openclaw-1p-setup.sh`](openclaw-1p-setup.sh) and run `./openclaw-1p-setup.sh setup`. After OpenClaw updates, run `./openclaw-1p-setup.sh repair` to fix the LaunchAgent.

---

## How It Works

OpenClaw has a native SecretRef system that calls external programs to resolve secrets at runtime. Instead of storing secrets as strings (or `${VAR}` environment variable references), you store structured JSON objects that tell OpenClaw how to fetch the secret.

The flow:

1. Gateway starts and reads `openclaw.json`
2. It encounters a SecretRef object: `{ "source": "exec", "provider": "discord-token", "id": "discord-token" }`
3. It calls `op read "op://vault/item/field"` directly (configured in the provider entry)
4. `op` fetches the actual value from 1Password
5. The gateway uses the resolved value in memory. It never writes it to disk.

Each secret gets its own provider entry. The provider calls `op` directly with `jsonOnly: false`. No custom resolver script, no custom JSON protocol.

The critical advantage over `${VAR}` environment variable interpolation: SecretRef objects are stored as structured JSON. OpenClaw's config write path treats them as opaque objects. When `openclaw doctor`, `openclaw update`, or `openclaw configure` rewrites the config file, the SecretRef objects survive intact. No more plaintext bake-back.

---

## Prerequisites

- **OpenClaw 2026.3.2 or later.** Earlier versions have limited SecretRef credential surface. Run `openclaw --version` to check, and `npm install -g openclaw@latest` to update.
- **1Password CLI** (`op`) installed ([install guide](https://developer.1password.com/docs/cli/get-started/))
- **A paid 1Password account** (Teams, Business, or Enterprise). Service accounts require a paid plan.
- **jq** installed (`brew install jq` on macOS). Used by the setup script.

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

## Step 3: Create the Env File

The gateway needs 4 environment variables for 1Password to work headlessly. Store them in a single file:

```bash
cat > ~/.openclaw/.env << 'EOF'
OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...your-token-here...
OP_BIOMETRIC_UNLOCK_ENABLED=false
OP_NO_AUTO_SIGNIN=true
OP_LOAD_DESKTOP_APP_SETTINGS=false
EOF
chmod 600 ~/.openclaw/.env
```

This file is the one secret that lives on disk. It's the bootstrap credential that unlocks everything else. Lock it down:

```bash
# Verify permissions
ls -la ~/.openclaw/.env
# Should show: -rw-------
```

**Why these 4 vars?**

| Var | Purpose |
|-----|---------|
| `OP_SERVICE_ACCOUNT_TOKEN` | Auth for the service account |
| `OP_BIOMETRIC_UNLOCK_ENABLED=false` | Prevents `op` from trying Native Messaging to the desktop app (triggers TCC) |
| `OP_NO_AUTO_SIGNIN=true` | Suppresses interactive signin prompts |
| `OP_LOAD_DESKTOP_APP_SETTINGS=false` | Prevents `op` from `lstat`-ing Group Containers (triggers TCC) |

> **Why a file instead of environment variables in the plist?** The plist also needs these vars (see Step 6). But the file is the source of truth because it's outside OpenClaw's config management. Nothing OpenClaw does can overwrite it.

---

## Step 4: Test op read

Before touching the config, verify `op` works headlessly:

```bash
source ~/.openclaw/.env
op read "op://OpenClaw Secrets/openclaw-discord/credential"
```

You should see your Discord token. If it fails, verify `~/.openclaw/.env` contains the correct service account token and the vault/item names match.

---

## Step 5: Migrate openclaw.json to SecretRef

This is the core migration. You'll add per-secret provider entries and replace each plaintext secret with a SecretRef object.

### Add a provider for each secret

Add entries under `secrets.providers` in `~/.openclaw/openclaw.json`. Each provider calls `op read` for one specific secret:

```json
{
  "secrets": {
    "providers": {
      "discord-token": {
        "source": "exec",
        "command": "/opt/homebrew/bin/op",
        "args": ["read", "op://OpenClaw Secrets/openclaw-discord/credential", "--no-newline"],
        "allowSymlinkCommand": true,
        "trustedDirs": ["/opt/homebrew"],
        "passEnv": [
          "OP_SERVICE_ACCOUNT_TOKEN",
          "OP_BIOMETRIC_UNLOCK_ENABLED",
          "OP_NO_AUTO_SIGNIN",
          "OP_LOAD_DESKTOP_APP_SETTINGS"
        ],
        "jsonOnly": false,
        "timeoutMs": 15000
      },
      "voyage-api-key": {
        "source": "exec",
        "command": "/opt/homebrew/bin/op",
        "args": ["read", "op://OpenClaw Secrets/openclaw-voyage/credential", "--no-newline"],
        "allowSymlinkCommand": true,
        "trustedDirs": ["/opt/homebrew"],
        "passEnv": [
          "OP_SERVICE_ACCOUNT_TOKEN",
          "OP_BIOMETRIC_UNLOCK_ENABLED",
          "OP_NO_AUTO_SIGNIN",
          "OP_LOAD_DESKTOP_APP_SETTINGS"
        ],
        "jsonOnly": false,
        "timeoutMs": 15000
      }
    }
  }
}
```

Repeat for each secret. The pattern is the same every time; only the provider name and `op://` reference change.

> **Linux users:** Replace `/opt/homebrew/bin/op` with the path from `which op` on your system. Set `trustedDirs` accordingly.

### Replace secrets with SecretRef objects

For each secret in your config, replace the string value with a SecretRef object. The `provider` and `id` fields match the provider name:

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
      "provider": "discord-token",
      "id": "discord-token"
    }
  }
},
"agents": {
  "defaults": {
    "memorySearch": {
      "remote": {
        "apiKey": {
          "source": "exec",
          "provider": "voyage-api-key",
          "id": "voyage-api-key"
        }
      }
    }
  }
}
```

Do this for every credential field: channel tokens, API keys, search keys, TTS keys, skill API keys, etc. The complete list of SecretRef-eligible fields is at [docs.openclaw.ai/reference/secretref-credential-surface](https://docs.openclaw.ai/reference/secretref-credential-surface).

### The one exception: gateway.auth.token

`gateway.auth.token` is excluded from SecretRef support (it's classified as session-bearing, blocked by #29183). For this one field, use the `${VAR}` environment variable approach:

```json
"gateway": {
  "auth": {
    "mode": "token",
    "token": "${OPENCLAW_GATEWAY_TOKEN}"
  }
}
```

This is the only `${VAR}` reference remaining in your config. We handle it via plist EnvironmentVariables in the next step.

---

## Step 6: Configure the LaunchAgent

The plist needs two things: the correct node path and the right environment variables.

### Set ProgramArguments

Edit `~/Library/LaunchAgents/ai.openclaw.gateway.plist` and ensure `ProgramArguments` uses the stable node symlink (not a versioned Cellar path):

```xml
<key>ProgramArguments</key>
<array>
  <string>/opt/homebrew/opt/node/bin/node</string>
  <string>/opt/homebrew/lib/node_modules/openclaw/dist/index.js</string>
  <string>gateway</string>
  <string>--port</string>
  <string>18789</string>
</array>
```

### Set EnvironmentVariables

Add all the env vars the gateway needs:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>HOME</key>
  <string>/Users/YOUR_USERNAME</string>
  <key>OP_SERVICE_ACCOUNT_TOKEN</key>
  <string>ops_eyJ...your-token...</string>
  <key>OP_BIOMETRIC_UNLOCK_ENABLED</key>
  <string>false</string>
  <key>OP_NO_AUTO_SIGNIN</key>
  <string>true</string>
  <key>OP_LOAD_DESKTOP_APP_SETTINGS</key>
  <string>false</string>
  <key>OPENCLAW_GATEWAY_TOKEN</key>
  <string>your-resolved-gateway-token</string>
</dict>
```

To resolve the gateway token for the plist:
```bash
source ~/.openclaw/.env
op read "op://OpenClaw Secrets/openclaw-gateway/credential"
```

### Set ThrottleInterval

Make sure ThrottleInterval is 30 (not 1):

```xml
<key>ThrottleInterval</key>
<integer>30</integer>
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
# 1Password env vars for OpenClaw
source ~/.openclaw/.env

# OpenClaw: resolve the one ${VAR} secret the CLI needs
openclaw() {
  OPENCLAW_GATEWAY_TOKEN="$(op read "op://OpenClaw Secrets/openclaw-gateway/credential")" \
    command openclaw "$@"
}
```

Reload and test:

```bash
source ~/.zshrc
openclaw status
```

---

## Gotchas

### `openclaw gateway install` still clobbers the plist

When OpenClaw regenerates the plist, it resets everything: node path, env vars, ThrottleInterval. Run `./openclaw-1p-setup.sh repair` to fix it. Your `openclaw.json` SecretRef objects are untouched since they survive config rewrites.

### The biometric unlock prompt

If you see macOS prompting *"op would like to access data from other apps"*, one of the 4 TCC-prevention vars is missing. Check all three places: `~/.openclaw/.env`, the plist EnvironmentVariables, and the provider `passEnv` arrays.

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
# Should match the number of secrets you migrated (plus provider entries)

# 4. Gateway running and reachable
openclaw gateway status
# Should show: RPC probe: ok

# 5. Secrets audit clean
source ~/.openclaw/.env
OPENCLAW_GATEWAY_TOKEN="$(op read "op://OpenClaw Secrets/openclaw-gateway/credential")" \
  openclaw secrets audit --check
# Should show 0 unresolved, 0 plaintext (except vibeproxy dummy key if applicable)

# 6. .env file permissions locked down
stat -f '%Sp' ~/.openclaw/.env
# Should show: -rw-------
```

---

## For Enterprise and Teams

This approach gives you properties that matter at organizational scale:

- **Centralized credential control.** All secrets live in a 1Password vault. Onboarding a new machine means granting vault access and copying the `.env` file, not distributing individual secrets.
- **Instant revocation.** Disable the service account or remove vault access, and the gateway stops authenticating on next restart. No hunting through config files on individual machines.
- **Audit trail.** 1Password logs every `op read` call. You know exactly when each credential was accessed and by which service account.
- **Rotation without downtime.** Update a secret in 1Password, restart the gateway, done. No config file edits on any machine.
- **Separation of duties.** The person who manages 1Password vaults doesn't need SSH access to the OpenClaw host. The person who manages OpenClaw doesn't need to know actual secret values.
- **Config files are safe to share.** `openclaw.json` contains SecretRef objects with provider references, not secrets. You can check it into version control, share it in onboarding docs, or paste it in a support ticket.
- **Survives updates.** SecretRef objects persist through `openclaw update`, `openclaw doctor`, and config rewrites. The only manual step after an update is running the repair command to fix the plist.

---

## Appendix: File Inventory

After setup, these are the files this guide creates or modifies:

| File | Purpose | Contains secrets? |
|------|---------|-------------------|
| `~/.openclaw/.env` | 1Password env vars (token + TCC vars) | **Yes** (chmod 600) |
| `~/.openclaw/openclaw.json` | OpenClaw config with SecretRef objects | No |
| `~/Library/LaunchAgents/ai.openclaw.gateway.plist` | macOS service definition | Yes (token in EnvironmentVariables) |
| `~/.zshrc` (modified) | Shell wrapper for CLI | No (sources .env at runtime) |

---

## Troubleshooting

**Gateway won't start after migration:**
Check `~/.openclaw/logs/gateway.err.log`. If you see "expected string, received object" for a field, that field doesn't support SecretRef. Revert it to a `${VAR}` reference and add the env var to the plist.

**"MissingEnvVarError" for OPENCLAW_GATEWAY_TOKEN:**
The plist doesn't have the gateway token in EnvironmentVariables. Resolve it from 1Password and add it:

```bash
source ~/.openclaw/.env
op read "op://OpenClaw Secrets/openclaw-gateway/credential"
# Copy the output and add to plist EnvironmentVariables
```

**Provider fails with "No accounts configured":**
`OP_SERVICE_ACCOUNT_TOKEN` is missing from the execution context. Check the plist EnvironmentVariables and the provider `passEnv` array.

**"op would like to access data from other apps":**
One of the 4 TCC-prevention vars is missing. Check `~/.openclaw/.env`, the plist, and the `passEnv` arrays.

**Gateway shows "unreachable" but LaunchAgent says "running":**
The process is crash-looping. Check the error log. This usually means `op` can't reach 1Password (network issue or expired token).

**After `openclaw gateway install`, gateway breaks:**
The plist was regenerated. Run `./openclaw-1p-setup.sh repair`.

**`openclaw secrets audit` shows plaintext findings:**
Check which field it flags. If it's `models.providers.vibeproxy.apiKey` with a value like `"dummy"`, that's fine (it's a local proxy with no real credential). For real secrets, migrate them to SecretRef following Step 5.
