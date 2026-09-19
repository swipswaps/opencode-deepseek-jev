FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    && apt-get clean

USER root
RUN echo "npm before: $(npm --version)" && \
    npm install -g npm@10 && \
    echo "npm after:  $(npm --version)"

USER node
RUN curl -fsSL https://opencode.ai/install | bash
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
