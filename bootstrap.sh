#!/usr/bin/env bash
# bootstrap.sh — Ubuntu side. Run inside WSL Ubuntu 24.04.
# Installs Docker if missing, builds the claude-box image, runs the container.
# Idempotent: re-running picks up image / config / repo changes and restarts.

set -euo pipefail

# ── Customise these for your machine ──────────────────────────────────────────
# Each setting falls back to the default below if not exported by the caller.
# A private wrapper script can `export VAR=...` then `exec bash bootstrap.sh`
# to drive this without locally editing the tracked file.
REPO_DIR="${REPO_DIR:-/mnt/e/Projects/agent-sandbox}"          # Path to this repo in WSL
PROJECTS_HOST_PATH="${PROJECTS_HOST_PATH:-/mnt/e/Projects}"    # Host path bind-mounted as /projects
AUDIT_HOST_PATH="${AUDIT_HOST_PATH:-/mnt/e/Projects/.claude-audit}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-box}"
IMAGE_TAG="${IMAGE_TAG:-claude-box:latest}"
AGENT_SANDBOX_REPO="${AGENT_SANDBOX_REPO:-https://github.com/your-username/agent-sandbox.git}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-you@example.com}"            # Passed into container for git commits
GIT_USER_NAME="${GIT_USER_NAME:-Your Name}"
# ──────────────────────────────────────────────────────────────────────────────
PAT_FILE="${HOME}/.agent-sandbox/github-pat"

echo "==> Checking Docker"
if ! command -v docker >/dev/null; then
  echo "Docker not installed. Run Phase A4 of the plan first." >&2
  exit 1
fi
docker info >/dev/null 2>&1 || { sudo service docker start && sleep 2; }

echo "==> Ensuring agent-sandbox repo is up to date"
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" pull --ff-only || true
else
  git clone "$AGENT_SANDBOX_REPO" "$REPO_DIR"
fi

echo "==> Ensuring host paths exist"
if [[ ! -d "$PROJECTS_HOST_PATH" ]]; then
  echo "FATAL: $PROJECTS_HOST_PATH does not exist." >&2
  exit 2
fi
mkdir -p "$AUDIT_HOST_PATH"

echo "==> Installing docker.service retry drop-in"
# Default StartLimitBurst=3 in StartLimitIntervalSec=10s puts docker into a
# permanent failed state after a quick bad patch. Widen the budget so a
# transient WSL2 / kernel event that briefly kills docker can be auto-recovered.
sudo install -m 0644 -D "$REPO_DIR/host/docker-retry.conf" \
  /etc/systemd/system/docker.service.d/retry.conf
sudo systemctl daemon-reload
sudo systemctl restart docker.service

echo "==> Enabling persistent systemd journal"
# Default WSL2 journald is in-memory at /run/log/journal — logs are lost on
# every restart and were paused during the 2026-05-18 overnight wedge so we
# had no record of what killed docker. Disk-backed journal at /var/log/journal
# survives restarts and gives us forensic data after the next incident.
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald

echo "==> Checking GitHub PAT file"
if [[ ! -s "$PAT_FILE" ]]; then
  echo "No PAT at $PAT_FILE. The container will start but config-clone will be skipped."
  echo "After Task B4, store the PAT there and re-run this script."
fi

echo "==> Building image"
cd "$REPO_DIR"
docker build -t "$IMAGE_TAG" .

echo "==> Stopping any existing container"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo "==> Starting container"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --user 1000:1000 \
  -p 127.0.0.1:8000-8099:8000-8099 \
  -v "$PROJECTS_HOST_PATH:/projects" \
  -v "$AUDIT_HOST_PATH:/audit" \
  -v claude-auth:/home/claude/.claude-auth \
  -v claude-cfg-cache:/home/claude/.claude \
  -v claude-gh-config:/home/claude/.config \
  -e GIT_USER_EMAIL="$GIT_USER_EMAIL" \
  -e GIT_USER_NAME="$GIT_USER_NAME" \
  -e AGENT_CONFIG_PRIVATE_REPO="${AGENT_CONFIG_PRIVATE_REPO:-}" \
  "$IMAGE_TAG"

# If PAT is on host, copy it into the auth volume now (one-time wiring).
if [[ -s "$PAT_FILE" ]]; then
  echo "==> Provisioning PAT into claude-auth volume"
  docker cp "$PAT_FILE" "$CONTAINER_NAME:/home/claude/.claude-auth/github-pat"
  docker exec "$CONTAINER_NAME" chown claude:claude /home/claude/.claude-auth/github-pat
  docker exec "$CONTAINER_NAME" chmod 600 /home/claude/.claude-auth/github-pat
  # Trigger config sync now by restarting (entrypoint reads the PAT on start).
  docker restart "$CONTAINER_NAME"
fi

echo "==> Installing cbox helper to /usr/local/bin"
sudo ln -sf "$REPO_DIR/scripts/cbox" /usr/local/bin/cbox

echo "==> Installing clip-watcher as systemd service"
sudo ln -sf "$REPO_DIR/scripts/clip-watcher" /usr/local/bin/claude-clip-watcher
sudo cp "$REPO_DIR/scripts/claude-clip-watcher.service" /etc/systemd/system/claude-clip-watcher.service
sudo systemctl daemon-reload
sudo systemctl enable --now claude-clip-watcher.service
sudo systemctl restart claude-clip-watcher.service
echo "    status: $(systemctl is-active claude-clip-watcher.service)"
echo "    log at /tmp/claude-clip-watcher.log"

echo
echo "Done. To use:"
echo "  cbox             bash shell in /projects"
echo "  cbox <repo>      bash shell in /projects/<repo>"
echo "  cbox -c <repo>   claude in /projects/<repo>"
echo
echo "First-time only:"
echo "  docker exec -it $CONTAINER_NAME bash -lc 'claude login'"
