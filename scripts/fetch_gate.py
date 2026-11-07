"""LICENSE-001 over what a build fetches: a request leaves the runner only
for a prefix in scripts/fetch_allowlist.txt, a url: row of
openspec/specs/legal/components.tsv, or a redirect one of those answered
with. A prefix holds by whole path segments, `.git` aside, and a row's
${VAR} stands for any one segment's text.

As a mitmproxy addon (scripts/fetch_gate.sh arms it), any other request is
answered 403, and every decision is a JSON line in $WS_FETCH_LOG.

    python3 scripts/fetch_gate.py check [--after URL] URL...
    python3 scripts/fetch_gate.py report LOG
"""

import json
import os
import re
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import urljoin, urlsplit

REPO = Path(__file__).resolve().parent.parent
ALLOWLIST = 'scripts/fetch_allowlist.txt'
COMPONENTS = 'openspec/specs/legal/components.tsv'
REDIRECTS = (301, 302, 303, 307, 308)


def _segments(path):
    return [s[:-4] if s.endswith('.git') else s for s in path.split('/') if s]


def _rule(url):
    parts = urlsplit(url)
    pats = [re.compile('^' + '[^/]*'.join(re.escape(p) for p in re.split(r'\$\{\w+\}', s)) + '$')
            for s in _segments(parts.path)]
    return parts.scheme, parts.hostname, pats


def rules(repo=REPO):
    """[(why, rule)] for each allowlist prefix and each components.tsv url: row."""
    out = []
    for line in (repo / ALLOWLIST).read_text().splitlines():
        entry = line.split('#', 1)[0].strip()
        if entry:
            out.append(('allowlist', _rule(entry)))
    for line in (repo / COMPONENTS).read_text().splitlines():
        if line.startswith('url:'):
            out.append(('component', _rule(line.split('\t', 1)[0][len('url:'):])))
    return out


def _matches(url, rule):
    scheme, host, pats = rule
    parts = urlsplit(url)
    segs = _segments(parts.path)
    return (parts.scheme == scheme and parts.hostname == host and len(segs) >= len(pats)
            and all(p.match(s) for p, s in zip(pats, segs)))


def decide(url, table, redirects=frozenset()):
    """Why [url] may be fetched ('allowlist', 'component', 'redirect'), or None."""
    for why, rule in table:
        if _matches(url, rule):
            return why
    return 'redirect' if url in redirects else None


class FetchGate:
    def __init__(self):
        self.table = rules()
        self.redirects = set()
        self.log = os.environ['WS_FETCH_LOG']

    def _write(self, entry):
        with open(self.log, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def request(self, flow):
        from mitmproxy import http
        url = flow.request.pretty_url
        why = decide(url, self.table, self.redirects)
        self._write({'url': url, 'why': why})
        if why is None:
            flow.response = http.Response.make(
                403, f'fetch gate: {url} is in neither {ALLOWLIST} nor a url: row of {COMPONENTS}\n'.encode())
        else:
            flow.metadata['fetch_gate'] = why

    def response(self, flow):
        location = flow.response.headers.get('Location')
        if flow.metadata.get('fetch_gate') and flow.response.status_code in REDIRECTS and location:
            self.redirects.add(urljoin(flow.request.pretty_url, location))

    def tls_failed_client(self, data):
        self._write({'tls_failed': data.conn.sni, 'error': str(data.conn.error)})


addons = [FetchGate()] if 'WS_FETCH_LOG' in os.environ else []


def report(log):
    """Each refused fetch and each client that refused the gate's certificate, as ::error:: lines."""
    refused, allowed = [], Counter()
    for line in Path(log).read_text().splitlines():
        entry = json.loads(line)
        if 'tls_failed' in entry:
            refused.append(f"a client refused the gate's certificate for {entry['tls_failed']}: {entry['error']}")
        elif entry['why'] is None:
            refused.append(f"refused {entry['url']}: in neither {ALLOWLIST} nor a url: row of {COMPONENTS}")
        else:
            allowed[(entry['why'], urlsplit(entry['url']).hostname)] += 1
    for (why, host), n in sorted(allowed.items()):
        print(f'fetch gate: {n:5} allowed from {host} ({why})')
    for r in refused:
        print(f'::error::fetch gate (LICENSE-001): {r}')
    print(f'fetch gate: {sum(allowed.values())} fetches allowed, {len(refused)} refused')
    return 1 if refused else 0


def main(argv):
    if argv[:1] == ['report'] and len(argv) == 2:
        return report(argv[1])
    if argv[:1] == ['check']:
        args, after = argv[1:], None
        if args[:1] == ['--after']:
            after, args = args[1], args[2:]
        table = rules()
        redirects = frozenset(args) if after and decide(after, table) else frozenset()
        for url in args:
            print(f'{decide(url, table, redirects) or "refused"}\t{url}')
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
