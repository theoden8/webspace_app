// Class-level gate for BUG-009 / WORK-007 / ETP-025.
//
// A shim that wraps a native constructor and takes its prototype
// (`Patched.prototype = Real.prototype`) gets the native prototype *object*,
// whose own `constructor` property still names the native constructor. The
// wrapper is then one expression from being bypassed:
// `new (Worker.prototype.constructor)('probe.js')` returns an unshimmed
// worker, `new (RTCPeerConnection.prototype.constructor)(cfg)` a peer
// connection that gathers host candidates outside the proxy.
//
// Structural, not behavioural: it reads the Dart shim sources, so it fires on
// a NEW wrapper written the same way rather than only on the four that were
// fixed. Sources rather than test/js_fixtures/, so a stale fixture dump cannot
// make it pass or fail.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const libRoot = path.join(repoRoot, 'lib');

// How far below the assignment the re-point may sit. Enough for a comment
// explaining why, not enough to be somewhere else entirely.
const WINDOW = 10;

function dartFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartFiles(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

// `Patched.prototype = Real.prototype` — taking another constructor's
// prototype object. `X.prototype = {}` / `Object.create(...)` build a fresh
// object with a fresh `constructor` and are not affected.
const TAKES_NATIVE_PROTOTYPE =
  /(^|[^\w$.])([A-Za-z_$][\w$]*)\.prototype\s*=\s*[A-Za-z_$][\w$.]*\.prototype\s*;/;

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const offenders = [];
const sites = [];

for (const file of dartFiles(libRoot)) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    const m = TAKES_NATIVE_PROTOTYPE.exec(line);
    if (!m) return;
    const wrapper = m[2];
    const rel = path.relative(repoRoot, file);
    sites.push(`${rel}:${i + 1} (${wrapper})`);
    const after = lines.slice(i, i + 1 + WINDOW).join('\n');
    const repoint = new RegExp(
      `defineProperty\\(\\s*${escapeRe(wrapper)}\\.prototype\\s*,\\s*['"]constructor['"]`,
    );
    const value = new RegExp(`value:\\s*${escapeRe(wrapper)}\\b`);
    if (!repoint.test(after) || !value.test(after)) {
      offenders.push(`${rel}:${i + 1} — ${wrapper}.prototype takes a native prototype without re-pointing its constructor`);
    }
  });
}

test('every wrapper that takes a native prototype re-points its constructor', () => {
  assert.deepEqual(
    offenders,
    [],
    `BUG-009: add\n` +
      `  try { Object.defineProperty(X.prototype, 'constructor', ` +
      `{ value: X, writable: true, configurable: true }); } catch (e) {}\n` +
      `next to each assignment below:\n${offenders.join('\n')}`,
  );
});

test('the scan still finds the known wrapper sites', () => {
  // Guards the guard: a regex that stops matching would make the gate above
  // vacuously green. These four are the wrappers BUG-009 attempt 3 fixed.
  const expected = [
    'lib/services/worker_shim.dart',
    'lib/services/language_shim.dart',
    'lib/services/location_spoof_service.dart',
  ];
  for (const file of expected) {
    assert.ok(
      sites.some((s) => s.startsWith(`${file}:`)),
      `expected at least one prototype-taking wrapper in ${file}, found:\n${sites.join('\n')}`,
    );
  }
  assert.ok(sites.length >= 4, `expected >= 4 wrapper sites, found ${sites.length}`);
});

test('the re-point is guarded so it cannot silence the rest of the payload', () => {
  // The shim payload is one script of concatenated IIFEs: an uncaught throw
  // (a frozen prototype, a non-configurable `constructor`) would take every
  // later shim with it.
  const unguarded = [];
  for (const file of dartFiles(libRoot)) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach((line, i) => {
      if (!/defineProperty\(\s*[A-Za-z_$][\w$]*\.prototype\s*,\s*['"]constructor['"]/.test(line)) {
        return;
      }
      const around = lines.slice(Math.max(0, i - 2), i + 1).join('\n');
      if (!/try\s*\{/.test(around)) {
        unguarded.push(`${path.relative(repoRoot, file)}:${i + 1}`);
      }
    });
  }
  assert.deepEqual(unguarded, [], `constructor re-point must sit inside try/catch:\n${unguarded.join('\n')}`);
});
