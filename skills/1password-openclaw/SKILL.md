---
name: 1password-openclaw
description: This skill provides guided setup, diagnosis, and repair for securing OpenClaw with 1Password service accounts and SecretRef exec providers. Triggers when users ask to "set up 1Password with OpenClaw", "fix OpenClaw secrets", "repair OpenClaw gateway", "secure OpenClaw after update", "migrate from ${VAR} to SecretRef", "debug OpenClaw secret resolution", "configure SecretRef exec provider", or reference openclaw-1p-setup.sh, op-resolver.sh, gateway token issues, the gateway.auth.token exception, or durable secret management after OpenClaw updates.
version: 1.0.0
---

# OpenClaw + 1Password Integration Skill

Provide guided setup, diagnosis, adaptation, and repair for securing OpenClaw with 1Password service accounts using SecretRef exec providers.

## Version Awareness

**This skill was authored against OpenClaw 2026.3.2.** The user's version may be newer. Before taking any action:

1. Run `openclaw --version` and `op --version` to establish the user's exact versions
2. Run `openclaw secretref --help` or `openclaw help` to discover current CLI surface (commands may have been added, renamed, or removed)
3. Read `~/.openclaw/openclaw.json` to see the current config schema (new fields, renamed keys, or structural changes indicate version drift)
4. If the user's OpenClaw version is newer than 2026.3.2, check the OpenClaw changelog or docs for SecretRef changes before applying scripts or config patterns from this skill

**The golden rules that transcend any version:**
- Secrets must never be stored as plaintext in config files
- The resolver script is the bridge between OpenClaw and 1Password; its protocol may evolve but the concept is stable
- File-backed tokens (`~/.openclaw/.op-token`) are durable because they live outside OpenClaw's config management
- The `gateway.auth.token` exception may eventually be resolved in a future version; check before assuming it still applies
- The exec provider pattern is OpenClaw's intended extension point for external secret managers

For detailed version adaptation guidance, consult `references/version-adaptation.md`.

## Core Architecture

OpenClaw's SecretRef system stores structured JSON objects in `openclaw.json` instead of plaintext secrets or `${VAR}` environment variable references. These objects tell the gateway to call an external resolver script at runtime. The resolver calls `op read` to fetch secrets from 1Password. Secrets never touch disk.

**Key files (once set up):**

| File | Purpose |
|---|---|
| `~/.openclaw/.op-token` | Service account token (chmod 600) |
| `~/.openclaw/bin/op-resolver.sh` | SecretRef exec provider (jsonOnly protocol) |
| `~/.openclaw/bin/launch-gateway.sh` | Gateway launcher (resolves gateway token) |
| `~/.openclaw/openclaw.json` | Config with SecretRef objects |

**The one exception (as of 2026.3.2):** `gateway.auth.token` does not support SecretRef (classified as session-bearing by OpenClaw). It uses `${OPENCLAW_GATEWAY_TOKEN}` resolved by the launcher script. Verify this is still the case on the user's version by checking whether the field accepts a SecretRef object or if the docs have changed.

## Workflow

### 1. Diagnose the User's Environment

Before running any scripts, understand the local setup. Run these checks:

```bash
openclaw --version          # Note exact version
op --version                # Need 1Password CLI
jq --version                # Required by resolver
uname -s                    # macOS vs Linux
```

Read the current config to understand what secrets exist and their current state:
- Read `~/.openclaw/openclaw.json` and identify all credential fields
- Check for plaintext values, `${VAR}` references, or existing SecretRef objects
- Check if `~/.openclaw/secrets.env` exists (indicates legacy `op run` setup)
- Check if `~/.openclaw/.op-token` exists (indicates partial/complete setup)
- Compare the config structure against what this skill expects; flag any new or renamed fields

For detailed architecture, design decisions, why SecretRef survives updates where `${VAR}` doesn't, cross-platform setup, and manual step-by-step instructions, consult `references/architecture.md`.

### 2. Adapt Scripts to the Local Environment

The setup script at `scripts/openclaw-1p-setup.sh` handles standard setups. For non-standard environments, adapt before running:

