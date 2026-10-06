# Real pnpm versions on a filesystem separate from the runner workspace.
FROM node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6
RUN npm install --prefix /opt/pnpm10 --ignore-scripts --no-audit --no-fund pnpm@10.32.1 \
 && npm install --prefix /opt/pnpm11 --ignore-scripts --no-audit --no-fund pnpm@11.28.0
