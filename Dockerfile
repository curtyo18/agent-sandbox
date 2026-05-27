FROM node:lts-bookworm

# System packages: gh CLI, squid, gitleaks (binary install via curl), python3, tini.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git git-lfs sudo \
        python3 python3-pip python3-venv pipx \
        squid \
        tini \
        jq \
        tmux \
        tzdata \
        rsync \
        procps && \
    rm -rf /var/lib/apt/lists/*

# gh CLI from official keyring + apt repo.
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# gitleaks (binary release; check latest on https://github.com/gitleaks/gitleaks/releases)
ARG GITLEAKS_VERSION=8.21.2
RUN curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks

# Claude Code CLI.
RUN npm install -g @anthropic-ai/claude-code

# Non-root user. `node:lts-bookworm` base ships a `node` user/group at UID/GID 1000 —
# delete it so we can reuse 1000 for `claude` (matches host curt UID for bind-mount ownership).
ARG UID=1000
ARG GID=1000
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g ${GID} claude && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash claude && \
    mkdir -p /home/claude/.claude /home/claude/.claude-auth /home/claude/.config /audit /projects && \
    chown -R claude:claude /home/claude /audit /projects

# Wrappers + entrypoint + squid template — copied from the repo at build time.
COPY wrappers/gh                          /usr/local/bin/gh
COPY wrappers/git-audit-wrapper           /usr/local/bin/git-audit-wrapper
COPY wrappers/audit-shell.sh              /usr/local/bin/audit-shell.sh
COPY wrappers/git                         /usr/local/bin/git
COPY wrappers/rm                          /usr/local/bin/rm
COPY wrappers/rmdir                       /usr/local/bin/rmdir
COPY squid.conf.template                  /etc/squid/squid.conf.template
COPY entrypoint.sh                        /usr/local/bin/entrypoint.sh
COPY scripts/clip                         /usr/local/bin/clip
COPY scripts/paste                        /usr/local/bin/paste
COPY scripts/life-bot-launcher.py         /usr/local/bin/life-bot-launcher.py
RUN chmod 0755 /usr/local/bin/gh \
               /usr/local/bin/git \
               /usr/local/bin/git-audit-wrapper \
               /usr/local/bin/audit-shell.sh \
               /usr/local/bin/entrypoint.sh \
               /usr/local/bin/clip \
               /usr/local/bin/life-bot-launcher.py \
               /usr/local/bin/rm \
               /usr/local/bin/rmdir \
               /usr/local/bin/paste

# Environment: timezone, proxy for all HTTPS-aware tools.
ARG TZ=Europe/London
ENV TZ=${TZ} \
    HTTP_PROXY=http://127.0.0.1:3128 \
    HTTPS_PROXY=http://127.0.0.1:3128 \
    NO_PROXY=127.0.0.1,localhost \
    BASH_ENV=/usr/local/bin/audit-shell.sh \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

# Passwordless sudo for the claude user.
# Originally an allowlist of /usr/sbin/squid, /bin/bash, /usr/bin/tail, /bin/cp — but having
# /bin/bash in the list means `sudo bash -c '<anything>'` already grants full root, so the
# allowlist was friction without security. Made it honest: NOPASSWD: ALL.
# The real safety envelope is the container boundary (squid allowlist, bind-mount scope, gh
# wrapper, secret-scan hook). Those still apply regardless of in-container root.
RUN echo 'claude ALL=(root) NOPASSWD: ALL' > /etc/sudoers.d/claude && \
    chmod 440 /etc/sudoers.d/claude

USER claude
WORKDIR /projects

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
