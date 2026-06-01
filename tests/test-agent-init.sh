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

# Case 3: non-interactive provisions a single git-credential line (mode 600).
AGENT_SANDBOX_ENV="$T/.env" AGENT_INIT_NONINTERACTIVE=1 \
  AGENT_GIT_CREDENTIALS='https://oauth2:tok1@gitlab.com' \
  bash "$INIT" >/dev/null 2>&1
grep -qx 'https://oauth2:tok1@gitlab.com' "$T/git-credentials"  && pass "writes gitlab cred"    || fail "gitlab cred: $(cat "$T/git-credentials" 2>&1)"
[[ "$(stat -c '%a' "$T/git-credentials")" == 600 ]]             && pass "creds mode 600"        || fail "creds mode $(stat -c '%a' "$T/git-credentials" 2>&1)"

# Case 4: multiple newline-separated lines both land.
AGENT_SANDBOX_ENV="$T/.env" AGENT_INIT_NONINTERACTIVE=1 \
  AGENT_GIT_CREDENTIALS=$'https://oauth2:tok1@gitlab.com\nhttps://u:pw@bitbucket.org' \
  bash "$INIT" >/dev/null 2>&1
grep -qx 'https://u:pw@bitbucket.org' "$T/git-credentials"      && pass "writes bitbucket cred" || fail "bitbucket missing: $(cat "$T/git-credentials" 2>&1)"
[[ "$(grep -c . "$T/git-credentials")" == 2 ]]                  && pass "two cred lines"        || fail "expected 2 lines: $(cat "$T/git-credentials" 2>&1)"

# Case 5: upsert by host — re-running with a new gitlab token replaces, not duplicates.
AGENT_SANDBOX_ENV="$T/.env" AGENT_INIT_NONINTERACTIVE=1 \
  AGENT_GIT_CREDENTIALS='https://oauth2:tok2@gitlab.com' \
  bash "$INIT" >/dev/null 2>&1
[[ "$(grep -c 'gitlab.com' "$T/git-credentials")" == 1 ]]       && pass "gitlab upserted once"  || fail "dup gitlab: $(cat "$T/git-credentials" 2>&1)"
grep -qx 'https://oauth2:tok2@gitlab.com' "$T/git-credentials"  && pass "gitlab token updated"  || fail "token not updated: $(cat "$T/git-credentials" 2>&1)"
grep -qx 'https://u:pw@bitbucket.org' "$T/git-credentials"      && pass "other host preserved"  || fail "bitbucket lost: $(cat "$T/git-credentials" 2>&1)"

# Case 6: no AGENT_GIT_CREDENTIALS → no creds file; .env still written.
rm -f "$T/.env" "$T/git-credentials"
AGENT_SANDBOX_ENV="$T/.env" AGENT_INIT_NONINTERACTIVE=1 \
  PROJECTS_HOST_PATH="/tmp/projx" GIT_USER_NAME="Test User" GIT_USER_EMAIL="t@e.st" \
  bash "$INIT" >/dev/null 2>&1
[[ ! -e "$T/git-credentials" ]]                                 && pass "no creds when unset"   || fail "creds file should not exist"
grep -q '^REPO_DIR=' "$T/.env"                                  && pass ".env still written"    || fail ".env missing: $(cat "$T/.env" 2>&1)"

echo "ALL agent-init tests passed."
