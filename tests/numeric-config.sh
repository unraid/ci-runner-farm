#!/usr/bin/env bash
# The web-written cfg is untrusted input, and most of its numeric keys land in
# arithmetic contexts where bash evaluates the variable's contents. load_cfg must
# shape-check those keys, keep the built-in default when a value fails, and leave
# every non-numeric key assigned verbatim.
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Print a labeled failure message to stderr and abort the test script.
fail() { printf 'NUMERIC CONFIG FAIL: %s\n' "$*" >&2; exit 1; }

(
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/cfg" CRF_RUNDIR="$tmp/run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  # Write each argument as its own line to $CFG (resolved under CRF_CFGDIR), so
  # load_cfg can be driven directly against a scratch cfg file.
  write_cfg() { printf '%s\n' "$@" > "$CFG"; }

  # A command substitution in an array-subscript shape is what makes this a code
  # execution bug rather than a typo: $(( RUNNER_COUNT + 1 )) would run it. The
  # value must be rejected and the built-in default must survive.
  canary="$tmp/canary"
  write_cfg "RUNNER_COUNT=\"a[\$(touch $canary)]\""
  load_cfg 2>/dev/null
  [ "$RUNNER_COUNT" = 4 ] || fail "crafted RUNNER_COUNT was assigned: '$RUNNER_COUNT'"
  [ "$(( RUNNER_COUNT + 1 ))" = 5 ] || fail "RUNNER_COUNT is not usable as an integer"
  if [ -e "$canary" ]; then fail "crafted RUNNER_COUNT reached an arithmetic context"; fi

  # The diagnostic names the key on stderr and never echoes the value back. It
  # cannot go through log(), which is defined after load_cfg's first invocation.
  write_cfg 'MIRROR_PORT="$(id -u)"'
  load_cfg 2>"$tmp/diag"
  [ "$(cat "$tmp/diag")" = "load_cfg: ignoring non-numeric MIRROR_PORT" ] \
    || fail "unexpected load_cfg diagnostic: '$(cat "$tmp/diag")'"
  [ "$MIRROR_PORT" = 5000 ] || fail "crafted MIRROR_PORT was assigned: '$MIRROR_PORT'"

  # Every numeric key is guarded, not just the two probed above.
  for key in $CFG_NUMERIC_KEYS; do
    printf -v "$key" '%s' sentinel
    write_cfg "$key=\"a[\$(id -u)]\""
    load_cfg 2>/dev/null
    [ "${!key}" = sentinel ] || fail "$key accepted a non-numeric value: '${!key}'"
  done

  # Leading zeros are rejected (invalid in the generated GitLab TOML, and octal
  # to some arithmetic paths), but a bare 0 is a shipped default and must load.
  AUTOSCALE_MIN=2; GITLAB_SHM_SIZE=1
  write_cfg 'AUTOSCALE_MIN="07"' 'GITLAB_SHM_SIZE="0"'
  load_cfg 2>/dev/null
  [ "$AUTOSCALE_MIN" = 2 ] || fail "leading-zero AUTOSCALE_MIN was assigned: '$AUTOSCALE_MIN'"
  [ "$GITLAB_SHM_SIZE" = 0 ] || fail "a bare 0 must remain a valid numeric value"

  # Well-formed values still load, and the autoscale_tick arithmetic is unchanged.
  write_cfg \
    'RUNNER_COUNT="6"' \
    'AUTOSCALE_MIN_IDLE="3"' \
    'AUTOSCALE_STEP="2"' \
    'AUTOSCALE_MAX="16"' \
    'AUTOSCALE_IDLE_GRACE="5"'
  load_cfg 2>/dev/null || fail "a well-formed numeric cfg was rejected"
  [ "$RUNNER_COUNT" = 6 ] || fail "RUNNER_COUNT did not load: '$RUNNER_COUNT'"
  [ "$(( RUNNER_COUNT + AUTOSCALE_STEP ))" = 8 ] \
    || fail "autoscale grow-target arithmetic changed"
  [ "$(( AUTOSCALE_MIN_IDLE + AUTOSCALE_STEP ))" = 5 ] \
    || fail "autoscale shrink-threshold arithmetic changed"

  # Non-numeric keys are untouched by the guard and still assigned verbatim.
  write_cfg 'RUNNER_LABELS="self-hosted,unraid,gpu"' 'RUNNER_CPUS="2.5"' 'RUNNER_MEMORY="16g"'
  load_cfg 2>/dev/null
  [ "$RUNNER_LABELS" = "self-hosted,unraid,gpu" ] || fail "RUNNER_LABELS was not assigned verbatim"
  [ "$RUNNER_CPUS" = "2.5" ] || fail "RUNNER_CPUS must still accept a decimal"
  [ "$RUNNER_MEMORY" = "16g" ] || fail "RUNNER_MEMORY must still accept a unit suffix"
) || exit 1

# The autoscale anti-flap counter is read back from a file into the same kind of
# arithmetic context, so it carries the identical guard — proven here by driving
# autoscale_tick itself rather than grepping for the guard's source text.
(
  export CRF_SOURCE_ONLY=1 CRF_CFGDIR="$tmp/autoscale-cfg" CRF_RUNDIR="$tmp/autoscale-run"
  mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
  # shellcheck source=/dev/null
  source "$ENGINE"

  # Shape the fleet so the shrink branch runs every tick: idle comfortably above
  # the min+step buffer, current above the floor. That's the only branch that
  # reads the persisted counter into `over + 1` arithmetic.
  AUTOSCALE=true AUTOSCALE_MIN=1 AUTOSCALE_MAX=10 AUTOSCALE_MIN_IDLE=1 \
    AUTOSCALE_STEP=1 AUTOSCALE_IDLE_GRACE=5
  # Stub out reaping so the tick can't be short-circuited by real container state.
  reap_dead_runners() { return 0; }
  # Stub the provider query autoscale_tick reads fleet counts from: 3 running, all idle.
  provider_call() { cur=3; busy=0; idle=3; return 0; }
  # Stub out stale-runner reconciliation; irrelevant to the counter guard under test.
  reconcile_stale_runners() { :; }

  statef="$CRF_RUNDIR/autoscale.state"
  canary="$tmp/autoscale-canary"

  printf 'not-a-number\n' > "$statef"
  autoscale_tick || fail "autoscale_tick rejected a malformed persisted counter"
  [ "$(cat "$statef")" = 1 ] || fail "malformed 'over' counter did not restart at 0: '$(cat "$statef")'"

  # Leading zeros are rejected the same as in load_cfg (bash treats them as octal).
  printf '007\n' > "$statef"
  autoscale_tick || fail "autoscale_tick rejected a leading-zero persisted counter"
  [ "$(cat "$statef")" = 1 ] || fail "leading-zero 'over' counter did not restart at 0: '$(cat "$statef")'"

  # An array-subscript shape is what turns 'over + 1' into code execution: bash
  # runs a $(...) inside an array subscript even in an otherwise-arithmetic context.
  printf 'a[$(touch %s)]\n' "$canary" > "$statef"
  autoscale_tick || fail "autoscale_tick rejected a crafted persisted counter"
  [ "$(cat "$statef")" = 1 ] || fail "crafted 'over' counter did not restart at 0: '$(cat "$statef")'"
  if [ -e "$canary" ]; then fail "crafted 'over' counter reached an arithmetic context"; fi
) || exit 1

echo "numeric-config: OK — numeric cfg keys are shape-checked before assignment."
