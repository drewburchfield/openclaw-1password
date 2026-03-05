<div align="center">

<img src="https://ghrb.waren.build/banner?header=openclaw-1password%20![1password]&subheader=Zero%20plaintext%20secrets%20in%20OpenClaw&bg=0a1628&secondaryBg=1e3a5f&color=e8f0fe&subheaderColor=7eb8da&headerFont=Inter&subheaderFont=Inter&support=false" alt="openclaw-1password" width="100%">

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin from the [not-my-job](https://github.com/drewburchfield/not-my-job) marketplace.

![License](https://img.shields.io/badge/license-MIT-blue)

</div>

## What it does

Guided setup, diagnosis, and repair for securing OpenClaw with 1Password service accounts using SecretRef exec providers. Moves every secret out of `openclaw.json` and into 1Password, resolved at runtime. Survives OpenClaw updates by design.

Includes:
- **Setup automation** (`openclaw-1p-setup.sh`) with setup, repair, verify, and migrate commands
- **Claude Code skill** for adapting the setup to any local environment, with version-aware guidance
- **Resolver script template** for the SecretRef exec provider bridge
- **Troubleshooting guide** covering every known failure mode

## Install

```
claude plugins install openclaw-1password@not-my-job
```

## License

MIT