**Common adaptations needed:**
- **Non-Homebrew `op` path:** Update `OP_BIN` references in `op-resolver.sh`. Find with `which op`.
- **Non-Homebrew `jq` path:** Update `JQ_BIN` references. Find with `which jq`.
- **Non-standard node path:** Update `launch-gateway.sh`. Find with `which node`.
- **Custom vault names:** The default is "OpenClaw Secrets". The setup script prompts for this interactively.
- **Custom item naming:** Default convention is `openclaw-<service>` with field `credential`. Adapt the `PATH_TO_ITEM_NAME` map in the setup script if the user's vault uses different names.
- **Linux/systemd:** The setup script detects Linux but only provides guidance (not auto-repair). Adapt `launch-gateway.sh` path into the systemd `ExecStart=` directive.
- **Docker:** The resolver needs `HOME` set in the container. Pass `OP_SERVICE_ACCOUNT_TOKEN` via Docker secrets or env, not the token file.
- **Existing 1Password items:** If secrets already exist in a vault, skip creation and just wire up SecretRef references to existing `op://` paths.
- **Newer OpenClaw version:** Read the setup script and compare its assumptions against the user's `openclaw --version`. Patch version checks, config paths, or CLI commands that have changed.

Read `scripts/openclaw-1p-setup.sh` before running to verify paths and version assumptions match the user's system. Patch anything that doesn't match.

### 3. Run Setup or Repair

**Fresh setup:** Run `scripts/openclaw-1p-setup.sh setup` interactively. It handles: prerequisite checks, vault creation, secret migration, config rewrite, resolver/launcher generation, LaunchAgent repair, and verification.

**After OpenClaw update:** Run `scripts/openclaw-1p-setup.sh repair`. This fixes the LaunchAgent plist that `openclaw gateway install` clobbers.

**Verification only:** Run `scripts/openclaw-1p-setup.sh verify` for a 9-point health check.

**Manual migration:** If the user prefers manual control, follow the step-by-step process in `references/architecture.md` and use `examples/openclaw-secretref-config.json` as a reference.

### 4. Verify and Troubleshoot

After setup, verify with `scripts/openclaw-1p-setup.sh verify`. For failures, consult `references/troubleshooting.md` which covers every known failure mode with exact diagnostic commands.

If the verify script itself fails on a newer OpenClaw version (e.g., CLI output format changed), consult `references/version-adaptation.md` for how to adapt the checks.

## SecretRef Object Format

Each secret in `openclaw.json` becomes:

```json
{
  "source": "exec",
  "provider": "onepassword",
  "id": "op://VaultName/item-name/credential"
}
```

The provider is defined once at top level:

```json
{
  "secrets": {
    "providers": {
      "onepassword": {
        "source": "exec",
        "command": "/path/to/.openclaw/bin/op-resolver.sh",
        "allowSymlinkCommand": false,
        "trustedDirs": ["/path/to/.openclaw/bin"],
        "passEnv": ["HOME"],
        "jsonOnly": true,
        "timeoutMs": 15000
      }
    }
  }
}
```

All paths must be absolute. Adapt to the user's `$HOME`. If the provider schema has changed in the user's version, check `openclaw help secretref` or the OpenClaw docs for current field names.

## Critical Rules

1. **Never store actual secret values in openclaw.json.** Only SecretRef objects or `${VAR}` references.
2. **The `.op-token` file must be chmod 600.** Verify after any operation that touches it.
3. **gateway.auth.token cannot use SecretRef (as of 2026.3.2).** Always use `${OPENCLAW_GATEWAY_TOKEN}` for this field. Check if this restriction has been lifted in the user's version.
4. **Always set `OP_BIOMETRIC_UNLOCK_ENABLED=false` in headless contexts.** The resolver and launcher scripts handle this, but verify if the user adds custom scripts.
5. **After `openclaw gateway install` or `openclaw update`:** Always run repair. The plist gets regenerated.
6. **Test the resolver before modifying config.** Pipe a test request and verify it returns values.
7. **When the user's version differs from 2026.3.2:** Verify assumptions before applying changes. The spirit (zero plaintext, file-backed token, exec provider bridge) matters more than specific field names or CLI flags.

## Additional Resources

### Reference Files

- **`references/architecture.md`** - Full SecretRef architecture, design decisions, cross-platform notes, and the manual step-by-step setup process
- **`references/troubleshooting.md`** - Every known failure mode with diagnostic commands and fixes
- **`references/version-adaptation.md`** - How to handle version differences, what to verify on newer OpenClaw releases, and the durable principles that guide adaptation
- **`references/tutorial.md`** - Complete step-by-step tutorial for manual setup

### Scripts

- **`scripts/openclaw-1p-setup.sh`** - Setup/repair/verify/migrate automation
- **`scripts/op-resolver-template.sh`** - Resolver script template (adapt paths for user's system)

### Examples

- **`examples/openclaw-secretref-config.json`** - Example openclaw.json with SecretRef objects for 8 common credentials
