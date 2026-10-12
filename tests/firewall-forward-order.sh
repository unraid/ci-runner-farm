#!/usr/bin/env bash
# Exercise packet outcomes when a VPN accepts traffic before Docker's hook.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CRF_CFGDIR="$tmp/config" CRF_RUNDIR="$tmp/run" CRF_SOURCE_ONLY=1
mkdir -p "$CRF_CFGDIR" "$CRF_RUNDIR"
# shellcheck source=/dev/null
source src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
export MOCK_FIREWALL="$tmp/rules.json"

cat > "$tmp/iptables.py" <<'PY'
import ipaddress
import json
import os
from pathlib import Path
import sys

state_file = Path(os.environ['MOCK_FIREWALL'])
args = sys.argv[1:]

def canonical(rule):
    rule = list(rule)
    index = rule.index('-j')
    target = rule[index:index + 2]
    del rule[index:index + 2]
    return rule + target

if args[0] == 'init':
    rules = {
        'FORWARD': [['-j', 'ts-forward'], ['-j', 'DOCKER-USER']],
        'ts-forward': [['-o', 'tailscale1', '-j', 'ACCEPT']],
        'DOCKER-USER': [
            ['-s', '172.31.0.0/16', '-d', '100.100.10.20/32', '-p', 'tcp',
             '--dport', '8333', '-m', 'comment', '--comment', 'ci-runner-farm:artifact', '-j', 'RETURN'],
        ],
        'INPUT': [],
    }
    # Preserve an old network alongside the current one and an unrelated rule.
    rules['DOCKER-USER'] = rules['DOCKER-USER'][:1] + [
        ['-s', subnet, '-d', '100.64.0.0/10', '-m', 'comment',
         '--comment', 'ci-runner-farm:cgnat', '-j', 'DROP']
        for subnet in ['172.30.0.0/16', '172.31.0.0/16']
    ] + [['-s', '192.0.2.0/24', '-d', '198.51.100.0/24', '-j', 'DROP']]
    state_file.write_text(json.dumps(rules))
    sys.exit(0)

rules = json.loads(state_file.read_text())
if args[0] == 'packet':
    source, destination, port, expected = args[1:]
    output_interface = ('tailscale1' if ipaddress.ip_address(destination) in
                        ipaddress.ip_network('100.64.0.0/10') else 'eth0')
    def visit(chain):
        for rule in rules.get(chain, []):
            fields = dict(zip(rule[::2], rule[1::2]))
            if '-o' in fields and fields['-o'] != output_interface:
                continue
            if '-s' in fields and ipaddress.ip_address(source) not in ipaddress.ip_network(fields['-s']):
                continue
            if '-d' in fields and ipaddress.ip_address(destination) not in ipaddress.ip_network(fields['-d']):
                continue
            if '--dport' in fields and fields['--dport'] != port:
                continue
            target = fields['-j']
            if target in ('ACCEPT', 'DROP', 'RETURN'):
                return target
            result = visit(target)
            if result != 'RETURN':
                return result
        return 'RETURN'
    actual = visit('FORWARD')
    actual = 'ACCEPT' if actual == 'RETURN' else actual
    assert actual == expected, f'{source} -> {destination}:{port}: expected {expected}, got {actual}'
    sys.exit(0)

if args[0] == '-w':
    args.pop(0)
action, chain, *rest = args
if os.environ.get('MOCK_FIREWALL_FAILURE') in (action, f'{action}:{chain}'):
    sys.exit(2)
if action == '-S':
    print('-P FORWARD ACCEPT' if chain == 'FORWARD' else f'-N {chain}')
    for rule in rules[chain]:
        print('-A', chain, *canonical(rule))
elif action == '-L':
    for index, rule in enumerate(rules[chain], 1):
        print(index, *rule)
elif action == '-C':
    sys.exit(0 if canonical(rest) in [canonical(rule) for rule in rules[chain]] else 1)
elif action == '-I':
    index = int(rest.pop(0)) - 1
    rules[chain].insert(index, canonical(rest))
elif action == '-D':
    rules[chain].pop(int(rest[0]) - 1)
else:
    raise AssertionError(args)
state_file.write_text(json.dumps(rules))
PY

iptables() { python3 "$tmp/iptables.py" "$@"; }
packet() { python3 "$tmp/iptables.py" packet "$@"; }
python3 "$tmp/iptables.py" init

# Existing CGNAT drops are bypassed by the earlier VPN ACCEPT.
packet 172.31.0.5 100.100.10.20 18080 ACCEPT
packet 192.0.2.5 198.51.100.20 443 DROP
firewall_ensure_forward_hooks
packet 172.31.0.5 100.100.10.20 18080 DROP
packet 172.31.0.5 100.100.10.20 8333 ACCEPT
packet 172.30.0.5 100.100.10.20 18080 DROP
packet 192.0.2.5 100.100.10.20 18080 ACCEPT
packet 192.0.2.5 198.51.100.20 443 DROP
packet 172.31.0.5 203.0.113.20 443 ACCEPT
cp "$MOCK_FIREWALL" "$tmp/settled.json"
firewall_ensure_forward_hooks
cmp "$MOCK_FIREWALL" "$tmp/settled.json"

# A later VPN reconfiguration can move its accepting hook ahead again.
iptables -w -I FORWARD 1 -j ts-forward
packet 172.31.0.5 100.100.10.20 18080 ACCEPT
firewall_ensure_forward_hooks
packet 172.31.0.5 100.100.10.20 18080 DROP
packet 172.30.0.5 100.100.10.20 18080 DROP
cp "$MOCK_FIREWALL" "$tmp/repaired.json"
firewall_ensure_forward_hooks
cmp "$MOCK_FIREWALL" "$tmp/repaired.json"

if MOCK_FIREWALL_FAILURE=-S firewall_ensure_forward_hooks; then
  echo 'forward inspection failure was accepted' >&2; exit 1
fi
if MOCK_FIREWALL_FAILURE=-S:FORWARD firewall_ensure_forward_hooks; then
  echo 'forward hook inspection failure was accepted' >&2; exit 1
fi
iptables -w -I FORWARD 1 -j ts-forward
if MOCK_FIREWALL_FAILURE=-I firewall_ensure_forward_hooks; then
  echo 'forward insertion failure was accepted' >&2; exit 1
fi

# Empty-fleet cleanup removes only owned rules and preserves other owners.
firewall_clear
python3 - <<'PY'
import json
import os
from pathlib import Path
rules = json.loads(Path(os.environ['MOCK_FIREWALL']).read_text())
assert rules['FORWARD'] == [['-j', 'ts-forward']] * 3 + [['-j', 'DOCKER-USER']]
assert rules['DOCKER-USER'] == [
    ['-s', '192.0.2.0/24', '-d', '198.51.100.0/24', '-j', 'DROP']]
assert not any('ci-runner-farm:' in ' '.join(rule) for chain in rules.values() for rule in chain)
PY
echo 'firewall-forward-order: OK — strict policy precedes VPN accepts for current and preserved runner subnets'
