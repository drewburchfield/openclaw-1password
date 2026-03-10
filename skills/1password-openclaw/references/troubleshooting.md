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

# .env file check
ls -la ~/.openclaw/.env

# Test token validity
source ~/.openclaw/.env && op vault list

# Test op read directly
source ~/.openclaw/.env && op read "op://YOUR_VAULT/YOUR_ITEM/credential"
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
- If it's `gateway.auth.token`: ensure `OPENCLAW_GATEWAY_TOKEN` is in the plist EnvironmentVariables

**Cause 2: Invalid SecretRef field**
Error: `Invalid input: expected string, received object`
A field that doesn't support SecretRef has a SecretRef object. Revert to `${VAR}` or plaintext.

**Cause 3: Provider command failure**
Error: timeout or connection errors in the log.
Test `op` directly:
```bash
source ~/.openclaw/.env
op read "op://OpenClaw Secrets/openclaw-discord/credential"
```

### "op would like to access data from other apps" prompt

**Symptom:** Persistent macOS TCC dialog about `op` accessing data, especially after reboot or gateway restart.

**Cause:** One or more of the 4 TCC-prevention env vars is missing from the `op` execution context. The most common culprit is `OP_LOAD_DESKTOP_APP_SETTINGS` not being set to `false`, which causes `op` to `lstat` the Group Containers directory.

**Fix:** Ensure all 4 vars are present in three places:

1. **`~/.openclaw/.env`** (source of truth):
```bash
OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...
OP_BIOMETRIC_UNLOCK_ENABLED=false
OP_NO_AUTO_SIGNIN=true
OP_LOAD_DESKTOP_APP_SETTINGS=false
```

2. **Plist EnvironmentVariables** (for LaunchAgent context):
```bash
# Check what's in the plist
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables" ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

3. **Provider `passEnv` arrays** (in openclaw.json):
Each provider needs `"passEnv": ["OP_SERVICE_ACCOUNT_TOKEN", "OP_BIOMETRIC_UNLOCK_ENABLED", "OP_NO_AUTO_SIGNIN", "OP_LOAD_DESKTOP_APP_SETTINGS"]`.

Run repair to fix all three:
```bash
./openclaw-1p-setup.sh repair
```

### After `openclaw gateway install`, gateway breaks

**Symptom:** Gateway was working, then after an OpenClaw update or `openclaw gateway install`, it crashes or triggers TCC prompts.

**Cause:** The plist was regenerated. Typical damage:
- Node path set to versioned Cellar path (e.g., `/opt/homebrew/Cellar/node/25.7.0/bin/node`)
- ThrottleInterval reset to 1
- 1Password env vars removed from EnvironmentVariables
- OPENCLAW_GATEWAY_TOKEN removed from EnvironmentVariables

**Fix:**
```bash
./openclaw-1p-setup.sh repair
```

This fixes the node path to the stable symlink, restores ThrottleInterval to 30, ensures all 1Password env vars are in the plist, resolves and sets OPENCLAW_GATEWAY_TOKEN, and bounces the gateway.

### After Homebrew upgrade of `op`, gateway breaks

**Symptom:** Gateway can't resolve secrets after upgrading 1Password CLI via Homebrew.

**Cause:** Unlikely with the new architecture. The providers use `allowSymlinkCommand: true` with `trustedDirs: ["/opt/homebrew"]`, so the symlink `/opt/homebrew/bin/op` keeps working even when the Cellar target changes.

**If it still breaks:** Check that the `op` binary actually exists:
```bash
ls -la /opt/homebrew/bin/op
```
If Homebrew unlinked it, run `brew link 1password-cli`.

### After Homebrew upgrade of `node`, gateway breaks

**Symptom:** Gateway fails to start. Error log shows "No such file or directory" for a `/opt/homebrew/Cellar/node/X.Y.Z/bin/node` path.

**Cause:** `openclaw gateway install` hardcoded the versioned Cellar path. When Homebrew upgrades node, that path no longer exists.

**Fix:**
```bash
./openclaw-1p-setup.sh repair
```

This replaces Cellar paths with the stable symlink `/opt/homebrew/opt/node/bin/node`, which survives Homebrew upgrades.

### "No accounts configured" from op read

**Symptom:** Provider calls fail with "No accounts configured for use with 1Password CLI."

**Cause 1:** `OP_SERVICE_ACCOUNT_TOKEN` is not in the environment. Check:
```bash
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:OP_SERVICE_ACCOUNT_TOKEN" ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

**Cause 2:** Token is expired or revoked. Test it:
```bash
source ~/.openclaw/.env && op vault list
```
If it fails, create a new service account and update `~/.openclaw/.env`.

**Cause 3:** In a LaunchAgent context, `HOME` isn't set. Check:
```bash
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:HOME" ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

### Secrets audit shows "unresolved"

**Symptom:** `openclaw secrets audit --check` reports unresolved references.

**Cause 1:** The audit CLI needs `OPENCLAW_GATEWAY_TOKEN` in its environment (for the one `${VAR}` field). Run with it:
```bash
source ~/.openclaw/.env
OPENCLAW_GATEWAY_TOKEN="$(op read "op://OpenClaw Secrets/openclaw-gateway/credential")" \
  openclaw secrets audit --check
```

**Cause 2:** A provider failed to resolve. Test `op read` directly with the specific `op://` reference from the failing provider.

### Mac app can't connect to gateway

**Symptom:** OpenClaw Mac app shows "health check failed."

**Cause:** The Mac app may need env vars that aren't in the GUI process environment.

**Fix:** Verify the gateway is running and the Mac app can reach localhost:18789. If the Mac app works through the gateway (which it should), just fixing the gateway is enough.

### SecretRef provider not found in config after update

**Symptom:** Gateway starts but can't resolve secrets. Error mentions unknown provider.

**Cause:** `openclaw doctor` or `openclaw configure` removed the `secrets.providers` block.

**Fix:**
```bash
./openclaw-1p-setup.sh repair
```

This re-adds the provider entries if missing.

### Config shows plaintext after openclaw doctor

**Symptom:** Running `openclaw doctor --fix` or `openclaw configure` replaced SecretRef objects with plaintext values.

**Cause:** This is the config rewrite bug (issue #13835, still open). SecretRef objects should survive, but `gateway.auth.token` might get its `${VAR}` resolved to plaintext.

**Fix:**
1. Check what was overwritten: `grep -E '"(sk-|xox|ghp_|pa-|ops_)' ~/.openclaw/openclaw.json`
2. Re-run setup or manually restore the SecretRef objects
3. Run `openclaw secrets audit --check` to verify

### Permission denied on .env file

**Symptom:** Gateway can't read 1Password env vars.

**Fix:**
```bash
chmod 600 ~/.openclaw/.env
chown $(whoami) ~/.openclaw/.env
```

If running as a different user (e.g., systemd service), ensure the service user owns the file.

### Provider timeout errors

**Symptom:** Gateway logs show timeout errors when resolving secrets.

**Cause:** `op read` is slow or hanging. Common reasons: network issues reaching 1Password servers, or `op` is trying interactive auth instead of using the service account.

**Fix:**
1. Test `op read` manually to see how long it takes:
```bash
time source ~/.openclaw/.env && op read "op://OpenClaw Secrets/openclaw-discord/credential"
```
2. If it hangs, check that `OP_SERVICE_ACCOUNT_TOKEN` is set (not empty)
3. Increase `timeoutMs` in the provider config if `op` is just slow (e.g., on a flaky network)
