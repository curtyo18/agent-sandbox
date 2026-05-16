# audit-shell.sh — sourced into bash to log every command via the DEBUG trap.
# Intentionally permissive (logs only; never blocks). Pair with gh wrapper for blocking.

if [[ "${CLAUDE_AUDIT_DISABLE:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi

CLAUDE_AUDIT_LOG="${CLAUDE_AUDIT_LOG:-/audit/$(date -u +%F).jsonl}"

_claude_audit_log_cmd() {
  # $BASH_COMMAND is the about-to-run command. Skip recursive logging.
  [[ "$BASH_COMMAND" == "_claude_audit_log_cmd"* ]] && return 0
  [[ "$BASH_COMMAND" == "trap "* ]] && return 0

  local ts cwd cmd
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cwd="${PWD}"
  # Escape backslashes and double quotes for JSON.
  cmd="${BASH_COMMAND//\\/\\\\}"
  cmd="${cmd//\"/\\\"}"

  mkdir -p "$(dirname "$CLAUDE_AUDIT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","src":"audit-shell","action":"cmd","argv":"%s","cwd":"%s","blocked":false}\n' \
    "$ts" "$cmd" "$cwd" >> "$CLAUDE_AUDIT_LOG" 2>/dev/null || true

  # Hook git: if command starts with `git push|remote add|push --force`, call wrapper for richer log.
  case "$BASH_COMMAND" in
    git\ push*|git\ remote\ add*)
      /usr/local/bin/git-audit-wrapper ${BASH_COMMAND#git } >/dev/null 2>&1 || true
      ;;
  esac
}

trap '_claude_audit_log_cmd' DEBUG
