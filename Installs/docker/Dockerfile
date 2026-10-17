# =============================================================================
# AI Cockpit — Docker image
# Apache + PHP 8.3 + tmux + Node (Claude Code CLI, Gemini CLI) + Ollama + LocalAI.
#
# Ollama runs INSIDE this same container, not as a separate one — the app's
# PHP backends call it at a hardcoded http://127.0.0.1:11434 in several files
# (e.g. caveman.php), not an env-configurable host, so a split container
# would silently fail to reach it. Bundling it here is the correct choice
# for the code as it exists today, not a simplification.
#
# LocalAI is bundled the same way, for the same reason — Power Combos can
# now run against LocalAI (or a dual Ollama+LocalAI combo) via
# combos_localai_base(), which similarly assumes 127.0.0.1:8080 by default.
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_MAJOR=20 \
    COCKPIT_USER=cockpit \
    COCKPIT_HOME=/home/cockpit

# ── System packages ─────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        php8.3 php8.3-cli php8.3-xml php8.3-curl php8.3-mbstring php8.3-zip \
        libapache2-mod-php8.3 \
        tmux jq curl wget ca-certificates gnupg \
        git util-linux unzip iputils-ping zstd sudo \
        ffmpeg pandoc imagemagick poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js (for Claude Code CLI + Gemini CLI) ──────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code @google/gemini-cli

# ── Ollama (official install script — runs in-process on 127.0.0.1:11434) ──
RUN curl -fsSL https://ollama.com/install.sh | sh

# ── LocalAI (no official install script like Ollama's — fetch the real
#    GitHub release binary directly, checksum-verified, matching the exact
#    build/version this app was tested against. Runs on 127.0.0.1:8080). ──
ENV LOCALAI_VERSION=v4.7.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) bin=local-ai-${LOCALAI_VERSION}-linux-amd64; sha=2a4ccf4cd7ecc76fb6dde8d847a6d1448b67d7cf84fdcb4285cd002f42a9c801 ;; \
        arm64) bin=local-ai-${LOCALAI_VERSION}-linux-arm64; sha=6cb39eb765ca005aad6ad3e4c34197406d46f5b7700c5c9a8c543b35847db553 ;; \
        *) echo "unsupported architecture for LocalAI: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/local-ai "https://github.com/mudler/LocalAI/releases/download/${LOCALAI_VERSION}/${bin}"; \
    echo "${sha}  /tmp/local-ai" | sha256sum -c -; \
    install -m 0755 /tmp/local-ai /usr/local/bin/local-ai; \
    rm /tmp/local-ai

# ── Non-root user the tmux sessions and web files run as ───────────────────
RUN useradd -m -s /bin/bash ${COCKPIT_USER}

# ── Cockpit web app ─────────────────────────────────────────────────────────
# COCKPIT_EDITION picks which tarball's web/ folder to bake in — v2 (full,
# SaaS/Marketplace/remote control) or v1 (no-account, fully local, zero
# network calls to our server). Stage both as ./v2/web/ and ./v1/web/ next
# to this Dockerfile (see README) and select at build time:
#   docker compose build --build-arg COCKPIT_EDITION=v1
# Defaults to v2 — matches every other install path's default.
ARG COCKPIT_EDITION=v2
COPY --chown=${COCKPIT_USER}:www-data ${COCKPIT_EDITION}/web/ /var/www/html/cockpit/
RUN mkdir -p /var/www/html/cockpit/queue /var/www/html/cockpit/responses \
    && chown -R ${COCKPIT_USER}:www-data /var/www/html/cockpit \
    && chmod -R u+rwX,g+rwX /var/www/html/cockpit

# ── Cockpit data dir (Library / Snippets / Sources / Code / Approvals) ──────
RUN mkdir -p ${COCKPIT_HOME}/scripts/cockpit_data/{library,snippets,sources,code,approvals} \
    && chown -R ${COCKPIT_USER}:www-data ${COCKPIT_HOME}/scripts \
    && chmod -R 775 ${COCKPIT_HOME}/scripts

# ── Ollama models dir — mounted as a volume so pulled models survive
#    container rebuilds (re-pulling multi-GB models every rebuild is painful)
ENV OLLAMA_MODELS=${COCKPIT_HOME}/ollama/models
RUN mkdir -p ${OLLAMA_MODELS} && chown -R ${COCKPIT_USER}:${COCKPIT_USER} ${COCKPIT_HOME}/ollama

# ── LocalAI models dir — same reasoning, same pattern ───────────────────────
ENV LOCALAI_MODELS=${COCKPIT_HOME}/localai/models
RUN mkdir -p ${LOCALAI_MODELS} && chown -R ${COCKPIT_USER}:${COCKPIT_USER} ${COCKPIT_HOME}/localai

# Apache: allow www-data to run tmux/agent scripts as the cockpit user without
# a password — same NOPASSWD pattern install_cockpit.sh sets up on bare metal,
# just scoped to root-in-container instead of a real sudoers file dance.
RUN echo "www-data ALL=(${COCKPIT_USER}) NOPASSWD: ALL" > /etc/sudoers.d/cockpit \
    && chmod 0440 /etc/sudoers.d/cockpit

COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
