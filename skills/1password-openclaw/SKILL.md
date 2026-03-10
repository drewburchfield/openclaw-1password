---
name: 1password-openclaw
description: This skill provides guided setup, diagnosis, and repair for securing OpenClaw with 1Password service accounts and SecretRef exec providers. Triggers when users ask to "set up 1Password with OpenClaw", "fix OpenClaw secrets", "repair OpenClaw gateway", "secure OpenClaw after update", "migrate from ${VAR} to SecretRef", "debug OpenClaw secret resolution", "configure SecretRef exec provider", or reference openclaw-1p-setup.sh, gateway token issues, the gateway.auth.token exception, TCC prompts from op, or durable secret management after OpenClaw updates.
version: 2.0.0
---

# OpenClaw + 1Password Integration Skill

Provide guided setup, diagnosis, adaptation, and repair for securing OpenClaw with 1Password service accounts using direct-op SecretRef exec providers.

## Version Awareness

**This skill was authored against OpenClaw 2026.3.2.** The user's version may be newer. Before taking any action:

1. Run `openclaw --version` and `op --version` to establish the user's exact versions
2. Run `openclaw secretref --help` or `openclaw help` to discover current CLI surface (commands may have been added, renamed, or removed)
3. Read `~/.openclaw/openclaw.json` to see the current config schema (new fields, renamed keys, or structural changes indicate version drift)
4. If the user's OpenClaw version is newer than 2026.3.2, check the OpenClaw changelog or docs for SecretRef changes before applying scripts or config patterns from this skill

