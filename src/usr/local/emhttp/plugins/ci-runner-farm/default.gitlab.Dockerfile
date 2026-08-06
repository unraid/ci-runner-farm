# ci-runner-farm GitLab job image (starter). Edit this from the plugin UI,
# build it, and use the resulting tag as GitLab's default Docker-executor image.
# A job may override it with `image:` in .gitlab-ci.yml.
#
# This is deliberately a JOB image, not a GitLab Runner manager image. The farm
# runs the official gitlab/gitlab-runner image separately and asks it to launch
# one container from this image for each accepted job.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/runner

# A practical baseline for shell-based build scripts plus a Docker client for
# jobs that talk to the slot's private DinD daemon. Add project toolchains below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      docker.io \
      git \
      jq \
      openssh-client \
      unzip \
      zip \
 && rm -rf /var/lib/apt/lists/*

# --- Add your packages / tools here ---
# RUN apt-get update && apt-get install -y --no-install-recommends <your-packages> \
#  && rm -rf /var/lib/apt/lists/*

# Common cache destinations match the plugin's backwards-compatible cache-mount
# defaults. The image still runs as root, but HOME points at /home/runner so npm,
# cargo, yarn, pnpm, and similar tools naturally use the warm mounted paths.
RUN mkdir -p \
      /home/runner/.cargo/git \
      /home/runner/.cargo/registry \
      /home/runner/.cache/ms-playwright \
      /home/runner/.cache/sccache \
      /home/runner/.cache/yarn \
      /home/runner/.local/share/pnpm/store \
      /home/runner/.npm

WORKDIR /builds

# GitLab Runner supplies the job script; no runner daemon or custom entrypoint
# belongs in this image.
CMD ["/bin/bash"]
