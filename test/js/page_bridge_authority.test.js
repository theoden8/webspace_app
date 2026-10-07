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
//   openspec/specs/captcha-support/spec.md      CAPTCHA-007/008/009/010
//   openspec/specs/web-camera-access/spec.md    CAM-013 / MIC-013
//   openspec/specs/ip-leakage/spec.md           LEAK-002
//   openspec/specs/per-site-location/spec.md    LOC-011
//   openspec/changes/upstream-webview-defects/specs/nested-url-blocking/spec.md  NESTED-013

const test = require('node:test');
const assert = require('node:assert/strict');
const source = require('./helpers/source');

const { blockAfter, dartFiles } = source;
// Comments blanked so prose describing a call does not count as one.
const read = (rel) => source.code(source.read(rel));

const WEBVIEW = read('lib/services/webview.dart');

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
  const captcha = NAV.indexOf('isCaptchaChallenge(url, siteUrl: config.initialUrl)');
  assert.notEqual(override, -1, 'the shouldOverrideUrlLoading call is gone');
  assert.notEqual(captcha, -1, 'the captcha allow is gone');
  assert.ok(captcha > override,
    'taken first, "is this a captcha URL?" is a way to navigate the parent ' +
    'webview to any origin with the gesture requirement and the ' +
    'cross-domain nested route skipped');
});

test('HTTPS-004: the https upgrade comes after the routing decision', () => {
  const override = NAV.indexOf('config.shouldOverrideUrlLoading!(url, hasGesture)');
  const upgrade = NAV.indexOf('WebViewFactory.httpsUpgrade');
  assert.notEqual(override, -1, 'the shouldOverrideUrlLoading call is gone');
  assert.notEqual(upgrade, -1, 'the https upgrade is gone');
  assert.ok(upgrade > override,
    'taken first, a scheme rewrite re-enters the navigation pipeline with ' +
    'the gesture requirement and the cross-domain nested route already ' +
    'behind it — the same hole CAPTCHA-008 had to close');
});

// The upgrade cancels and reissues, so it is the shape the guard above the
// ClearURLs / $removeparam rewrites exists for: the URL it hands to loadUrl
// must be one the engine produced from the navigation's own URL, never one a
// page supplied.
test('HTTPS-004: the upgraded URL is the engine\'s, not the page\'s', () => {
  assert.match(NAV, /onNavigation\(url, enabled: config\.posture\.blocking\.httpsUpgrade\)/,
    'the engine must be asked about the navigation URL itself, and about the ' +
    'site\'s own setting');
  const upgrade = NAV.indexOf('WebViewFactory.httpsUpgrade');
  const load = NAV.indexOf('inapp.WebUri(upgrade.load!)');
  assert.ok(load > upgrade, 'loadUrl must consume what the engine returned');
});

test('CAPTCHA-007: the captcha markers Cloudflare serves per-origin are path-scoped', () => {
  const body = blockAfter(WEBVIEW, 'static bool isCaptchaChallenge(String url, {String? siteUrl}) {',
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
  ]) {
    assert.ok(body.includes(wiring),
      `createPopupWebView no longer carries ${wiring}`);
  }
  assert.match(body, /initialSettings: _siteSettings\(\s*binding,\s*parent\.posture,/,
    'the popup must take its native settings from the parent posture, '
    + 'through the builder the site webview uses');
  assert.ok(WEBVIEW.includes('_popupParentConfigs[windowId] = config;'),
    'onCreateWindow must record the requesting webview\'s config so the '
    + 'popup can inherit it');
});

// --- top-document steering from a subframe --------------------------------

