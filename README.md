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

Personal config (skills, hooks, CLAUDE.md, allowlist, gitleaks rules) lives in the **private** companion repo `agent-config`. The container clones it on start using a GitHub token stored on a Docker volume.

## Reproducing on a fresh machine

Open elevated PowerShell on Windows 10/11 Pro and:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/curtyo18/agent-sandbox/main/bootstrap.ps1 | iex
```

Then follow on-screen prompts. After Ubuntu is installed and Docker is up, write a GitHub token (any token with `repo` scope) to `~/.agent-sandbox/github-pat` inside WSL, re-run `bootstrap.sh`, then:

```powershell
wsl -d Ubuntu-24.04 -- docker exec -it claude-box bash -lc 'claude login'
```

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — design decisions and trade-offs (why squid, why two repos, why the gh wrapper).
- [`docs/operations.md`](docs/operations.md) — daily entry, adding allowlist hosts, recovery, override env vars.
- [`docs/verification.md`](docs/verification.md) — what was tested when the sandbox was first built (filesystem boundaries, network allowlist, gh guard, secret-scan, audit log).
- [`docs/journal.md`](docs/journal.md) — bugs found during the initial bring-up and how they were fixed. Read this first if your bootstrap is failing.
