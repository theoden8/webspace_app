// Every webview's HTTP auth challenge goes through answerHttpAuthChallenge
// (HTTPAUTH-001), which asks the proxy router first: on Android the relay's
// 407 and a site's 401 reach the same callback, so a webview that answered
// from the site's session directly could hand the router's challenge to the
// sign-in dialog or a saved password. Rung 5: no type says which function a
// plugin callback calls. The order inside the funnel is a boundary test in
// test/proxy_router_service_test.dart.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code, dartFiles, lineAt } = require('./helpers/source');

// The router's own attribution probe has no site session and no prompt; its
// answer claims nothing the router does not own.
const EXEMPT = new Map([
  ['lib/services/proxy_router_probe.dart', 'answerProxyRouterChallenge'],
]);

test('every auth callback answers through the funnel (HTTPAUTH-001)', () => {
  let seen = 0;
  for (const f of dartFiles()) {
    const src = code(read(f));
    for (const m of src.matchAll(/\bonReceivedHttpAuthRequest:\s*\([^)]*\)\s*(=>|async\s*\{|\{)/g)) {
      seen++;
      const body = src.slice(m.index + m[0].length).trimStart();
      const callee = EXEMPT.get(f) ?? 'answerHttpAuthChallenge';
      assert.ok(body.startsWith(`${callee}(`) || body.startsWith(`return ${callee}(`),
        `${f}:${lineAt(src, m.index)} answers a challenge without ${callee}`);
    }
  }
  assert.ok(seen >= 3, 'the site webview, its popups and the headless check');
});
