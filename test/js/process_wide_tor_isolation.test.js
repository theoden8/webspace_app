// Structural gate: under the process-wide proxy rule (Android without the
// router, Linux) each Tor site keeps its own circuit (TOR-003, TOR-025).
//
// A Tor site's isolation is the SOCKS credential it presents, and the tag in
// that credential is the site id. On this path two things lose it silently:
// resolving a site's proxy without its id, which hands every Tor site the
// app-global tag, and applying a TOR setting without expanding it, which
// dials the leftover manual address a TOR setting keeps (PROXY-010). Neither
// fails a request; both put sites on one circuit or off Tor altogether.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

function dartFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartFiles(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

function read(rel) {
  return fs
    .readFileSync(path.join(repoRoot, rel), 'utf8')
    .replace(/^\s*\/\/.*$/gm, '');
}

/// The text enclosed by the first [opener] at or after [from], balanced.
function enclosedAt(text, from, opener) {
  const open = text.indexOf(opener, from);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return null;
}

test('every setProxySettings call names the site it applies for', () => {
  const missing = [];
  let seen = 0;
  for (const file of dartFiles(path.join(repoRoot, 'lib'))) {
    const text = fs.readFileSync(file, 'utf8').replace(/^\s*\/\/.*$/gm, '');
    const re = /\.setProxySettings\s*\(/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      seen++;
      const args = enclosedAt(text, m.index, '(');
      if (!/\bsiteId\s*:/.test(args)) {
        missing.push(`${path.relative(repoRoot, file)}: setProxySettings(${args})`);
      }
    }
  }
  assert.ok(seen > 0, 'no setProxySettings call sites found; gate is stale');
  assert.deepEqual(missing, []);
});

test('the process-wide rule expands TOR with the site id before applying', () => {
  const text = read('lib/services/webview.dart');
  const at = text.search(/Future<void>\s+setProxySettings\s*\(/);
  assert.ok(at >= 0, 'ProxyManager.setProxySettings not found');
  const body = enclosedAt(text, text.indexOf(')', at), '{');
  assert.match(body, /resolveEffectiveProxy\(\s*settings\s*,\s*siteId:\s*siteId\s*\)/);
  const expand = body.search(/expandTorProxy\(/);
  const override = body.search(/\.setProxyOverride\(/);
  assert.ok(expand >= 0, 'TOR is never expanded on the process-wide path');
  assert.ok(expand < override, 'TOR must be expanded before any override');
});

test('the mismatch unload compares Tor sites by their own tags', () => {
  const text = read('lib/services/site_unload_engine.dart');
  const at = text.indexOf('indicesToUnloadForProxyMismatch(');
  const body = enclosedAt(text, text.indexOf(')', at), '{');
  const calls = body.match(/resolveEffectiveProxy\(([^;]*?)\)\s*;/gs) || [];
  assert.ok(calls.length >= 2, 'expected the target and each loaded site');
  for (const call of calls) {
    assert.match(call, /siteId:/, `resolved without a site id: ${call}`);
  }
});
