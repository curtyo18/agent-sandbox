# agent-sandbox

Sandboxed Claude Code CLI runtime: Linux container on WSL2 Ubuntu, allowlisted forward proxy, destructive-action guard, secret-leak guard, audit log surfaced in-session.

> **Note (2026-05-16):** This repo is currently **PRIVATE**. The "Reproducing on a fresh machine" `iwr | iex` flow below requires public read access; flip to public is deferred until content review is complete.

## What's in here

- `Dockerfile` — extends `node:lts-bookworm`, installs claude/gh/gitleaks/squid + wrappers.
- `entrypoint.sh` — runs at container start: clones `agent-config`, renders squid config, starts squid, stays alive.
- `squid.conf.template` — base squid config; allowlist injected at startup.
- `wrappers/gh` — gh CLI wrapper blocking visibility flips, repo delete/transfer/archive.
- `wrappers/git-audit-wrapper` — logs force-push and non-origin push (no block).
- `wrappers/audit-shell.sh` — bash DEBUG-trap logger; sourced via `BASH_ENV`.
- `bootstrap.ps1` — Windows entry point (enables WSL2, installs Ubuntu, hands off).
- `bootstrap.sh` — Ubuntu side (installs Docker, builds image, runs container).
- `tests/test-gh-wrapper.sh` — unit-style test for the gh wrapper.

Personal config (skills, hooks, CLAUDE.md, allowlist, gitleaks rules) lives in the **private** companion repo `agent-config`. The container clones it on start using a fine-grained GitHub PAT stored on a Docker volume.

## Reproducing on a fresh machine

Open elevated PowerShell on Windows 10/11 Pro and:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/curtyo18/agent-sandbox/main/bootstrap.ps1 | iex
```

Then follow on-screen prompts. After Ubuntu is installed and Docker is up, paste a fine-grained PAT for `curtyo18/agent-config` (Contents: read), then:

```powershell
wsl -d Ubuntu-24.04 -- docker exec -it claude-box bash -lc 'claude login'
```

## Design

See the design spec in the parent project workspace at `~/.claude/specs/2026-05-16-claude-code-sandbox-design.md`.
