# Verification log

What was tested when the sandbox was first built. Test scripts referenced live in `tests/` (in this repo) or are reproducible from the commands below.

## F1 — Filesystem boundary (5/5 pass)

Run inside container:

| Check | Expected | Result |
|---|---|---|
| `ls /mnt/c/Users/<host-user>/.ssh` | not visible | not visible ✅ |
| `ls /mnt/c` | not visible | not visible ✅ |
| `ls /projects` | host repos visible | 22 entries ✅ |
| `echo x > /projects/_write-test` | succeeds | succeeds ✅ |
| `ls /home/<host-user>` | not present | not present ✅ |

Conclusion: the container can only see `/projects` (bind mount of host workspace) plus its own internal filesystem. No host-side `.ssh`, credential stores, or other user paths leak in.

## F2 — Network allowlist (8/8 pass)

Run inside container; all HTTPS via the in-container squid on `127.0.0.1:3128`.

| Host | Expected | Actual |
|---|---|---|
| github.com | allowed | HTTP 200 ✅ |
| api.anthropic.com | allowed | HTTP 404 (server reached) ✅ |
| platform.claude.com | allowed | HTTP 200 ✅ |
| registry.npmjs.org | allowed | HTTP 200 ✅ |
| pypi.org | allowed | HTTP 200 ✅ |
| evil.example.com | denied | 000 (proxy refused CONNECT) ✅ |
| reddit.com | denied | 000 ✅ |
| gitlab.com | denied | 000 ✅ |

`npm install left-pad` also succeeds, confirming the proxy is transparent to npm.

## F3 — gh wrapper (2/2 pass)

| Check | Result |
|---|---|
| `command -v gh` → `/usr/local/bin/gh` (wrapper, not real gh) | ✅ |
| `gh repo delete <anything>` exits non-zero with `BLOCKED` in stderr (no auth needed — pattern match runs before any API call) | ✅ |

Full behavioural coverage (benign passes through, override allows, audit log captures the attempt) is in `tests/test-gh-wrapper.sh` — six assertions, all green.

## F4 — Secret-scan pre-commit hook (5/5 pass)

Layered scan: filename → regex → gitleaks.

| Check | Expected exit | Actual |
|---|---|---|
| Stage `.env`, run hook | 50 | 50 ✅ |
| Stage file with `sk-ant-fake…` | 51 | 51 ✅ |
| Same with `CLAUDE_ALLOW_SECRET_COMMIT=1` | 0 | 0 ✅ |
| `git commit` of staged `.env` (real commit path) | non-zero, `BLOCKED` in stderr | non-zero ✅ |
| `git config --global core.hooksPath` points at `~/.claude/hooks/` | path set | path set ✅ |

## F5 — Audit log + SessionStart hook (4/4 pass)

| Check | Result |
|---|---|
| `/audit/YYYY-MM-DD.jsonl` exists | yes (487 events accumulated by end of test run) |
| Event sources span `audit-shell`, `entrypoint`, `gh-wrapper`, `pre-commit`, `squid` | yes |
| `node session-start.cjs` runs cleanly | exit 0 |
| Emits `<system-reminder>…</system-reminder>` listing blocked/interesting events since last session | yes (18 events surfaced in test) |

Sample surfaced events: TCP_DENIED for blocked hosts, gh wrapper blocks, secret-scan hits, entrypoint config-clone-failed during the bootstrap chicken-and-egg.

## F6 — `/remote-control` (skipped, requires phone)

Deferred. To verify: inside an interactive `claude` session in the container, run `/remote-control`, open the URL on a phone, confirm a prompt round-trips. Fallback if `docker exec -it` doesn't satisfy `/remote-control`'s TTY assumptions: SSH from phone (e.g. Termius) into the WSL host, then `docker exec`.

## F7 — Bootstrap idempotency (pass)

Re-running `bootstrap.sh` recreates the container (new container ID) but **state persists** via two named Docker volumes:

- `claude-auth` → `/home/claude/.claude-auth/` (GitHub token — a PAT or your gh login's token)
- `claude-cfg-cache` → `/home/claude/.claude/` (Anthropic OAuth `.credentials.json`, claude CLI history, cached agent-config clone)

User-visible behaviour after re-run: claude still authed, agent-config still synced, no manual recovery needed. The container handle is fresh but the workspace inside is identical.
