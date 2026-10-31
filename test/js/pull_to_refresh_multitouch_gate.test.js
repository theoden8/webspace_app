// Pull-to-refresh multi-touch gate (NAV-006).
//
// Neither Android's SwipeRefreshLayout nor iOS's UIRefreshControl looks at the
// pointer count, so a two-finger pinch at scroll top fires a refresh. The fix
// lives in PullToRefreshGate, whose state machine
// test/pull_to_refresh_gate_test.dart drives through a fake control.
// WebViewConfig takes the gate and no controller, and the gate is the only way
// to build one, so a surface cannot hand the webview a controller without it.
// What is left here is the wiring no Dart test reaches: the factory feeding the
// gate from the raw Listener the gate builds.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

test('the factory feeds the gate from a raw pointer Listener', () => {
  const factory = read('lib/services/webview.dart');
  assert.match(factory, /config\.pullToRefreshGate\?\.around\(focused\)/,
    'WebViewFactory must wrap the webview in its refresh gate');
  const src = read('lib/services/pull_to_refresh_gate.dart');
  const start = src.indexOf('Widget around(Widget webView)');
  assert.ok(start >= 0, 'the gate builds the Listener that feeds it');
  const decl = src.slice(start, src.indexOf(');\n', start));
  assert.match(decl, /Listener\(/,
    'a raw Listener (never a GestureDetector, which would join the arena)');
  for (const cb of ['onPointerDown', 'onPointerUp', 'onPointerCancel']) {
    assert.match(decl, new RegExp(`${cb}:`), `the Listener must handle ${cb}`);
  }
});
