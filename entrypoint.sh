#!/usr/bin/env bash
# entrypoint.sh — runs once at container start, then stays alive for `docker exec`.

set -uo pipefail

CLAUDE_HOME="/home/claude"
CONFIG_DIR="$CLAUDE_HOME/.claude"
AUTH_DIR="$CLAUDE_HOME/.claude-auth"
AUDIT_DIR="/audit"
TODAY="$(date -u +%F)"
AUDIT_FILE="$AUDIT_DIR/$TODAY.jsonl"

log_event() {
  local src="$1" action="$2" reason="${3:-}"
  mkdir -p "$AUDIT_DIR"
  printf '{"ts":"%s","src":"%s","action":"%s","reason":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$src" "$action" "$reason" >> "$AUDIT_FILE"
}

# 1. Ensure audit dir + today's file exist.
mkdir -p "$AUDIT_DIR" "$AUTH_DIR"
touch "$AUDIT_FILE"

# 2. Render squid config from template + global allowlist + any per-project allowlists.
render_squid_conf() {
  local out="/tmp/squid.conf"
  local includes=""

  # Global allowlist from agent-config.
  if [[ -f "$CONFIG_DIR/network-allowlist.conf" ]]; then
    includes+=$'\n# from agent-config/network-allowlist.conf\n'
    includes+=$(cat "$CONFIG_DIR/network-allowlist.conf")
  fi

  # Per-project allowlists (any file matching /projects/*/.claude-allowlist.conf).
  for plf in /projects/*/.claude-allowlist.conf; do
    [[ -f "$plf" ]] || continue
    includes+=$'\n# from '"$plf"$'\n'
    includes+=$(cat "$plf")
  done

  # If no allowlist was found (e.g. agent-config clone failed), write a tombstone ACL
  # so squid still parses cleanly. Effectively denies all egress until allowlist arrives.
  if [[ -z "$includes" ]]; then
    includes=$'\n# fallback: no allowlist found, deny everything\nacl allowed_hosts dstdomain .invalid-no-allowlist\n'
  fi

  # Substitute placeholder.
  awk -v inc="$includes" '{gsub(/\{ALLOWLIST_INCLUDES\}/, inc); print}' \
    /etc/squid/squid.conf.template > "$out"
  sudo cp "$out" /etc/squid/squid.conf
}

# 3. Clone or pull agent-config.
# Bypass the in-container proxy for these git ops — squid isn't running yet (chicken-and-egg:
# render_squid_conf needs network-allowlist.conf which lives in agent-config which needs this clone).
# github.com would be on the allowlist anyway, so direct egress here matches policy.
sync_config() {
  local pat="$(cat "$AUTH_DIR/github-pat" 2>/dev/null || true)"

  if [[ -z "$pat" ]]; then
    log_event "entrypoint" "config-sync-skipped" "no-pat"
    echo "WARN: no GitHub PAT at $AUTH_DIR/github-pat; using cached config (if any)." >&2
    return 0
  fi

  if [[ -d "$CONFIG_DIR/.git" ]]; then
    cd "$CONFIG_DIR"
    if ! HTTPS_PROXY="" HTTP_PROXY="" git pull --ff-only 2>>/tmp/git-pull.err; then
      log_event "entrypoint" "config-pull-failed" "$(tail -1 /tmp/git-pull.err 2>/dev/null)"
      echo "WARN: git pull failed in $CONFIG_DIR; using last-good cache." >&2
    fi
  else
    if ! HTTPS_PROXY="" HTTP_PROXY="" git clone --depth=1 \
      "https://x-access-token:${pat}@github.com/curtyo18/agent-config.git" \
      "$CONFIG_DIR" 2>>/tmp/git-clone.err
    then
      log_event "entrypoint" "config-clone-failed" "$(tail -1 /tmp/git-clone.err 2>/dev/null)"
      echo "FATAL: initial config clone failed; container will run without skills/hooks." >&2
    fi
  fi

  # Ensure hooks have read+exec.
  find "$CONFIG_DIR/hooks" -name "*.cjs" -exec chmod +rx {} \; 2>/dev/null || true
  find "$CONFIG_DIR/hooks" -name "*.sh"  -exec chmod +rx {} \; 2>/dev/null || true

  # Wire git: hooksPath for pre-commit, identity for commits (idempotent).
  git config --global core.hooksPath "$CONFIG_DIR/hooks" 2>/dev/null || true
  git config --global user.email "curtyo18@gmail.com" 2>/dev/null || true
  git config --global user.name "curtyo18" 2>/dev/null || true

  # Auth gh with the PAT and register it as git credential helper (idempotent).
  if [[ -s "$AUTH_DIR/github-pat" ]] && ! gh auth status >/dev/null 2>&1; then
    cat "$AUTH_DIR/github-pat" | gh auth login --hostname github.com --git-protocol https --with-token 2>/dev/null || true
  fi
  gh auth setup-git 2>/dev/null || true

  # Mark first-run onboarding as complete in /home/claude/.claude.json.
  # Without this, claude shows the "Select login method" wizard on every container recreate
  # (the file lives outside the claude-cfg-cache volume, so it doesn't persist).
  # See: https://github.com/anthropics/claude-code/issues/4714
  python3 -c "
import json, os
p = '$CLAUDE_HOME/.claude.json'
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except: d = {}
d['hasCompletedOnboarding'] = True
json.dump(d, open(p, 'w'), indent=2)
" 2>/dev/null || true

  # Install enabledPlugins from settings.json (idempotent: skip if already installed).
  if [[ -f "$CONFIG_DIR/settings.json" ]]; then
    local plugins
    plugins=$(python3 -c "import json; d=json.load(open('$CONFIG_DIR/settings.json')); print(' '.join((d.get('enabledPlugins') or {}).keys()))" 2>/dev/null || true)
    local installed
    installed=$(claude plugin list 2>/dev/null | awk 'NR>1 {print $1}' || true)
    for p in $plugins; do
      if ! echo "$installed" | grep -qF "$p"; then
        echo "==> Installing plugin: $p"
        claude plugin install "$p" || echo "WARN: plugin install $p failed"
      fi
    done
  fi
}

# 4. Start squid (after render_squid_conf).
start_squid() {
  sudo squid -N -f /etc/squid/squid.conf &
  # Tail access.log into audit (best-effort; squid format).
  sudo bash -c 'tail -F /var/log/squid/access.log 2>/dev/null | while read -r line; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    host="$(echo "$line" | awk "{print \$7}")"
    action="$(echo "$line" | awk "{print \$4}")"
    printf "{\"ts\":\"%s\",\"src\":\"squid\",\"action\":\"%s\",\"host\":\"%s\"}\n" \
      "$ts" "$action" "$host" >> "'"$AUDIT_FILE"'"
  done' &
}

# === Run sequence ===
sync_config
render_squid_conf
start_squid
log_event "entrypoint" "ready" ""

# 5. Stay alive forever.
exec sleep infinity
