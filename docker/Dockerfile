# Base image pinned by digest (linux/amd64 manifest) for reproducible builds.
# node:22-bookworm-slim, resolved 2026-09-23.
FROM node:22-bookworm-slim@sha256:43aeff40f4afc22e83f7589a2f37e111cff5ca84529571f1c8415bcc5fcc21b2

# xdg-open shim ----------------------------------------------------------
# opencode web tries to spawn xdg-open to launch a browser. That
# binary is not present in node:22-bookworm-slim; Bun's spawn throws
# ENOENT and the process exits. A no-op shim that returns 0 lets
# opencode proceed to serve; the actual client is the host browser.
#   https://www.freedesktop.org/wiki/Software/xdg-utils/
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/xdg-open \
    && chmod +x /usr/local/bin/xdg-open


RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates coreutils python3 sqlite3 tesseract-ocr \
    && apt-get clean

RUN chmod 777 /home/node && \
    mkdir -p /home/node/.config/opencode /home/node/.cache && \
    chmod -R 777 /home/node/.config /home/node/.cache

USER root
RUN echo "npm before: $(npm --version)" && \
    npm install -g npm@10 && \
    echo "npm after:  $(npm --version)"

USER node
RUN curl -fsSL https://opencode.ai/install | bash -s -- --version 1.18.32
ENV PATH="/home/node/.opencode/bin:${PATH}"
ENV OPENCODE_DISABLE_DEFAULT_PLUGINS=true
RUN echo "installing jev-guard@0.3.1" && \
    opencode plugin jev-guard@0.3.1 --global

USER root
RUN git clone https://github.com/NiazMorshed2007/jev-review.git /opt/jev-review
WORKDIR /opt/jev-review
RUN git checkout 3fb6042ebf07f0fdaae30d65c6393848e1a549e3
RUN echo "npm in jev-review: $(npm --version)" && npm ci
RUN npm run build
RUN ls -la /opt/jev-review/dist/server.js
RUN chown -R node:node /opt/jev-review

WORKDIR /workspace
USER node
ENTRYPOINT ["opencode"]
