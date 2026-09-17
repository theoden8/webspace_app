// Structural gates for the HTTPS upgrade's call-site wiring.
//
// These assert the two things a Dart test cannot: that the call site FORWARDS
// rather than decides, and that its handlers sit where they must relative to
// code the engine knows nothing about.
//
// Everything else moved. The orderings this file used to assert as "line X
// before line Y" are now `test/https_upgrade_events_test.dart`, which drives
// the engine event by event: a text-order assertion catches a deletion and
// nothing else, breaks on reformatting, and passes happily on
// equivalent-but-wrong code. The one rule worth holding structurally is that
// no decision lives in a webview closure in the first place, because a
// decision that lives there is one no test can reach.
//
// Cross-links:
//   openspec/changes/https-upgrade/specs/https-upgrade/spec.md  HTTPS-002/005/006/007
//   openspec/changes/https-upgrade/specs/tracking-protection/spec.md  ETP-028
//
// The call-site ORDERING against the navigation verdict (HTTPS-004) lives in
// page_bridge_authority.test.js, beside the CAPTCHA-008 ordering it copies.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const readRaw = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');
const stripComments = (src) =>
  src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

const WEBVIEW = stripComments(readRaw('lib/services/webview.dart'));

// Dart wraps a long call between the receiver and the method, so every check
// below matches across whitespace. Matching the literal text would make the
// no-decision rule silently miss a wrapped primitive call, which is a false
// PASS in the one gate that must not have one.
const calls = (src, method) =>
  new RegExp(`httpsUpgrade\\s*\\.\\s*${method}\\s*\\(`).test(src);

// The rule that keeps the state machine testable. Every decision belongs to
// the engine, so the call site may only call its event surface; reaching for a
// primitive means a branch has moved back into a closure where the only
// possible cover is a regex like the ones this file used to carry.
const EVENTS = [
  'onNavigation', 'onLoadStarted', 'onLoadFinished', 'onLoadFailed',
  'onCertificateRejected', 'onDeadline',
];
const PRIMITIVES = [
  'upgradeFor', 'fallbackFor', 'fallbackForHost', 'fallbackForTimeout',
  'recordUpgradeSuccess', 'recordUpgradeFailure', 'noteUpgradeResponded',
];

test('the call site forwards events and never decides', () => {
  for (const p of PRIMITIVES) {
    assert.ok(!calls(WEBVIEW, p),
      `webview.dart calls httpsUpgrade.${p}() directly. That is a decision ` +
      'in a closure no Dart test can drive — put it behind an event on the ' +
      'engine and forward, the way the other five handlers do.');
  }
});

// Each platform event that can resolve an upgrade must actually reach the
// engine. Presence, not position: where the outcome is applied is the call
// site's business, what it means is the engine's.
const HANDLERS = [
  ['shouldOverrideUrlLoading: (controller, navigationAction) async {', 'onNavigation', undefined],
  ['onLoadStart: (controller, url) async {', 'onLoadStarted', undefined],
  ['onLoadStop: (controller, url) async {', 'onLoadFinished', undefined],
  ['onReceivedError: (controller, request, error) async {', 'onLoadFailed', undefined],
  ['static Future<inapp.ServerTrustAuthResponse?> _handleServerTrust(', 'onCertificateRejected', ') async {'],
];

for (const [marker, event, openAt] of HANDLERS) {
  test(`${event} is forwarded from its handler`, () => {
    const body = blockAfter(WEBVIEW, marker, openAt, 'webview.dart');
    assert.ok(calls(body, event),
      `${marker.split(':')[0]} no longer tells the engine about ${event}; ` +
      'that event silently stops resolving upgrades');
  });
}

