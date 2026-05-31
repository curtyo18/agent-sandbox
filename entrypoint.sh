#!/usr/bin/env bash
# entrypoint.sh — runs once at container start, then stays alive for `docker exec`.
# Thin orchestrator: agent-config-sync and render-squid-conf hold the real logic (as standalone
# scripts so cbox-refresh-pat can re-run them on a live container without re-triggering boot).
set -uo pipefail
# shellcheck source=/dev/null
. "${AGENT_LIB:-/usr/local/bin/agent-lib.sh}"

# 1. Ensure audit dir + today's file exist.
mkdir -p "$AUDIT_DIR" "$AUTH_DIR"
touch "$AUDIT_FILE"

CONTAINER_MODE="${CONTAINER_MODE:-default}"
if [[ "$CONTAINER_MODE" == "research" ]]; then
  if [[ -z "${RESEARCH_REPO:-}" ]]; then
    echo "ERROR: CONTAINER_MODE=research requires RESEARCH_REPO env var." >&2
    exit 1
  fi
  # Research containers run public-config only — disable any private overlay.
  unset AGENT_CONFIG_PRIVATE_REPO
fi
export CONTAINER_MODE

start_squid() {
  # Clean up a stale PID file left behind by a previous abrupt shutdown.
  sudo rm -f /run/squid.pid
  sudo squid -N -f /etc/squid/squid.conf &
  sudo bash -c 'tail -F /var/log/squid/access.log 2>/dev/null | while read -r line; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    host="$(echo "$line" | awk "{print \$7}")"
    action="$(echo "$line" | awk "{print \$4}")"
    printf "{\"ts\":\"%s\",\"src\":\"squid\",\"action\":\"%s\",\"host\":\"%s\"}\n" \
      "$ts" "$action" "$host" >> "'"$AUDIT_FILE"'"
  done' &
}

start_launcher() {
  if ! pgrep -f session-launcher.py >/dev/null 2>&1; then
    nohup python3 /usr/local/bin/session-launcher.py >>/tmp/session-launcher.log 2>&1 &
    log_event "entrypoint" "launcher-started" ""
  fi
}

# === Run sequence ===
/usr/local/bin/agent-config-sync || true
/usr/local/bin/render-squid-conf || true
start_squid
start_launcher
log_event "entrypoint" "ready" ""

# Stay alive forever.
exec sleep infinity
