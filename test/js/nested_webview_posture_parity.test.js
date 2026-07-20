// Nested-webview posture propagation parity.
//
// CLAUDE.md invariant ("Per-site settings MUST apply to nested webviews"): a
// cross-domain outbound link opens an InAppWebViewScreen whose WebViewConfig
// must carry every per-site posture field, or a hostile link silently bypasses
// the user's privacy posture. This test enforces that structurally so the
// class of bug can't silently regress.
//
// Every WebViewConfig field is classified as exactly one of:
//   POSTURE    - per-site setting that MUST propagate to nested webviews.
//                Asserted present in both the nested WebViewConfig(...) call
//                (lib/screens/inappbrowser.dart) and the launchUrl(...)
//                signature (lib/main.dart).
//   PLUMBING   - callbacks / controllers / content / deliberate root-only
//                wiring that legitimately differs on the nested surface.
//   KNOWN_GAP  - posture-ish field NOT yet propagated; tracked, not hidden.
//
// A new WebViewConfig field that is left unclassified fails the completeness
// check, forcing the author to decide (and, if POSTURE, to wire propagation).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

// Strip Dart comments (string-aware so `//` inside a literal survives), so
// commented-out args and brackets in prose can't confuse the parsers below.
function stripComments(src) {
  let out = '';
  let str = null;
  for (let i = 0; i < src.length; i++) {
    const c = src[i], c2 = src[i + 1];
    if (str) {
      out += c;
      if (c === '\\') { out += (c2 ?? ''); i++; continue; }
      if (c === str) str = null;
      continue;
    }
    if (c === '/' && c2 === '/') { while (i < src.length && src[i] !== '\n') i++; out += '\n'; continue; }
    if (c === '/' && c2 === '*') { i += 2; while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) i++; i++; continue; }
    if (c === '"' || c === "'") { str = c; out += c; continue; }
    out += c;
  }
  return out;
}

const read = (p) => stripComments(fs.readFileSync(path.join(repoRoot, p), 'utf8'));

// --- parsers -------------------------------------------------------------

// The `final <type> <name>;` fields declared on the WebViewConfig class,
// stopping at its constructor.
function webViewConfigFields(src) {
  const start = src.indexOf('class WebViewConfig {');
  assert.notEqual(start, -1, 'WebViewConfig class not found');
  const body = src.slice(start);
  const ctor = body.search(/\n  (?:const )?WebViewConfig\(/);
  const decls = body.slice(0, ctor);
  const fields = new Set();
  for (const m of decls.matchAll(/^\s*final\s+.+?\s(\w+);/gm)) fields.add(m[1]);
  return fields;
}

// Balanced extraction of the text inside the first `<opener>` ... matching
// close, starting the scan at `from`.
function balanced(src, opener, from = 0) {
  const start = src.indexOf(opener, from);
  assert.notEqual(start, -1, `"${opener}" not found`);
  let i = start + opener.length - 1; // points at the opening bracket
  const open = src[i];
  const close = { '(': ')', '{': '}', '[': ']' }[open];
  let depth = 0;
  const bodyStart = i + 1;
  for (; i < src.length; i++) {
    const c = src[i];
    if (c === '(' || c === '{' || c === '[') depth++;
    else if (c === ')' || c === '}' || c === ']') {
      depth--;
      if (depth === 0) return { body: src.slice(bodyStart, i), end: i };
    }
  }
  throw new Error(`unbalanced "${opener}"`);
}

// Named argument labels at the top level of a call body (`name: value,`),
// ignoring `:` inside nested groups and ternaries.
function topLevelLabels(body) {
  const labels = [];
  let depth = 0;
  let atArgStart = true;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === '(' || c === '[' || c === '{') { depth++; atArgStart = false; continue; }
    if (c === ')' || c === ']' || c === '}') { depth--; atArgStart = false; continue; }
    if (depth !== 0) continue;
    if (c === ',') { atArgStart = true; continue; }
    if (atArgStart && !/\s/.test(c)) {
      const m = body.slice(i).match(/^(\w+)\s*:/);
      if (m) labels.push(m[1]);
      atArgStart = false;
    }
  }
  return new Set(labels);
}

// Named parameters of `launchUrl(String url, { ... })`: last identifier of
// each top-level entry in the `{ ... }` block, minus any `= default`.
function launchUrlParams(src) {
  // The opener ends at the `{`, so balanced() returns the named-params body.
  const inner = balanced(src, 'launchUrl(String url, {', 0).body;
  const names = new Set();
  let depth = 0, seg = '';
  const flush = () => {
    const noDefault = seg.split('=')[0].trim();
    const m = noDefault.match(/(\w+)\s*$/);
    if (m) names.add(m[1]);
    seg = '';
  };
  for (const c of inner) {
    if (c === '(' || c === '[' || c === '{' || c === '<') depth++;
    else if (c === ')' || c === ']' || c === '}' || c === '>') depth--;
    if (c === ',' && depth === 0) { flush(); continue; }
    seg += c;
  }
  flush();
  return names;
}

