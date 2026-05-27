#!/usr/bin/env bash
set -euo pipefail
WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/wrappers/rm"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

# Test 1: rm blocked in research mode
export CONTAINER_MODE=research
touch /tmp/test-rm-research-$$
result=$("$WRAPPER" /tmp/test-rm-research-$$ 2>&1) || true
rm -f /tmp/test-rm-research-$$  # clean up in case wrapper didn't block
echo "$result" | grep -q "blocked in research mode" && pass "rm blocked in research mode" || \
  fail "rm should be blocked in research mode, got: $result"

# Test 2: rm passes through in default mode
unset CONTAINER_MODE
touch /tmp/test-rm-normal-$$
"$WRAPPER" /tmp/test-rm-normal-$$ 2>&1 && pass "rm passes through in default mode" || \
  fail "rm should pass through in default mode"

echo "ALL rm-wrapper tests passed."
