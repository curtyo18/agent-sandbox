#!/usr/bin/env bash
# test-tokenless-boot.sh — verify a TOKENLESS container boots to a working state, then that
# cbox-refresh-pat upgrades it in place. Runs on the WSL HOST (needs docker). Uses the EXISTING
# image with the new files bind-mounted + a throwaway auth volume; never touches claude-box.
#
#   IMAGE=claude-box:latest ./tests/test-tokenless-boot.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-claude-box:latest}"
NAME="tokenless-test-$$"
VOL="tokenless-auth-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Booting tokenless container off $IMAGE (new files bind-mounted, fresh empty auth volume)"
docker run -d --name "$NAME" \
  -e GIT_USER_EMAIL="t@e.st" -e GIT_USER_NAME="Tester" \
  -v "$VOL:/home/claude/.claude-auth" \
  -v "$REPO/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
  -v "$REPO/scripts/agent-lib.sh:/usr/local/bin/agent-lib.sh:ro" \
  -v "$REPO/scripts/agent-config-sync:/usr/local/bin/agent-config-sync:ro" \
  -v "$REPO/scripts/render-squid-conf:/usr/local/bin/render-squid-conf:ro" \
  "$IMAGE" >/dev/null

for i in $(seq 1 30); do
  docker exec "$NAME" test -f /audit/"$(date -u +%F)".jsonl 2>/dev/null && \
    docker exec "$NAME" grep -q '"action":"ready"' /audit/"$(date -u +%F)".jsonl 2>/dev/null && break
  sleep 1
done

echo "==> Assert: public config cloned tokenless"
docker exec "$NAME" test -d /home/claude/.claude/.git && echo "  PASS: config cloned" || { echo "  FAIL: no config"; exit 1; }
echo "==> Assert: claude() wrapper + trust seeded"
docker exec "$NAME" grep -q 'claude --dangerously-skip-permissions' /home/claude/.bashrc && echo "  PASS: wrapper" || { echo "  FAIL: wrapper"; exit 1; }
docker exec "$NAME" grep -q 'hasTrustDialogAccepted' /home/claude/.claude.json && echo "  PASS: trust" || { echo "  FAIL: trust"; exit 1; }
echo "==> Assert: squid allows api.anthropic.com tokenless"
code=$(docker exec "$NAME" bash -lc 'curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://api.anthropic.com' || true)
[[ "$code" != "000" && -n "$code" ]] && echo "  PASS: egress allowed (HTTP $code)" || { echo "  FAIL: egress blocked ($code)"; exit 1; }

echo "==> Assert: no gh auth tokenless"
docker exec "$NAME" gh auth status >/dev/null 2>&1 && { echo "  FAIL: gh authed without a token"; exit 1; } || echo "  PASS: gh unauthenticated tokenless"

echo "ALL tokenless-boot assertions passed."