**The golden rules that transcend any version:**
- Secrets must never be stored as plaintext in config files
- Each provider calls `op` directly with `jsonOnly: false`. No custom resolver script needed.
- Env vars in `~/.openclaw/.env` (chmod 600) are durable because they live outside OpenClaw's config management
- The `gateway.auth.token` exception may eventually be resolved (#29183); check before assuming it still applies
- The exec provider pattern is OpenClaw's intended extension point for external secret managers
- Four TCC-prevention env vars must be set wherever `op` runs headlessly

For detailed version adaptation guidance, consult `references/version-adaptation.md`.

## Core Architecture

Each secret gets its own provider entry that calls `op read` directly. No custom resolver script, no custom JSON protocol. The providers use `jsonOnly: false` and `allowSymlinkCommand: true` with `trustedDirs: ["/opt/homebrew"]` to handle Homebrew symlinks.

**Key files (once set up):**

| File | Purpose |
|---|---|
| `~/.openclaw/.env` | 1Password env vars: token + 3 TCC-prevention vars (chmod 600) |
| `~/.openclaw/openclaw.json` | Config with per-secret providers and SecretRef objects |

**Deprecated files (no longer needed):**

| File | Status |
|---|---|
| `~/.openclaw/bin/op-resolver.sh` | Replaced by direct op calls |
| `~/.openclaw/bin/launch-gateway.sh` | Replaced by plist EnvironmentVariables |
| `~/.openclaw/.op-token` | Replaced by `~/.openclaw/.env` |

**The one exception (as of 2026.3.2):** `gateway.auth.token` does not support SecretRef (blocked by #29183, Zod validation ordering bug). It uses `${OPENCLAW_GATEWAY_TOKEN}` resolved into the plist EnvironmentVariables. Verify this is still the case on the user's version.

## Workflow

### 1. Diagnose the User's Environment

Before running any scripts, understand the local setup. Run these checks:

```bash
openclaw --version          # Note exact version
op --version                # Need 1Password CLI
jq --version                # Required by setup script
uname -s                    # macOS vs Linux
```

Read the current config to understand what secrets exist and their current state:
- Read `~/.openclaw/openclaw.json` and identify all credential fields
- Check for plaintext values, `${VAR}` references, or existing SecretRef objects
- Check if `~/.openclaw/.env` exists (indicates partial/complete setup)
- Check if `~/.openclaw/bin/op-resolver.sh` exists (indicates old architecture, needs migration)
- Compare the config structure against what this skill expects; flag any new or renamed fields

For detailed architecture, design decisions, the 4 TCC-prevention env vars, cross-platform setup, and manual step-by-step instructions, consult `references/architecture.md`.

### 2. Adapt Scripts to the Local Environment

The setup script at `scripts/openclaw-1p-setup.sh` handles standard setups. For non-standard environments, adapt before running:

**Common adaptations needed:**
- **Non-Homebrew `op` path:** Update provider `command` fields. Find with `which op`.
- **Non-standard `trustedDirs`:** Match to where `op` actually lives on the system.
- **Custom vault names:** The default is "OpenClaw Secrets". The setup script prompts for this interactively.
- **Custom item naming:** Default convention is `openclaw-<service>` with field `credential`. Adapt the `PATH_TO_ITEM_NAME` map in the setup script if the user's vault uses different names.
- **Linux/systemd:** The setup script detects Linux but only provides guidance (not auto-repair). Set 1Password env vars and OPENCLAW_GATEWAY_TOKEN in the systemd unit `Environment=` directives.
- **Docker:** Pass `OP_SERVICE_ACCOUNT_TOKEN` and TCC vars via Docker secrets or env. Set `trustedDirs` to match container paths.
- **Existing 1Password items:** If secrets already exist in a vault, skip creation and just wire up provider entries and SecretRef references.
- **Old architecture (resolver/launcher scripts):** The setup command detects and migrates from the old approach. It removes the resolver-based provider and creates per-secret direct-op providers.
- **Newer OpenClaw version:** Read the setup script and compare its assumptions against the user's `openclaw --version`. Patch version checks, config paths, or CLI commands that have changed.

Read `scripts/openclaw-1p-setup.sh` before running to verify paths and version assumptions match the user's system. Patch anything that doesn't match.

### 3. Run Setup or Repair

**Fresh setup:** Run `scripts/openclaw-1p-setup.sh setup` interactively. It handles: prerequisite checks, vault creation, .env file creation, secret migration, per-secret provider generation, LaunchAgent repair, and verification.

**After OpenClaw update:** Run `scripts/openclaw-1p-setup.sh repair`. This fixes the LaunchAgent plist that `openclaw gateway install` clobbers: node path, ThrottleInterval, 1Password env vars, and OPENCLAW_GATEWAY_TOKEN.

**Verification only:** Run `scripts/openclaw-1p-setup.sh verify` for a health check.

**Manual migration:** If the user prefers manual control, follow the step-by-step process in `references/tutorial.md` and use `examples/openclaw-secretref-config.json` as a reference.

### 4. Verify and Troubleshoot

After setup, verify with `scripts/openclaw-1p-setup.sh verify`. For failures, consult `references/troubleshooting.md` which covers every known failure mode with exact diagnostic commands.

If the verify script itself fails on a newer OpenClaw version (e.g., CLI output format changed), consult `references/version-adaptation.md` for how to adapt the checks.

## Per-Secret Provider Format

Each secret gets a provider entry calling `op read` directly:

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
"token": {
  "source": "exec",
  "provider": "discord-token",
  "id": "discord-token"
}
```

All paths must be absolute. Adapt `command` and `trustedDirs` to the user's system. If the provider schema has changed in the user's version, check `openclaw help secretref` or the OpenClaw docs for current field names.

## Critical Rules

1. **Never store actual secret values in openclaw.json.** Only SecretRef objects or `${VAR}` references.
2. **The `.env` file must be chmod 600.** Verify after any operation that touches it.
3. **gateway.auth.token cannot use SecretRef (as of 2026.3.2).** Always use `${OPENCLAW_GATEWAY_TOKEN}` for this field. Check if this restriction has been lifted in the user's version (#29183).
4. **Always set all 4 TCC-prevention env vars in headless contexts.** `OP_SERVICE_ACCOUNT_TOKEN`, `OP_BIOMETRIC_UNLOCK_ENABLED=false`, `OP_NO_AUTO_SIGNIN=true`, `OP_LOAD_DESKTOP_APP_SETTINGS=false`.
5. **After `openclaw gateway install` or `openclaw update`:** Always run repair. The plist gets regenerated.
6. **Test op read before modifying config.** Run `source ~/.openclaw/.env && op read "op://..."` and verify it returns values.
7. **When the user's version differs from 2026.3.2:** Verify assumptions before applying changes. The spirit (zero plaintext, file-backed token, direct op calls) matters more than specific field names or CLI flags.

## Additional Resources

### Reference Files

- **`references/architecture.md`** - Direct-op architecture, TCC prevention, cross-platform notes, and manual setup
- **`references/troubleshooting.md`** - Every known failure mode with diagnostic commands and fixes
- **`references/version-adaptation.md`** - How to handle version differences, what to verify on newer OpenClaw releases
- **`references/tutorial.md`** - Complete step-by-step tutorial for manual setup

### Scripts

- **`scripts/openclaw-1p-setup.sh`** - Setup/repair/verify automation
- **`scripts/op-resolver-template.sh`** - DEPRECATED. Kept for reference only.

### Examples

- **`examples/openclaw-secretref-config.json`** - Example openclaw.json with per-secret providers for 7 common credentials
