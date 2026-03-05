<div align="center">

<img src="https://ghrb.waren.build/banner?header=![1password]%20openclaw-1password&subheader=Zero%20plaintext%20secrets%20in%20OpenClaw&bg=0a1628&secondaryBg=1e3a5f&color=e8f0fe&subheaderColor=7eb8da&headerFont=Inter&subheaderFont=Inter&support=false" alt="openclaw-1password" width="100%">

**Move every secret out of `openclaw.json` and into 1Password. Resolved at runtime, never on disk.**

![License](https://img.shields.io/badge/license-MIT-blue)

</div>

<br>

## What it does

Replaces plaintext secrets in `openclaw.json` with SecretRef exec provider objects that call 1Password at runtime. Secrets survive config rewrites by design, so `openclaw update` and `openclaw doctor` can't accidentally bake them back into your config file.

| Before | After |
|--------|-------|
| `"token": "xoxb-real-token"` | `"token": { "source": "exec", "provider": "onepassword", "id": "op://..." }` |
| Plaintext secrets on disk | Secrets in 1Password, resolved at runtime |
| `openclaw update` bakes secrets into JSON | SecretRef objects survive config rewrites |
| LaunchAgent breaks after every update | One repair command fixes it |

<br>

<p align="center">· · ·</p>

## How to use this

This repo is a knowledge base and script toolkit. It works with any AI coding assistant that can read files from a directory, and it also ships as a Claude Code plugin for one-command installation.

### Option A: Any agentic CLI

Clone or download this repo, then point your tool at the `skills/1password-openclaw/` directory.

```bash
git clone https://github.com/drewburchfield/openclaw-1password.git
```

The directory structure is self-contained:

```
skills/1password-openclaw/
├── SKILL.md                  # Main guide (start here)
├── references/
│   ├── architecture.md       # SecretRef design, cross-platform notes
│   ├── troubleshooting.md    # Every known failure mode
│   ├── tutorial.md           # Step-by-step manual setup
│   └── version-adaptation.md # Handling newer OpenClaw versions
├── scripts/
│   ├── openclaw-1p-setup.sh  # Setup/repair/verify/migrate automation
│   └── op-resolver-template.sh
└── examples/
    └── openclaw-secretref-config.json
```

Tell your assistant to read `skills/1password-openclaw/SKILL.md` and it will have full context on setup, diagnosis, repair, and version adaptation.

**Cursor, Windsurf, Codex, etc.:** Add the `skills/1password-openclaw/` path to your project context or rules file. The skill and references are plain Markdown; any tool that reads files can use them.

### Option B: Claude Code plugin

```bash
claude plugins install openclaw-1password@not-my-job
```

This registers the skill automatically. Ask Claude Code to "set up 1Password with OpenClaw" and it picks up the full guide.

<br>

<p align="center">· · ·</p>

## Setup script

The included shell script handles the full lifecycle:

| Command | What it does |
|---------|-------------|
| `openclaw-1p-setup.sh setup` | Guided onboarding: vault, service account, secret migration, resolver, launcher |
| `openclaw-1p-setup.sh repair` | Fix LaunchAgent after `openclaw update` or `openclaw gateway install` |
| `openclaw-1p-setup.sh verify` | 9-point health check across token, scripts, config, and gateway |
| `openclaw-1p-setup.sh migrate` | Convert remaining `${VAR}` references to SecretRef objects |

You can run the script directly or let your AI assistant run it for you.

<br>

## Requirements

- [OpenClaw](https://openclaw.ai) 2026.3.2+ (works with newer versions)
- [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`)
- A paid 1Password account (service accounts require Teams, Business, or Enterprise)
- `jq` (used by the resolver script)

## License

MIT
