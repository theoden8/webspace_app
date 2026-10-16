// Unscoped global cookie-clear gate (BUG-007, issues #524 / #525).
//
// `CookieManager.deleteAllCookies()` carries no site with it: the plugin
// resolves which jar to empty from its own state. Under the container engine
// every site owns its jar and that state is the only thing standing between
// "clear the unused default jar" and "wipe a live site's session", which is
// exactly what happened when a container-scoped read poisoned the plugin's
// static CookieManager memo (fixed in the fork at v6.2.0-beta.3-privacy-v6).
// On the legacy shared jar the same call, issued outside the jar's turn,
// empties sessions a restore just put back (BUG-032's shape).
//
// So the call has one owner: CookieIsolationEngine, which issues it in its
// turn (the nuke of a restore, and clearUnloaded). Only a `SharedJar` holds
// the engine, and the restore makes one only when containers are off, so
// past the binding the container check is a type. Rung 5 for the rest: no
// type says a cookie manager may be emptied only by one class, or that the
// page reaches its engine only to bind it.
//
// Structural rather than behavioral: reproducing the real defect needs an
// Android device with WebViewFeature.MULTI_PROFILE and two live profiles,
// which no CI tier here has. The legacy half is the activation model's
// (formal/activation.tla, the cold start's ClearJar).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles } = require('./helpers/source');

/// The engine that owns the call, and the wrapper's own definition.
const OWNERS = new Set([
  'lib/services/cookie_isolation.dart',
  'lib/services/cookie_manager.dart',
]);

test('only the legacy engine empties a cookie jar unscoped', () => {
  const callers = [];
  for (const rel of dartFiles()) {
    if (OWNERS.has(rel)) continue;
    read(rel).split('\n').forEach((line, i) => {
      // `deleteAllCookiesForUrl` is URL-scoped and therefore not this class.
      if (/\.deleteAllCookies\(\)/.test(line)) callers.push(`${rel}:${i + 1}`);
    });
  }
  assert.deepEqual(callers, [],
    'unscoped deleteAllCookies() goes through CookieIsolationEngine, in the ' +
    'jar\'s turn: elsewhere it can empty a live container or restored sessions');
});

test('the page reaches the legacy engine only to bind it', () => {
  const page = read('lib/screens/webspace_page.dart');
  assert.equal((page.match(/_cookieIsolation\b/g) ?? []).length, 2,
    'past its definition the engine is reached only by legacyJar, which the ' +
    'restore wraps in a SharedJar when containers are off; everything else ' +
    'takes it from _sites.isolation');
  assert.match(read('lib/controllers/startup_controller.dart'),
    /legacy: \(\) => _host\.legacyJar,/,
    'the restore hands the legacy engine to the decision, which binds it only '
    + 'when containers are not supported');
});
