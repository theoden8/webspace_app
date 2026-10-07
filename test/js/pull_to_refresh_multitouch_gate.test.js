// Pull-to-refresh multi-touch gate (NAV-006).
//
// Neither Android's SwipeRefreshLayout nor iOS's UIRefreshControl looks at the
// pointer count, so a two-finger pinch at scroll top fires a refresh. The fix
// lives in PullToRefreshGate. WebViewConfig takes the gate and no controller,
// and the gate is the only way to build one, so a surface cannot hand the
// webview a controller without it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const GATE = 'lib/services/pull_to_refresh_gate.dart';

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
