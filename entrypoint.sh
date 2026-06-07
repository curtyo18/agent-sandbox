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

# Mirror squid's access.log into the audit JSONL. Spawned ONCE for the life of the container —
# `tail -F` follows the file across squid restarts, so the supervision loop must never re-spawn
# this or every audited request would be logged twice.
start_audit_tailer() {
  sudo bash -c 'tail -F /var/log/squid/access.log 2>/dev/null | while read -r line; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    host="$(echo "$line" | awk "{print \$7}")"
    action="$(echo "$line" | awk "{print \$4}")"
    printf "{\"ts\":\"%s\",\"src\":\"squid\",\"action\":\"%s\",\"host\":\"%s\"}\n" \
      "$ts" "$action" "$host" >> "'"$AUDIT_FILE"'"
  done' &
}

# (Re)start squid in no-daemon mode. Safe to call repeatedly: clears the stale PID file the 5.x
# HappyConnOpener crash can leave behind, then launches a fresh squid as a background child of
# this process (reaped by tini -g).
start_squid() {
  sudo rm -f /run/squid.pid
  sudo squid -N -f /etc/squid/squid.conf &
}

# True when something is accepting TCP on the proxy port. A bare /dev/tcp connect is unambiguous
# (unlike `pgrep -f squid`, which also matches the tailer's command line) and sends zero bytes,
# so it never appears in access.log / the audit JSONL. `timeout 2` guards a half-broken socket.
squid_up() {
  timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3128' 2>/dev/null
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
start_audit_tailer
start_squid
start_launcher
log_event "entrypoint" "ready" ""

# === Supervision (PID 1) ===
# squid 5.7 sporadically aborts (FATAL: check failed: waiting(), HappyConnOpener.cc:225); when it
# dies nothing listens on 3128 and every proxied request fails with ConnectionRefused. Poll the
# port and respawn on death. Capped backoff keeps a persistent failure (e.g. an unparseable
# rendered config) from becoming a restart/log storm. This loop is PID 1's foreground process: if
# it ever exits, the container exits and docker's `--restart unless-stopped` heals the whole thing.
SQUID_POLL_INTERVAL="${SQUID_POLL_INTERVAL:-5}"
SQUID_RESTART_GRACE="${SQUID_RESTART_GRACE:-2}"
SQUID_BACKOFF_MAX="${SQUID_BACKOFF_MAX:-60}"
fails=0
delay="$SQUID_POLL_INTERVAL"
while true; do
  sleep "$delay"
  if squid_up; then
    fails=0
    delay="$SQUID_POLL_INTERVAL"
    continue
  fi
  log_event "squid-watchdog" "restart" "port 3128 down (attempt $((fails + 1)))"
  start_squid
  sleep "$SQUID_RESTART_GRACE"
  if squid_up; then
    fails=0
    delay="$SQUID_POLL_INTERVAL"
  else
    fails=$((fails + 1))
    delay=$(( delay * 2 > SQUID_BACKOFF_MAX ? SQUID_BACKOFF_MAX : delay * 2 ))
    [ "$fails" -eq 3 ] && log_event "squid-watchdog" "flapping" \
      "squid still down after 3 consecutive restarts; backing off to ${delay}s"
  fi
done
