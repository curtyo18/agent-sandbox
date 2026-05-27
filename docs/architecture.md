# Architecture decisions

The *why* behind the design. For *what's where*, see the README.

## Two repos, not one

`agent-sandbox` (this repo) holds the runtime artifacts — Dockerfile, bootstrap scripts, wrappers, squid template, tests. Intended to be public-readable eventually so the bootstrap one-liner works on a fresh machine without auth.

`agent-config-private` (personal overlay) holds personal config — CLAUDE.md tweaks, private skill prefs, anything that shouldn't go public. Rsynced on top of the public `agent-config` clone at container start. The container fetches both using a GitHub token stored on a persistent Docker volume.

**Why split:** runtime changes rarely; config changes often. Coupling them would mean every skill edit triggers an image rebuild path. The split also keeps personal/sensitive config out of any repo that eventually goes public.

## Forward proxy (squid), not iptables egress filtering

Considered: iptables/nftables rules to whitelist outbound destinations.

**Chose squid because:**
- ACLs are by domain, not just IP — important for CDN-fronted services (npm registry, GitHub, anthropic).
- Logs are richer (full URL, method) — feeds the audit pipeline directly.
- All shell tools that respect `HTTPS_PROXY` (curl, wget, git, gh, npm, pip, the claude CLI) route through it automatically. iptables would need per-tool config to log who-talked-to-what.
- Easier to widen for one specific host without touching kernel networking.

**Trade-off:** SSH egress isn't proxy-mediated. Port 22 outbound is open by default. If you need SSH for a specific deploy key, document the override; for now git uses HTTPS everywhere.

## `gh` wrapper on PATH, not iptables block of the GitHub API

The gh wrapper sits at `/usr/local/bin/gh`, ahead of the real binary, and pattern-matches argv for destructive verbs (repo delete, visibility flip, transfer, archive). Pure shell.

**Chose wrapper because:**
- It can BLOCK *and* log structured JSON with the full intent — "what was the user trying to do?". An iptables block would just produce a connection-refused error with no context for the audit log.
- Composable: future guards (e.g. blocking certain `gh api` POSTs) are just new patterns in one file.
- Easy to override via env var (`CLAUDE_UNLOCK_DESTRUCTIVE=1`) without disabling the whole guard.

**Trade-off:** if the wrapper has a regex bug, dangerous calls can slip through. Mitigated by `tests/test-gh-wrapper.sh` covering all the blocked patterns + the override path.

## Existing gh token, not a fine-grained PAT

Originally scoped: a fine-grained PAT with read-only access to one private repo. Replaced during implementation with the host's existing `gh` token (broader `repo` scope).

**Why:** the gh wrapper is the actual safety mechanism. A scoped PAT is *secondary* defense — convenient if leaked, since damage is limited. But once we trust the wrapper to block destructive ops, scope becomes ergonomic noise (annoying to renew, friction to use for legitimate work the broader token supports).

**When to revisit:** if the gh wrapper ever turns out to be bypassable (someone calls the GitHub API via `curl` directly), the scoped-PAT defense is worth bringing back.

## Bind-mount all of `/projects`, not per-repo

The container sees the host's entire workspace as `/projects`. Could have mounted per-repo on demand instead.

**Chose all-at-once because:**
- Cross-repo work is common (referencing one project from another, multi-repo searches, hand-rolling tooling that lists everything).
- One mount, one container, one process tree — much simpler than orchestrating per-repo containers.

**Trade-off:** an exploited or buggy claude session can touch any project in the workspace, not just the one it was started in. Acceptable because (a) the same risk exists when running claude on the host without containerisation; (b) the wrapper + audit + secret-scan still apply project-wide.

## Single persistent container, not a pool

Spec considered N parallel containers for parallel agent dispatches. Rejected: volume of dispatches doesn't justify the complexity of provisioning, routing, lifecycle management.

**Trade-off:** sessions inside the same container aren't isolated from each other (they share filesystem, history, OAuth token). If you want one session to run untouched while another experiments, today you'd open two shells in the same container and accept they can see each other. A future iteration could add a "spawn ephemeral container per session" mode.

## systemd inside WSL

`/etc/wsl.conf` has `[boot] systemd=true` so PID 1 in the Ubuntu distro is systemd. This lets `docker.service` and friends auto-start.

**Why:** without systemd, Docker has to be `sudo service docker start`-ed manually after every WSL relaunch. With systemd, it just works.

**Trade-off:** systemd-in-WSL is relatively new (2022+) and occasionally has quirks (cgroup v1 vs v2, some services that expect a "real" boot). For our minimal needs (docker.service) it's stable.

## In-container sudo is `NOPASSWD: ALL`

The `claude` user inside the container has unrestricted passwordless sudo. This isn't a "trust the agent fully" stance — it's an honest recognition that:

- The original sudoers allowlist included `/bin/bash`, which means `sudo bash -c '<anything>'` already grants full root regardless of what else is on the list.
- Maintaining an allowlist of `apt-get`, `pip`, `systemctl`, etc. would just be friction without adding any security envelope, since the bash escape hatch is already open.

