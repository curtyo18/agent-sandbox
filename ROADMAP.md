# Roadmap

Planned improvements deferred from initial public release. Context preserved so
the reasoning behind each decision isn't lost.

---

## Project scoping (per-container mount restriction)

**Target approach:** At `docker run` time, mount only the target project directory:
`-v /projects/<name>:/projects/<name>:rw`. Container cannot access other projects.

**Why deferred:** Restart-to-rescope friction is too high for daily use. A full-day
session on one project that occasionally needs to glance at another becomes
painful if it requires stopping and restarting the container.

**When this lands:** Extend `cbox` with a `-p <project>` flag and a `--add-project`
flag to mount additional directories into a running container. WSL-only — cannot
be set from inside the container.

---

## PAT lifecycle (short-lived tokens + in-session refresh)

**Target approach:** Replace the current long-lived OAuth token in the
`claude-auth` volume with short-lived fine-grained PATs. A `cbox-refresh-pat`
WSL-side script delivers a new token to a running container via `docker exec`
without requiring a restart, updating both the in-memory gh auth and the PAT
file in the volume.

**Why deferred:** Currently the container runs on the existing `gh auth token`
(OAuth). The refresh mechanism works independently of project scoping and is
straightforward to add, but is low urgency until the scoped-PAT work lands.

**When this lands:** Add `scripts/cbox-refresh-pat` — reads token from stdin,
runs `docker exec <container> gh auth login --with-token` and writes to
`/home/claude/.claude-auth/github-pat`. Expiry is set at PAT creation time on
GitHub; the script only handles delivery.

---

## Scoped PATs (per-project token permissions)

**Target approach:** PAT created with repository scope limited to the mounted
project only. Limits blast radius if a token is accidentally leaked in chat or
logs.

**Why deferred:** Depends on project scoping landing first. Fine-grained PATs
with per-repo scope also have GitHub API limitations worth evaluating.

**When this lands:** Extend `cbox-refresh-pat` to accept a `--repo` flag and
create fine-grained PATs via `gh api`.

---

## Responsive terminal / mobile access

**Problem:** The current setup (session-launcher.py + Tailscale) works for viewing
output but the iOS native keyboard doesn't handle terminal arrow keys, escape
sequences, or modifier keys reliably. Makes real editing from phone impractical.

**Ideas to explore:**
- Purpose-built mobile terminal app with proper escape sequence support
- A web-based terminal (ttyd, wetty) fronted by Tailscale instead of raw tmux
- Whether other AI coding tools offer equivalent remote-control that sidesteps
  the terminal keyboard problem entirely

**Current state:** session-launcher.py is the placeholder. Rethink from scratch
when tackling this — it's not a tweak to what exists.
