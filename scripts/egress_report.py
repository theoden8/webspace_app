#!/usr/bin/env python3
"""Turn an egress-guard recording into a verdict (INTEG-016).

Reads the JSONL `egress_recorder.py` wrote, matches every distinct target
against the allowlist, and reports what the Linux integration suite tried
to send off the runner. Loopback never reaches the recorder, so anything
in the log is by construction traffic that wanted to leave.

Modes:
  record   report only, always exit 0. What a first run on a new branch
           wants -- the report is the inventory you build the allowlist
           from, and turning the job red for a download nobody had audited
           yet teaches nothing.
  enforce  exit 3 on any unallowlisted target.

An allowlist line is `dns:<suffix>`, `host:<suffix>` (SNI or HTTP Host) or
`ip:<address-or-cidr>`; a suffix matches the name itself and anything
under it. Lines are expected to carry a comment saying who makes the
request and why it is allowed to -- an entry without one is a coverage
hole in the ip-leakage matrix (LEAK-007) that nobody has noticed yet.

Exit codes: 0 = clean (or record mode), 3 = unallowlisted egress,
2 = the recording is missing or unreadable.
"""

import argparse
import ipaddress
import json
import os
import sys
from collections import defaultdict


def _norm(name):
    return (name or '').strip().rstrip('.').lower()


class Allowlist:
    def __init__(self, path):
        self.names, self.nets, self.raw = [], [], []
        if not path or not os.path.exists(path):
            return
        with open(path) as fh:
            for line in fh:
                entry = line.split('#', 1)[0].strip()
                if not entry:
                    continue
                self.raw.append(entry)
                kind, _, value = entry.partition(':')
                if kind in ('dns', 'host'):
                    self.names.append(_norm(value))
                elif kind == 'ip':
                    try:
                        self.nets.append(ipaddress.ip_network(value.strip(),
                                                              strict=False))
                    except ValueError:
                        print(f'::warning::egress allowlist: bad network '
                              f'{value!r}', file=sys.stderr)
                else:
                    print(f'::warning::egress allowlist: unknown entry '
                          f'{entry!r}', file=sys.stderr)

    def allows_name(self, name):
        name = _norm(name)
        if not name:
            return False
        return any(name == a or name.endswith('.' + a) for a in self.names)

    def allows_addr(self, target):
        host = target.rsplit(':', 1)[0] if target else ''
        try:
            addr = ipaddress.ip_address(host)
        except ValueError:
            return False
        return any(addr in net for net in self.nets)


def load(path):
    records, repeats = [], {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get('proto') == 'summary':
                repeats.update(rec.get('repeats', {}))
            else:
                records.append(rec)
    return records, repeats


def counters(state_dir):
    """Packet counts from the degraded reject ruleset, if that is what ran."""
    path = os.path.join(state_dir, 'counters.txt')
    found = {}
    if not os.path.exists(path):
        return found
    # `nft list table` puts the name and its packet count on separate
    # lines, so the parse has to carry the name forward.
    current = None
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == 'counter':
                current = parts[1].strip('"')
            elif current and parts[:1] == ['packets']:
                try:
                    found[current] = int(parts[1])
                except (IndexError, ValueError):
                    pass
                current = None
    return found


def describe(rec):
    """One line naming a target as specifically as the recording allows."""
    proto, target = rec.get('proto'), rec.get('target', '?')
    name = rec.get('name')
    if proto == 'dns':
        via = f" via resolver {rec['resolver']}" if rec.get('resolver') else ''
        return f'dns    {target}{via}'
    where = target if target != 'unattributed' else 'address not captured'
    return f'{proto:<6} {name or "(unnamed)"} [{where}]'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--log', required=True)
    ap.add_argument('--allowlist')
    ap.add_argument('--state', default='/tmp/ws-egress')
    ap.add_argument('--mode', choices=['record', 'enforce'], default='record')
    args = ap.parse_args()

    if not os.path.exists(args.log):
        # Record mode is an observer: a runner that could not arm the guard
        # should not take the Linux job down. Enforce mode is the opposite
        # -- a suite nobody watched cannot be reported as clean.
        if args.mode == 'record':
            print('::warning::egress guard produced no recording — it never '
                  'armed. Nothing was watched this run.')
            return 0
        print('::error::egress guard produced no recording — it never armed',
              file=sys.stderr)
        return 2

    records, repeats = load(args.log)
    allow = Allowlist(args.allowlist)
    blocked = counters(args.state)

    permitted, violations = [], []
    for rec in records:
        name = rec.get('target') if rec.get('proto') == 'dns' else rec.get('name')
        ok = allow.allows_name(name) or allow.allows_addr(rec.get('target', ''))
        (permitted if ok else violations).append(rec)

    by_proto = defaultdict(int)
    for rec in records:
        by_proto[rec.get('proto', '?')] += 1

    print(f'egress guard: mode={args.mode} '
          f'targets={len(records)} allowed={len(permitted)} '
          f'unallowlisted={len(violations)} '
          f'({", ".join(f"{k}={v}" for k, v in sorted(by_proto.items())) or "none"})')

    if permitted:
        print('::group::allowlisted egress')
        for rec in sorted(permitted, key=describe):
            print('  ' + describe(rec))
        print('::endgroup::')

    # Degraded mode counts packets but cannot name them, so an allowlist
    # entry has nothing to match and the only safe verdict is to fail.
    # That is deliberate: a run that cannot see where traffic was going
    # must not be able to pass by saying it saw nothing.
    unattributed = sum(v for k, v in blocked.items() if v)
    if unattributed:
        level = 'error' if args.mode == 'enforce' else 'warning'
        print(f'::{level}::egress guard ran degraded (no nat hook): '
              f'{unattributed} packets blocked with no destination captured '
              f'({blocked}). DNS names below are still attributed; the rest '
              f'needs the nat hook, which needs CAP_NET_ADMIN.')

    if violations:
        print('::group::unallowlisted egress')
        for rec in sorted(violations, key=describe):
            print('  ' + describe(rec))
        print('::endgroup::')
        # Record mode annotates as warnings: an error annotation on a
        # green step reads as a broken job, and the whole point of the
        # mode is that the inventory is not a verdict yet.
        level = 'error' if args.mode == 'enforce' else 'warning'
        for rec in sorted(violations, key=describe):
            print(f'::{level}::unallowlisted egress: {describe(rec).strip()}')

    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as fh:
            fh.write(f'\n### Egress guard ({args.mode})\n\n')
            fh.write(f'{len(records)} distinct targets, {len(violations)} '
                     f'unallowlisted.\n\n')
            if violations:
                fh.write('| verdict | target |\n|---|---|\n')
                for rec in sorted(violations, key=describe):
                    fh.write(f'| unallowlisted | `{describe(rec).strip()}` |\n')
            if repeats:
                fh.write(f'\n{len(repeats)} targets were contacted more than '
                         f'once.\n')

    if (violations or unattributed) and args.mode == 'enforce':
        print('::error::the integration suite sent traffic off the runner '
              'that no allowlist entry covers. Either route it through '
              'outboundHttp with the right proxy (LEAK-002), point it at a '
              'loopback fixture, or add an allowlist entry saying why it is '
              'exempt (LEAK-007).', file=sys.stderr)
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main())
