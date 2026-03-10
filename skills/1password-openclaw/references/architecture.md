# Direct-op SecretRef Architecture

## Why Direct op Over a Resolver Script

The old approach used a custom `op-resolver.sh` script as a `jsonOnly: true` batch exec provider. It worked, but it added a layer of indirection that created debugging surface area and diverged from the official OpenClaw docs.

The new approach calls `op` directly. One provider per secret, `jsonOnly: false`, matching the patterns in the OpenClaw exec provider documentation. No custom script to maintain, no custom JSON protocol to debug.

**What changed:**

| Old (resolver script) | New (direct op) |
|---|---|
| Single `jsonOnly: true` provider with a custom script | Per-secret `jsonOnly: false` providers calling `op` directly |
| `op-resolver.sh` reads JSON on stdin, calls `op read` in a loop | `op read "op://..."` called directly by OpenClaw |
| `launch-gateway.sh` resolves gateway token before exec | Plist EnvironmentVariables resolves gateway token |
| 2 custom scripts to maintain | 0 custom scripts |
| `passEnv: ["HOME"]` | `passEnv` includes 4 TCC-prevention env vars |

## Per-Secret Provider Pattern

Each secret gets its own provider entry. The provider `command` is `op` itself, and the `args` array passes the `read` subcommand and the `op://` reference.

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
      }
    }
  }
}
```

And the corresponding SecretRef on the credential field:

```json
"channels": {
  "discord": {
    "token": {
      "source": "exec",
      "provider": "discord-token",
      "id": "discord-token"
    }
  }
}
```

Repeat for each secret. The provider name should be descriptive (e.g., `voyage-api-key`, `brave-search-key`).

## The 4 TCC-Prevention Env Vars

macOS Transparency, Consent, and Control (TCC) can trigger permission dialogs when `op` runs headlessly in a LaunchAgent context. Four env vars prevent this completely.

| Env var | Value | Why it matters |
|---|---|---|
| `OP_SERVICE_ACCOUNT_TOKEN` | `ops_eyJ...` | Authenticates the service account. Without it, `op` tries interactive signin. |
| `OP_BIOMETRIC_UNLOCK_ENABLED` | `false` | Prevents `op` from trying Native Messaging to the 1Password desktop app. That IPC triggers TCC prompts. |
| `OP_NO_AUTO_SIGNIN` | `true` | Suppresses the "sign in to continue" flow that pops up when the token is missing or expired. |
| `OP_LOAD_DESKTOP_APP_SETTINGS` | `false` | Prevents `op` from calling `lstat` on `~/Library/Group Containers/`, which triggers a TCC dialog about accessing data from other apps. This is the sneakiest one. |

All four must be set in any context where `op` runs headlessly: the LaunchAgent plist `EnvironmentVariables`, the `~/.openclaw/.env` file, and the `passEnv` array on each provider.

## Env Var Injection via ~/.openclaw/.env

The gateway reads `~/.openclaw/.env` at startup and makes those vars available to child processes. The `passEnv` array on each provider tells OpenClaw which vars to forward when calling `op`.

```bash
# ~/.openclaw/.env
OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...your-token...
OP_BIOMETRIC_UNLOCK_ENABLED=false
OP_NO_AUTO_SIGNIN=true
OP_LOAD_DESKTOP_APP_SETTINGS=false
```

This file replaces the old `~/.openclaw/.op-token` file. The token is still stored with `chmod 600` permissions, but now it's part of a broader env file that includes all the TCC vars.

## allowSymlinkCommand + trustedDirs for Homebrew

On macOS with Homebrew, `/opt/homebrew/bin/op` is a symlink to `/opt/homebrew/Cellar/op/X.Y.Z/bin/op`. By default, OpenClaw rejects symlinked commands as a security measure.

Two settings handle this:

- `"allowSymlinkCommand": true` tells OpenClaw to follow symlinks when resolving the command path.
- `"trustedDirs": ["/opt/homebrew"]` restricts where the resolved target can live.

This combination survives `op` upgrades. When Homebrew installs a new version, the symlink target changes but it's still under `/opt/homebrew`, so the trust check passes. No repair needed.

## The gateway.auth.token Exception

`gateway.auth.token` does not support SecretRef. OpenClaw classifies it as "session-bearing" and validates it as a plain string before SecretRef resolution runs (Zod validation ordering bug, tracked as #29183).

The workaround: use `${OPENCLAW_GATEWAY_TOKEN}` in the config and resolve the actual value into the plist's `EnvironmentVariables`. The repair command handles this by calling `op read` to fetch the token and writing it into the plist with `PlistBuddy`.

This is the one `${VAR}` reference remaining in the config. It's vulnerable to plaintext bake-back if `openclaw doctor` runs while the var is in the environment. The repair command can restore it.

## File-Backed Token

The `OP_SERVICE_ACCOUNT_TOKEN` value lives in `~/.openclaw/.env` (chmod 600). This is outside OpenClaw's config management, so nothing OpenClaw does can overwrite it. The same file also carries the three TCC-prevention vars.

For backward compatibility, `~/.openclaw/.op-token` is also supported. The setup script creates `.env` as the primary source.

## Plist Repair

After `openclaw gateway install` regenerates the LaunchAgent plist, three things typically need fixing:

### Node path
`openclaw gateway install` hardcodes the versioned Cellar path (e.g., `/opt/homebrew/Cellar/node/25.7.0/bin/node`). This breaks on the next Homebrew node upgrade. The repair command uses `sed` to replace Cellar paths with the stable symlink `/opt/homebrew/opt/node/bin/node`.

### ThrottleInterval
The default is 1 second. If the gateway crashes, launchd restarts it every second, which can spam TCC prompts. The repair command uses `PlistBuddy` to set it to 30.

### Environment variables
The plist needs 5 env vars in its `EnvironmentVariables` dict:

- `HOME` (for `op` and node to find configs)
- `OP_SERVICE_ACCOUNT_TOKEN` (auth for `op`)
- `OP_BIOMETRIC_UNLOCK_ENABLED=false`
- `OP_NO_AUTO_SIGNIN=true`
- `OP_LOAD_DESKTOP_APP_SETTINGS=false`
- `OPENCLAW_GATEWAY_TOKEN` (resolved from 1Password at repair time)

The repair command uses `PlistBuddy` for all env var operations (Print to check, Add or Set to write).

## Cross-Platform Considerations

### macOS (LaunchAgent)
- Gateway runs as `~/Library/LaunchAgents/ai.openclaw.gateway.plist`
- ProgramArguments should point to `/opt/homebrew/opt/node/bin/node` directly (stable symlink, NOT versioned Cellar path)
- EnvironmentVariables must include HOME, the 4 1Password env vars, and OPENCLAW_GATEWAY_TOKEN
- ThrottleInterval should be >= 30 (default 1 causes prompt spam on crash loops)
- `op` is typically at `/opt/homebrew/bin/op` (Apple Silicon) or `/usr/local/bin/op` (Intel)
- Repair uses `sed` for node path, `PlistBuddy` for ThrottleInterval and env vars

### Linux (systemd)
- Gateway runs as `~/.config/systemd/user/openclaw-gateway.service`
- `Environment=` directives in the unit file carry the 1Password env vars and OPENCLAW_GATEWAY_TOKEN
- `op` is typically at `/usr/local/bin/op` or `/snap/bin/op`
- Repair requires editing the unit file and running `systemctl --user daemon-reload`

### Docker
- Pass `OP_SERVICE_ACCOUNT_TOKEN` via Docker secrets or env, not a file mount
- Set the other 3 TCC vars in the container environment
- `trustedDirs` must match container paths for `op`
- `allowSymlinkCommand` may not be needed if `op` is installed directly (not via package manager symlinks)

### CLI (Terminal)
- The shell wrapper resolves `OPENCLAW_GATEWAY_TOKEN` inline before calling `openclaw`
- `~/.openclaw/.env` is sourced in the shell profile for the 1Password env vars
- All other secrets are resolved by the gateway via SecretRef

## Manual Step-by-Step Setup

For users who prefer manual control over the automated script:

### 1. Create 1Password vault and items
```bash
op vault create "OpenClaw Secrets"
op item create --category "API Credential" --title "openclaw-discord" --vault "OpenClaw Secrets" "credential=YOUR_TOKEN"
# Repeat for each secret
```

### 2. Create service account
Create at https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount/ with `read_items` access to the vault.

### 3. Create ~/.openclaw/.env
```bash
cat > ~/.openclaw/.env << 'EOF'
OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...your-token...
OP_BIOMETRIC_UNLOCK_ENABLED=false
OP_NO_AUTO_SIGNIN=true
OP_LOAD_DESKTOP_APP_SETTINGS=false
EOF
chmod 600 ~/.openclaw/.env
```

### 4. Add per-secret providers to openclaw.json
For each secret, add a provider entry under `secrets.providers` with the `op read` command and args. Add the corresponding SecretRef object on the credential field. See the example config in `examples/openclaw-secretref-config.json`.

### 5. Set gateway.auth.token to ${OPENCLAW_GATEWAY_TOKEN}
This is the one field that can't use SecretRef. Use the `${VAR}` pattern.

### 6. Update the LaunchAgent plist
Ensure ProgramArguments uses the stable node path. Add all env vars to EnvironmentVariables. Set ThrottleInterval to 30.

### 7. Verify
```bash
openclaw gateway status    # Should show RPC probe: ok
openclaw secrets audit --check  # Should show 0 unresolved
```

## OpenClaw's Roadmap Alignment

This integration follows OpenClaw's intended architecture:

- **Exec provider is the official extension point** for external secret managers.
- **No first-party 1Password integration is planned.** The exec bridge is the long-term model.
- **SecretRef credential surface expanded to 64 targets in 2026.3.2.** Covers all common credential fields.
- **gateway.auth.token SecretRef support is blocked by #29183.** The `${VAR}` + plist env var workaround is the correct approach until this is fixed.
- **No post-install lifecycle hooks exist.** The repair command is the best available mitigation for plist clobbering.
