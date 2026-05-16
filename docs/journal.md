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

## Host-side gotchas (not in this repo's code, but bit us)

- **BIOS virtualization off by default.** AMD CPUs need SVM Mode enabled in BIOS (Gigabyte: Tweaker → Advanced CPU Settings). WSL2 fails with `HCS_E_HYPERV_NOT_INSTALLED` until this is on.
- **WSL Store-package install gets stuck.** After enabling WSL features + reboot, the kernel update can wedge with `0x80070652` ("another install in progress"). Recovery: `Stop-Process -Force` any lingering `msiexec`, then `wsl --update` succeeds.
- **`gh auth setup-git` is not automatic.** `gh auth login --with-token` populates gh's token but doesn't wire gh as a git credential helper. Private-repo `git clone` then hangs at `Username for 'https://github.com':`. Run `gh auth setup-git` once after auth to fix.
- **PowerShell `Set-Content -Encoding utf8` writes a BOM.** Bash treats the BOM as garbage on the first line, breaking `set -e` and similar. When generating shell scripts from PowerShell, use `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))`.
- **Editing files via `\\wsl.localhost\…` UNC paths strips the executable bit.** Always `chmod +x` after editing a script through the UNC bridge.
