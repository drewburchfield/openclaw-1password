<div align="center">

<img src="https://ghrb.waren.build/banner?header=openclaw-1password%20%F0%9F%94%92&subheader=Zero%20plaintext%20secrets%20in%20OpenClaw&bg=0a1628&secondaryBg=1e3a5f&color=e8f0fe&subheaderColor=7eb8da&headerFont=Inter&subheaderFont=Inter&support=false" alt="openclaw-1password" width="100%">

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin from the [not-my-job](https://github.com/drewburchfield/not-my-job) marketplace.

![License](https://img.shields.io/badge/license-MIT-blue)

</div>

## What it does

Moves every secret out of `openclaw.json` and into 1Password using OpenClaw's SecretRef exec provider system. Secrets are resolved at runtime, never touch disk, and survive config rewrites by design. Includes a setup script, version-aware Claude Code skill, and troubleshooting for every known failure mode.

## Setup Script

| Command | What it does |
|---------|-------------|
| `openclaw-1p-setup.sh setup` | Full guided setup: vault, service account, secret migration, resolver, launcher |
| `openclaw-1p-setup.sh repair` | Fix LaunchAgent after `openclaw update` or `openclaw gateway install` |
| `openclaw-1p-setup.sh verify` | 9-point health check across token, scripts, config, and gateway |
| `openclaw-1p-setup.sh migrate` | Migrate remaining `${VAR}` references to SecretRef objects |

## How It Works

| Before | After |
|--------|-------|
| `"token": "xoxb-real-token"` | `"token": { "source": "exec", "provider": "onepassword", "id": "op://..." }` |
| Plaintext secrets on disk | Secrets in 1Password, resolved at runtime |
| `openclaw update` bakes secrets into JSON | SecretRef objects survive config rewrites |
| LaunchAgent breaks after every update | One repair command fixes it |

## Features

- Version-aware skill that adapts to the user's OpenClaw release
- File-backed service account token outside OpenClaw's config management
- Resolver script template with marked adaptation points for non-standard environments
- Handles the `gateway.auth.token` exception (the one field that can't use SecretRef)
- Cross-platform guidance for macOS (LaunchAgent), Linux (systemd), and Docker

## Requirements

- [OpenClaw](https://openclaw.ai) 2026.3.2+ (works with newer versions)
- [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`)
- A paid 1Password account (service accounts require Teams, Business, or Enterprise)
- `jq` (used by the resolver script)

## Install

```
claude plugins install openclaw-1password@not-my-job
```

## License

MIT
