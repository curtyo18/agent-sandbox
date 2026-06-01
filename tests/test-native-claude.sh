#!/usr/bin/env bash
# test-native-claude.sh — verify the image installs Claude via the native standalone
# installer (not npm-global): the binary lives in the claude-owned ~/.local, resolves on
# PATH, the npm global package is absent, and the safety wrappers stay root-owned.
# Runs on the HOST (needs docker). Requires a FRESHLY BUILT image (the install is baked at
# build time and cannot be bind-mounted).
#
#   IMAGE=claude-box:native-test ./tests/test-native-claude.sh
set -euo pipefail
IMAGE="${IMAGE:-claude-box:latest}"
NAME="native-claude-test-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Booting container off $IMAGE"
docker run -d --name "$NAME" --entrypoint sleep "$IMAGE" infinity >/dev/null

echo "==> Assert: claude resolves to the native ~/.local binary"
path=$(docker exec --user claude "$NAME" bash -lc 'command -v claude')
[[ "$path" == "/home/claude/.local/bin/claude" ]] \
  && echo "  PASS: claude at $path" \
  || { echo "  FAIL: claude resolved to '$path' (expected /home/claude/.local/bin/claude)"; exit 1; }

echo "==> Assert: claude --version runs"
ver=$(docker exec --user claude "$NAME" bash -lc 'claude --version' 2>/dev/null || true)
[[ -n "$ver" ]] \
  && echo "  PASS: $ver" \
  || { echo "  FAIL: claude --version produced no output"; exit 1; }

echo "==> Assert: npm-global claude package is absent"
docker exec "$NAME" test ! -e /usr/local/lib/node_modules/@anthropic-ai/claude-code \
  && echo "  PASS: no npm-global claude-code" \
  || { echo "  FAIL: npm-global claude-code still present"; exit 1; }

echo "==> Assert: safety wrappers still root-owned"
owner=$(docker exec "$NAME" stat -c '%U' /usr/local/bin/git)
[[ "$owner" == "root" ]] \
  && echo "  PASS: /usr/local/bin/git owned by root" \
  || { echo "  FAIL: /usr/local/bin/git owned by '$owner' (expected root)"; exit 1; }

echo "ALL native-claude assertions passed."
