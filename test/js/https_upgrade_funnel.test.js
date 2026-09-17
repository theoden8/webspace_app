// Structural gates for the HTTPS upgrade's call-site wiring.
//
// The engine is unit-tested and driven over real sockets, but the ~20 lines
// that connect it to the webview are the part no Dart test reaches: delete the
// `onReceivedError` fallback and every other test in this repo still passes,
// while a default-on upgrade silently stops falling back and every http-only
// site in the world becomes an error page. Same for the success bookkeeping,
// for the single shared engine, and for the platform flag HTTPS-006 says to
// leave alone.
//
// Each assertion below was checked against the mutation it is meant to catch
// (delete the call, move it, flip the flag); a gate that passes either way is
// worse than no gate, because it reads as cover.
//
// Cross-links:
//   openspec/changes/https-upgrade/specs/https-upgrade/spec.md  HTTPS-002/005/006
//   openspec/changes/https-upgrade/specs/tracking-protection/spec.md  ETP-028
//
// The call-site ORDERING (HTTPS-004) lives in page_bridge_authority.test.js,
// beside the CAPTCHA-008 ordering it copies.

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

// HTTPS-002. The fallback is what keeps a default-on upgrade from turning
// every http-only host into an error page, and it is one `if` block deep in a
// handler that has five other recovery branches.
test('HTTPS-002: onReceivedError asks the engine for a fallback', () => {
  const body = blockAfter(WEBVIEW,
    'onReceivedError: (controller, request, error) async {',
    undefined, 'webview.dart');
  assert.match(body, /httpsUpgrade\s*\n?\s*\.fallbackFor\(/,
    'without this, an upgraded navigation to a host with no TLS ends as an ' +
    'error page instead of loading over http');
  const ask = body.search(/httpsUpgrade\s*\n?\s*\.fallbackFor\(/);
  const load = body.indexOf('inapp.WebUri(upgradeFallback)');
  assert.ok(load > ask, 'the fallback URL must be the one the engine returned');
});

// The other branches of that handler treat the failing URL as the one the site
// asked for. For an upgraded navigation that is false — we substituted it — so
// the fallback has to be reached before any of them can act on it.
test('HTTPS-002: the fallback runs before the handler\'s other recoveries', () => {
  const body = blockAfter(WEBVIEW,
    'onReceivedError: (controller, request, error) async {',
    undefined, 'webview.dart');
  const fallback = body.search(/httpsUpgrade\s*\n?\s*\.fallbackFor\(/);
  for (const later of ['LogService.instance.log(', 'ExternalUrlParser', 'reload(']) {
    const at = body.indexOf(later);
    if (at === -1) continue;
    assert.ok(fallback < at,
      `the upgrade fallback must precede "${later}": that branch reads the ` +
      'failing URL as the site\'s own, and an upgraded one is not');
  }
});

// Without this the in-flight map grows by one per upgraded navigation for the
// life of the process, and a later unrelated failure on the same URL string
// reads as a fallback to a load that finished long ago.
test('HTTPS-002: a completed load clears its in-flight upgrade', () => {
  const body = blockAfter(WEBVIEW, 'onLoadStop: (controller, url) async {',
    undefined, 'webview.dart');
  assert.match(body, /httpsUpgrade\.recordUpgradeSuccess\(/,
    'onLoadStop must tell the engine the upgrade landed');
});

// HTTPS-002 again: one engine per process. A per-webview instance would let a
// host learned http-only in the site's webview be probed again by every nested
// webview, which is the cost the record exists to avoid.
test('HTTPS-002: the engine is one shared instance, not per webview', () => {
  assert.match(WEBVIEW, /static final HttpsUpgradeEngine httpsUpgrade = HttpsUpgradeEngine\(\);/,
    'the engine must be a static on WebViewFactory');
  const constructions = WEBVIEW.match(/HttpsUpgradeEngine\(\)/g) || [];
  assert.equal(constructions.length, 1,
    'a second HttpsUpgradeEngine() means two hosts-seen sets that never agree');
});

// HTTPS-002, the deadline. A refused port errors and reaches onReceivedError;
// a port that accepts and then says nothing produces no event at all, so the
// only thing that can rescue that navigation is a timer armed when the upgrade
// was issued. Delete it and the page hangs on a site that would have loaded
// instantly over http, with every other test still green.
test('HTTPS-002: issuing an upgrade arms the deadline', () => {
  const nav = blockAfter(WEBVIEW,
    'shouldOverrideUrlLoading: (controller, navigationAction) async {',
    undefined, 'webview.dart');
  assert.match(nav, /Timer\(WebViewFactory\.httpsUpgrade\.deadline,/,
    'the deadline must come from the engine, not a literal at the call site');
  const timer = nav.indexOf('Timer(WebViewFactory.httpsUpgrade.deadline,');
  const load = nav.indexOf('inapp.WebUri(upgraded)');
  assert.ok(timer !== -1 && load !== -1 && timer < load,
    'arm the deadline before issuing the load it is meant to rescue');
});

// The two things that make a late timer harmless. Without the engine call it
// would re-derive an http URL and downgrade a page that is already up over
// https; without the generation check it would yank a user back to http on a
// navigation they have since left.
test('HTTPS-002: the deadline goes through the engine and checks generation',
  () => {
    const nav = blockAfter(WEBVIEW,
      'shouldOverrideUrlLoading: (controller, navigationAction) async {',
      undefined, 'webview.dart');
    const timer = nav.indexOf('Timer(WebViewFactory.httpsUpgrade.deadline,');
    const body = nav.slice(timer);
    const gen = body.indexOf('if (navigationGen != genAtUpgrade) return;');
    const ask = body.indexOf('fallbackForTimeout(upgraded)');
    assert.ok(gen !== -1,
      'a deadline armed for a navigation the user has left must not fire');
    assert.ok(ask !== -1,
      'the timeout fallback must be the engine\'s: it is fallbackFor, so a ' +
      'load that already succeeded left no in-flight entry to reverse');
    assert.ok(gen < ask, 'check the generation before touching engine state');
  });

// HTTPS-007. A certificate failure does not reach onReceivedError on
// Android/Linux — it reaches the trust callback, which PROMPTS and pins on
// approval (TLS-002/007). Without this carve-out a default-on upgrade asks the
// user to vouch for a connection the app invented, about a URL they never
// typed, and a yes pins a bad certificate for good.
test('HTTPS-007: an upgrade never reaches the certificate prompt', () => {
  const body = blockAfter(WEBVIEW,
    'static Future<inapp.ServerTrustAuthResponse?> _handleServerTrust(',
    ') async {', 'webview.dart');
  const carve = body.indexOf('httpsUpgrade.fallbackForHost(host)');
  assert.notEqual(carve, -1,
    'the trust handler must ask whether this host is an upgrade of ours');

  const prompt = body.indexOf('await prompt(host, port, cert)');
  assert.notEqual(prompt, -1, 'the user prompt is gone');
  assert.ok(carve < prompt,
    'the carve-out must come first: past the prompt it cannot stop the ' +
    'dialog, which is the entire point');

  const pin = body.indexOf('TrustedHostsService.instance.trust(');
  assert.ok(pin === -1 || carve < pin, 'and it must come before any pin');
});

// Cancelling without loading the http URL would leave the user on an error
// page for a navigation they did not make; loading without cancelling would
// leave the rejected connection live.
test('HTTPS-007: the carve-out loads the fallback and cancels the challenge',
  () => {
    const body = blockAfter(WEBVIEW,
      'static Future<inapp.ServerTrustAuthResponse?> _handleServerTrust(',
      ') async {', 'webview.dart');
    const carve = body.indexOf('httpsUpgrade.fallbackForHost(host)');
    const after = body.slice(carve);
    const load = after.indexOf('inapp.WebUri(upgradeFallback)');
    const cancel = after.indexOf('ServerTrustAuthResponseAction.CANCEL');
    assert.ok(load !== -1, 'the http URL the user actually asked for is not loaded');
    assert.ok(cancel !== -1 && cancel > load,
      'the challenge must be cancelled, after handing back the http load');
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
