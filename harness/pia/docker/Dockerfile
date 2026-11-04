FROM node:24-bookworm

# Install python, pip, ripgrep, fd-find, htop, jq and tshark.
# jq is used by the agent skills (and agents themselves) to parse JSON API
# responses, e.g. the github-proxy and tasks-server skills pipe curl into jq.
# tshark backs 'pia monitor': it reads the TLS ServerNameIndication and the
# cleartext HTTP requests leaving the container. Capture only needs CAP_NET_RAW,
# which Docker grants by default, so no extra capabilities are required.
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends python3 python3-pip ripgrep fd-find htop jq tshark && \
    rm -rf /var/lib/apt/lists/*

# Debian ships python3 only; symlink 'python' (and 'pip') to python3/pip3 so
# scripts and agents can call 'python' too. A symlink on PATH beats a bash
# alias: it also works in non-interactive shells ('docker exec', tool calls).
RUN ln -s "$(command -v python3)" /usr/local/bin/python && \
    ln -s "$(command -v pip3)" /usr/local/bin/pip

# Install Docker CLI (client only). No daemon runs in this image: with
# 'pia run --docker' the host Docker socket is mounted and the CLI talks to
# the host daemon (see harness/pia/README.md).
ARG DOCKER_CLI_VERSION=29.9.2
RUN set -eux; \
    darch="$(dpkg --print-architecture)"; \
    case "$darch" in \
        amd64) darch=x86_64 ;; \
        arm64) darch=aarch64 ;; \
        *) echo "unsupported architecture: $darch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${darch}/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/docker-cli.tgz; \
    tar -xzf /tmp/docker-cli.tgz -C /tmp; \
    mv /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker-cli.tgz; \
    docker --version

# Install Docker Compose v2 as a CLI plugin, so agents can run 'docker compose'
# against the host daemon via 'pia run --docker' — e.g. to bring up a project's
# own docker-compose.yml stack from /workspace.
ARG DOCKER_COMPOSE_VERSION=5.6.1
RUN set -eux; \
    carch="$(dpkg --print-architecture)"; \
    case "$carch" in \
        amd64) carch=x86_64 ;; \
        arm64) carch=aarch64 ;; \
        *) echo "unsupported architecture: $carch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${carch}"; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    curl -fsSL "$url.sha256" -o /tmp/docker-compose.sha256; \
    echo "$(cut -d' ' -f1 /tmp/docker-compose.sha256)  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c -; \
    rm -f /tmp/docker-compose.sha256; \
    chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose; \
    docker compose version

# Install pi globally (ignore-scripts disables lifecycle scripts)
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# Create agent and skill folder
RUN mkdir -p /root/.pi/agent/skills

# Install playwright CLI + skills
RUN npm install -g @playwright/cli@latest && \
    playwright-cli install --skills && \
    cp -r .claude/skills/* /root/.pi/agent/skills && \
    rm -r .claude && \
    echo y | npx playwright install-deps

# Install playwright browser
RUN mkdir -p /root/.playwright
RUN playwright-cli install-browser chromium

# Add config
COPY harness/pia/configs/settings.json /root/.pi/agent/settings.json
COPY harness/pia/configs/models.json /root/.pi/agent/models.json
COPY harness/pia/configs/cli.config.json /root/.playwright/cli.config.json

# Copy agent skills
COPY skills/ /root/.pi/agent/skills/

# Keep-alive entrypoint: the container idles, and the pia CLI attaches pi via
# 'docker exec -it <name> pi [--continue]' for both 'pia run' and 'pia rs'.
# This lets 'pia rs' revive a stopped container (docker start takes no
# arguments) and continue the last pi session. Direct docker usage: 'docker
# run -it pia pi [args]'.
COPY harness/pia/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Traffic + resource sampler used by 'pia monitor' (called via docker exec).
COPY harness/pia/docker/monitor-inside.sh /usr/local/bin/pia-monitor
RUN chmod +x /usr/local/bin/pia-monitor

# Create workspace directory
WORKDIR /workspace

ENTRYPOINT ["entrypoint.sh"]