#!/usr/bin/env bash
# bootstrap.sh — Ubuntu side. Run inside WSL Ubuntu 24.04.
# Installs Docker if missing, builds the claude-box image, runs the container.
# Idempotent: re-running picks up image / config / repo changes and restarts.

set -euo pipefail

# ── First-run / config (guided init) ───────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DO_INIT=0; NONINTERACTIVE=0; PRINT_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --init)                   DO_INIT=1 ;;
    --non-interactive)        NONINTERACTIVE=1 ;;
    --print-config|--dry-run) PRINT_CONFIG=1 ;;
  esac
done

ENV_FILE="${AGENT_SANDBOX_ENV:-$HOME/.agent-sandbox/.env}"
# Load ~/.agent-sandbox/.env WITHOUT clobbering anything already exported, so a caller's env
# (e.g. a personal launch.sh) always wins over the file. No source/eval: KEY=value lines only.
load_env_file() {
  [[ -f "$1" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; key="${key%%[[:space:]]}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key+x}" ]] && continue
    val="${line#*=}"; val="${val#"${val%%[![:space:]]*}"}"
    if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi
    export "$key=$val"
  done < "$1"
}

if [[ "$DO_INIT" == 1 ]]; then
  [[ "$NONINTERACTIVE" == 1 ]] && export AGENT_INIT_NONINTERACTIVE=1
  bash "$SELF_DIR/scripts/agent-init" || { echo "init aborted; not building." >&2; exit 1; }
fi
load_env_file "$ENV_FILE"
# ────────────────────────────────────────────────────────────────────────────────

# ── Customise these for your machine ──────────────────────────────────────────
# Each setting falls back to the default below if not exported by the caller.
# A private wrapper script can `export VAR=...` then `exec bash bootstrap.sh`
# to drive this without locally editing the tracked file.
REPO_DIR="${REPO_DIR:-$HOME/projects/agent-sandbox}"          # Path to this repo (change to match your clone)
PROJECTS_HOST_PATH="${PROJECTS_HOST_PATH:-$HOME/projects}"    # Host path bind-mounted as /projects
AUDIT_HOST_PATH="${AUDIT_HOST_PATH:-$PROJECTS_HOST_PATH/.claude-audit}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-box}"
IMAGE_TAG="${IMAGE_TAG:-claude-box:latest}"
AGENT_SANDBOX_REPO="${AGENT_SANDBOX_REPO:-https://github.com/your-username/agent-sandbox.git}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"            # git commit identity (auto-detected below if unset)
GIT_USER_NAME="${GIT_USER_NAME:-}"
# ──────────────────────────────────────────────────────────────────────────────
PAT_FILE="${HOME}/.agent-sandbox/github-pat"
GIT_CREDS_FILE="${HOME}/.agent-sandbox/git-credentials"   # optional per-host creds for non-github hosts

if [[ "$PRINT_CONFIG" == 1 ]]; then
  cat <<EOF
REPO_DIR=$REPO_DIR
PROJECTS_HOST_PATH=$PROJECTS_HOST_PATH
AUDIT_HOST_PATH=$AUDIT_HOST_PATH
CONTAINER_NAME=$CONTAINER_NAME
IMAGE_TAG=$IMAGE_TAG
AGENT_SANDBOX_REPO=$AGENT_SANDBOX_REPO
AGENT_CONFIG_REPO=${AGENT_CONFIG_REPO:-}
AGENT_CONFIG_PRIVATE_REPO=${AGENT_CONFIG_PRIVATE_REPO:-}
CONTAINER_MODE=${CONTAINER_MODE:-default}
RESEARCH_REPO=${RESEARCH_REPO:-}
GIT_USER_NAME=${GIT_USER_NAME:-}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-}
TZ=${TZ:-Europe/London}
EOF
  exit 0
fi

echo "==> Checking Docker"
if ! command -v docker >/dev/null; then
  echo "Docker not installed. Install Docker (or start it in WSL) and re-run." >&2
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

