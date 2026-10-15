#!/usr/bin/env bash
# Under storage pressure only the current job's checkout survives the job hook.
set -euo pipefail
cd "$(dirname "$0")/.."
hook="$PWD/src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-job-cleanup.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export PATH="$tmp/bin:$PATH"
export GITHUB_ACTIONS=true GITHUB_RUN_ID=123456 GITHUB_RUN_ATTEMPT=1 CRF_JOB_CLEANUP_DIND=1
export RUNNER_WORKDIR="$tmp/work" GITHUB_WORKSPACE="$tmp/work/core/core"
cat > "$tmp/bin/df" <<'MOCK'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
case "$WS_TEST_MODE" in
 pressure) echo 'cache 1000 950 50 95% /_work' ;;
 malformed) echo 'cache unknown 950 50 95% /_work' ;;
 *) echo 'cache 1000 700 300 70% /_work' ;;
esac
MOCK
# Docker is irrelevant to workspaces; its failure must not block this pass.
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/docker"
chmod +x "$tmp/bin/"*

seed() {
  rm -rf "$RUNNER_WORKDIR"; mkdir -p "$RUNNER_WORKDIR"/{core/core,account/account,beam/beam,_actions,_temp,_tool}
  mkdir -p "$tmp/outside"; ln -s "$tmp/outside" "$RUNNER_WORKDIR/linked"
}
left() { (cd "$RUNNER_WORKDIR" && printf '%s\n' * | sort | tr '\n' ' '); }
run() { export WS_TEST_MODE="$1"; bash "$hook" > "$tmp/output" 2>&1; }

kept='_actions _temp _tool account beam core linked '
seed; run healthy; [ "$(left)" = "$kept" ]
seed; run malformed; [ "$(left)" = "$kept" ]
seed; run pressure; [ "$(left)" = '_actions _temp _tool core linked ' ]
[ -d "$tmp/outside" ]
grep -q 'removed idle workspace checkout' "$tmp/output"
# An interrupted earlier pass is finished even without pressure.
seed; mkdir -p "$RUNNER_WORKDIR/_crf-trash-1-2-old/x"; run healthy; [ "$(left)" = "$kept" ]
# Without a recognizable current workspace nothing is renamed.
seed; GITHUB_WORKSPACE=/elsewhere run pressure; [ "$(left)" = "$kept" ]
# Unsafe or unresolvable work roots are refused before any rename.
seed
for root in '' / relative "$tmp/work/../work" "$tmp/work/linked"; do
 RUNNER_WORKDIR="$root" run pressure; grep -q 'workspace cleanup incomplete' "$tmp/output"
done
[ "$(left)" = "$kept" ]
seed; CRF_JOB_CLEANUP_DIND=0 run pressure; [ "$(left)" = "$kept" ]
echo 'job workspace pressure: only the current checkout kept, runner state and links preserved PASS'
