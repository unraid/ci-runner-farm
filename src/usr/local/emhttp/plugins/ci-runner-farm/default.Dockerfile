# ci-runner-farm runner image (starter). Edit this from the plugin UI
# (Settings -> Utilities -> CI Runner Farm -> Runner image builder), then Build,
# and point the IMAGE setting at the resulting tag.
#
# This is a minimal starting point: the stock self-hosted runner base plus a
# docker-in-docker readiness wrapper. Add whatever your CI needs (language
# runtimes, browsers, build tools) in the marked section below.
FROM myoung34/github-runner:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive

# --- Add your packages / tools here ---
# RUN apt-get update && apt-get install -y --no-install-recommends <your-packages> \
#  && rm -rf /var/lib/apt/lists/*

# DinD: the base entrypoint starts dockerd (START_DOCKER_SERVICE=true) but does
# NOT wait for it to be ready. Wrap the runner CMD so it waits for docker before
# the runner accepts jobs — otherwise 'Checking docker version'/services: race a
# cold daemon.
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# supervise dockerd: it can die under the services: workload (nested overlay)' \
  '( while true; do docker info >/dev/null 2>&1 || { rm -f /var/run/docker.pid; service docker start >>/var/log/dockerd.log 2>&1; }; sleep 3; done ) &' \
  '# wait for first readiness before the runner accepts jobs' \
  'for i in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 1; done' \
  'exec "$@"' \
  > /usr/local/bin/wait-docker.sh \
 && chmod +x /usr/local/bin/wait-docker.sh
CMD ["/usr/local/bin/wait-docker.sh", "./bin/Runner.Listener", "run", "--startuptype", "service"]
