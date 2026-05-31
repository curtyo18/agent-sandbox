#!/usr/bin/env bash
set -uo pipefail
INIT="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent-init"
pass(){ echo "  PASS: $1"; }
fail(){ echo "  FAIL: $1"; exit 1; }

T=$(mktemp -d)

# Case 1: non-interactive writes .env from env vars + derives the audit path.
AGENT_SANDBOX_ENV="$T/.env" AGENT_INIT_NONINTERACTIVE=1 \
  PROJECTS_HOST_PATH="/tmp/projx" GIT_USER_NAME="Test User" GIT_USER_EMAIL="t@e.st" \
  bash "$INIT" >/dev/null 2>&1
grep -q 'PROJECTS_HOST_PATH="/tmp/projx"' "$T/.env"            && pass "writes projects dir"  || fail "projects dir: $(cat "$T/.env" 2>&1)"
grep -q 'AUDIT_HOST_PATH="/tmp/projx/.claude-audit"' "$T/.env" && pass "derives audit path"   || fail "audit path"
grep -q 'GIT_USER_EMAIL="t@e.st"' "$T/.env"                    && pass "writes identity"      || fail "identity"
grep -q '^REPO_DIR=' "$T/.env"                                 && pass "writes REPO_DIR"      || fail "repo dir"

# Case 2: re-run pre-fills from the existing .env; an env override changes ONLY that key.
AGENT_SANDBOX_ENV="$T/.env" AGENT_INIT_NONINTERACTIVE=1 GIT_USER_EMAIL="new@e.st" \
  bash "$INIT" >/dev/null 2>&1
grep -q 'GIT_USER_EMAIL="new@e.st"' "$T/.env"                  && pass "env override applied" || fail "override: $(cat "$T/.env" 2>&1)"
grep -q 'PROJECTS_HOST_PATH="/tmp/projx"' "$T/.env"            && pass "prefill preserved"    || fail "prefill lost: $(cat "$T/.env" 2>&1)"

echo "ALL agent-init tests passed."
