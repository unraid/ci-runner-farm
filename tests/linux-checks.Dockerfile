# Reproducible Linux check environment for macOS and other non-Unraid hosts.
# Build context is the repository root; tests/run-linux-checks.sh drives it.
FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea

ENV DEBIAN_FRONTEND=noninteractive
# The minimal Ubuntu image has no CA bundle. Bootstrap that one package from
# signed snapshot metadata, then require normal TLS verification for everything
# else. Both archive/security and ports images resolve through this fixed URL.
RUN sed -Ei \
      's#https?://(archive\.ubuntu\.com|security\.ubuntu\.com)/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/20260801T000000Z/#; s#http://ports\.ubuntu\.com/ubuntu-ports/?#https://snapshot.ubuntu.com/ubuntu/20260801T000000Z/#' \
      /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get -o Acquire::https::Verify-Peer=false update \
 && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
      ca-certificates=20260601~24.04.1 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bash=5.2.21-2ubuntu4 \
      coreutils=9.4-3ubuntu6.2 \
      diffutils=1:3.10-1build1 \
      findutils=4.9.0-5build1 \
      git=1:2.43.0-1ubuntu7.3 \
      gzip=1.12-1ubuntu3.2 \
      php-cli=2:8.3+93ubuntu2 \
      python3=3.12.3-0ubuntu2.1 \
      sed=4.9-2ubuntu0.24.04.1 \
      tar=1.35+dfsg-3ubuntu0.4 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace
RUN bash tests/check.sh
