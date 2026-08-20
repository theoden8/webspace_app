// Structural guard: the app must not reach the device's location service on
// behalf of a page unless that page's site is in live mode (LOC-REACH-001).
//
// The per-site location controls are enforced in two very different places.
// The JS shim decides what a page *sees*, and it is not a security boundary:
// it runs in the page's own realm. What keeps a non-live site away from the
// real device is narrower and stronger -- the Dart bridge that talks to the
// platform location service is only registered for live sites, and the
// Android WebChromeClient path is denied outright.
//
// Both facts live in call-site wiring rather than in a testable unit, so they
// are guarded structurally here: a future refactor that hoists the handler
// registration out of its guard, or grants the Android prompt, fails CI
// instead of silently widening what a page can reach.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const WEBVIEW = read('lib/services/webview.dart');

// Strip line comments so prose describing a call does not count as one.
const stripComments = (src) =>
  src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

const WEBVIEW_CODE = stripComments(WEBVIEW);

test('LOC-REACH-001: the getRealLocation bridge is registered only for live sites', () => {
  const registrations = [...WEBVIEW_CODE.matchAll(/handlerName:\s*'getRealLocation'/g)];
  assert.equal(registrations.length, 1,
    'expected exactly one getRealLocation registration');

  // The registration must sit inside a live-mode guard. Walk back from it to
  // the nearest enclosing condition rather than matching a fixed shape, so
  // reformatting does not break the test but removing the guard does.
  const at = registrations[0].index;
  const before = WEBVIEW_CODE.slice(0, at);
  const guard = before.lastIndexOf('config.locationMode == LocationMode.live');
  assert.notEqual(guard, -1,
    'getRealLocation must be registered behind a LocationMode.live check');
  const between = WEBVIEW_CODE.slice(guard, at);
  assert.ok(!between.includes('}\n    }'),
    'the LocationMode.live guard appears to close before the registration');
});

test('LOC-REACH-002: the platform location service has exactly two call sites', () => {
  // The live bridge and the picker's explicit "use current location" button.
  // Anything else reaching CurrentLocationService is a new way for a site to
  // cause a device fix, and needs its own review.
  const expected = new Set([
    'lib/services/webview.dart',
    'lib/screens/location_picker.dart',
  ]);
  const searchRoots = ['lib'];
  const found = new Set();
  const walk = (dir) => {
    for (const entry of fs.readdirSync(path.join(repoRoot, dir), { withFileTypes: true })) {
      const rel = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(rel);
      else if (entry.name.endsWith('.dart')
        && stripComments(read(rel)).includes('CurrentLocationService.getCurrentLocation')) {
        found.add(rel);
      }
    }
  };
  searchRoots.forEach(walk);
  assert.deepEqual([...found].sort(), [...expected].sort());
});

test('LOC-REACH-003: the Android geolocation prompt is never granted', () => {
  // Even a live site is served through the Dart bridge, which applies the
  // site's granularity snapping. Granting the native prompt would hand the
  // page the raw platform fix and bypass the approximate/GSM tiers.
  const at = WEBVIEW_CODE.indexOf('onGeolocationPermissionsShowPrompt:');
  assert.notEqual(at, -1,
    'onGeolocationPermissionsShowPrompt must be wired explicitly, not left to '
    + 'the plugin default');
  const body = WEBVIEW_CODE.slice(at, at + 400);
  assert.match(body, /allow:\s*false/,
    'the Android geolocation prompt must be denied unconditionally');
  assert.ok(!/allow:\s*(true|config\.|\w+\s*==)/.test(body),
    'allow must be the literal false, not a condition');
});
