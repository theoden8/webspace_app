// On-device proof of the one-rule path (PROXY-008): where the WebView gives
// sites no profile of their own, one process-wide rule carries the proxy of
// the site on screen, so sites on different proxies take turns. No CI image
// lacks MULTI_PROFILE, so the binding is pinned to the one such a device
// gets; everything below it is the real WebView. Each site must reach its
// own upstream, and only its own, one at a time, with no router credential
// anywhere. It also guards what this path lost once: site A's webview, let
// go of as B opened, fetched its icon after the rule had moved to B's proxy,
// while the plugin was still tearing it down.
//
// Android-only by construction: `ProxyController` is Android's.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/webview_proxy.dart' show ProxyManager;
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
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
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        for (final (id, upstream) in [('one-rule-a', upstreamA), ('one-rule-b', upstreamB)])
          jsonEncode(WebViewModel(
            siteId: SiteId(id),
            initUrl: 'http://${id.substring(id.length - 1)}.example.test/',
            name: 'One rule ${id.substring(id.length - 1).toUpperCase()}',
            proxySettings: UserProxySettings(
              type: ProxyType.HTTP,
              address: '127.0.0.1:${upstream.port}',
            ),
          ).toJson()),
      ],
    });
    ProxyManager.pinBindingForTest(ProxyBinding.processWide);
  });

  tearDownAll(() async {
    ProxyManager.pinBindingForTest(null);
    await upstreamA.close();
    await upstreamB.close();
  });

  testWidgets('one rule carries each site\'s own proxy in turn (PROXY-008)', (
    tester,
  ) async {
    if (!hostIsAndroid) {
      markTestSkipped('the one rule is Android\'s ProxyController');
      return;
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(ProxyRouterService.instance.isActive, isFalse,
        reason: 'the router never starts on this binding');

    for (final name in ['One rule A', 'One rule B']) {
      LogTag.test.info('opening $name');
      await openSiteFromDrawer(tester, name: name);
    }

    final seen = '(A=${upstreamA.requestLines}, B=${upstreamB.requestLines})';
    expect(upstreamA.wasReached, isTrue,
        reason: 'site A must reach its own proxy $seen');
    expect(upstreamB.wasReached, isTrue,
        reason: 'site B must reach its own proxy once A gives way $seen');
    expect(upstreamA.onlyFor('a.example.test'), isTrue,
        reason: 'upstream A saw another site $seen');
    expect(upstreamB.onlyFor('b.example.test'), isTrue,
        reason: 'upstream B saw another site $seen');
    expect([...upstreamA.credentials, ...upstreamB.credentials], isEmpty,
        reason: 'no router credential on this binding');
  });
}
