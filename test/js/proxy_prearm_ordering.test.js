// The per-site proxy pre-arm has exactly one shot, and order is all of it
// (LEAK-003, BUG-014).
//
// On iOS and macOS a data store's proxy reaches WebKit's network process
// either in the parameters that create the store's network session or as an
// update afterwards, and WebKit clears the pending proxy before the call that
// registers the session. So the assignment that registers a store can never
// carry the proxy into that store's session parameters, and the update path
// does not take: only stores already armed when the network process comes up
// are proxied.
//
// Two properties follow, and neither is visible at the call site:
//
//  1. One call. Arming each container separately is one run-loop turn each,
//     and every turn after the first misses the window. The batch is the
//     reason `prepareContainers` takes a list at all.
//  2. First. The pre-arm has to run before anything else registers a network
//     session — the proxy router, the startup GC, the first cookie restore,
//     the first WebView. Moving it below any of those silently puts every
//     site but one back on the device IP, and nothing fails.
//
// Both read like ordinary code however they are arranged, which is why they
// are gated structurally. The effect is only observable in the macOS
// integration tier, which runs once an hour.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const webviewRel = 'lib/services/webview.dart';
const mainRel = 'lib/main.dart';
const webview = read(webviewRel);
const main = read(mainRel);

/// Code only: the comments in both files describe the very shapes these
/// rules forbid.
const stripComments = (src) => src.replace(/^\s*\/\/.*$/gm, '');

test('the container pre-arm is a single batched native call', () => {
  const code = stripComments(webview);
  const calls = code.match(/\.prepareContainers\(/g) ?? [];
  assert.equal(
    calls.length,
    1,
    `${webviewRel} calls prepareContainers ${calls.length} times; it must be ` +
      'one call carrying every container, because one call per container is ' +
      'one run-loop turn per container and all but the first miss the window',
  );

  // The call has to carry the whole set, so its argument is the accumulator
  // the pre-arm fills -- not one spec, and not a call per site.
  const body = code.slice(code.indexOf('prearmProxiedContainers'));
  const accumulator = body.match(/final (\w+) = <inapp\.ContainerProxySpec>\[\]/);
  assert.ok(
    accumulator,
    `${webviewRel} must collect every container into one list before arming`,
  );
  const argument = body.match(/\.prepareContainers\(([^)]*)\)/);
  assert.ok(argument, `${webviewRel} must call prepareContainers from the pre-arm`);
  assert.equal(
    argument[1].trim(),
    accumulator[1],
    `${webviewRel} passes ${argument[1].trim()} to prepareContainers rather ` +
      `than the ${accumulator[1]} list, so it is not arming every container ` +
      'in the one call that can reach them',
  );
});

test('the pre-arm runs before anything else registers a network session', () => {
  const code = stripComments(main);
  const prearmAt = code.indexOf('prearmProxiedContainers');
  assert.ok(
    prearmAt > 0,
    `${mainRel} must pre-arm proxied container stores at startup, or only ` +
      'the first site opened in a launch is ever proxied',
  );
  assert.equal(
    (code.match(/prearmProxiedContainers/g) ?? []).length,
    1,
    `${mainRel} must pre-arm once; a second pass after the network process ` +
      'is up arms nothing and reads as if it did',
  );

  const containerDecisionAt = code.indexOf(
    '_useContainers = await ContainerNative.instance.isSupported()',
  );
  assert.ok(
    containerDecisionAt > 0,
    `${mainRel} must still resolve container support at startup`,
  );
  assert.ok(
    prearmAt > containerDecisionAt,
    `${mainRel} pre-arms before it knows whether containers are supported, ` +
      'so it would arm nothing',
  );

  const routerAt = code.indexOf('await _activateProxyRouter()');
  assert.ok(routerAt > 0, `${mainRel} must still activate the proxy router`);
  assert.ok(
    prearmAt < routerAt,
    `${mainRel} pre-arms after the proxy router; the router registers a ` +
      'network session, which closes the window and leaves every proxied ' +
      'site after the first on the device IP',
  );
});
