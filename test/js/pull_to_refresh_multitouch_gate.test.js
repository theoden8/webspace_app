// Pull-to-refresh multi-touch gate (NAV-006).
//
// Neither Android's SwipeRefreshLayout nor iOS's UIRefreshControl looks at the
// pointer count, so a two-finger pinch at scroll top fires a refresh. The fix
// lives in PullToRefreshGate, which both webview surfaces must go through: a
// bare PullToRefreshController anywhere else reintroduces the bug on that
// surface, and a controller handed to InAppWebView without its gate leaves the
// pointer stream unwatched.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const GATE = 'lib/services/pull_to_refresh_gate.dart';
// The surfaces that own a refresh controller: the main webview and the nested
// cross-domain one.
const SURFACES = ['lib/web_view_model.dart', 'lib/screens/inappbrowser.dart'];

const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

test('the gate disables the control on a second pointer', () => {
  const src = read(GATE);
  assert.match(src, /_pointers\.length\s*<\s*2/,
    'the gate must key off the pointer count');
  assert.match(src, /_setEnabled\(false\)/,
    'a second pointer must disable the refresh control');
});

test('the gate swallows a refresh that outran the disable', () => {
  const src = read(GATE);
  assert.match(src, /suppressesRefresh/,
    'runRefresh must consult the multi-touch state');
  assert.match(src, /endRefreshing/,
    'a swallowed refresh must still stop the spinner');
});

for (const rel of SURFACES) {
  const src = read(rel);

  test(`${rel}: the refresh controller is built by the gate`, () => {
    assert.match(src, /PullToRefreshGate\.create\(/,
      'build the controller through PullToRefreshGate.create');
  });

  test(`${rel}: no bare PullToRefreshController (NAV-006 gate)`, () => {
    const offenders = src
      .split('\n')
      .map((l, i) => [l, i + 1])
      .filter(([l]) => /(?:inapp\.)?PullToRefreshController\(/.test(l))
      .map(([, n]) => n);
    assert.deepEqual(offenders, [],
      `bare PullToRefreshController at line(s) ${offenders.join(', ')}. ` +
        'Route it through PullToRefreshGate.create (NAV-006).');
  });

  test(`${rel}: the controller ships with its gate`, () => {
    assert.match(src, /pullToRefreshController:\s*\S*[Gg]ate\?\.controller/,
      'the config must take the controller off the gate');
    assert.match(src, /pullToRefreshGate:\s*\S*[Gg]ate/,
      'the config must carry the gate so the factory can feed it pointers');
  });
}

test('the factory feeds the gate from a raw pointer Listener', () => {
  const src = read('lib/services/webview.dart');
  const idx = src.indexOf('_applyRefreshGate');
  assert.ok(idx >= 0, 'WebViewFactory must wrap the webview in a refresh gate');
  const body = src.slice(src.indexOf('static Widget _applyRefreshGate'));
  const decl = body.slice(0, body.indexOf('\n  static Widget _applyLetterbox'));
  assert.match(decl, /Listener\(/,
    'a raw Listener (never a GestureDetector, which would join the arena)');
  for (const cb of ['onPointerDown', 'onPointerUp', 'onPointerCancel']) {
    assert.match(decl, new RegExp(`${cb}:`), `the Listener must handle ${cb}`);
  }
});
