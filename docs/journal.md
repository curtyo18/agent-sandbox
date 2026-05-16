# Bug journal

Issues found while bringing the sandbox up the first time. Capturing each so the next bootstrap doesn't re-discover them.

## In-repo bugs (fixed)

### 1. `node:lts-bookworm` base ships a `node` user at UID/GID 1000

**Symptom.** Docker build fails at `groupadd -g 1000 claude`:
```
groupadd: GID '1000' already exists
```

**Cause.** The base image already has a `node:node` user/group at 1000:1000.

**Fix.** Drop the existing user before creating `claude`. Now in `Dockerfile`:
```dockerfile
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g ${GID} claude && \
    ...
```

Why keep UID 1000 — bind-mounted files from the host show as UID 1000 inside the container; matching them avoids permission surprises.

### 2. HTTPS_PROXY chicken-and-egg in `entrypoint.sh`

**Symptom.** First-time container start: `FATAL: initial config clone failed`, squid bungled with `ACL not found: allowed_hosts`. Container alive but useless.

**Cause.** Image ENV sets `HTTPS_PROXY=http://127.0.0.1:3128` globally. The entrypoint's `git clone` of `agent-config` routes through that proxy. But squid isn't running yet — its config needs the allowlist, which lives in `agent-config`, which needs this clone.

**Fix.** Two parts in `entrypoint.sh`:
- `sync_config` clears proxy env for git: `HTTPS_PROXY="" HTTP_PROXY="" git clone ...`. Direct egress for the bootstrap clone. github.com would have been allowlisted anyway, so this matches policy.
- `render_squid_conf` writes a tombstone ACL (`acl allowed_hosts dstdomain .invalid-no-allowlist`) when no allowlist file is present, so squid still parses cleanly and the container stays usable for troubleshooting.

### 3. `/mnt/e/projects` vs `/mnt/e/Projects` case mismatch

**Symptom.** Container's `/projects` shows almost no files; user's repos missing.

**Cause.** WSL's 9p mount of Windows drives can expose `E:\projects` and `E:\Projects` as separate directories even though NTFS is case-insensitive at the filesystem level. `bootstrap.sh` originally hardcoded the lowercase path; reality on the host was capital P.

**Fix.** `bootstrap.sh` uses `/mnt/e/Projects` to match what's actually on disk. If your host uses a different layout, adjust `PROJECTS_HOST_PATH` at the top of `bootstrap.sh`.

### 4. `git core.hooksPath` never wired up

**Symptom.** Pre-commit secret-scan hook present at `/home/claude/.claude/hooks/pre-commit` but `git commit` of a `.env` file *succeeds* — hook never fires.

**Cause.** Git only runs hooks from `$GIT_DIR/hooks/` or from a path explicitly set in `core.hooksPath`. Just dropping the script in the right place isn't enough.

**Fix.** `entrypoint.sh` `sync_config` now runs:
```bash
git config --global core.hooksPath "$CONFIG_DIR/hooks"
```

after pulling agent-config. Verified by running `git commit` with a staged `.env` — hook fires, commit blocked with exit 50.

### 5. Container `git push` fails — no credential helper

**Symptom.** Inside the container, `git push` errors with `fatal: could not read Username for 'https://github.com': No such device or address`.

**Cause.** `entrypoint.sh` had wired the PAT into `/home/claude/.claude-auth/github-pat`, but never authed `gh` or set it up as the git credential helper. git pull was working only because the bootstrap clone uses a token-in-URL (`https://x-access-token:$PAT@…`); regular `git push` to an existing remote has no token in the URL and prompts for credentials.

**Fix.** `entrypoint.sh` now runs at every container start (idempotent):

```bash
if [[ -s "$AUTH_DIR/github-pat" ]] && ! gh auth status >/dev/null 2>&1; then
  cat "$AUTH_DIR/github-pat" | gh auth login --hostname github.com --git-protocol https --with-token
fi
gh auth setup-git
```

Also added a separate `claude-gh-config` Docker volume at `/home/claude/.config` so `gh`'s `hosts.yml` persists across container recreates (otherwise gh state lives outside the existing volumes and is wiped on every recreate).

### 6. New Docker volume mounts as root, not as the container user

**Symptom.** After adding the `claude-gh-config` volume, `gh auth login` failed with `mkdir /home/claude/.config/gh: permission denied`.

