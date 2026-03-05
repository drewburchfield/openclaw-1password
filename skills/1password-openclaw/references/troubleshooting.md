# Troubleshooting Guide

## Diagnosis Commands

Run these to understand the current state:

```bash
# OpenClaw version (need 2026.3.2+)
openclaw --version

# Gateway status
openclaw gateway status

# Port check
lsof -i :18789

# Error log (most recent)
tail -50 ~/.openclaw/logs/gateway.err.log

# Config validation
cat ~/.openclaw/openclaw.json | jq '.' > /dev/null && echo "Valid JSON" || echo "INVALID"

# Count ${VAR} references (should be 0 or 1)
grep -c '"\${' ~/.openclaw/openclaw.json

# Count SecretRef objects
grep -c '"source" : "exec"' ~/.openclaw/openclaw.json

# Token file check
ls -la ~/.openclaw/.op-token

# Test token validity
OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.openclaw/.op-token)" OP_BIOMETRIC_UNLOCK_ENABLED=false op vault list

# Test resolver
echo '{"protocolVersion":1,"provider":"onepassword","ids":["op://YOUR_VAULT/YOUR_ITEM/credential"]}' | ~/.openclaw/bin/op-resolver.sh | jq '.'
```

## Common Failures

### Gateway crash-looping (ECONNREFUSED on port 18789)

**Symptom:** `openclaw status` shows gateway as running but unreachable. Nothing listening on port 18789.

**Diagnose:**
```bash
tail -20 ~/.openclaw/logs/gateway.err.log
```

**Cause 1: Missing env var**
Error: `MissingEnvVarError: Missing env var "SOME_VAR"`
The config has a `${VAR}` reference but the variable isn't in the environment.
- If the field supports SecretRef: migrate it to a SecretRef object
- If it's `gateway.auth.token`: ensure the launcher script resolves it

**Cause 2: Invalid SecretRef field**
Error: `Invalid input: expected string, received object`
A field that doesn't support SecretRef has a SecretRef object. Revert to `${VAR}` or plaintext.

**Cause 3: Resolver script failure**
Error: timeout or connection errors in the log.
Test the resolver manually:
```bash
echo '{"protocolVersion":1,"provider":"onepassword","ids":["op://vault/item/field"]}' | ~/.openclaw/bin/op-resolver.sh
```

### "op would like to access data from other apps" prompt

**Symptom:** Persistent macOS TCC dialog about `op` accessing data.

**Cause:** `OP_BIOMETRIC_UNLOCK_ENABLED` is not set to `false` in a headless context. When `true`, `op` tries to connect to the 1Password desktop app via IPC.

**Fix:** Ensure `export OP_BIOMETRIC_UNLOCK_ENABLED=false` appears in:
- `op-resolver.sh`
- `launch-gateway.sh`
- Any Mac app wrapper scripts

### After `openclaw gateway install`, gateway breaks

**Symptom:** Gateway was working, then after an OpenClaw update or `openclaw gateway install`, it crashes.

**Cause:** The plist was regenerated with default ProgramArguments (direct node call, no launcher).

**Fix:**
```bash
./openclaw-1p-setup.sh repair
```

Or manually:
```bash
# Re-point ProgramArguments to launcher
/usr/libexec/PlistBuddy -c "Delete :ProgramArguments" ~/Library/LaunchAgents/ai.openclaw.gateway.plist
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" ~/Library/LaunchAgents/ai.openclaw.gateway.plist
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $HOME/.openclaw/bin/launch-gateway.sh" ~/Library/LaunchAgents/ai.openclaw.gateway.plist

# Bounce
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
sleep 2
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

### "No accounts configured" from op read

**Symptom:** Resolver or launcher fails with "No accounts configured for use with 1Password CLI."

**Cause 1:** Token file is missing or empty.
```bash
cat ~/.openclaw/.op-token | head -c 10
# Should start with "ops_"
```

**Cause 2:** Token is expired or revoked. Create a new service account and update the token file.

**Cause 3:** In a LaunchAgent context, `HOME` isn't set. Check:
```bash
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:HOME" ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

### Secrets audit shows "unresolved"

**Symptom:** `openclaw secrets audit --check` reports unresolved references.

**Cause 1:** The audit CLI needs `OPENCLAW_GATEWAY_TOKEN` in its environment (for the one `${VAR}` field). Run with it:
```bash
OPENCLAW_GATEWAY_TOKEN="$(OP_SERVICE_ACCOUNT_TOKEN=$(cat ~/.openclaw/.op-token) OP_BIOMETRIC_UNLOCK_ENABLED=false op read "op://vault/openclaw-gateway/credential")" openclaw secrets audit --check
```

**Cause 2:** A SecretRef provider failed to resolve. Test the resolver manually.

### Mac app can't connect to gateway

**Symptom:** OpenClaw Mac app shows "health check failed."

**Cause:** The Mac app may need env vars that aren't in the GUI process environment.

**Fix:** Use the wrapper app ("OpenClaw (Safe)") that runs the Mac app binary under `op read` context. Or verify the gateway is running and the Mac app can reach localhost:18789.

### Node path changed after Homebrew upgrade

**Symptom:** Gateway fails to start. Error log shows "MODULE_NOT_FOUND" or the node binary path doesn't exist.

**Fix:** Update `launch-gateway.sh` with the new node path:
```bash
which node  # Get the new path
# Edit ~/.openclaw/bin/launch-gateway.sh
```

Or use a dynamic path in the launcher:
```bash
exec "$(brew --prefix node)/bin/node" ...
```

### SecretRef provider not found in config after update

**Symptom:** Gateway starts but can't resolve secrets. Error mentions unknown provider.

**Cause:** `openclaw doctor` or `openclaw configure` removed the `secrets.providers` block.

**Fix:**
```bash
./openclaw-1p-setup.sh repair
```

This re-adds the provider block if missing.

### Config shows plaintext after openclaw doctor

**Symptom:** Running `openclaw doctor --fix` or `openclaw configure` replaced SecretRef objects with plaintext values.

**Cause:** This is the config rewrite bug (issue #13835, still open). SecretRef objects should survive, but `gateway.auth.token` might get its `${VAR}` resolved to plaintext.

**Fix:**
1. Check what was overwritten: `grep -E '"(sk-|xox|ghp_|pa-|ops_)' ~/.openclaw/openclaw.json`
2. Re-run setup or manually restore the SecretRef objects
3. Run `openclaw secrets audit --check` to verify

### Permission denied on .op-token

**Symptom:** Resolver fails because it can't read the token file.

**Fix:**
```bash
chmod 600 ~/.openclaw/.op-token
chown $(whoami) ~/.openclaw/.op-token
```

If running as a different user (e.g., systemd service), ensure the service user owns the file.