// The deadline is the one outcome the call site has to schedule rather than
// apply, so its arming is structural. The generation it passes is what lets
// the engine refuse a navigation the user has left (asserted behaviourally in
// https_upgrade_events_test.dart).
test('HTTPS-002: the deadline is armed from the engine, with a generation', () => {
  const nav = blockAfter(WEBVIEW,
    'shouldOverrideUrlLoading: (controller, navigationAction) async {',
    undefined, 'webview.dart');
  assert.match(nav, /Timer\(WebViewFactory\.httpsUpgrade\.deadline,/,
    'the duration must be the engine\'s, not a literal at the call site');
  assert.match(nav, /generationAtArm: genAtUpgrade/,
    'without a generation the engine cannot tell a stale deadline from a live one');
  assert.match(nav, /currentGeneration: \(\) => navigationGen/,
    'the engine needs the CURRENT generation, read when the timer fires');
});

// HTTPS-002: one engine per process. A per-webview instance would let a host
// learned http-only in the site's webview be probed again by every nested
// webview, which is the cost the record exists to avoid.
test('HTTPS-002: the engine is one shared instance, not per webview', () => {
  assert.match(WEBVIEW, /static final HttpsUpgradeEngine httpsUpgrade = HttpsUpgradeEngine\(\);/,
    'the engine must be a static on WebViewFactory');
  const constructions = WEBVIEW.match(/HttpsUpgradeEngine\(\)/g) || [];
  assert.equal(constructions.length, 1,
    'a second HttpsUpgradeEngine() means two hosts-seen sets that never agree');
});

// HTTPS-007's position, which the engine cannot own: past the prompt the
// carve-out cannot stop the dialog, and stopping the dialog is the point.
test('HTTPS-007: the certificate carve-out precedes the prompt and any pin', () => {
  const body = blockAfter(WEBVIEW,
    'static Future<inapp.ServerTrustAuthResponse?> _handleServerTrust(',
    ') async {', 'webview.dart');
  const carve = body.search(/httpsUpgrade\s*\.\s*onCertificateRejected\s*\(/);
  const prompt = body.indexOf('await prompt(host, port, cert)');
  const pin = body.indexOf('TrustedHostsService.instance.trust(');
  assert.notEqual(carve, -1, 'the carve-out is gone');
  assert.notEqual(prompt, -1, 'the user prompt is gone');
  assert.ok(carve < prompt,
    'past the prompt it cannot stop the dialog, which is the entire point');
  assert.ok(pin === -1 || carve < pin, 'and it must come before any pin');
});

// HTTPS-002's position: the other branches of the error handler read the
// failing URL as the one the site asked for, and an upgraded one is not.
test('HTTPS-002: the failure forward precedes the handler\'s other recoveries', () => {
  const body = blockAfter(WEBVIEW,
    'onReceivedError: (controller, request, error) async {',
    undefined, 'webview.dart');
  const forward = body.search(/httpsUpgrade\s*\.\s*onLoadFailed\s*\(/);
  for (const later of ['ExternalUrlParser', 'reload(']) {
    const at = body.indexOf(later);
    if (at === -1) continue;
    assert.ok(forward < at,
      `the upgrade failure must be forwarded before "${later}"`);
  }
});

// HTTPS-006. The plugin's own known-host upgrade is iOS/macOS only and covers
// strictly less, but it acts earlier and costs nothing; turning it off would
// be a silent downgrade on the two platforms that have it.
test('HTTPS-006: the app never overrides upgradeKnownHostsToHTTPS', () => {
  const dartFiles = (dir, out = []) => {
    for (const e of fs.readdirSync(path.join(repoRoot, dir), { withFileTypes: true })) {
      const rel = path.join(dir, e.name);
      if (e.isDirectory()) dartFiles(rel, out);
      else if (e.name.endsWith('.dart')) out.push(rel);
    }
    return out;
  };
  for (const f of dartFiles('lib')) {
    const src = stripComments(readRaw(f));
    assert.ok(!/upgradeKnownHostsToHTTPS\s*[:=]/.test(src),
      `${f} sets upgradeKnownHostsToHTTPS; HTTPS-006 says leave it at its ` +
      'default true');
  }
});

// HTTPS-005. The default is the whole feature for anyone who never opens
// settings, so it is worth one line of gate.
test('HTTPS-005: the global pref is registered and defaults on', () => {
  const prefs = stripComments(readRaw('lib/settings/app_prefs.dart'));
  assert.match(prefs, /kHttpsUpgradeEnabledKey:\s*true,/,
    'registered in kExportedAppPrefs so it rides export/import, and true so ' +
    'a fresh install is upgraded');
  assert.match(prefs, /const String kHttpsUpgradeEnabledKey = 'httpsUpgradeEnabled';/);
});