echo "==> Checking GitHub token"
if [[ ! -s "$PAT_FILE" ]]; then
  # Prefer the host's existing gh login — no separate PAT to mint or rotate.
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    echo "    No token file; reusing the host's gh auth token."
    mkdir -p "$(dirname "$PAT_FILE")"
    gh auth token > "$PAT_FILE"
    chmod 600 "$PAT_FILE"
  else
    echo "==> No GitHub token found (no $PAT_FILE, no host 'gh' login)."
    echo "    The container will still start as a working tokenless session: public config,"
    echo "    skills/hooks, identity, the claude wrapper, and network egress all work."
    echo "    Private clone/push and the private overlay stay off until you add a token."
    echo "    Add one any time WITHOUT a rebuild or restart:"
    echo "        cbox-refresh-pat            # uses your host 'gh auth token'"
    echo "        cbox-refresh-pat <path>     # a PAT file (repo scope)"
  fi
fi

echo "==> Resolving git identity"
# Auto-detect from the host git config, then the authenticated gh account, so consumers
# need set nothing. An explicit GIT_USER_* env (e.g. from a private wrapper) always wins.
if [[ -z "$GIT_USER_EMAIL" ]]; then
  GIT_USER_EMAIL="$(git config --global user.email 2>/dev/null || true)"
  if [[ -z "$GIT_USER_EMAIL" ]] && command -v gh >/dev/null 2>&1; then
    GIT_USER_EMAIL="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null || true)"
  fi
fi
if [[ -z "$GIT_USER_NAME" ]]; then
  GIT_USER_NAME="$(git config --global user.name 2>/dev/null || true)"
  if [[ -z "$GIT_USER_NAME" ]] && command -v gh >/dev/null 2>&1; then
    GIT_USER_NAME="$(gh api user --jq '.name // .login' 2>/dev/null || true)"
  fi
fi
missing=()
[[ -z "$GIT_USER_EMAIL" ]] && missing+=("GIT_USER_EMAIL") || true
[[ -z "$GIT_USER_NAME" ]] && missing+=("GIT_USER_NAME") || true
if ((${#missing[@]})); then
  echo "FATAL: couldn't auto-detect git identity (${missing[*]})." >&2
  echo "  Set it on the host:  git config --global user.name 'You' && git config --global user.email you@you.com" >&2
  echo "  ...or export GIT_USER_NAME / GIT_USER_EMAIL, then re-run." >&2
  exit 2
fi
echo "    using $GIT_USER_NAME <$GIT_USER_EMAIL>"

echo "==> Building image"
cd "$REPO_DIR"
build_args=()
[[ -n "${TZ:-}" ]] && build_args+=(--build-arg "TZ=$TZ")
docker build -t "$IMAGE_TAG" "${build_args[@]}" .

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
  -e CONTAINER_MODE="${CONTAINER_MODE:-default}" \
  -e RESEARCH_REPO="${RESEARCH_REPO:-}" \
  -e AGENT_CONFIG_REPO="${AGENT_CONFIG_REPO:-}" \
  "$IMAGE_TAG"

# Provision host credential files into the auth volume (one-time wiring), then restart once so the
# entrypoint re-syncs with them. github-pat = GitHub's token; git-credentials = per-host lines for
# any other git host (GitLab/Bitbucket/Gitea/self-hosted).
provisioned=0
if [[ -s "$PAT_FILE" ]]; then
  echo "==> Provisioning GitHub token into claude-auth volume"
  docker cp "$PAT_FILE" "$CONTAINER_NAME:/home/claude/.claude-auth/github-pat"
  docker exec "$CONTAINER_NAME" chown claude:claude /home/claude/.claude-auth/github-pat
  docker exec "$CONTAINER_NAME" chmod 600 /home/claude/.claude-auth/github-pat
  provisioned=1
fi
if [[ -s "$GIT_CREDS_FILE" ]]; then
  echo "==> Provisioning per-host git-credentials into claude-auth volume"
  docker cp "$GIT_CREDS_FILE" "$CONTAINER_NAME:/home/claude/.claude-auth/git-credentials"
  docker exec "$CONTAINER_NAME" chown claude:claude /home/claude/.claude-auth/git-credentials
  docker exec "$CONTAINER_NAME" chmod 600 /home/claude/.claude-auth/git-credentials
  provisioned=1
fi
[[ "$provisioned" == 1 ]] && docker restart "$CONTAINER_NAME"

echo "==> Installing cbox helper to /usr/local/bin"
sudo ln -sf "$REPO_DIR/scripts/cbox" /usr/local/bin/cbox
sudo ln -sf "$REPO_DIR/scripts/cbox-refresh-pat" /usr/local/bin/cbox-refresh-pat

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
