// LICENSE-001 over what the Linux build fetches (scripts/fetch_gate.py, armed
// by scripts/fetch_gate.sh around the build in CI, which also probes that an
// unlisted repository is refused there): each rule held on the URL it is for.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');

const GATE = path.join(REPO, 'scripts/fetch_gate.py');
const check = (...args) => Object.fromEntries(execFileSync('python3', [GATE, 'check', ...args], { encoding: 'utf8' })
  .trim().split('\n').map((l) => l.split('\t').reverse()));

test('LICENSE-001 a fetch under a url: row of components.tsv passes, by whole segments', () => {
  assert.deepEqual(check(
    'https://github.com/duckduckgo/tracker-surrogates.git/info/refs?service=git-upload-pack',
    'https://github.com/duckduckgo/tracker-surrogates/git-upload-pack',
    'https://archive.torproject.org/tor-package-archive/tor-0.4.8.13.tar.gz',
    'https://github.com/duckduckgo/tracker-surrogates-fork/info/refs',
    'https://github.com/torvalds/linux/info/refs',
    'https://archive.torproject.org/tor-package-archive/other/tor-0.4.8.13.tar.gz',
    'http://github.com/duckduckgo/tracker-surrogates.git/info/refs',
  ), {
    'https://github.com/duckduckgo/tracker-surrogates.git/info/refs?service=git-upload-pack': 'component',
    'https://github.com/duckduckgo/tracker-surrogates/git-upload-pack': 'component',
    'https://archive.torproject.org/tor-package-archive/tor-0.4.8.13.tar.gz': 'component',
    'https://github.com/duckduckgo/tracker-surrogates-fork/info/refs': 'refused',
    'https://github.com/torvalds/linux/info/refs': 'refused',
    'https://archive.torproject.org/tor-package-archive/other/tor-0.4.8.13.tar.gz': 'refused',
    'http://github.com/duckduckgo/tracker-surrogates.git/info/refs': 'refused',
  });
});

test("LICENSE-001 a registry passes under its allowlist prefix only, and a redirect only from a fetch that passed", () => {
  assert.deepEqual(check('https://static.crates.io/crates/serde/serde-1.0.0.crate', 'https://storage.googleapis.com/other/x'), {
    'https://static.crates.io/crates/serde/serde-1.0.0.crate': 'allowlist',
    'https://storage.googleapis.com/other/x': 'refused',
  });
  const asset = 'https://release-assets.githubusercontent.com/github-production-release-asset/1/x';
  assert.deepEqual(check('--after', 'https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz', asset), { [asset]: 'redirect' });
  assert.deepEqual(check('--after', 'https://github.com/torvalds/linux/releases/download/v1/x.tar.xz', asset), { [asset]: 'refused' });
});

test('LICENSE-001 the report fails on a refused fetch or a refused certificate, and names it', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fetch-gate-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const report = (lines) => {
    fs.writeFileSync(path.join(dir, 'log'), lines.map((l) => JSON.stringify(l)).join('\n'));
    return spawnSync('python3', [GATE, 'report', path.join(dir, 'log')], { encoding: 'utf8' });
  };
  assert.equal(report([{ url: 'https://index.crates.io/config.json', why: 'allowlist' }]).status, 0);
  const refused = report([{ url: 'https://github.com/torvalds/linux', why: null }]);
  assert.equal(refused.status, 1);
  assert.match(refused.stdout, /::error::.*refused https:\/\/github\.com\/torvalds\/linux/);
  const tls = report([{ tls_failed: 'github.com', error: 'unknown ca' }]);
  assert.equal(tls.status, 1);
  assert.match(tls.stdout, /refused the gate's certificate for github\.com/);
});

test('LICENSE-001 every allowlist entry is a URL prefix that says which gate reads what it serves', () => {
  for (const [i, line] of read('scripts/fetch_allowlist.txt').split('\n').entries()) {
    const [entry, ...comment] = line.split('#');
    if (!entry.trim()) continue;
    assert.match(entry.trim(), /^https:\/\/[^\s/]+\/\S*$/, `line ${i + 1}: ${entry.trim()} is not an https URL prefix`);
    assert.ok(comment.join('#').trim().length >= 10, `line ${i + 1}: ${entry.trim()} names no gate`);
  }
});

test('LICENSE-001 the Linux job arms the gate before its first fetch of the build and reports after', () => {
  const job = read('.github/workflows/build-and-test.yml').split(/\n {2}build-linux:\n/)[1].split(/\n {2}\S[^\n]*:\n/)[0];
  const at = (name) => {
    const i = job.indexOf(`- name: ${name}`);
    assert.ok(i >= 0, `build-linux has no step "${name}"`);
    return i;
  };
  assert.ok(at('Arm the fetch gate') < at('Test webspace_adblock crate'));
  assert.ok(at('Build Linux') < at('Disarm the fetch gate and report'));
  assert.match(job.slice(at('Disarm the fetch gate and report')), /^[^\n]*\n\s+if: always\(\)/);
});
