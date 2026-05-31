#!/usr/bin/env bash
set -uo pipefail
BS="$(cd "$(dirname "$0")/.." && pwd)/bootstrap.sh"
pass(){ echo "  PASS: $1"; }
fail(){ printf '  FAIL: %s\n%s\n' "$1" "$2"; exit 1; }

T=$(mktemp -d)
printf 'REPO_DIR="/from/dotenv"\n' > "$T/env"

# 1. exported env wins over .env
out=$(REPO_DIR="/from/env" AGENT_SANDBOX_ENV="$T/env" bash "$BS" --print-config 2>/dev/null)
echo "$out" | grep -qx 'REPO_DIR=/from/env'    && pass "env wins over .env"    || fail "env should win" "$out"
# 2. .env wins over default
out=$(AGENT_SANDBOX_ENV="$T/env" bash "$BS" --print-config 2>/dev/null)
echo "$out" | grep -qx 'REPO_DIR=/from/dotenv' && pass ".env wins over default" || fail ".env should win" "$out"
# 3. default when neither
out=$(AGENT_SANDBOX_ENV="$T/none" bash "$BS" --print-config 2>/dev/null)
echo "$out" | grep -qx "REPO_DIR=$HOME/projects/agent-sandbox" && pass "default when neither" || fail "default expected" "$out"

echo "ALL env-precedence tests passed."
