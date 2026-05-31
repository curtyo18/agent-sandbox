#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent-config-sync"
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent-lib.sh"
export AGENT_LIB="$LIB"   # the script sources ${AGENT_LIB:-/usr/local/bin/agent-lib.sh}

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

run_case() {  # $1 = "withpat" | "nopat"
  local mode="$1"
  local T; T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/home" "$T/auth" "$T/audit" "$T/config" "$T/projects"
  # Stub git + gh: record args, never touch the network.
  cat > "$T/bin/git" <<EOSTUB
#!/usr/bin/env bash
echo "GIT: \$*" >> "$T/calls.log"
EOSTUB
  cat > "$T/bin/gh" <<EOSTUB
#!/usr/bin/env bash
echo "GH: \$*" >> "$T/calls.log"
# 'gh auth status' must report "not logged in" so the script attempts login when a pat exists.
[[ "\$1" == "auth" && "\$2" == "status" ]] && exit 1
exit 0
EOSTUB
  chmod +x "$T/bin/git" "$T/bin/gh"
  [[ "$mode" == "withpat" ]] && printf 'ghp_faketoken' > "$T/auth/github-pat"
  # Seed trust against a test-owned dir: the script keys trust off /projects and $LAUNCHER_PROJECT,
  # and /projects only exists inside the container — so on a bare host we point LAUNCHER_PROJECT here.
  PATH="$T/bin:$PATH" \
    CLAUDE_HOME="$T/home" CONFIG_DIR="$T/config" AUTH_DIR="$T/auth" AUDIT_DIR="$T/audit" \
    LAUNCHER_PROJECT="$T/projects" \
    GIT_USER_EMAIL="t@e.st" GIT_USER_NAME="Tester" \
    bash "$SCRIPT" >/dev/null 2>&1
  echo "$T"
}

# Case 1: no PAT — clone + wiring run, gh auth NOT attempted.
T=$(run_case nopat)
grep -q 'GIT: clone' "$T/calls.log"        && pass "nopat: config clone attempted"      || fail "nopat: no clone"
grep -q 'claude --dangerously-skip-permissions' "$T/home/.bashrc" && pass "nopat: claude() wrapper added" || fail "nopat: no wrapper"
grep -q 'hasTrustDialogAccepted' "$T/home/.claude.json" && pass "nopat: trust seeded" || fail "nopat: no trust seed"
grep -q 'GH: auth login' "$T/calls.log"    && fail "nopat: gh auth login should NOT run" || pass "nopat: gh auth login skipped"

# Case 2: PAT present — gh auth login IS attempted.
T=$(run_case withpat)
grep -q 'GH: auth login' "$T/calls.log"    && pass "withpat: gh auth login attempted"   || fail "withpat: no gh auth login"
grep -q 'GH: auth setup-git' "$T/calls.log" && pass "withpat: gh auth setup-git ran"     || fail "withpat: no setup-git"
grep -q 'GIT: clone' "$T/calls.log"        && pass "withpat: config clone attempted"     || fail "withpat: no clone"

# Case 3: idempotent re-run (nopat) — wrapper not duplicated.
T=$(mktemp -d); mkdir -p "$T/bin" "$T/home" "$T/auth" "$T/audit" "$T/config"
cat > "$T/bin/git" <<EOSTUB
#!/usr/bin/env bash
exit 0
EOSTUB
cat > "$T/bin/gh" <<'EOSTUB'
#!/usr/bin/env bash
exit 0
EOSTUB
chmod +x "$T/bin/git" "$T/bin/gh"
for _ in 1 2; do
  PATH="$T/bin:$PATH" CLAUDE_HOME="$T/home" CONFIG_DIR="$T/config" AUTH_DIR="$T/auth" AUDIT_DIR="$T/audit" \
    GIT_USER_EMAIL="t@e.st" GIT_USER_NAME="Tester" bash "$SCRIPT" >/dev/null 2>&1
done
n=$(grep -c 'claude --dangerously-skip-permissions' "$T/home/.bashrc")
[[ "$n" -eq 1 ]] && pass "idempotent: wrapper appended exactly once" || fail "idempotent: wrapper appears $n times"

echo "ALL agent-config-sync tests passed."
