# Operations guide

Day-2 reference. Things you'll do more than once.

## Daily entry

From inside WSL (the bootstrap installs a `cbox` helper symlinked into `/usr/local/bin`):

```bash
cbox              # bash shell in /projects
cbox life         # bash shell in /projects/life
cbox -c           # claude in /projects
cbox -c life      # claude in /projects/life
```

`cbox` auto-starts the container if it has exited. Source: [`scripts/cbox`](../scripts/cbox).

Direct invocation (no helper) is just:
```powershell
wsl -d Ubuntu-24.04 -- docker exec -it claude-box bash -lc 'cd /projects/<repo> && claude'
```

After a host reboot the first invocation takes ~5-10s extra (WSL distro start + Docker engine start). Subsequent calls are instant. The container has `--restart unless-stopped` so it comes up automatically with Docker.

A short PowerShell alias in `$PROFILE` makes daily use one word from the Windows side too:

```powershell
function claude {
  param([string]$Repo)
  if ($Repo) {
    wsl -d Ubuntu-24.04 -- cbox -c $Repo
  } else {
    wsl -d Ubuntu-24.04 -- cbox -c
  }
}
```

## Multiple concurrent sessions

`docker exec` is multiplex-safe. Open as many shells as you want; each `claude` invocation is its own process. They share the same filesystem (`/projects`, `/home/claude/.claude`), the same audit log (`/audit/YYYY-MM-DD.jsonl`), and the same OAuth token.

Caveat: they're not isolated like separate containers. If you want true isolation per task (e.g. one runs a long task while another browses), that's a future enhancement — currently parked.

## Adding an allowlisted host

**Globally (applies to all sessions):**
1. Edit `agent-config/network-allowlist.conf` — add `acl allowed_hosts dstdomain .example.com`
2. `git commit && git push`
3. `wsl -d Ubuntu-24.04 -- docker restart claude-box` — entrypoint pulls the new allowlist and re-renders squid.conf.

**Per-project (one repo only):**
1. Drop `.claude-allowlist.conf` at the root of the project (`/projects/<repo>/.claude-allowlist.conf`), same format as the global file.
2. `docker restart claude-box`. Entrypoint scans `/projects/*/.claude-allowlist.conf` and concatenates them with the global allowlist.

There's no watcher — new per-project files won't take effect until a container restart.

## Recovery scenarios

**Container exited.**
```powershell
wsl -d Ubuntu-24.04 -- docker start claude-box
wsl -d Ubuntu-24.04 -- docker logs claude-box --tail 30   # check for FATAL lines
```

**Squid bungles (`ACL not found` etc.) after editing allowlist.**
```powershell
wsl -d Ubuntu-24.04 -- docker exec claude-box cat /etc/squid/squid.conf   # inspect rendered config
```
Fix the allowlist syntax, push, `docker restart`.

**Need to rebuild after editing Dockerfile / wrappers / entrypoint.**
```powershell
wsl -d Ubuntu-24.04 -- bash /home/curt/code/agent-sandbox/bootstrap.sh
```
Image rebuilds (Docker layer cache makes most steps instant), container is recreated, state persists via named volumes.

**Auth token expired mid-session.**
```powershell
wsl -d Ubuntu-24.04 -- docker exec -it claude-box bash -lc 'claude login'
```
Re-auth; token written to the persistent `claude-cfg-cache` volume.

## Overriding the guard rails

When you intentionally need to do something a guard blocks:

| Guard | Override |
|---|---|
| `gh` wrapper blocking `repo delete` / visibility flip / transfer / archive | `CLAUDE_UNLOCK_DESTRUCTIVE=1 gh ...` |
| Pre-commit secret-scan blocking a commit | `CLAUDE_ALLOW_SECRET_COMMIT=1 git commit ...`, or add `# gitleaks:allow` on the offending line |
| Squid blocking a host | widen the allowlist (see above) |

Every override is itself audit-logged with a distinct `reason` field, so they're discoverable in the SessionStart surface next time you start a claude session.

## Inspecting the audit log

The audit log lives at `/audit/YYYY-MM-DD.jsonl` inside the container, which is bind-mounted from `<host-projects>/.claude-audit/YYYY-MM-DD.jsonl` on the host — so you can read it from either side without entering the container.

```powershell
wsl -d Ubuntu-24.04 -- cat /mnt/e/Projects/.claude-audit/$(Get-Date -Format yyyy-MM-dd).jsonl
```

Useful one-liners (inside container):
```bash
# only blocked events
jq -c 'select(.blocked == true)' /audit/$(date -u +%F).jsonl

# group denies by host
jq -r 'select(.src=="squid") | .host' /audit/$(date -u +%F).jsonl | sort | uniq -c | sort -rn
```

## Updating agent-config from outside the container

Edit files in `~/code/agent-config/` (WSL side) → commit → push. Then `docker restart claude-box` to pull. The entrypoint always does `git pull --ff-only` on start.
