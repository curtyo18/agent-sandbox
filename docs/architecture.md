# Architecture decisions

The *why* behind the design. For *what's where*, see the README.

## Two repos, not one

`agent-sandbox` (this repo) holds the runtime artifacts — Dockerfile, bootstrap scripts, wrappers, squid template, tests. Intended to be public-readable eventually so the bootstrap one-liner works on a fresh machine without auth.

`agent-config` (private) holds personal config — CLAUDE.md, skills, hooks, the network allowlist, gitleaks rules. The container clones it on every start using a GitHub token stored on a persistent Docker volume.

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

## `--dangerously-skip-permissions` in this sandbox

Claude Code's permission system was designed assuming claude runs on a developer's host machine where mistakes can damage the host. In that environment, prompting before every Bash command and every file edit is the right default.

Here the host is the container. The container can only touch `/projects` (bind mount of host's workspace), can only reach hosts on the squid allowlist, can't run destructive `gh` operations (wrapper blocks), can't commit secrets (pre-commit hook blocks), and every command is captured in the audit log. The blast radius is small.

In that environment the permission prompts buy nothing. They add ~1 round-trip of friction per Bash call, which dominates session experience. Bypassing them via `--dangerously-skip-permissions` (in `cbox -c`), `permissions.defaultMode: bypassPermissions` (in settings), and a `claude()` shell function (in `.bashrc`) means claude can work end-to-end without interruption.

The real safety mechanisms — squid, gh wrapper, secret-scan, audit — are at a lower level than prompts and continue to enforce regardless of what the agent or the user accepts.

**When this would be the wrong call:** if the container ever ran without those guard rails (squid disabled, wrapper removed), bypass mode would lose its safety net. Re-introducing prompts would be the right move at that point.

## squid in-container, not host-side

Could have run squid on the WSL host and pointed the container at it via a published port.

**Chose in-container because:**
- One process tree to inspect / restart / debug.
- The allowlist is defined by the config-in-the-container; the host doesn't need to know about it.
- Bootstrap on a new machine is simpler — no extra service to install on WSL.

**Trade-off:** if the container itself is exploited, squid is in the same blast radius. Acceptable; the proxy is a defense against the *agent's* outbound traffic, not a defense against the container being rooted.
