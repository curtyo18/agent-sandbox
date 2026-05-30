# Bug journal

Issues found while bringing the sandbox up the first time. Capturing each so the next bootstrap doesn't re-discover them.

## In-repo bugs (fixed)

### 1. `node:lts-bookworm` base ships a `node` user at UID/GID 1000

**Symptom.** Docker build fails at `groupadd -g 1000 claude`:
```
groupadd: GID '1000' already exists
```

**Cause.** The base image already has a `node:node` user/group at 1000:1000.

**Fix.** Drop the existing user before creating `claude`. Now in `Dockerfile`:
```dockerfile
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g ${GID} claude && \
    ...
```

Why keep UID 1000 — bind-mounted files from the host show as UID 1000 inside the container; matching them avoids permission surprises.

### 2. HTTPS_PROXY chicken-and-egg in `entrypoint.sh`

**Symptom.** First-time container start: `FATAL: initial config clone failed`, squid bungled with `ACL not found: allowed_hosts`. Container alive but useless.

**Cause.** Image ENV sets `HTTPS_PROXY=http://127.0.0.1:3128` globally. The entrypoint's `git clone` of `agent-config` routes through that proxy. But squid isn't running yet — its config needs the allowlist, which lives in `agent-config`, which needs this clone.

**Fix.** Two parts in `entrypoint.sh`:
- `sync_config` clears proxy env for git: `HTTPS_PROXY="" HTTP_PROXY="" git clone ...`. Direct egress for the bootstrap clone. github.com would have been allowlisted anyway, so this matches policy.
- `render_squid_conf` writes a tombstone ACL (`acl allowed_hosts dstdomain .invalid-no-allowlist`) when no allowlist file is present, so squid still parses cleanly and the container stays usable for troubleshooting.

### 3. `/mnt/e/projects` vs `/mnt/e/Projects` case mismatch

**Symptom.** Container's `/projects` shows almost no files; user's repos missing.

**Cause.** WSL's 9p mount of Windows drives can expose `E:\projects` and `E:\Projects` as separate directories even though NTFS is case-insensitive at the filesystem level. `bootstrap.sh` originally hardcoded the lowercase path; reality on the host was capital P.

**Fix.** Set `PROJECTS_HOST_PATH` to the path exactly as it exists on disk (matching the real casing). It now defaults to a neutral `$HOME/projects` placeholder; override it in your environment or at the top of `bootstrap.sh`.

### 4. `git core.hooksPath` never wired up

**Symptom.** Pre-commit secret-scan hook present at `/home/claude/.claude/hooks/pre-commit` but `git commit` of a `.env` file *succeeds* — hook never fires.

**Cause.** Git only runs hooks from `$GIT_DIR/hooks/` or from a path explicitly set in `core.hooksPath`. Just dropping the script in the right place isn't enough.

**Fix.** `entrypoint.sh` `sync_config` now runs:
```bash
git config --global core.hooksPath "$CONFIG_DIR/hooks"
```

after pulling agent-config. Verified by running `git commit` with a staged `.env` — hook fires, commit blocked with exit 50.

### 5. Container `git push` fails — no credential helper

**Symptom.** Inside the container, `git push` errors with `fatal: could not read Username for 'https://github.com': No such device or address`.

**Cause.** `entrypoint.sh` had wired the PAT into `/home/claude/.claude-auth/github-pat`, but never authed `gh` or set it up as the git credential helper. git pull was working only because the bootstrap clone uses a token-in-URL (`https://x-access-token:$PAT@…`); regular `git push` to an existing remote has no token in the URL and prompts for credentials.

**Fix.** `entrypoint.sh` now runs at every container start (idempotent):

```bash
if [[ -s "$AUTH_DIR/github-pat" ]] && ! gh auth status >/dev/null 2>&1; then
  cat "$AUTH_DIR/github-pat" | gh auth login --hostname github.com --git-protocol https --with-token
fi
gh auth setup-git
```

Also added a separate `claude-gh-config` Docker volume at `/home/claude/.config` so `gh`'s `hosts.yml` persists across container recreates (otherwise gh state lives outside the existing volumes and is wiped on every recreate).

### 6. New Docker volume mounts as root, not as the container user

**Symptom.** After adding the `claude-gh-config` volume, `gh auth login` failed with `mkdir /home/claude/.config/gh: permission denied`.

**Cause.** Docker named volumes inherit ownership from the image's mountpoint. If the path doesn't exist in the image (`/home/claude/.config` was not pre-created), Docker creates it owned by root when the volume mounts. The non-root container user can't write inside.

**Fix.** Add the path to the Dockerfile's `mkdir` before `chown`:

