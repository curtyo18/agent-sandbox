# agent-sandbox

A sandboxed Claude Code runtime. Docker container with:
- Network egress via squid proxy (strict allowlist by default)
- GitHub CLI wrapper that blocks destructive operations and logs all calls
- Pre-commit secret scanning
- Automatic config from [agent-config](https://github.com/curtyo18/agent-config)

## Requirements

- Docker (Linux or WSL2)
- GitHub CLI (`gh`) on the host
- A GitHub PAT with repo scope

## Quick start

```bash
# Clone and build
git clone https://github.com/curtyo18/agent-sandbox.git
cd agent-sandbox
docker build --build-arg TZ=America/New_York -t claude-sandbox .

# Run (replace values)
docker run -d \
  --name claude-sandbox \
  -e GIT_USER_EMAIL="you@example.com" \
  -e GIT_USER_NAME="Your Name" \
  claude-sandbox
```

## Config overlay

Point `AGENT_CONFIG_PRIVATE_REPO` at a private fork of agent-config to layer
personal settings on top of the public base at startup:

```bash
docker run -d \
  --name claude-sandbox \
  -e GIT_USER_EMAIL="you@example.com" \
  -e GIT_USER_NAME="Your Name" \
  -e AGENT_CONFIG_PRIVATE_REPO="https://github.com/you/agent-config-private.git" \
  claude-sandbox
```

The private repo is rsynced on top of the public config. Private wins on any
filename clash.

## Research mode

A variant mode with full internet access and write restrictions:

```bash
docker run -d \
  --name claude-research \
  -e CONTAINER_MODE=research \
  -e RESEARCH_REPO="https://github.com/you/research.git" \
  -e GIT_USER_EMAIL="you@example.com" \
  -e GIT_USER_NAME="Your Name" \
  claude-sandbox
```

In research mode: squid allows all HTTPS, `rm`/`rmdir` are blocked, `git push`
is restricted to `RESEARCH_REPO` only.

## Phone access (optional)

`scripts/session-launcher.py` is an HTTP server that spawns/restarts Claude
sessions. Intended to be fronted by Tailscale for remote access from a phone.
Configure via env vars — see the file header. Not started by default.

## Network allowlist

Default allowlist (strict mode): anthropic.com, claude.ai, github.com,
npmjs.org, pypi.org, cloudflare API. Edit `network-allowlist.conf` in your
agent-config and rebuild.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned improvements: project scoping,
scoped PATs, and mobile terminal access.
