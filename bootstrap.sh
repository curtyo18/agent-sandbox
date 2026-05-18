#!/usr/bin/env bash
# bootstrap.sh — Ubuntu side. Run inside WSL Ubuntu 24.04.
# Installs Docker if missing, builds the claude-box image, runs the container.
# Idempotent: re-running picks up image / config / repo changes and restarts.

set -euo pipefail

REPO_DIR="${HOME}/code/agent-sandbox"
PROJECTS_HOST_PATH="/mnt/e/Projects"
AUDIT_HOST_PATH="/mnt/e/Projects/.claude-audit"
CONTAINER_NAME="claude-box"
IMAGE_TAG="claude-box:latest"
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
  git clone https://github.com/curtyo18/agent-sandbox.git "$REPO_DIR"
fi

echo "==> Ensuring host paths exist"
if [[ ! -d "$PROJECTS_HOST_PATH" ]]; then
  echo "FATAL: $PROJECTS_HOST_PATH does not exist." >&2
  exit 2
fi
mkdir -p "$AUDIT_HOST_PATH"

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
  -p 127.0.0.1:7681:7681 \
  -p 127.0.0.1:8000-8099:8000-8099 \
  -v "$PROJECTS_HOST_PATH:/projects" \
  -v "$AUDIT_HOST_PATH:/audit" \
  -v claude-auth:/home/claude/.claude-auth \
  -v claude-cfg-cache:/home/claude/.claude \
  -v claude-gh-config:/home/claude/.config \
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
