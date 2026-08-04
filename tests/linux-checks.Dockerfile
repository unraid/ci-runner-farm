# Reproducible Linux check environment for macOS and other non-Unraid hosts.
# Build context is the repository root; tests/run-linux-checks.sh drives it.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      coreutils \
      diffutils \
      findutils \
      git \
      gzip \
      php-cli \
      python3 \
      sed \
      tar \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace
RUN bash tests/check.sh
