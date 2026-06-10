#!/usr/bin/env bash
set -euo pipefail
# Tests the wrappers/git PATH shim — the actual blocking mechanism for research mode.
# (git-audit-wrapper is log-only and intentionally cannot block.)
SHIM="$(cd "$(dirname "$0")/.." && pwd)/wrappers/git"

TMP=$(mktemp -d)
trap '/usr/bin/rm -rf "$TMP"' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

# A local bare repo stands in for RESEARCH_REPO so the "allowed" case can be
# asserted positively, offline (no real network push).
/usr/bin/git init -q --bare "$TMP/research-repo.git"

cd "$TMP"
/usr/bin/git init -q
/usr/bin/git config user.email test@example.com
/usr/bin/git config user.name test
/usr/bin/git commit -q --allow-empty -m "init"
# Default branch name varies; normalize to main for predictable push refspecs.
/usr/bin/git branch -M main
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

# Test 3: git push to RESEARCH_REPO allowed in research mode (positive, offline)
/usr/bin/git remote set-url origin "$TMP/research-repo.git"
export RESEARCH_REPO="$TMP/research-repo.git"
result=$(bash "$SHIM" push origin main 2>&1) || ec=$?
[[ "${ec:-0}" -eq 0 ]] || fail "git push to RESEARCH_REPO should succeed, got ec=${ec:-?}: $result"
# Confirm the push actually landed in the bare repo.
/usr/bin/git --git-dir="$TMP/research-repo.git" rev-parse --verify main >/dev/null 2>&1 && \
  pass "git push to research repo allowed and landed" || \
  fail "git push to research repo did not land, got: $result"
unset ec

# Test 4: git push allowed in default mode regardless of remote
unset CONTAINER_MODE
/usr/bin/git remote set-url origin https://github.com/example/any-repo.git
export RESEARCH_REPO="https://github.com/example/research-repo.git"
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

# --- Regression: global options and force-anywhere must not bypass the guard. -

# Test 6: a leading global option (-C <path>) must not skip the guard. The
# remote in $TMP is non-research, so this should be remote-checked + blocked.
/usr/bin/git remote set-url origin https://github.com/example/other-repo.git
result=$(bash "$SHIM" -C "$TMP" push origin main 2>&1) || true
echo "$result" | grep -q "blocked in research mode" && pass "git -C <dir> push remote-checked, not bypassed" || \
  fail "git -C <dir> push should be remote-checked/blocked, got: $result"

# Test 7: a leading -c k=v global option must not skip the guard.
result=$(bash "$SHIM" -c http.sslVerify=false push origin main 2>&1) || true
echo "$result" | grep -q "blocked in research mode" && pass "git -c k=v push remote-checked, not bypassed" || \
  fail "git -c k=v push should be remote-checked/blocked, got: $result"

# Test 8: force flag AFTER the refspec must be blocked (even to RESEARCH_REPO).
/usr/bin/git remote set-url origin "$TMP/research-repo.git"
export RESEARCH_REPO="$TMP/research-repo.git"
result=$(bash "$SHIM" push origin main --force 2>&1) || true
echo "$result" | grep -q "git push --force is blocked" && pass "force flag after refspec blocked" || \
  fail "git push origin main --force should be blocked, got: $result"

# Test 9: short -f anywhere must be blocked.
result=$(bash "$SHIM" push -f origin main 2>&1) || true
echo "$result" | grep -q "git push --force is blocked" && pass "push -f blocked" || \
  fail "git push -f origin main should be blocked, got: $result"

echo "ALL git-research-mode tests passed."