**Cause.** Docker named volumes inherit ownership from the image's mountpoint. If the path doesn't exist in the image (`/home/claude/.config` was not pre-created), Docker creates it owned by root when the volume mounts. The non-root container user can't write inside.

**Fix.** Add the path to the Dockerfile's `mkdir` before `chown`:

```dockerfile
RUN ... && \
    mkdir -p /home/claude/.claude /home/claude/.claude-auth /home/claude/.config /audit /projects && \
    chown -R claude:claude /home/claude /audit /projects
```

Now the path exists with claude ownership at image build time; the volume preserves that on first mount.

### 7. Claude Code wizard fires every container recreate

**Symptom.** Even though `claude auth status` reports `loggedIn: true`, every fresh container shows the "Select login method" first-run wizard and forces an OAuth round-trip.

**Cause.** The "wizard complete" marker isn't in `~/.claude/.credentials.json` or `~/.claude/settings.json` — it's `hasCompletedOnboarding: true` in **`~/.claude.json`** (note: file directly in `$HOME`, not under `.claude/`). That file is outside the `claude-cfg-cache` volume, so every container recreate wipes it.

**Fix.** `entrypoint.sh` now writes the marker on every start (merging into existing JSON if present):

```bash
python3 -c "
import json, os
p = '/home/claude/.claude.json'
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except: d = {}
d['hasCompletedOnboarding'] = True
json.dump(d, open(p, 'w'), indent=2)
"
```

See [anthropics/claude-code#4714](https://github.com/anthropics/claude-code/issues/4714).

### 8. Permission settings ignored — wrong file and wrong key

**Symptom.** `permissions.defaultMode: bypassPermissions` in `~/.claude/settings.local.json` did nothing — every Bash command still prompted.

**Cause.** Two distinct mistakes:
- Per [Claude Code docs](https://code.claude.com/docs/en/permissions), `settings.local.json` is a *project-level* override file (`<project>/.claude/settings.local.json`). At the **user** level (`~/.claude/`), only `settings.json` is read. `~/.claude/settings.local.json` is ignored entirely.
- The first version of the config had `permissionMode` at the top level. The correct path is `permissions.defaultMode` (nested under `permissions`).

**Fix.** Moved config back into `~/.claude/settings.json`, used the correct nested key, and additionally added `--dangerously-skip-permissions` to the CLI invocation as belt-and-suspenders (CLI flag bypasses settings.json drift entirely).

### 9. `--dangerously-skip-permissions` still shows accept dialog every launch

**Symptom.** Even with the CLI flag, the "WARNING: Claude Code running in Bypass Permissions mode — Yes, I accept / No" dialog appears on every session start.

**Cause.** The flag alone tells claude to bypass tool prompts, but the warning dialog about bypass mode itself is a separate prompt. It's only suppressed when `skipDangerousModePermissionPrompt: true` is persisted in `~/.claude/settings.json` (normally written when the user accepts the dialog once).

**Fix.** Added `"skipDangerousModePermissionPrompt": true` to `agent-config/settings.json`. See [anthropics/claude-code#25503](https://github.com/anthropics/claude-code/issues/25503).

## Host-side gotchas (not in this repo's code, but bit us)

- **BIOS virtualization off by default.** AMD CPUs need SVM Mode enabled in BIOS (Gigabyte: Tweaker → Advanced CPU Settings). WSL2 fails with `HCS_E_HYPERV_NOT_INSTALLED` until this is on.
- **WSL Store-package install gets stuck.** After enabling WSL features + reboot, the kernel update can wedge with `0x80070652` ("another install in progress"). Recovery: `Stop-Process -Force` any lingering `msiexec`, then `wsl --update` succeeds.
- **`gh auth setup-git` is not automatic.** `gh auth login --with-token` populates gh's token but doesn't wire gh as a git credential helper. Private-repo `git clone` then hangs at `Username for 'https://github.com':`. Run `gh auth setup-git` once after auth to fix.
- **PowerShell `Set-Content -Encoding utf8` writes a BOM.** Bash treats the BOM as garbage on the first line, breaking `set -e` and similar. When generating shell scripts from PowerShell, use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))`.
- **Editing files via `\\wsl.localhost\…` UNC paths strips the executable bit.** Always `chmod +x` after editing a script through the UNC bridge.
