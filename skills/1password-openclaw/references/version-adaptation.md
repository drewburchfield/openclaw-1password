# Version Adaptation Guide

This plugin was authored against OpenClaw 2026.3.2 and 1Password CLI 2.18+. Both tools update frequently. This guide covers how to adapt when the user's versions differ.

## Durable Principles

These principles hold regardless of OpenClaw version:

1. **Zero plaintext secrets in config files.** The config file should contain references (SecretRef objects or `${VAR}` strings), never actual credential values.
2. **File-backed service account token.** Store `OP_SERVICE_ACCOUNT_TOKEN` in `~/.openclaw/.op-token` (chmod 600) rather than environment variables that get clobbered by OpenClaw config management.
3. **Exec provider as the extension point.** OpenClaw's exec provider pattern is the official, long-term model for external secret managers. No first-party 1Password integration is planned.
4. **Resolver script as the bridge.** A script that speaks the jsonOnly protocol (JSON on stdin/stdout) bridges OpenClaw's SecretRef system to `op read`. The protocol may evolve but the concept is stable.
5. **Launcher script for exceptions.** Any credential field that doesn't support SecretRef needs env var resolution before the gateway process starts. The launcher script handles this.
6. **Repair after updates.** OpenClaw updates can regenerate service configuration (LaunchAgent plists, systemd units). Always verify and repair after updates.

## Version Discovery Checklist

Before applying any scripts or config patterns, run these discovery commands:

```bash
# 1. OpenClaw version
openclaw --version

# 2. Available CLI commands (look for new secretref/secrets subcommands)
openclaw --help
openclaw secretref --help 2>/dev/null
openclaw secrets --help 2>/dev/null

# 3. Current config structure
cat ~/.openclaw/openclaw.json | jq 'keys'

# 4. SecretRef credential surface (which fields accept SecretRef)
# Check docs or try: openclaw secretref list 2>/dev/null

# 5. 1Password CLI version
op --version

# 6. 1Password CLI capabilities
op read --help
op service-account --help 2>/dev/null
```

## What May Change Between Versions

### OpenClaw Changes to Watch For

| Area | What to check | Impact |
|------|--------------|--------|
| SecretRef credential surface | New fields added, or restrictions removed | More fields may accept SecretRef; `gateway.auth.token` may gain support |
| Config schema | New top-level keys, renamed fields | Setup script's jq queries may need updating |
| CLI commands | New subcommands for secrets management | May replace manual jq-based config editing |
| Exec provider protocol | Protocol version bump, new fields in request/response | Resolver script may need protocol updates |
| Gateway launcher | Changes to entry point path or arguments | `launch-gateway.sh` exec line may need updating |
| Service management | New LaunchAgent/systemd handling | Repair logic may need updating |
| Built-in providers | First-party secret manager support | May eventually replace the exec provider bridge |

### 1Password CLI Changes to Watch For

| Area | What to check | Impact |
|------|--------------|--------|
| `op read` syntax | Flag changes, output format | Resolver script may need updating |
| Service accounts | Authentication flow changes | Token file format or creation process may change |
| Biometric unlock | Default behavior changes | `OP_BIOMETRIC_UNLOCK_ENABLED` handling may change |
| Connect server | 1Password Connect as alternative to CLI | May offer a socket-based resolver instead of CLI calls |

## Adaptation Strategies

### If the user's OpenClaw is newer than 2026.3.2

1. **Check the changelog.** Look for SecretRef or secrets-related changes.
2. **Test the gateway.auth.token exception.** Try setting it to a SecretRef object. If it works, the launcher script can be simplified to just exec node directly (no env var resolution needed).
3. **Check for a built-in secrets CLI.** Newer versions may have `openclaw secrets migrate` or similar commands that automate what the setup script does.
4. **Verify the exec provider schema.** Run `openclaw help secretref` or check if `secrets.providers` in the config still uses the same field names.
5. **Test the verify script.** Run `scripts/openclaw-1p-setup.sh verify` and check for false positives/negatives caused by version differences.

### If the user's OpenClaw is older than 2026.3.2

1. **Check SecretRef support.** Versions before 2026.3.2 had limited SecretRef credential surface (fewer than 64 fields). Some secrets may need to remain as `${VAR}` references.
2. **Consider upgrading first.** `npm install -g openclaw@latest` is usually safe and gets full SecretRef support.
3. **Fall back to `${VAR}` + `op run`.** For fields that don't support SecretRef on older versions, use the legacy pattern documented in `references/tutorial.md`.

### If the setup script fails

1. **Read the error output.** The script provides diagnostic information on failure.
2. **Check version assumptions.** The script checks for 2026.3.2+ but the exact check may need updating for version numbering changes.
3. **Run steps manually.** Use `references/architecture.md` for the manual step-by-step process. The script automates these steps but isn't required.
4. **Adapt jq queries.** If config structure changed, the jq paths used to discover and migrate secrets may need updating.

## Testing After Adaptation

After making any version-specific changes:

```bash
# 1. Test resolver in isolation
echo '{"protocolVersion":1,"provider":"onepassword","ids":["op://VAULT/ITEM/FIELD"]}' \
  | ~/.openclaw/bin/op-resolver.sh | jq '.'

# 2. Test launcher in isolation (just the token resolution, not the exec)
OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.openclaw/.op-token)" \
  OP_BIOMETRIC_UNLOCK_ENABLED=false \
  op read "op://VAULT/ITEM/FIELD"

# 3. Validate config JSON
cat ~/.openclaw/openclaw.json | jq '.' > /dev/null && echo "Valid JSON"

# 4. Start gateway and check
openclaw gateway status

# 5. Full verification
scripts/openclaw-1p-setup.sh verify
```

## Future-Proofing Notes

Based on OpenClaw's roadmap (as of 2026.3.2):

- **Exec provider is the long-term model.** No first-party vault integrations are planned. The exec bridge pattern is intentional and stable.
- **SecretRef credential surface expanded to 64 targets in 2026.3.2.** This covers all common credential fields. Further expansion is likely.
- **gateway.auth.token SecretRef support was not planned as of 2026.3.2.** The `${VAR}` + launcher workaround is the correct approach until this changes.
- **No post-install lifecycle hooks exist.** The repair command remains the best mitigation for service config clobbering after updates.
- **Config rewrite safety has open bugs.** SecretRef objects survive by design, but `${VAR}` references remain vulnerable to plaintext bake-back.
