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

# Health probe so ci-runner-farm can reap a runner whose GitHub registration was
# removed: its listener then loops forever on "Registration was not found /
# Retrying until reconnected" instead of exiting, so it never gets recycled and
# silently counts as idle capacity. Reports unhealthy ONLY in that stuck state —
# never a runner that is running a job or still starting.
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  '# Running a job => healthy, unconditionally (never interrupt a build).' \
  'pgrep -x Runner.Worker >/dev/null 2>&1 && exit 0' \
  '# No listener => nothing services jobs; recycle it.' \
  'pgrep -x Runner.Listener >/dev/null 2>&1 || exit 1' \
  '# Idle: require positive proof of a live session in the newest listener log.' \
  'log="$(ls -1t /actions-runner/_diag/Runner_*.log 2>/dev/null | head -1)"' \
  '[ -n "$log" ] || exit 0   # too early to tell; --start-period covers startup' \
  'last="$(grep -niE "Session created|Listening for Jobs|create session|connect error|Registration.*not found|has been removed|SessionConflict|SessionExpired|Retrying until reconnected|Runner listener exit" "$log" 2>/dev/null | tail -1)"' \
  'case "$last" in' \
  '  *"Session created"*|*"Listening for Jobs"*) exit 0 ;;  # connected' \
  '  "") exit 0 ;;                                          # inconclusive -> healthy' \
  '  *) exit 1 ;;                                           # stuck disconnected' \
  'esac' \
  > /usr/local/bin/runner-healthcheck.sh \
 && chmod +x /usr/local/bin/runner-healthcheck.sh
HEALTHCHECK --start-period=120s --interval=30s --timeout=10s --retries=3 \
  CMD ["/usr/local/bin/runner-healthcheck.sh"]

CMD ["/usr/local/bin/wait-docker.sh", "./bin/Runner.Listener", "run", "--startuptype", "service"]
