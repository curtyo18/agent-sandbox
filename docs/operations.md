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

## Permission prompts: bypassed by design

`cbox -c` launches claude with `--dangerously-skip-permissions`, and `agent-config/settings.json` sets `permissions.defaultMode: bypassPermissions` plus `skipDangerousModePermissionPrompt: true`. Inside the container's shell, a `claude()` bash function also injects `--dangerously-skip-permissions` for any manual `claude` invocation. The container is the safety net; the prompts add friction without adding safety here.

The sandbox guard rails still enforce regardless: squid still blocks non-allowlisted egress, the `gh` wrapper still blocks destructive ops (`repo delete`, visibility flip, etc.), the pre-commit hook still blocks secret commits, and the audit log still captures everything. See [architecture.md](architecture.md) for the reasoning.

## Dev server ports

Container publishes `127.0.0.1:8000-8099 → container:8000-8099`. Bind any dev server to a port in that range and it's reachable from the host browser at `http://localhost:<port>/`. `agent-config/CLAUDE.md` tells in-container claude sessions to default to that range.

To bind a port outside the range you'd recreate the container with `-p` mappings — easier to just pick a free port in 8000-8099.

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
wsl -d Ubuntu-24.04 -- bash /mnt/e/Projects/agent-sandbox/bootstrap.sh
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

## Phone access (life-bot)

A claude session in `/projects/life` is reachable from any device on your tailnet via a tiny in-container HTTP launcher fronted by Tailscale Serve. See [architecture.md](architecture.md) → "Phone access via Tailscale" for the why.

### One-time setup on a fresh Windows machine

1. Install Tailscale Windows (https://tailscale.com/download/windows), sign in.
2. Make sure the container is up and listening on `127.0.0.1:8088` from the WSL host:
   ```bash
   wsl -d Ubuntu-24.04 -- bash -c 'curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8088/'
   ```
   Expect `HTTP 200`.
3. From PowerShell, point Tailscale Serve at the launcher:
   ```powershell
   & "C:\Program Files\Tailscale\tailscale.exe" serve --bg --https=443 http://127.0.0.1:8088
   & "C:\Program Files\Tailscale\tailscale.exe" serve status
   ```
   The status output shows the tailnet URL (e.g. `https://<your-hostname>.<your-tailnet>.ts.net (tailnet only)`).
4. Confirm funnel is off (we do NOT want public internet exposure):
   ```powershell
   & "C:\Program Files\Tailscale\tailscale.exe" funnel status
   ```
   Should show `(tailnet only)` next to the URL, no `funnel` flag.

Serve config persists in Tailscale's local state — survives Windows reboot, no re-run needed.

### Daily phone use

Phone (Tailscale logged into the same account):

1. Open `https://<hostname>.<tailnet>.ts.net/`.
2. Page renders `● tmux session running in /projects/life` or `○ not running`.
3. Tap the button (`Start` if dead, `Restart` if alive — both work). Page reloads.
4. Switch to the Claude mobile app → Code tab → the `life-bot` session appears for chat.

`Restart` is unconditional kill + respawn — useful because the Claude remote-control link can time out independently of the tmux session (mobile app shows no session, but the in-container tmux still exists). Always-restart sidesteps that.

### Changing what life-bot runs

`scripts/life-bot-launcher.py` hardcodes the directory and session name. To point it at a different repo, edit `SESSION_NAME` and the spawn command's `cd /projects/<repo>` then rebuild via `bash bootstrap.sh`.

## Copy to host clipboard from inside the container

Inside the container:

```bash
echo "stuff" | clip            # container → host clipboard
git log --oneline -5 | clip
clip < some-file.txt

URL=$(paste)                   # host clipboard → container (one-shot, current value)
paste > /tmp/saved.txt
```

How it works: both commands talk to a tiny WSL-side watcher (`claude-clip-watcher`, started by `bootstrap.sh` in the background) via files in `/projects/.claude-clipboard/`. The watcher pipes outbound text to Windows `clip.exe` and captures inbound clipboard via `Get-Clipboard`.

The watcher fires **only** when the container writes a sentinel file — your normal Ctrl+C / Ctrl+V on the host is untouched and there's no clipboard polling (so password-manager / clipboard-monitor apps don't get noisy).

`paste` is a one-shot snapshot of the current Windows clipboard at the moment you ask. If the clipboard changes after that, you call `paste` again.

Watcher log: `/tmp/claude-clip-watcher.log` in WSL. Restart manually with `nohup /usr/local/bin/claude-clip-watcher >/dev/null 2>&1 &` if it ever dies; bootstrap re-runs are idempotent.

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

Edit files in `E:\Projects\agent-config\` (Windows side, surfaces as `/mnt/e/Projects/agent-config` from WSL) → commit → push. Then `docker restart claude-box` to pull. The entrypoint always does `git pull --ff-only` on start.
