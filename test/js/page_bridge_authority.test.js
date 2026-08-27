// Structural guard on what page-reachable code is allowed to decide.
//
// Every JS bridge handler and every shim-driven rewrite in webview.dart is
// reachable from the page — the shims are injected `forMainFrameOnly: false`,
// so a cross-origin iframe can call the handlers directly, and a subframe
// navigation reaches shouldOverrideUrlLoading. Each fact below is call-site
// wiring rather than a testable unit, so a refactor that hands authority back
// to the page fails CI here instead of silently reopening the hole.
//
// Cross-links:
//   openspec/specs/clearurls/spec.md            CURL-014, CURL-015
//   openspec/specs/content-blocker/spec.md      CB-014
//   openspec/specs/dns-blocklist/spec.md        DNS-018
//   openspec/specs/captcha-support/spec.md      CAPTCHA-007/008/009
//   openspec/specs/web-camera-access/spec.md    CAM-013 / MIC-013
//   openspec/specs/ip-leakage/spec.md           LEAK-002

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const readRaw = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');
// Strip line comments so prose describing a call does not count as one.
const stripComments = (src) =>
  src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
const read = (rel) => stripComments(readRaw(rel));

const WEBVIEW = read('lib/services/webview.dart');

const dartFiles = (dir, out = []) => {
  for (const e of fs.readdirSync(path.join(repoRoot, dir), { withFileTypes: true })) {
    const rel = path.join(dir, e.name);
    if (e.isDirectory()) dartFiles(rel, out);
    else if (e.name.endsWith('.dart')) out.push(rel);
  }
  return out;
};

// --- the navigation decision ---------------------------------------------

const NAV = blockAfter(WEBVIEW, 'shouldOverrideUrlLoading: (controller, navigationAction) async {',
  undefined, 'webview.dart');

test('CURL-014/015 + CB-014: URL rewrites sit below the main-frame gate', () => {
  const gate = NAV.indexOf('if (!isMainFrame) {');
  assert.notEqual(gate, -1, 'the isForMainFrame gate is gone');

  for (const rewrite of ['ClearUrlService.instance.cleanUrl(url)',
    'ContentBlockerService.instance\n              .rewrittenUrl(url']) {
    const at = NAV.indexOf(rewrite);
    assert.notEqual(at, -1, `${rewrite} is gone from shouldOverrideUrlLoading`);
    assert.ok(at > gate,
      `${rewrite} drives a top-frame loadUrl, so it must run below the ` +
      'main-frame gate — above it, a cross-origin subframe navigation ' +
      'steers the top document');
  }
});