// --- classification ------------------------------------------------------

const POSTURE = new Set([
  'siteId', 'javascriptEnabled', 'userAgent', 'thirdPartyCookiesEnabled',
  'incognito', 'language', 'zoomPercent', 'clearUrlEnabled', 'dnsBlockEnabled',
  'contentBlockEnabled', 'trackingProtectionEnabled', 'spoofWindowWidth',
  'spoofWindowHeight', 'letterboxEnabled', 'fingerprintResetNonce',
  'localCdnEnabled', 'userScripts', 'locationMode', 'spoofLatitude',
  'spoofLongitude', 'spoofAccuracy', 'spoofTimezone', 'spoofTimezoneFromLocation',
  'liveLocationGranularity', 'webRtcPolicy', 'proxySettings',
  'notificationsEnabled',
]);

const PLUMBING = new Set([
  'key', 'initialUrl', 'initialHtml', 'deferInitialLoad',
  'backForwardGestures', // deliberate root-only: nested uses route-pop (NAV-008)
  // deliberate root-only (BGAUDIO-006): drives the Android media notification
  // for the root site's playback. Not a privacy posture, so a nested
  // cross-domain webview not raising the notification is acceptable, not a
  // bypass — Android-only behavioral wiring, like backForwardGestures.
  'backgroundAudioEnabled',
  'onUrlChanged', 'onCookiesChanged', 'cookieManager', 'containerCookieManager',
  'cookieSiteId', 'onFindResult', 'shouldOverrideUrlLoading', 'onLoadingChanged',
  'onProgressChanged',
  'onWindowRequested', 'onHtmlLoaded', 'shouldFetchHtml', 'onConsoleMessage',
  'onConfirmScriptFetch', 'onExternalSchemeUrl', 'pullToRefreshController',
  'onRendererGone', 'onProtectedMediaRequest',
]);

// Posture-ish but not yet threaded to nested webviews. An archive-tier site
// following an outbound link gets a nested webview bound to the cleartext
// `ws-<siteId>` container instead of the opaque archive container. Narrow
// (archive-tier + cross-domain nav) and tracked here rather than hidden.
const KNOWN_GAP = new Set([
  'archiveContainerId',
]);

// --- tests ---------------------------------------------------------------

const webviewSrc = read('lib/services/webview.dart');
const nestedSrc = read('lib/screens/inappbrowser.dart');
const mainSrc = read('lib/main.dart');

const fields = webViewConfigFields(webviewSrc);
const nestedArgs = topLevelLabels(balanced(nestedSrc, 'WebViewConfig(', 0).body);
const launchParams = launchUrlParams(mainSrc);

test('every WebViewConfig field is classified (no field slips past unclassified)', () => {
  const unclassified = [...fields].filter(
    (f) => !POSTURE.has(f) && !PLUMBING.has(f) && !KNOWN_GAP.has(f));
  assert.deepEqual(
    unclassified, [],
    `unclassified WebViewConfig field(s): ${unclassified.join(', ')}. ` +
    'Add each to POSTURE (and wire it into launchUrl + the nested ' +
    'WebViewConfig), PLUMBING, or KNOWN_GAP.');
});

test('classification only names real WebViewConfig fields', () => {
  for (const set of [['POSTURE', POSTURE], ['PLUMBING', PLUMBING], ['KNOWN_GAP', KNOWN_GAP]]) {
    for (const f of set[1]) {
      assert.ok(fields.has(f), `${set[0]} names "${f}", not a WebViewConfig field`);
    }
  }
});

test('every POSTURE field propagates into the nested WebViewConfig', () => {
  const missing = [...POSTURE].filter((f) => !nestedArgs.has(f));
  assert.deepEqual(
    missing, [],
    `per-site field(s) dropped from the nested WebViewConfig ` +
    `(lib/screens/inappbrowser.dart): ${missing.join(', ')}`);
});

test('every POSTURE field is carried by the launchUrl signature', () => {
  const missing = [...POSTURE].filter((f) => !launchParams.has(f));
  assert.deepEqual(
    missing, [],
    `per-site field(s) missing from launchUrl (lib/main.dart): ${missing.join(', ')}`);
});

test('KNOWN_GAP fields are still absent from nested (else promote to POSTURE)', () => {
  const nowPresent = [...KNOWN_GAP].filter((f) => nestedArgs.has(f));
  assert.deepEqual(
    nowPresent, [],
    `field(s) now propagate to nested webviews: ${nowPresent.join(', ')}. ` +
    'Move them from KNOWN_GAP to POSTURE.');
});
