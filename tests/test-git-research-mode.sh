#!/usr/bin/env bash
set -euo pipefail
# Tests the wrappers/git PATH shim — the actual blocking mechanism for research mode.
# (git-audit-wrapper is log-only and intentionally cannot block.)
SHIM="$(cd "$(dirname "$0")/.." && pwd)/wrappers/git"

TMP=$(mktemp -d)
trap '/usr/bin/rm -rf "$TMP"' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

cd "$TMP"
/usr/bin/git init -q
/usr/bin/git remote add origin https://github.com/example/other-repo.git

export RESEARCH_REPO="https://github.com/example/research-repo.git"

# Test 1: git push to non-research remote blocked in research mode
export CONTAINER_MODE=research
result=$(bash "$SHIM" push origin main 2>&1) || true
echo "$result" | grep -q "blocked in research mode" && pass "git push to non-research repo blocked" || \
  fail "git push to non-research repo should be blocked, got: $result"

# Test 2: git push --force always blocked in research mode
result=$(bash "$SHIM" push --force origin main 2>&1) || true
echo "$result" | grep -q "blocked in research mode" && pass "git push --force blocked in research mode" || \
  fail "git push --force should be blocked in research mode, got: $result"

# Test 3: git push to RESEARCH_REPO allowed in research mode
/usr/bin/git remote set-url origin "$RESEARCH_REPO"
result=$(bash "$SHIM" push origin main 2>&1) || true
echo "$result" | grep -q "blocked" && \
  fail "git push to RESEARCH_REPO should be allowed, got: $result" || \
  pass "git push to research repo allowed"

# Test 4: git push allowed in default mode regardless of remote
unset CONTAINER_MODE
/usr/bin/git remote set-url origin https://github.com/example/any-repo.git
result=$(bash "$SHIM" push origin main 2>&1) || true
echo "$result" | grep -q "blocked" && \
  fail "git push in default mode should not be blocked, got: $result" || \
  pass "git push in default mode not blocked"

# Test 5: non-push git commands pass through in research mode
export CONTAINER_MODE=research
result=$(bash "$SHIM" status 2>&1) || true
echo "$result" | grep -q "blocked" && \
  fail "git status should not be blocked in research mode, got: $result" || \
  pass "git status passes through in research mode"

echo "ALL git-research-mode tests passed."