test('CURL-014/015 + CB-014: a rewrite target is scheme-checked before it is loaded', () => {
  const loads = [...NAV.matchAll(/controller\.loadUrl\(/g)];
  assert.ok(loads.length >= 2, 'expected the two rewrite loads');

  // Both rewrite results are attacker-influenced: ClearURLs returns a
  // redirection capture group, $removeparam a filter-list rewrite. Android's
  // loadUrl takes any scheme, so `javascript:` would run in the top document.
  for (const source of ['cleanedUrl', 'rewritten']) {
    const guard = new RegExp(`ExternalUrlParser\\.isLoadableWebUrl\\(${source}\\)`);
    assert.match(NAV, guard,
      `the ${source} rewrite target must be gated on isLoadableWebUrl`);
    const at = NAV.search(guard);
    const load = NAV.indexOf(`inapp.WebUri(${source})`);
    assert.ok(at !== -1 && load !== -1 && at < load,
      `the ${source} guard must precede the loadUrl that consumes it`);
  }
});

test('CAPTCHA-008: the captcha allow comes after the routing decision', () => {
  const override = NAV.indexOf('config.shouldOverrideUrlLoading!(url, hasGesture)');
  const captcha = NAV.indexOf('isCaptchaChallenge(url)');
  assert.notEqual(override, -1, 'the shouldOverrideUrlLoading call is gone');
  assert.notEqual(captcha, -1, 'the captcha allow is gone');
  assert.ok(captcha > override,
    'taken first, "is this a captcha URL?" is a way to navigate the parent ' +
    'webview to any origin with blockAutoRedirects, the gesture requirement ' +
    'and the cross-domain nested route all skipped');
});

test('CAPTCHA-007: the captcha markers Cloudflare serves per-origin are path-scoped', () => {
  const body = blockAfter(WEBVIEW, 'static bool isCaptchaChallenge(String url) {',
    undefined, 'webview.dart');
  assert.ok(!/url\.contains\(/.test(body),
    'a substring test on the whole URL lets any origin claim a challenge ' +
    'with an attacker-chosen query or fragment — match uri.path instead');
  for (const marker of ['cdn-cgi/challenge-platform', 'cf-turnstile']) {
    assert.ok(body.includes(`uri.path.contains('`) && body.includes(marker),
      `${marker} must be matched against uri.path`);
  }
});

// --- the popup ------------------------------------------------------------

test('CAPTCHA-009: the popup webview inherits the parent site posture', () => {
  const body = blockAfter(WEBVIEW, 'static Widget createPopupWebView({', '}) {',
    'webview.dart');
  assert.ok(!/javaScriptEnabled:\s*true/.test(body),
    'the popup must honor the site\'s javascriptEnabled, not hardcode true');
  for (const wiring of [
    '_buildPageScripts(parent)',   // the same shims as the site webview
    '_bindingFor(parent)',         // the same container + proxy
    '_registerPageHandlers(',      // the Dart side those shims call
    'parent.userAgent',
    'parent.incognito',
  ]) {
    assert.ok(body.includes(wiring),
      `createPopupWebView no longer carries ${wiring}`);
  }
  assert.ok(WEBVIEW.includes('_popupParentConfigs[windowId] = config;'),
    'onCreateWindow must record the requesting webview\'s config so the '
    + 'popup can inherit it');
});

// --- the permission prompts ----------------------------------------------

test('CAM-013 / MIC-013: camera / microphone prompts name an origin read from the webview', () => {
  for (const handler of ['webCameraRequest', 'webMicrophoneRequest']) {
    const at = WEBVIEW.indexOf(`handlerName: '${handler}'`);
    assert.notEqual(at, -1, `${handler} registration is gone`);
    const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
    assert.ok(!body.includes('args[0]'),
      `${handler} must not take the origin from the page: the shim is ` +
      'injected forMainFrameOnly:false, so any frame can call the handler ' +
      'directly and name a site it is not');
    assert.ok(body.includes('_promptOrigin(controller, config)'),
      `${handler} must derive the origin from the controller`);
  }
  assert.match(WEBVIEW,
    /_promptOrigin\([\s\S]{0,200}?await controller\.getUrl\(\)\)\?\.toString\(\) \?\? config\.initialUrl/,
    '_promptOrigin must read the live URL, falling back to the site URL');
});

// --- the blocker bridge ---------------------------------------------------

test('DNS-018: getBlockBloom hands page JS no cross-site host list', () => {
  const at = WEBVIEW.indexOf("handlerName: 'getBlockBloom'");
  assert.notEqual(at, -1, 'the getBlockBloom handler is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(!body.includes("map['cache']"),
    'the app-wide domain-decision cache records every host every site ' +
    'requests; any page can call this handler and there is no origin ' +
    'allowlist, so it must not travel in the response');
  assert.ok(!/getDomainCache/.test(body));

  const leakers = dartFiles('lib').filter((f) => read(f).includes('getDomainCache('));
  assert.deepEqual(leakers, [],
    'the raw domain cache accessor is back; use debugDomainCache and keep it '
    + 'off the bridge');
});

test('DNS-018: the bloom consumer no longer seeds its cache from the response', () => {
  assert.ok(!WEBVIEW.includes('var persisted = map.cache;'),
    'the interceptor JS must not read a host list off getBlockBloom');
});

// --- sub-resource reach ---------------------------------------------------

test('every page shim that must see sub-resources sets forMainFrameOnly: false', () => {
  // On iOS/macOS the JS interceptor is the ONLY sub-resource blocking (no
  // shouldInterceptRequest, no WKContentRuleList). UserScript.forMainFrameOnly
  // defaults to true, so an omission leaves every tracker in a cross-origin
  // iframe unblocked — and it looks identical to a correct call.
  for (const group of ['clearurl_share', 'block_resource_observer',
    'block_js_interceptor']) {
    const at = WEBVIEW.indexOf(`groupName: '${group}'`);
    assert.notEqual(at, -1, `the ${group} user script is gone`);
    // Read from injectionTime rather than the group name: the `source:` in
    // between is a JS blob whose own braces and parens defeat brace matching.
    const inj = WEBVIEW.indexOf('injectionTime:', at);
    const decl = WEBVIEW.slice(inj, inj + 300);
    assert.ok(decl.includes('forMainFrameOnly: false'),
      `${group} must be injected into every frame`);
  }
});

// --- outbound reach -------------------------------------------------------

test('LEAK-002: the media-session artwork fetch goes through the outbound seam', () => {
  const svc = read('lib/services/media_session_service.dart');
  assert.ok(svc.includes('outboundHttp.clientFor(') && svc.includes('resolveEffectiveProxy('),
    'the artwork URL is page-supplied, so its fetch must honor the site proxy');
  assert.ok(svc.includes('OutboundClientBlocked'),
    'a proxy that cannot be honored must drop the artwork, never fall back');

  assert.ok(!read('lib/platform/host_platform_io.dart').includes('hostFetchBounded'),
    'the native half of hostFetchBounded was an io.HttpClient with no proxy '
    + 'at all; it must stay deleted');
  // The web half survives as a stub that returns null without a request, so
  // it is exempt as a definition — but nothing may call the name.
  const callers = dartFiles('lib')
    .filter((f) => !f.startsWith(path.join('lib', 'platform', 'host_platform_')))
    .filter((f) => read(f).includes('hostFetchBounded('));
  assert.deepEqual(callers, [],
    'hostFetchBounded is a direct (unproxied) client; every Dart outbound '
    + 'call goes through outboundHttp.clientFor');
});
