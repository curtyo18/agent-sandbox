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
out=$("$WRAPPER" repo view example-user/example-repo 2>&1) || true
[[ "$out" == *"REAL-GH-CALLED-WITH: repo view example-user/example-repo"* ]] && pass "benign passes through" || fail "benign should pass through, got: $out"

# Test 2: destructive without unlock — must block.
out=$("$WRAPPER" repo edit example-user/example-repo --visibility public 2>&1) || ec=$?
[[ "${ec:-0}" -ne 0 ]] && pass "visibility-flip blocked (non-zero exit)" || fail "visibility-flip should block"
[[ "$out" == *"BLOCKED"* ]] && pass "block message present" || fail "expected BLOCKED in output, got: $out"

# Test 3: destructive with unlock — must call through.
unset ec
out=$(CLAUDE_UNLOCK_DESTRUCTIVE=1 "$WRAPPER" repo edit example-user/example-repo --visibility public 2>&1) || ec=$?
[[ "${ec:-0}" -eq 0 ]] && pass "unlock allows visibility-flip" || fail "unlock should allow, got ec=$ec out=$out"
[[ "$out" == *"REAL-GH-CALLED-WITH: repo edit example-user/example-repo --visibility public"* ]] && pass "real gh invoked under unlock" || fail "real gh not invoked"

# Test 4: repo delete — block.
unset ec
"$WRAPPER" repo delete example-user/example-repo 2>&1 || ec=$?
[[ "${ec:-0}" -ne 0 ]] && pass "repo delete blocked" || fail "repo delete should block"

# Test 5: gh api PATCH to change visibility — block.
unset ec
"$WRAPPER" api -X PATCH /repos/example-user/example-repo -f visibility=public 2>&1 || ec=$?
[[ "${ec:-0}" -ne 0 ]] && pass "api visibility patch blocked" || fail "api visibility patch should block"

# Test 6: audit log written for the blocked call.
grep -q '"action":"gh repo delete' "$CLAUDE_AUDIT_LOG" || fail "audit log missing repo delete entry"
pass "audit log captured blocked action"

# Helper: assert the wrapper BLOCKS a given command (non-zero exit + BLOCKED msg).
assert_block() {
  local desc="$1"; shift
  local out ec=0
  out=$("$WRAPPER" "$@" 2>&1) || ec=$?
  [[ "$ec" -ne 0 ]] || fail "$desc: should block (got exit 0), out: $out"
  [[ "$out" == *"BLOCKED"* ]] || fail "$desc: expected BLOCKED in output, got: $out"
  pass "$desc"
}

# Helper: assert the wrapper PASSES a command through to the real gh.
assert_pass() {
  local desc="$1"; shift
  local out ec=0
  out=$("$WRAPPER" "$@" 2>&1) || ec=$?
  [[ "$ec" -eq 0 ]] || fail "$desc: should pass through (got exit $ec), out: $out"
  [[ "$out" == *"REAL-GH-CALLED-WITH:"* ]] || fail "$desc: real gh not invoked, got: $out"
  pass "$desc"
}

# --- Regression: previously-bypassable destructive forms must now block. -----

# Equals form of --visibility (no pattern previously had `=`).
assert_block "repo edit --visibility=public (equals form) blocked" \
  repo edit example-user/example-repo --visibility=public

# Intervening flag between `edit <repo>` and --visibility.
assert_block "repo edit with intervening flag before --visibility blocked" \
  repo edit example-user/example-repo --some-flag --visibility public

# --method is gh's long form of -X.
assert_block "api --method DELETE /repos blocked" \
  api --method DELETE /repos/example-user/example-repo

# Trailing flag previously defeated the `$` end-anchor.
assert_block "api -X DELETE /repos with trailing flag blocked" \
  api -X DELETE /repos/example-user/example-repo --silent

# Path-before-method ordering.
assert_block "api /repos path before -X DELETE blocked" \
  api /repos/example-user/example-repo -X DELETE

# --method=DELETE equals form.
assert_block "api --method=DELETE /repos blocked" \
  api --method=DELETE /repos/example-user/example-repo

# --- Regression: previously-untested but intended-block patterns. ------------

# No-arg form: repo edit without a positional repo, just --visibility.
assert_block "repo edit --visibility public (no repo arg) blocked" \
  repo edit --visibility public

assert_block "repo transfer blocked" \
  repo transfer example-user/example-repo new-owner

assert_block "repo archive blocked" \
  repo archive example-user/example-repo

# DELETE alternation (the PATCH form is already covered by Test 5).
assert_block "api -X DELETE /repos blocked" \
  api -X DELETE /repos/example-user/example-repo

# visibility=public via api field, regardless of method targeting.
assert_block "api with visibility=public payload blocked" \
  api --method PATCH /repos/example-user/example-repo -f visibility=public

# --- Regression: over-block false positives must PASS through. ---------------

# A comment body that mentions "repo delete" must NOT be blocked.
assert_pass "issue comment with 'repo delete' in body passes" \
  issue comment 42 --body "please don't repo delete this, just archive locally"

assert_pass "pr comment with 'repo delete' in body passes" \
  pr comment 7 --body "we should not repo transfer or repo archive here"

# An ordinary api GET to /repos must pass.
assert_pass "api GET /repos passes through" \
  api /repos/example-user/example-repo

echo "ALL gh-wrapper tests passed."