```dockerfile
RUN ... && \
    mkdir -p /home/claude/.claude /home/claude/.claude-auth /home/claude/.config /audit /projects && \
    chown -R claude:claude /home/claude /audit /projects
```

Now the path exists with claude ownership at image build time; the volume preserves that on first mount.

### 7. Claude Code wizard fires every container recreate

**Symptom.** Even though `claude auth status` reports `loggedIn: true`, every fresh container shows the "Select login method" first-run wizard and forces an OAuth round-trip.

**Cause.** The "wizard complete" marker isn't in `~/.claude/.credentials.json` or `~/.claude/settings.json` — it's `hasCompletedOnboarding: true` in **`~/.claude.json`** (note: file directly in `$HOME`, not under `.claude/`). That file is outside the `claude-cfg-cache` volume, so every container recreate wipes it.

**Fix.** `entrypoint.sh` now writes the marker on every start (merging into existing JSON if present):

```bash
python3 -c "
import json, os
p = '/home/claude/.claude.json'
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except: d = {}
d['hasCompletedOnboarding'] = True
json.dump(d, open(p, 'w'), indent=2)
"
```

See [anthropics/claude-code#4714](https://github.com/anthropics/claude-code/issues/4714).

### 8. Permission settings ignored — wrong file and wrong key

**Symptom.** `permissions.defaultMode: bypassPermissions` in `~/.claude/settings.local.json` did nothing — every Bash command still prompted.

**Cause.** Two distinct mistakes:
- Per [Claude Code docs](https://code.claude.com/docs/en/permissions), `settings.local.json` is a *project-level* override file (`<project>/.claude/settings.local.json`). At the **user** level (`~/.claude/`), only `settings.json` is read. `~/.claude/settings.local.json` is ignored entirely.
- The first version of the config had `permissionMode` at the top level. The correct path is `permissions.defaultMode` (nested under `permissions`).

**Fix.** Moved config back into `~/.claude/settings.json`, used the correct nested key, and additionally added `--dangerously-skip-permissions` to the CLI invocation as belt-and-suspenders (CLI flag bypasses settings.json drift entirely).

### 9. `--dangerously-skip-permissions` still shows accept dialog every launch

**Symptom.** Even with the CLI flag, the "WARNING: Claude Code running in Bypass Permissions mode — Yes, I accept / No" dialog appears on every session start.

**Cause.** The flag alone tells claude to bypass tool prompts, but the warning dialog about bypass mode itself is a separate prompt. It's only suppressed when `skipDangerousModePermissionPrompt: true` is persisted in `~/.claude/settings.json` (normally written when the user accepts the dialog once).

**Fix.** Added `"skipDangerousModePermissionPrompt": true` to `agent-config/settings.json`. See [anthropics/claude-code#25503](https://github.com/anthropics/claude-code/issues/25503).

### 10. `inotify` doesn't fire on WSL2 9p mounts (`/mnt/c`, `/mnt/e`, …)

**Symptom.** Clipboard bridge first version used `inotifywait` to watch `/mnt/e/Projects/.claude-clipboard/out`. Container writes to that file (via its `/projects` bind mount), watcher should fire and pipe to `clip.exe`. It didn't — watcher silently sat there, no events.

**Cause.** WSL2's 9p filesystem (used to surface Windows drives at `/mnt/<letter>/`) doesn't propagate inotify events for changes made on the Windows side. Even though Docker's bind-mount writes go *through* WSL2's kernel, the path is on a 9p mount and inotify on that path doesn't see anything.

**Fix.** Switched the watcher to polling (`stat -c %Y` on the watched file every 500 ms; trigger when mtime changes). Slower in theory, imperceptible in practice for clipboard use; works reliably across the 9p boundary. Code in [`scripts/clip-watcher`](../scripts/clip-watcher).

### 11. `settings.json` clobber-on-pull

**Symptom.** Claude writes runtime preferences (theme, wizard-done state, etc.) into `~/.claude/settings.json`. The repo also tracks `agent-config/settings.json` as the source of truth for our config (statusLine, permissions, plugins, etc.). On every `git pull` in the container, either (a) pull aborts because local changes conflict, or (b) we discard local and the user's recently-set preferences vanish. Statusline disappearing is the most-visible symptom.

**Tried + rejected.** Moved config to `settings.local.json` first — turns out that path is *only* read at the **project** level (`<project>/.claude/`); at the user level (`~/.claude/`), only `settings.json` is read. Reverted.

**Currently mitigated, not fixed.** When the file conflicts on pull, we manually `mv settings.json settings.json.bak` then `git checkout HEAD -- settings.json` to restore the repo's version. Claude rewrites whatever it cares about on next launch. This is fragile — every recovery loses user-set theme etc.

**Proper fix (deferred).** Have the entrypoint deep-merge: load repo's `settings.json` as base, overlay any keys claude has written locally that we don't care about (`theme`, internal flags), force-overwrite the keys we control (`statusLine`, `enabledPlugins`, `permissions`, `effortLevel`). Use jq or python to do the merge. Tracked as a follow-up.

### 12. Web terminal (ttyd) is the wrong mobile UX for `claude`

**Symptom.** First mobile-access attempt put `ttyd` + `tmux` in front of `claude`, fronted by Tailscale Serve, with a custom soft-key bar (Esc/Ctrl-C/Tab/arrows/Paste) injected via a custom `ttyd -I` index page. End-to-end the plumbing worked — page rendered, basic auth (when on) prompted, WebSocket upgraded — but typing prompts into claude from an iPhone soft-keyboard inside an xterm.js terminal felt rough no matter how the chrome was polished. Voice input, image upload, threaded chat, and iOS copy-paste are all native in the Claude mobile app and absent in a terminal.

**Cause.** Mismatched interaction model. A web terminal is the right answer when the user needs full shell access from a constrained device; it's the wrong answer when the user wants to *chat with claude*.

**Fix.** Ripped out ttyd entirely. Replaced with `scripts/session-launcher.py` — a ~80-line Python HTTP utility that, when poked from a phone tap, spawns `claude --remote-control <session-name>` inside a tmux session. The Claude mobile app picks the session up automatically via the logged-in account; the phone never renders claude output, the mobile app does. The "host-side" UI is reduced to a status page and a button.

**Bonus.** Removing ttyd also removes the basic-auth-and-WebSocket-upgrade-through-Tailscale-Serve dance — browsers don't carry `Authorization` headers into WS upgrades and `ttyd -c user:pass` denied every mobile connection at `User code denied connection`. Tailnet membership is the auth boundary; nothing to bolt on.

### 13. WSL + Docker NAT hairpin breaks large-TCP for in-container Tailscale

**Symptom.** Briefly tried running Tailscale **inside** the container to avoid a host-side dependency. `--tun=userspace-networking` accepted incoming TLS but never completed the handshake — every connection from my-machine or the iPhone produced `TLS handshake error from <ip>: EOF` in the tailscaled log. Switched to kernel mode (`--device /dev/net/tun --cap-add NET_ADMIN`) and tailscale-policy routing populated correctly, but: `tailscale ping my-machine` worked, small HTTP responses (`/token`, ~25 bytes) worked, the full ttyd index page (~700 KB) consistently delivered `HTTP 200` headers fast and then **0 bytes** of body.

**Cause.** WSL2 + Docker bridge NAT between the container and the Windows-host Tailscale endpoint is a hairpin — container's outbound UDP wireguard packets bounce through the Docker bridge, WSL eth0, Windows network stack, then back into the Windows Tailscale service. Small packets survive; sustained TCP streams have outbound responses leak through `eth0` (default route) instead of `tailscale0` because the policy-routing `src_valid_mark` is rejected by `rp_filter` somewhere in the path even though `net.ipv4.conf.all.src_valid_mark=1` is set inside the container's namespace.

**Tried.** `iptables -t mangle … TCPMSS --clamp-mss-to-pmtu` on OUTPUT, lowering `tailscale0` MTU to 1280, `apt install iproute2` (a critical fix on its own: without `ip` in PATH, tailscaled silently can't install the tailnet route), adding `--sysctl net.ipv4.conf.all.src_valid_mark=1` to `docker run`. Each step fixed *something*, but TCP stalls persisted on payloads above a few KB.

**Fix.** Stopped fighting it. Pulled Tailscale out of the container; runs on the Windows host (as it already was for general use), with `tailscale serve --bg --https=443 http://127.0.0.1:<PORT>` proxying into the docker-published launcher port. The Windows Tailscale client is a native WireGuard implementation with no hairpin; small and large responses both work. The only thing this gives up is "Tailscale runs alongside the container" symmetry, which turned out to buy nothing.

**When to revisit.** WSL2's mirrored networking mode (`networkingMode=mirrored` in `.wslconfig`, ~2023+) removes the bridge NAT layer entirely and might allow in-container Tailscale to work without the hairpin. Not investigated; documented for future curiosity.

### 14. Workspace trust prompt blocks auto-pairing with the Claude mobile app

**Symptom.** After landing `claude --remote-control <session-name>` as the launcher's spawn command, the tmux session started fine — but no session ever appeared in the Claude mobile app. Inspecting the pane: claude was sitting at a `Trust this folder? 1. Yes 2. No` interactive prompt, never reaching the remote-control registration step.

**Cause.** First time claude runs in a directory it hasn't seen, it shows a one-time workspace trust prompt that blocks all session startup until answered. `--dangerously-skip-permissions` does NOT skip this prompt (it only bypasses per-tool-call permission prompts). The trust state is persisted at `~/.claude.json` → `projects["<absolute-path>"].hasTrustDialogAccepted: true`. Claude has no global "trust all directories" setting — trust is strictly per-absolute-path.

`~/.claude.json` lives outside the `claude-cfg-cache` Docker volume, so the trust state is wiped on every container recreate (same root cause as bug #7 — the same file is also where `hasCompletedOnboarding` lives).

**Fix.** Extended the entrypoint's existing `hasCompletedOnboarding` re-seeding block to enumerate `/projects/*` and set `hasTrustDialogAccepted: true` for every subdirectory at container start. Code in `entrypoint.sh::sync_config`. Soft caveat: a project directory added to `/projects` **after** the container starts isn't auto-trusted until the next container restart.

### 15. Container + docker.service died together; systemd gave up retrying; no journal forensics

**Symptom.** Container alive in the evening. Several hours later, container exited with code 135 (SIGBUS) and `docker.service` was in a permanently failed state. Restart policy `unless-stopped` did nothing because dockerd itself was down. WSL itself was fine the whole time — interactive shells still worked. Next morning `cbox` failed with "Cannot connect to the Docker daemon".

**Cause.** A WSL2 VM-level event around the time of death:
- A heavy in-container process (a long-running test runner in this case) hit SIGABRT.
- Within ~15 minutes the container's PID 1 (tini) got SIGBUS — typically a memory-mapping / hypervisor-side issue, not an application fault.
- `dockerd` died around the same window. Default `docker.service` retry budget is `StartLimitBurst=3` over `StartLimitIntervalSec=10s`. If three quick restart attempts fail (because the underlying issue is still live), systemd marks the unit "failed" and stops trying.
- `systemd-journald` paused too. Its default WSL2 storage is volatile (`/run/log/journal`), so subsequent reads from `journalctl --since <window>` returned "No entries" — no forensic data across the crash window at all.

The root cause of the VM-level event is undetermined; both `dmesg` and the systemd journal were silent across the relevant period.

**Fix (mitigations, not root cause).**

1. **Widen `docker.service` retry budget** via a systemd drop-in tracked at `host/docker-retry.conf` and installed by `bootstrap.sh` to `/etc/systemd/system/docker.service.d/retry.conf`:
   ```ini
   [Unit]
   StartLimitBurst=20
   StartLimitIntervalSec=900

   [Service]
   RestartSec=10
   ```
   `StartLimitBurst` and `StartLimitIntervalSec` must be in `[Unit]` on Ubuntu 24.04's systemd — in `[Service]`, `StartLimitIntervalSec` is silently dropped (you'll see "Unknown key name" only via `systemd-analyze verify docker.service`, not in the unit log). Verify effective values with `systemctl show docker.service -p RestartUSec -p StartLimitBurst -p StartLimitIntervalUSec` (note the `USec` suffix on time-valued properties — that's how `systemctl show` exposes them).

2. **Make systemd journal persistent.** `bootstrap.sh` does `mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal && systemctl restart systemd-journald`. After this, the journal survives WSL restarts and captures kernel / unit-transition events across an incident window.

**What we didn't add.** A higher-level watchdog (Windows-side scheduled task that hits the launcher URL and restarts docker on failure) was considered and parked. The retry+journal mitigations are the minimum-noise step; revisit if a second incident shows the retry budget wasn't enough.

## Host-side gotchas (not in this repo's code, but bit us)

- **BIOS virtualization off by default.** AMD CPUs need SVM Mode enabled in BIOS (Gigabyte: Tweaker → Advanced CPU Settings). WSL2 fails with `HCS_E_HYPERV_NOT_INSTALLED` until this is on.
- **WSL Store-package install gets stuck.** After enabling WSL features + reboot, the kernel update can wedge with `0x80070652` ("another install in progress"). Recovery: `Stop-Process -Force` any lingering `msiexec`, then `wsl --update` succeeds.
- **`gh auth setup-git` is not automatic.** `gh auth login --with-token` populates gh's token but doesn't wire gh as a git credential helper. Private-repo `git clone` then hangs at `Username for 'https://github.com':`. Run `gh auth setup-git` once after auth to fix.
- **PowerShell `Set-Content -Encoding utf8` writes a BOM.** Bash treats the BOM as garbage on the first line, breaking `set -e` and similar. When generating shell scripts from PowerShell, use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))`.
- **Editing files via `\\wsl.localhost\…` UNC paths strips the executable bit.** Always `chmod +x` after editing a script through the UNC bridge.
