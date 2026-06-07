#!/usr/bin/env bash
# test-squid-selfheal.sh — verify the entrypoint supervision loop respawns squid after a crash
# and does NOT duplicate the access.log->audit tailer. Runs on the WSL HOST (needs docker). Uses
# the EXISTING image with the new entrypoint bind-mounted + a throwaway auth volume; never
# touches claude-box.
#
#   IMAGE=claude-box:latest ./tests/test-squid-selfheal.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-claude-box:latest}"
NAME="squid-selfheal-test-$$"
VOL="squid-selfheal-auth-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

squid_up() { docker exec "$NAME" bash -c 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/3128"' 2>/dev/null; }
tailer_count() { docker exec "$NAME" pgrep -xc tail 2>/dev/null || true; }

echo "==> Booting container off $IMAGE (new entrypoint bind-mounted, fresh empty auth volume)"
docker run -d --name "$NAME" \
  -e GIT_USER_EMAIL="t@e.st" -e GIT_USER_NAME="Tester" \
  -v "$VOL:/home/claude/.claude-auth" \
  -v "$REPO/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
  -v "$REPO/scripts/agent-lib.sh:/usr/local/bin/agent-lib.sh:ro" \
  -v "$REPO/scripts/agent-config-sync:/usr/local/bin/agent-config-sync:ro" \
  -v "$REPO/scripts/render-squid-conf:/usr/local/bin/render-squid-conf:ro" \
  "$IMAGE" >/dev/null

echo "==> Wait for boot (entrypoint logs \"ready\")"
for i in $(seq 1 30); do
  docker exec "$NAME" grep -q '"action":"ready"' /audit/"$(date -u +%F)".jsonl 2>/dev/null && break
  sleep 1
done

echo "==> Assert: squid listening on 3128 at boot"
squid_up && echo "  PASS: squid up at boot" || { echo "  FAIL: squid not up at boot"; exit 1; }

echo "==> Assert: exactly one access.log tailer at boot"
n="$(tailer_count)"
[[ "$n" == "1" ]] && echo "  PASS: one tailer" || { echo "  FAIL: expected 1 tailer, found $n"; exit 1; }

echo "==> Kill squid (exact-match, leaving the tailer alone) to simulate the 5.x crash"
docker exec "$NAME" sudo pkill -x squid || true
for i in $(seq 1 10); do squid_up || break; sleep 1; done
squid_up && { echo "  FAIL: squid still up after kill"; exit 1; } || echo "  PASS: squid down after kill"

echo "==> Assert: watchdog respawns squid within ~15s"
up=0
for i in $(seq 1 15); do squid_up && { up=1; break; }; sleep 1; done
[[ "$up" == "1" ]] && echo "  PASS: squid respawned" || { echo "  FAIL: squid did not come back"; exit 1; }

echo "==> Assert: still exactly one tailer after respawn (duplicate-tailer guard)"
n="$(tailer_count)"
[[ "$n" == "1" ]] && echo "  PASS: still one tailer" || { echo "  FAIL: expected 1 tailer after respawn, found $n"; exit 1; }

echo "==> Assert: a restart was recorded in the audit log"
docker exec "$NAME" grep -q '"src":"squid-watchdog","action":"restart"' /audit/"$(date -u +%F)".jsonl \
  && echo "  PASS: restart logged" || { echo "  FAIL: no squid-watchdog restart in audit log"; exit 1; }

echo "ALL squid self-heal assertions passed."