test('NESTED-013: a subframe cannot steer the top document through an external scheme', () => {
  const at = WEBVIEW.indexOf("'External scheme intercepted: scheme=");
  assert.notEqual(at, -1, 'the external-scheme branch is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('onExternalSchemeUrl', at));
  const gate = body.indexOf('navigationAction.isForMainFrame == false');
  const load = body.indexOf('controller.loadUrl(');
  assert.notEqual(gate, -1,
    'the external branch must refuse a subframe: it resolves intent:// and '
    + 'x-safari- targets onto the top-frame controller');
  assert.ok(load === -1 || gate < load,
    'the frame test must precede the reissued load');
});

test('NESTED-013: onCreateWindow loads into the top webview only on a gesture', () => {
  const at = WEBVIEW.indexOf('onCreateWindow: (controller, createWindowAction)');
  assert.notEqual(at, -1, 'onCreateWindow is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('onProgressChanged:', at));
  const loads = body.split('controller.loadUrl(').length - 1;
  const gated = (body.match(/if \(allow && hasGesture\) \{/g) || []).length;
  assert.ok(loads > 0, 'no loadUrl in onCreateWindow: the guard has nothing to gate');
  assert.equal(gated, loads,
    'every loadUrl in onCreateWindow must sit under `allow && hasGesture`: a '
    + 'script-driven window.open() must not navigate the top document');
});

// --- web notifications ----------------------------------------------------

test('NOTIF-010: a notification post from a cross-origin iframe is dropped', () => {
  const at = WEBVIEW.indexOf("handlerName: 'webNotification'");
  assert.notEqual(at, -1, 'webNotification registration is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(body.includes('inapp.JavaScriptHandlerFunctionData call'),
    'webNotification must use the frame-aware callback: the polyfill is in '
    + 'every frame and any frame can call the handler directly');
  assert.ok(body.includes('if (!call.isMainFrame)'),
    'webNotification must test the frame before posting under the site');
  assert.ok(!body.includes('args[0][\'siteId\']') && !body.includes("data['siteId']"),
    'the target site is never taken from the page');
});

// --- the site icon ---------------------------------------------------------

test('ICON-011: only the top document can end its own icon round', () => {
  const at = WEBVIEW.indexOf('handlerName: kIconLinksChangedHandler');
  assert.notEqual(at, -1, 'the icon-link handler registration is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(body.includes('inapp.JavaScriptHandlerFunctionData call'),
    'the icon-link handler must use the frame-aware callback');
  assert.ok(body.includes('if (call.isMainFrame) iconEngine.onIconLinksChanged()'),
    'a subframe must not be able to stop the site icon from updating');
});

test('ICON-013: only the top document reports its load and its icon links', () => {
  const loaded = WEBVIEW.indexOf('handlerName: kIconDocumentLoadedHandler');
  assert.notEqual(loaded, -1, 'the load handler registration is gone');
  const loadedBody =
    WEBVIEW.slice(loaded, WEBVIEW.indexOf('addJavaScriptHandler', loaded + 1));
  assert.ok(loadedBody.includes('inapp.JavaScriptHandlerFunctionData call'),
    'the load handler must use the frame-aware callback');
  assert.ok(loadedBody.includes('if (call.isMainFrame) {'),
    'a subframe load must not open the icon gate for the top document');
  assert.ok(loadedBody.includes('.onDocumentLoaded(call.requestUrl.toString())'),
    'the document URL must come from the bridge, not from the page arguments');
  const fetcherBlock = WEBVIEW.lastIndexOf('if (iconFetcher != null) {', loaded);
  assert.ok(fetcherBlock !== -1 &&
      fetcherBlock > WEBVIEW.lastIndexOf('if (iconEngine != null) {', loaded),
    'the load report gates only the fetch path: on Android onReceivedIcon can '
    + 'overtake it, so it cannot open the gate for the webview\'s own icons');
  assert.ok(WEBVIEW.includes('iconEngine == null || iconSource != PageIconSource.declaredLinks'),
    'the fetch path runs only where the declared links are the icon source');

  const links = WEBVIEW.indexOf('handlerName: kIconLinksHandler');
  assert.notEqual(links, -1, 'the icon-links handler registration is gone');
  const linksBody =
    WEBVIEW.slice(links, WEBVIEW.indexOf('addJavaScriptHandler', links + 1));
  assert.ok(linksBody.includes('if (!call.isMainFrame) return null;'),
    'a subframe must not choose what the app fetches as the site icon');
  assert.ok(linksBody.includes('iconEngine.claimIconLinks(documentUrl)'),
    'one fetch per document: a page reporting in a loop must not refetch');
  assert.ok(linksBody.includes('final documentUrl = call.requestUrl.toString();'),
    'the host check must use the bridge URL, which the page cannot forge');
});

test('ICON-013: page icon fetches go through the guarded fetch only', () => {
  const at = WEBVIEW.indexOf('final iconFetcher =');
  assert.notEqual(at, -1, 'the icon fetcher is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf(';\n', WEBVIEW.indexOf('SiteIconFetcher(', at)));
  assert.ok(body.includes('fetchPageIconBytes('),
    'page icon links are page-chosen URLs: fetch them through the guarded path');
  assert.ok(body.includes('proxy: config.posture.container.proxy'),
    "a page icon must go through the site's proxy");
  assert.ok(body.includes('_pageIconRequestAllowed(config, target, documentUrl)'),
    "the site's blockers must see every page icon request");
});

test('ICON-014: the webview icon and the fetched links never run together', () => {
  const at = WEBVIEW.indexOf('onReceivedIcon: iconEngine == null');
  assert.notEqual(at, -1, 'the onReceivedIcon wiring is gone');
  const line = WEBVIEW.slice(at, WEBVIEW.indexOf('\n', at));
  assert.ok(line.includes('iconSource != PageIconSource.webview'),
    'onReceivedIcon must be dropped whenever the declared links are fetched: '
    + 'it can overtake the load report the fetch path relies on');
  assert.ok(WEBVIEW.includes('final iconSource = pageIconSource;'),
    'both paths must read one source, taken once per webview');
  const enable = WEBVIEW.indexOf('SiteIconNative.ensureEnabled()');
  assert.ok(WEBVIEW.slice(WEBVIEW.lastIndexOf('if (', enable), enable)
      .includes('iconSource == PageIconSource.webview'),
    "WebView's favicon downloads are turned on only when its icon is taken");
});

test('ICON-009: popups and the shared page scripts never report a site icon', () => {
  const build = WEBVIEW.indexOf('}) _buildPageScripts(WebViewConfig config) {');
  const buildBody = WEBVIEW.slice(build, WEBVIEW.indexOf('\n  }\n', build));
  assert.ok(!buildBody.includes('buildIconLinkWatcherShim'),
    '_buildPageScripts is shared with the popup webview');
  const popup = WEBVIEW.indexOf('static Widget createPopupWebView({');
  const popupBody = WEBVIEW.slice(popup, WEBVIEW.indexOf('\n  }\n', popup));
  assert.ok(!popupBody.includes('onReceivedIcon'),
    'a popup shows another page and must not repaint the site icon');
});

test('LIR-035: only the site\'s top document declares its search', () => {
  const build = WEBVIEW.indexOf('}) _buildPageScripts(WebViewConfig config) {');
  const buildBody = WEBVIEW.slice(build, WEBVIEW.indexOf('\n  }\n', build));
  assert.ok(!buildBody.includes('buildSearchLinkWatcherShim'),
    '_buildPageScripts is shared with the popup webview');
  const popup = WEBVIEW.indexOf('static Widget createPopupWebView({');
  const popupBody = WEBVIEW.slice(popup, WEBVIEW.indexOf('\n  }\n', popup));
  assert.ok(!popupBody.includes('kSearchLinksHandler'),
    'a popup shows another page and must not set the site\'s search');
  const at = WEBVIEW.indexOf('handlerName: kSearchLinksHandler,');
  assert.notEqual(at, -1, 'the search link handler is gone');
  const end = WEBVIEW.indexOf('siteSearch.onSearch(found)', at);
  assert.notEqual(end, -1, 'the handler no longer reports what it found');
  const handler = WEBVIEW.slice(at, end);
  assert.ok(handler.includes('if (!call.isMainFrame || !siteSearch.enabled()) return null;'),
    'a subframe can call the handler; its search is not the site\'s');
  assert.ok(handler.includes('_pageIconRequestAllowed('),
    'the description is fetched through the site\'s blockers');
  assert.ok(handler.includes('proxy: config.posture.container.proxy'),
    'the description is fetched through the site\'s proxy');
});

// --- the verification popup -----------------------------------------------

test('CAPTCHA-010: the popup webview runs the document checks and stays on the challenge', () => {
  const at = WEBVIEW.indexOf('static Widget createPopupWebView({');
  assert.notEqual(at, -1, 'createPopupWebView is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('\n  }\n', at));
  const settings = blockAfter(WEBVIEW, 'static inapp.InAppWebViewSettings _siteSettings(', '}) {',
    'webview.dart');
  assert.ok(body.includes('initialSettings: _siteSettings(')
      && settings.includes('..useShouldOverrideUrlLoading = true'),
    'the popup must opt into shouldOverrideUrlLoading or the callback never fires');
  assert.match(body,
    /shouldOverrideUrlLoading: \(_, navigationAction\) async =>\s*_onSiteNavigationPolicy\(parent, navigationAction,\s*allowCaptcha: true\)/,
    'the popup had no navigation gate: after the first load it went anywhere');
  const gateAt = WEBVIEW.indexOf('static inapp.NavigationActionPolicy _onSiteNavigationPolicy(');
  assert.notEqual(gateAt, -1, '_onSiteNavigationPolicy is gone');
  const gate = WEBVIEW.slice(gateAt, WEBVIEW.indexOf('\n  }\n', gateAt));
  for (const check of [
    '_judgeAndRecord(',
    "requestType: 'document'",
    'navigationAction.isForMainFrame == false',
    'isCaptchaChallenge(url, siteUrl: config.initialUrl)',
  ]) {
    assert.ok(gate.includes(check), `popup gate lacks ${check}`);
  }
  // The path markers only count on the site's own domain, at every caller.
  const callers = WEBVIEW.match(/isCaptchaChallenge\(url\)/g) || [];
  assert.equal(callers.length, 0,
    'isCaptchaChallenge must be called with siteUrl: a bare path marker on any origin is a claim');
});

// NOTIF-016: a background check is the site with no user, so its top
// document stays on the site with no captcha exception, and nothing it asks
// for is granted.
test('NOTIF-016: a headless check stays on the site and is granted nothing', () => {
  const at = WEBVIEW.indexOf('static Future<(HeadlessSiteCheck?, WakeSkip?)> openHeadlessCheck(');
  assert.notEqual(at, -1, 'openHeadlessCheck is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('\n  }\n', at));
  assert.match(body,
    /_onSiteNavigationPolicy\(config, navigationAction,\s*allowCaptcha: false,\s*refusePlainHttp: posture\.blocking\.httpsUpgrade\)/,
    'a headless check must run the on-site navigation gate without the captcha exception');
  assert.match(body, /initialSettings: _siteSettings\(\s*binding,\s*posture,/,
    'a headless check takes its native settings from the site posture, '
    + 'through the builder the site webview uses');
  for (const check of [
    'if (binding.proxyUnavailable) return (null, WakeSkip.proxyUnavailable);',
    '_registerPageHandlers(',
    'onCreateWindow: (_, _) async => false,',
    'inapp.PermissionResponseAction.DENY',
    'allow: false',
    '_handleServerTrust(controller, challenge, null)',
    'WebInterceptNative.attachToHeadless(',
  ]) {
    assert.ok(body.includes(check), `headless check lacks ${check}`);
  }
});

// --- the live location fix ------------------------------------------------

test('LOC-011: a live fix is served to the top document only', () => {
  const at = WEBVIEW.indexOf("handlerName: 'getRealLocation'");
  assert.notEqual(at, -1, 'getRealLocation registration is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(body.includes('inapp.JavaScriptHandlerFunctionData data'),
    'getRealLocation must use the frame-aware callback: the location shim is '
    + 'injected forMainFrameOnly:false, so a cross-origin iframe can call it '
    + 'directly and skip the Permissions-Policy check');
  assert.ok(body.includes('if (!data.isMainFrame)'),
    'getRealLocation must test the frame before reading the device');
  assert.ok(body.includes("'status': 'permission_denied'"),
    'a refused frame must see PERMISSION_DENIED, what an undelegated iframe '
    + 'gets in a browser');
});

test('PASSKEY-004: the origin asserted to Credential Manager is the bridge\'s, not the page\'s', () => {
  const at = WEBVIEW.indexOf("handlerName: 'webauthnRequest'");
  assert.notEqual(at, -1, 'webauthnRequest registration is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(body.includes('inapp.JavaScriptHandlerFunctionData data'),
    'webauthnRequest must use the frame-aware callback: the origin it asserts '
    + 'is what a provider signs for, so it must come from the plugin preamble');
  assert.ok(body.includes('frameOrigin: data.origin.toString()'),
    'the asserted origin must be the frame origin the bridge captured');
  assert.ok(body.includes('isMainFrame: data.isMainFrame'),
    'the frame check must use the bridge\'s isMainFrame');
  assert.ok(body.includes('topUrl: (await controller.getUrl())?.toString()'),
    'a main frame must still match the document the webview shows');
  assert.ok(!/request\['origin'\]|args\[\d\]\['origin'\]/.test(body),
    'nothing the page passes may be read as the origin: any page could '
    + 'otherwise ask for another site\'s passkey');
  assert.ok(body.includes('PasskeyEngine.plan('),
    'every request must pass the engine\'s origin, frame and rpId checks '
    + 'before reaching the native plugin');
  const plan = body.indexOf('PasskeyEngine.plan(');
  const native = body.indexOf('PasskeyNative.run(');
  assert.ok(plan !== -1 && native !== -1 && plan < native,
    'the native call must come after the plan that allows it');

  const cancelAt = WEBVIEW.indexOf("handlerName: 'webauthnCancel'");
  assert.notEqual(cancelAt, -1, 'webauthnCancel registration is gone');
  const cancel = WEBVIEW.slice(cancelAt, WEBVIEW.indexOf(');', cancelAt));
  assert.ok(cancel.includes('inapp.JavaScriptHandlerFunctionData data')
      && cancel.includes('data.origin'),
    'webauthnCancel must key the ceremony by the calling frame\'s origin, or '
    + 'another origin\'s frame in the page can abort it by guessing the id');
});

test('PASSKEY-015: a ceremony cannot hold the gate past its timeout or its page', () => {
  const at = WEBVIEW.indexOf("handlerName: 'webauthnRequest'");
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(body.includes('PasskeyEngine.runCeremony('),
    'webauthnRequest must send through PasskeyEngine.runCeremony, which '
    + 'cancels a request Credential Manager never answers; without it one '
    + 'stalled request refuses every later one until the app restarts');
  assert.ok(!body.includes('_passkeyGate.begin('),
    'the gate is taken inside runCeremony, not beside it');

  const load = WEBVIEW.indexOf('onLoadStart: (controller, url) async {');
  assert.notEqual(load, -1, 'onLoadStart is gone');
  const loadBody = WEBVIEW.slice(load, load + 1500);
  assert.match(loadBody,
    /_passkeyGate\.active[\s\S]*?startsWith\('\$\{_passkeyWebviewKey\(controller\)\}:'\)[\s\S]*?PasskeyNative\.cancel\(/,
    'a main-frame load must cancel the ceremony its webview started, and only that one');
});

// --- the permission prompts ----------------------------------------------

// Every capture kind's bridge is one registration, looped over CaptureKind.
const CAPTURE_BRIDGE = (() => {
  const at = WEBVIEW.indexOf('handlerName: kind.requestHandler');
  assert.notEqual(at, -1, 'the capture bridge registration is gone');
  return WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
})();

test('CAM-013 / MIC-013: capture prompts name an origin read from the webview', () => {
  assert.ok(!CAPTURE_BRIDGE.includes('args'),
    'a capture bridge must not take the origin from the page: the camera and ' +
    'microphone shims are injected forMainFrameOnly:false, so any frame can ' +
    'call the handler directly and name a site it is not');
  assert.ok(CAPTURE_BRIDGE.includes('_promptOrigin(controller, config, frame: data)'),
    'a capture bridge must derive the origin from the controller and the frame');
  assert.match(WEBVIEW,
    /_promptOrigin\([\s\S]{0,400}?await controller\.getUrl\(\)\)\?\.toString\(\) \?\? config\.initialUrl/,
    '_promptOrigin must read the live URL, falling back to the site URL');
  assert.match(WEBVIEW,
    /if \(frame != null && !frame\.isMainFrame\) return frame\.origin\.toString\(\);/,
    'a subframe prompt must name the frame, not the document that embeds it');
});

test('CAM-014 / MIC-016: a device grant does not travel to a subframe', () => {
  // The shims are injected forMainFrameOnly:false so a QR scanner in a
  // cross-origin frame is covered — which also puts an ad frame on the same
  // handler. `real` is the one answer that opens the device, and the popup
  // that produced it named the top document.
  assert.ok(CAPTURE_BRIDGE.includes('inapp.JavaScriptHandlerFunctionData data'),
    'a capture bridge must use the frame-aware callback: page script can ' +
    'neither forge isMainFrame nor call the handler around it');
  assert.ok(CAPTURE_BRIDGE.includes('isTopFrame: data.isMainFrame'),
    'a capture bridge must hand the frame identity to the store');
  const grant = read('lib/services/media_grant_engine.dart');
  assert.match(grant, /SitePermissionState\.allowed =>\s*isTopFrame \?/,
    'media_grant_engine.dart: a settled real mode must short-circuit only for ' +
    'the top document');
  // The answer a subframe popup produced is that request's, not the site's.
  assert.match(grant, /if \(isTopFrame\) \{\s*_recordCaptures\(/,
    'media_grant_engine.dart: a subframe answer must not be written back to ' +
    'the site — one frame cannot flip the whole site to real');
  assert.match(grant, /final key = \(kind, origin\);[\s\S]*_inFlight\.run\(key,/,
    'media_grant_engine.dart: coalescing must be keyed by prompt origin, or a ' +
    'subframe rides the answer the user gave for the top document');
});

test('BGAUDIO-008: only a main frame takes the notification off a main frame', () => {
  const at = WEBVIEW.indexOf("handlerName: 'wsMediaSession'");
  assert.notEqual(at, -1, 'the wsMediaSession handler is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  assert.ok(body.includes('inapp.JavaScriptHandlerFunctionData call'),
    'wsMediaSession must use the frame-aware callback: the frame token is ' +
    'minted by the shim, which runs in an ad iframe too');
  assert.ok(body.includes('isMainFrame: call.isMainFrame'),
    'wsMediaSession must report the frame identity, not infer it');
  const svc = read('lib/services/media_session_service.dart');
  assert.match(svc, /if \(!isMainFrame && _active && _ownerIsMainFrame && !sameFrame\) return;/,
    'media_session_service.dart: a subframe claiming playback must not ' +
    'displace the main frame that holds the notification');
});

test('CAM-012 / MIC-012: the capture stop is out of the page\'s reach', () => {
  // The hook is the only thing that ends a device capture on deactivation, and
  // Dart can only reach it by name from the page's own realm. Reachable is
  // fine; replaceable is not, and neither is a registry the page can empty.
  const registry = read('lib/services/capture_track_registry.dart');
  assert.match(registry, /writable: false,\s*\n\s*enumerable: false,\s*\n\s*configurable: false,/,
    'the hook must be installed non-writable and non-configurable');
  assert.ok(!/globalThis\.__wsRealTracks\s*=/.test(registry),
    'the device-track list must not be reachable through a global: assigning ' +
    'an empty one used to be a complete bypass');
  assert.ok(!/globalThis\.__wsSyntheticTracks\s*=/.test(registry),
    'the skip list must not be reachable through a global: adding a device ' +
    'track to it used to be a complete bypass');
  assert.match(registry, /if \(track && !isReal\(track\)\)/,
    'markSynthetic must refuse a track already registered as device-backed');
  assert.match(registry, /postMessage\(RELAY, '\*'\)/,
    'the stop must relay to subframes: Dart evaluates in the main frame only, ' +
    'and a subframe granted a device track holds its own registry');
  for (const shim of ['capture_shim_prelude', 'camera_stream_shim',
    'microphone_stream_shim', 'screen_share_shim']) {
    const src = read(`lib/services/${shim}.dart`);
    assert.ok(!src.includes('__wsSyntheticTracks'),
      `${shim}.dart must reach the registry through the shared block, not a global`);
  }
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
    .filter((f) => !f.startsWith('lib/platform/host_platform_'))
    .filter((f) => read(f).includes('hostFetchBounded('));
  assert.deepEqual(callers, [],
    'hostFetchBounded is a direct (unproxied) client; every Dart outbound '
    + 'call goes through outboundHttp.clientFor');
});
