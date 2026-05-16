#!/usr/bin/env bash
set -euo pipefail

# The wrapper script under test. Tests stub out the real `gh` to avoid making API calls.
WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/wrappers/gh"

# Make a temp dir with a fake `gh` (the "real" one) that just echoes its args.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/real-gh" <<'EOSTUB'
#!/usr/bin/env bash
echo "REAL-GH-CALLED-WITH: $*"
EOSTUB
chmod +x "$TMP/real-gh"

export CLAUDE_REAL_GH="$TMP/real-gh"
export CLAUDE_AUDIT_LOG="$TMP/audit.jsonl"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

# Test 1: benign command — must call through.
out=$("$WRAPPER" repo view curtyo18/life 2>&1) || true
[[ "$out" == *"REAL-GH-CALLED-WITH: repo view curtyo18/life"* ]] && pass "benign passes through" || fail "benign should pass through, got: $out"

# Test 2: destructive without unlock — must block.
out=$("$WRAPPER" repo edit curtyo18/life --visibility public 2>&1) || ec=$?
[[ "${ec:-0}" -ne 0 ]] && pass "visibility-flip blocked (non-zero exit)" || fail "visibility-flip should block"
[[ "$out" == *"BLOCKED"* ]] && pass "block message present" || fail "expected BLOCKED in output, got: $out"

# Test 3: destructive with unlock — must call through.
unset ec
out=$(CLAUDE_UNLOCK_DESTRUCTIVE=1 "$WRAPPER" repo edit curtyo18/life --visibility public 2>&1) || ec=$?
[[ "${ec:-0}" -eq 0 ]] && pass "unlock allows visibility-flip" || fail "unlock should allow, got ec=$ec out=$out"
[[ "$out" == *"REAL-GH-CALLED-WITH: repo edit curtyo18/life --visibility public"* ]] && pass "real gh invoked under unlock" || fail "real gh not invoked"

# Test 4: repo delete — block.
unset ec
"$WRAPPER" repo delete curtyo18/life 2>&1 || ec=$?
[[ "${ec:-0}" -ne 0 ]] && pass "repo delete blocked" || fail "repo delete should block"

# Test 5: gh api PATCH to change visibility — block.
unset ec
"$WRAPPER" api -X PATCH /repos/curtyo18/life -f visibility=public 2>&1 || ec=$?
[[ "${ec:-0}" -ne 0 ]] && pass "api visibility patch blocked" || fail "api visibility patch should block"

# Test 6: audit log written for the blocked call.
grep -q '"action":"gh repo delete' "$CLAUDE_AUDIT_LOG" || fail "audit log missing repo delete entry"
pass "audit log captured blocked action"

echo "ALL gh-wrapper tests passed."
