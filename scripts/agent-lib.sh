#!/usr/bin/env bash
# agent-lib.sh — shared constants + audit logging, sourced by entrypoint.sh, agent-config-sync,
# and render-squid-conf. Path vars are overridable so the unit tests can redirect them at temp dirs.
CLAUDE_HOME="${CLAUDE_HOME:-/home/claude}"
CONFIG_DIR="${CONFIG_DIR:-$CLAUDE_HOME/.claude}"
AUTH_DIR="${AUTH_DIR:-$CLAUDE_HOME/.claude-auth}"
AUDIT_DIR="${AUDIT_DIR:-/audit}"
AUDIT_FILE="${AUDIT_FILE:-$AUDIT_DIR/$(date -u +%F).jsonl}"

log_event() {
  local src="$1" action="$2" reason="${3:-}"
  mkdir -p "$AUDIT_DIR" 2>/dev/null || true
  printf '{"ts":"%s","src":"%s","action":"%s","reason":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$src" "$action" "$reason" >> "$AUDIT_FILE" 2>/dev/null || true
}
