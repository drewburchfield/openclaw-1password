# SecretRef + 1Password Architecture

## Why SecretRef Over ${VAR} Interpolation

OpenClaw supports two mechanisms for external secrets:

### ${VAR} Interpolation (Legacy)
- Config stores `"token": "${DISCORD_BOT_TOKEN}"`
- At startup, OpenClaw reads env var `DISCORD_BOT_TOKEN` and substitutes
- **Fatal flaw:** `openclaw doctor`, `openclaw update`, and `openclaw configure` can resolve the variable and write the plaintext value back to the JSON file (issues #9627, #4654, #10245)
- Requires `op run --env-file` wrapper around every process that reads the config
- The wrapper gets clobbered when `openclaw gateway install` regenerates the LaunchAgent plist

### SecretRef Exec Provider (Recommended, 2026.3.2+)
- Config stores a structured JSON object: `{ "source": "exec", "provider": "onepassword", "id": "op://..." }`
- At runtime, OpenClaw calls the resolver script, which calls `op read` to fetch the value
- **Key advantage:** SecretRef objects are treated as opaque by the config write path. They survive rewrites by design.
- No `op run` wrapper needed. The gateway resolves secrets itself.
- The only env var delivery needed is for `gateway.auth.token` (the one field that doesn't support SecretRef)

## The gateway.auth.token Exception

OpenClaw classifies `gateway.auth.token` as "session-bearing" and excludes it from SecretRef. The full list of unsupported fields includes: gateway access tokens, Matrix access tokens, OAuth refresh material, webhook tokens in thread bindings, and a few others. See docs.openclaw.ai/reference/secretref-credential-surface.

The workaround: use `${OPENCLAW_GATEWAY_TOKEN}` and resolve it in the launcher script before exec-ing node. This is the one `${VAR}` reference remaining in the config.

## File-Backed Service Account Token

The 1Password CLI (`op`) authenticates via `OP_SERVICE_ACCOUNT_TOKEN`. In the legacy setup, this was an environment variable in the LaunchAgent plist, which gets clobbered on updates.

The durable approach: store the token in `~/.openclaw/.op-token` (chmod 600). The resolver script and launcher script both read from this file. Since the file is outside OpenClaw's config management, nothing OpenClaw does can overwrite it.

## The Resolver Script (op-resolver.sh)

The resolver implements OpenClaw's jsonOnly exec provider protocol:

**Request (stdin from OpenClaw):**
```json
{"protocolVersion": 1, "provider": "onepassword", "ids": ["op://vault/item/field", "op://vault/item2/field"]}
```

**Response (stdout to OpenClaw):**
```json
{"protocolVersion": 1, "values": {"op://vault/item/field": "actual-secret", "op://vault/item2/field": "other-secret"}}
```

The script:
1. Reads `OP_SERVICE_ACCOUNT_TOKEN` from `~/.openclaw/.op-token`
2. Sets `OP_BIOMETRIC_UNLOCK_ENABLED=false`
3. Parses the IDs from stdin using `jq`
4. Calls `op read` for each ID
5. Returns the JSON response

## The Launcher Script (launch-gateway.sh)

Resolves the one credential that can't use SecretRef and execs the gateway:

1. Reads `OP_SERVICE_ACCOUNT_TOKEN` from `~/.openclaw/.op-token`
2. Calls `op read` for the gateway token
3. Exports `OPENCLAW_GATEWAY_TOKEN`
4. Execs node with the OpenClaw gateway entry point

The LaunchAgent plist points to this launcher instead of directly to node. After `openclaw gateway install` clobbers the plist, running `repair` re-points ProgramArguments to the launcher.

## Cross-Platform Considerations

### macOS (LaunchAgent)
- Gateway runs as `~/Library/LaunchAgents/ai.openclaw.gateway.plist`
- ProgramArguments should point to `launch-gateway.sh`
- EnvironmentVariables must include `HOME`
- `op` is typically at `/opt/homebrew/bin/op` (Apple Silicon) or `/usr/local/bin/op` (Intel)
- Repair uses `PlistBuddy` to modify the plist

### Linux (systemd)
- Gateway runs as `~/.config/systemd/user/openclaw-gateway.service`
- `ExecStart=` should point to `launch-gateway.sh`
- `Environment=HOME=/home/username` may be needed
- `op` is typically at `/usr/local/bin/op` or `/snap/bin/op`
- Repair requires editing the unit file and running `systemctl --user daemon-reload`

### Docker
- The resolver needs `HOME` set in the container environment
- The `.op-token` file should be mounted as a Docker secret, not baked into the image
- Alternatively, pass `OP_SERVICE_ACCOUNT_TOKEN` via Docker secrets and modify the resolver to read from env instead of file
- `trustedDirs` in the SecretRef provider must match container paths

### CLI (Terminal)
- The shell wrapper resolves `OPENCLAW_GATEWAY_TOKEN` inline before calling `openclaw`
- `OP_SERVICE_ACCOUNT_TOKEN` can be exported from the token file in the shell profile
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

### 3. Store token file
```bash
echo -n "ops_eyJ..." > ~/.openclaw/.op-token
chmod 600 ~/.openclaw/.op-token
```

### 4. Create resolver script
Copy `scripts/op-resolver-template.sh` to `~/.openclaw/bin/op-resolver.sh`, update paths for `op` and `jq`, and `chmod +x`.

### 5. Create launcher script
Copy pattern from `scripts/openclaw-1p-setup.sh`'s `generate_launcher_script` function. Update node path and `op://` reference for gateway token.

### 6. Add secrets provider to openclaw.json
Add the `secrets.providers.onepassword` block with absolute paths.

### 7. Replace each secret with SecretRef object
Replace `"token": "plaintext"` with `"token": { "source": "exec", "provider": "onepassword", "id": "op://vault/item/field" }` for each credential.

### 8. Update LaunchAgent/systemd
Point ProgramArguments (or ExecStart) to the launcher script.

### 9. Verify
```bash
openclaw gateway status    # Should show RPC probe: ok
openclaw secrets audit --check  # Should show 0 unresolved
```

## OpenClaw's Roadmap Alignment

This integration follows OpenClaw's intended architecture:
- **Exec provider is the official extension point** for external secret managers
- **No first-party 1Password integration is planned.** The exec bridge is the long-term model.
- **SecretRef credential surface expanded to 64 targets in 2026.3.2.** Covers all common credential fields.
- **gateway.auth.token SecretRef support is not planned.** The `${VAR}` + launcher workaround is the correct approach.
- **No post-install lifecycle hooks exist.** The repair command is the best available mitigation for plist clobbering.
