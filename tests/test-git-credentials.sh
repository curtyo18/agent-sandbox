#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent-config-sync"
export AGENT_LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent-lib.sh"
pass(){ echo "  PASS: $1"; }
fail(){ echo "  FAIL: $1"; exit 1; }

mkstub() {  # $1 = tmpdir; stub git logs calls and echoes a non-github embedded-cred URL for get-url
  cat > "$1/bin/git" <<EOSTUB
#!/usr/bin/env bash
echo "GIT: \$*" >> "$1/calls.log"
case "\$*" in *"remote get-url"*) echo "https://user:tok@gitlab.com/me/cfg.git" ;; esac
exit 0
EOSTUB
  cat > "$1/bin/gh" <<'EOSTUB'
#!/usr/bin/env bash
exit 0
EOSTUB
  chmod +x "$1/bin/git" "$1/bin/gh"
}

run() {  # run agent-config-sync with the temp env
  PATH="$1/bin:$PATH" CLAUDE_HOME="$1/home" CONFIG_DIR="$1/config" AUTH_DIR="$1/auth" AUDIT_DIR="$1/audit" \
    GIT_USER_NAME="x" GIT_USER_EMAIL="x@y.z" bash "$SCRIPT" >/dev/null 2>&1
}

# Case 1: git-credentials present → store registered + ~/.git-credentials installed mode 600.
T=$(mktemp -d); mkdir -p "$T/bin" "$T/home" "$T/auth" "$T/audit" "$T/config"; mkstub "$T"
printf 'https://oauth2:tok@gitlab.com\n' > "$T/auth/git-credentials"
run "$T"
grep -q 'GIT: config --global credential.helper store' "$T/calls.log" && pass "store helper registered" || fail "no store helper: $(cat "$T/calls.log" 2>&1)"
[[ -f "$T/home/.git-credentials" ]] && pass "git-credentials installed" || fail "not installed"
[[ "$(stat -c '%a' "$T/home/.git-credentials" 2>/dev/null)" == "600" ]] && pass "mode 600" || fail "wrong mode"

# Case 2: no git-credentials → store NOT registered (GitHub path untouched).
T=$(mktemp -d); mkdir -p "$T/bin" "$T/home" "$T/auth" "$T/audit" "$T/config"; mkstub "$T"
run "$T"
grep -q 'credential.helper store' "$T/calls.log" && fail "store should NOT be registered without the file" || pass "no store without git-credentials"

# Case 3: generalized scrub rewrites a non-github embedded-credential remote.
T=$(mktemp -d); mkdir -p "$T/bin" "$T/home" "$T/auth" "$T/audit" "$T/config/.git"; mkstub "$T"
run "$T"
grep -qE 'GIT: -C .* remote set-url origin' "$T/calls.log" && pass "scrub rewrites non-github embedded-cred URL" || fail "scrub didn't run: $(cat "$T/calls.log" 2>&1)"

echo "ALL git-credentials tests passed."
