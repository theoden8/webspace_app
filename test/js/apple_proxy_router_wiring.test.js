// The Apple half of router mode is wiring the Dart suite cannot reach.
//
// PROXY-026 puts each container store on the relay by writing the rule into
// the settings a WebView is built with. That happens inside
// `WebViewFactory._bindingFor`, on a platform this repo's unit tier never
// runs: `hostIsIOS`/`hostIsMacOS` answer false here, so an assertion about
// the branch passes without meaning it.
//
// Each rule below is a way the feature silently stops working while every
// Dart test stays green, which is the shape of BUG-014 itself: configured,
// reported as applied, not in force.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, methodBody } = require('./helpers/source');

const webviewRel = 'lib/services/webview.dart';
const probeRel = 'lib/services/proxy_router_probe.dart';
const mainRel = 'lib/main.dart';
const webview = read(webviewRel);
const probe = read(probeRel);
const main = read(mainRel);

test('the relay rule is consulted when a WebView is built', () => {
  assert.match(
    webview,
    /final relayProxy = [\s\S]{0,200}routerRelayProxyFor\(/,
    `${webviewRel} must ask for the relay rule while binding a store; `
      + 'without it every Apple store keeps its own proxy and router mode '
      + 'routes nothing',
  );
  assert.match(
    webview,
    /final inappProxy = relayProxy \?\?/,
    `${webviewRel}: the relay rule must WIN over the site's own rule. `
      + 'The other order leaves each store on its own upstream while the '
      + 'router believes it owns the traffic',
  );
});

test('the relay rule is not gated on the site having a proxy', () => {
  // A store left unproxied cannot answer the PROXY-015 probe, and one
  // unproven site stands router mode down for every site.
  const fn = methodBody('routerRelayProxyFor', { file: webviewRel });
  assert.doesNotMatch(
    fn,
    /proxySettings\s*==\s*null|effectiveProxy/,
    `${webviewRel}: routerRelayProxyFor must not depend on the site's own `
      + 'proxy; a DEFAULT site rides the relay too',
  );
});

test('the relay rule rides the named binding, not a platform test', () => {
  const fn = methodBody('routerRelayProxyFor', { file: webviewRel });
  assert.match(
    fn,
    /ProxyManager\.binding != ProxyBinding\.perSite/,
    `${webviewRel}: Android carries the router on one ProxyController rule, `
      + 'so a per-WebView rule there is a second source of truth for the '
      + 'same traffic. PROXY-027 says which platforms those are, and this '
      + 'path must read that decision rather than re-derive it',
  );
  assert.doesNotMatch(
    fn,
    /hostIsIOS|hostIsMacOS/,
    `${webviewRel}: PROXY-027 names the binding once; a platform test here `
      + 'is a fourth place for it to drift',
  );
});

test('a webview with no site id is not routed', () => {
  const fn = methodBody('routerRelayProxyFor', { file: webviewRel });
  assert.match(
    fn,
    /siteId == null \|\| siteId\.isEmpty/,
    `${webviewRel}: a webview with no route-table row must keep its own `
      + "rule; the shared identity belongs to a group it is not part of",
  );
});

test('the credential rides the fields, never only the URL', () => {
  const fn = methodBody('routerRelayProxyFor', { file: webviewRel });
  assert.match(
    fn,
    /username: router\.usernameFor\(identity\)/,
    `${webviewRel}: the relay rule must set ProxyRule.username`,
  );
  assert.match(
    fn,
    /password: token/,
    `${webviewRel}: the relay rule must set ProxyRule.password`,
  );
  assert.doesNotMatch(
    fn,
    /http:\/\/\$\{?router[\s\S]{0,40}@/,
    `${webviewRel}: userinfo in the URL never reaches applyCredential `
      + '(PROXY-025), so a credential written there authenticates with nothing',
  );
});

test('the attribution probe travels the relay too', () => {
  assert.match(
    probe,
    /final proxy = routerRelayProxyFor\(siteId: siteId, ownsContainer: true\);[\s\S]*proxySettings: proxy,/,
    `${probeRel}: the probe's headless view must carry the site's relay `
      + 'credential. Without it the probe resolves .invalid directly, every '
      + 'pair comes back missing, and router mode is refused on every device',
  );
});

test('the process-wide binder is not required off Android', () => {
  assert.match(
    main,
    /bindOverride: bindsProcessWide \? ProxyManager\(\)\.applyRouterOverride : null/,
    `${mainRel}: applyRouterOverride answers false off Android, and a `
      + 'binder that answers false stands router mode down. Apple binds per '
      + 'store instead, so it must be passed no binder at all',
  );
});
