// On-device proof of the one assumption PROXY-013 rests on: that each
// container profile gets its own Chromium `HttpNetworkSession`, so a
// per-site proxy credential cannot bleed onto another site's connections.
//
// This cannot be answered off-device. Chromium's `HttpAuthCache` is owned
// by the `HttpNetworkSession`, and its proxy entries are deliberately NOT
// keyed by `NetworkAnonymizationKey` — within one session a single cached
// proxy credential serves every request. The profile boundary is the only
// separation there is, and no fake can tell us whether it holds.
//
// The test is shaped so that a failure is impossible to mistake for a
// pass. Two sites are pointed at two DIFFERENT upstream proxies, both
// stood up here in Dart:
//
//   * If attribution works, each upstream is reached by exactly the site
//     configured for it.
//   * If the auth cache is shared, both sites present whichever credential
//     was cached first, the relay routes both to that one upstream, and
//     the other upstream is never contacted at all.
//
// So "the second upstream saw traffic" is the assertion, and it is the
// literal statement of the assumption. If this test fails, router mode
// must be withdrawn rather than patched: the failure mode in production
// is one site silently exiting through another site's proxy.
//
// Android-only by construction. Everywhere else router mode does not
// engage and there is nothing to attribute.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/proxy_upstreams.dart';
import 'secure_storage_fake.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late RecordingUpstream upstreamA;
  late RecordingUpstream upstreamB;

  setUpAll(() async {
    isDemoMode = true;
    await installInMemoryKeychainIfUnavailable();

    upstreamA = await RecordingUpstream.start('A');
    upstreamB = await RecordingUpstream.start('B');

    // Two accounts on one service, each with its own exit. Hostnames
    // carry a dot so Chromium's `<local>` bypass does not send them
    // straight out; they never need to resolve, because the upstream
    // answers on their behalf.
    final siteA = WebViewModel(
      siteId: SiteId('attr-a'),
      initUrl: 'http://a.example.test/',
      name: 'Attribution A',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '127.0.0.1:${upstreamA.port}',
      ),
    );
    final siteB = WebViewModel(
      siteId: SiteId('attr-b'),
      initUrl: 'http://b.example.test/',
      name: 'Attribution B',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '127.0.0.1:${upstreamB.port}',
      ),
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(siteA.toJson()),
        jsonEncode(siteB.toJson()),
      ],
    });
  });

  tearDownAll(() async {
    await upstreamA.close();
    await upstreamB.close();
  });

  testWidgets('each container presents its own proxy credential',
      (tester) async {
    if (!hostIsAndroid) {
      markTestSkipped('router mode is Android-only');
      return;
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    if (!await ContainerNative.instance.isSupported()) {
      markTestSkipped('no MULTI_PROFILE: PROXY-008 serialisation applies');
      return;
    }

    // Let startup settle. pumpAndSettle deadlocks on a live WebView.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(ProxyRouterService.instance.isActive, isTrue,
        reason: 'router mode should be active on a container-capable device');

    // Activate both sites. Under router mode neither activation may evict
    // the other, so by the end both are loaded and both have issued
    // traffic through their own credential.
    for (final name in ['Attribution A', 'Attribution B']) {
      await openSiteFromDrawer(tester, name: name);
    }

    // The assumption, stated literally. A shared auth cache routes both
    // sites through whichever credential was cached first, leaving the
    // other upstream at zero.
    expect(
      upstreamA.wasReached,
      isTrue,
      reason: 'site A never reached its own upstream '
          '(A=${upstreamA.requestLines}, B=${upstreamB.requestLines})',
    );
    expect(
      upstreamB.wasReached,
      isTrue,
      reason: 'PROXY-013 GATE FAILED: only one upstream was ever reached, so '
          'both containers presented the same proxy credential. Chromium is '
          'sharing an HttpAuthCache across profiles and router mode must be '
          'withdrawn, not patched — in production this is one site exiting '
          "through another site's proxy. "
          '(A=${upstreamA.requestLines}, B=${upstreamB.requestLines})',
    );

    // Each upstream saw exactly its own site, not a mixture.
    expect(
      upstreamA.requestLines.every((l) => l.contains('a.example.test')),
      isTrue,
      reason: 'upstream A saw traffic for another site: ${upstreamA.requestLines}',
    );
    expect(
      upstreamB.requestLines.every((l) => l.contains('b.example.test')),
      isTrue,
      reason: 'upstream B saw traffic for another site: ${upstreamB.requestLines}',
    );

    // The relay authenticates to each upstream with the user's own proxy
    // credentials, never with the site's router token.
    final routerTokens = [
      ProxyRouterService.instance.credentialFor(RouterIdentity.ofSite(SiteId('attr-a'))),
      ProxyRouterService.instance.credentialFor(RouterIdentity.ofSite(SiteId('attr-b'))),
    ].whereType<String>();
    for (final seen in [...upstreamA.credentials, ...upstreamB.credentials]) {
      for (final token in routerTokens) {
        expect(seen.contains(token), isFalse,
            reason: 'a router token was forwarded to an upstream proxy');
      }
    }
  });
}