The real safety boundary is **the container itself**, not what the in-container user can do:
- `squid` allowlist still blocks egress to non-allowed hosts (squid is rendered from config at start; in-container root can disable it but that breaks the *agent's* ability to reach anything, not the host).
- `/projects` bind-mount scope still limits what the agent can read/write on the host filesystem.
- `gh` wrapper still blocks destructive GitHub operations (in-container root can replace the wrapper, but at that point the agent is intentionally evading its own guard rails — a signal worth surfacing in the audit log).
- Audit log still captures every command.

If you ever wanted to actively fence the agent out of system mutations inside the container, removing `/bin/bash` from sudoers would be the first step — and then maintaining a narrow allowlist becomes meaningful. Today, that fence is intentionally absent.

## `--dangerously-skip-permissions` in this sandbox

Claude Code's permission system was designed assuming claude runs on a developer's host machine where mistakes can damage the host. In that environment, prompting before every Bash command and every file edit is the right default.

Here the host is the container. The container can only touch `/projects` (bind mount of host's workspace), can only reach hosts on the squid allowlist, can't run destructive `gh` operations (wrapper blocks), can't commit secrets (pre-commit hook blocks), and every command is captured in the audit log. The blast radius is small.

In that environment the permission prompts buy nothing. They add ~1 round-trip of friction per Bash call, which dominates session experience. Bypassing them via `--dangerously-skip-permissions` (in `cbox -c`), `permissions.defaultMode: bypassPermissions` (in settings), and a `claude()` shell function (in `.bashrc`) means claude can work end-to-end without interruption.

The real safety mechanisms — squid, gh wrapper, secret-scan, audit — are at a lower level than prompts and continue to enforce regardless of what the agent or the user accepts.

**When this would be the wrong call:** if the container ever ran without those guard rails (squid disabled, wrapper removed), bypass mode would lose its safety net. Re-introducing prompts would be the right move at that point.

## Phone access via Tailscale

To reach a `claude` session from a phone, the sandbox can run a tiny in-container HTTP launcher (`scripts/session-launcher.py`) on `127.0.0.1:${LAUNCHER_PORT}` (published from the container to the WSL host's loopback). Tailscale Serve on the **Windows host** fronts it as HTTPS at `https://<hostname>.<tailnet>.ts.net/`, tailnet-only (funnel off). Phone taps the URL → launcher kills any prior tmux session and spawns a fresh one running `claude --remote-control <session-name>` in the configured project path → the session auto-appears in the Claude mobile app's Code tab, where the actual chat UX lives.

```
[ Phone ] ──tailnet HTTPS──► [ Tailscale Serve (Windows) ]
                                       │ proxy → 127.0.0.1:<PORT>
                                       ▼
                          [ Docker port publish ] ──► [ launcher (in container) ]
                                                              │ tmux new-session …
                                                              ▼
                                                  [ claude --remote-control <session-name> ]
                                                              │
                                                              ▼
                                       [ Claude mobile app, same logged-in account ]
```

### Why Tailscale on the Windows host, not in the container

Spec assumed Tailscale would run in the container. Tried it — `--tun=userspace-networking` mode broke `tailscale serve` (TLS handshake EOF on every incoming connection); switching to kernel mode with `--device /dev/net/tun --cap-add NET_ADMIN --sysctl src_valid_mark=1` plus an `iproute2` install fixed routing but left a residual WSL+Docker NAT hairpin: small TCP responses worked, large TCP responses (the 700 KB ttyd HTML page in particular) stalled mid-stream because outbound responses leaked through the wrong interface despite the policy-routing table being correct.

Host-side Tailscale sidesteps the hairpin entirely: the Windows Tailscale client is a battle-tested kernel-level WireGuard implementation, `tailscale serve` proxies into the docker-published port on Windows loopback (WSL2's automatic localhost forwarding makes the WSL-side port appear at Windows' `127.0.0.1`), and the only thing that has to be configured per-machine is one `tailscale serve --bg --https=443 http://127.0.0.1:<PORT>` invocation (config persists in Tailscale's local state across reboots).

The launcher's responses are <1 KB, so the in-container variant probably *would* have worked, but there's no compelling reason to take on the WSL+Docker NAT complexity for a single tiny endpoint.

### Why claude-on-mobile, not a web terminal

First attempt put a web terminal (`ttyd` + `tmux` + a custom mobile-keyboard chrome) in front of `claude`. Worked end-to-end but the interaction model was wrong — typing prompts on an iPhone soft-keyboard inside an xterm.js terminal is rough no matter how many `Ctrl`/`Esc`/arrow soft-keys you bolt on top. Anthropic's mobile Claude app does this UX better natively: voice input, image upload, threaded chat, push notifications, copy-paste that respects iOS conventions. Once `claude --remote-control <name>` ships a session to the mobile app for free, the right move is to let the mobile app be the UI and reduce the host-side surface to just "wake the session".

### Why pre-seed workspace trust at entrypoint

`claude` shows a one-time "Trust this folder?" prompt for any directory it hasn't seen — blocks session startup until answered, which means an auto-spawned session sits at the prompt forever and never registers with the mobile app. Claude has no global "trust all" setting; trust is per-absolute-path, persisted in `~/.claude.json` under `projects["<path>"].hasTrustDialogAccepted: true`. That file lives **outside** the `claude-cfg-cache` volume so it's reset on every container recreate — the existing entrypoint already re-seeds `hasCompletedOnboarding: true` for the same reason; extending the same block to also enumerate `/projects/*` and seed each subdirectory's trust state is the cheapest fix. Soft caveat: a new project dir added after container start needs a container restart to be auto-trusted.

## squid in-container, not host-side

Could have run squid on the WSL host and pointed the container at it via a published port.

**Chose in-container because:**
- One process tree to inspect / restart / debug.
- The allowlist is defined by the config-in-the-container; the host doesn't need to know about it.
- Bootstrap on a new machine is simpler — no extra service to install on WSL.

**Trade-off:** if the container itself is exploited, squid is in the same blast radius. Acceptable; the proxy is a defense against the *agent's* outbound traffic, not a defense against the container being rooted.
