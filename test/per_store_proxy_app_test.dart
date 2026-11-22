import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart' show torProxyResolver;
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/tor_engine.dart' show TorEngine;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview_proxy.dart'
    show PlatformInfo, ProxyManager;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';

import 'helpers/fake_tor_runtime.dart';
import 'helpers/fake_webview_controller.dart';
import 'helpers/real_app.dart';

/// Where each site's store binds its own proxy, nothing needs one rule for
/// the process (PROXY-027): on iOS and macOS, and on Linux, where every site
/// runs in a network session of its own and the fork leaves a session that
/// holds a proxy alone when the override moves. The hosts CI runs this on
/// are Linux and macOS, so it runs the app as either binds.
void main() {
  const proxyChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_proxycontroller',
  );
  final ruleCalls = <String>[];
  setUp(() async {
    ruleCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, (call) async {
      ruleCalls.add(call.method);
      return null;
    });
    await PlatformInfo.initialize();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(proxyChannel, null);
    ProxyManager.pinBindingForTest(null);
  });

  UserProxySettings proxy(String address) =>
      UserProxySettings(type: ProxyType.HTTP, address: address);

  testWidgets('two sites with different proxies stay loaded together, each '
      'built with its own (PROXY-027)', (tester) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(
          initUrl: 'https://one.test',
          name: 'One',
          proxySettings: proxy('127.0.0.1:18081'),
        ),
        WebViewModel(
          initUrl: 'https://two.test',
          name: 'Two',
          proxySettings: proxy('127.0.0.1:18082'),
        ),
      ],
    );
    expect(
      ProxyManager.binding,
      ProxyBinding.perSite,
      reason: 'Linux and Apple hosts bind a proxy per store',
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'One');
    await attachWebViews(tester);
    await openSiteFromDrawer(tester, name: 'Two');
    await attachWebViews(tester);

    expect(
      appSite('One').webview,
      isNotNull,
      reason: 'Two\'s proxy unloaded One, as one rule for the process would',
    );
    expect(appSite('Two').webview, isNotNull);
    expect(
      ruleCalls,
      isNot(contains('setProxyOverride')),
      reason: 'no process-wide override is written',
    );
    final built = [
      for (final e in find
          .byType(inapp.InAppWebView, skipOffstage: false)
          .evaluate())
        for (final rule
            in (e.widget as inapp.InAppWebView)
                    .platform
                    .params
                    .initialSettings
                    ?.proxySettings
                    ?.proxyRules ??
                const <inapp.ProxyRule>[])
          rule.url,
    ];
    expect(built.join(' '), contains('127.0.0.1:18081'));
    expect(built.join(' '), contains('127.0.0.1:18082'));
  });

  test('an edited proxy rebuilds the webview its store binds (PROXY-027)',
      () async {
    // A container's session keeps the proxy it was built with, so a rule
    // written for the process would never reach it.
    ProxyManager.pinBindingForTest(ProxyBinding.perSite);
    final site = WebViewModel(
      siteId: SiteId('per-store-edit'),
      initUrl: 'https://edit.test',
      proxySettings: proxy('127.0.0.1:18081'),
    );
    site.controller = FakeWebViewController();
    var letGo = false;
    await site.updateProxySettings(
      proxy('127.0.0.1:18082'),
      letGo: () => letGo = true,
    );
    expect(letGo, isTrue, reason: 'the webview goes to be rebuilt');
    expect(ruleCalls, isEmpty);
  });

  testWidgets('saving Tor replaces the onion block without an app restart', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const url = 'https://example.onion/';
    final runtime = FakeTorRuntime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'test'),
    );
    torProxyResolver = (tag) => TorService.instance.routeFor(siteId: tag.site);
    addTearDown(() async {
      torProxyResolver = null;
      await TorService.reset();
      await runtime.dispose();
    });

    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: url, name: 'Onion Site')],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Onion Site');
    final webView = find.byType(inapp.InAppWebView);
    final before = tester.widget<inapp.InAppWebView>(webView).platform.params;
    expect(before.initialUrlRequest?.url?.toString(), 'about:blank');
    await attachWebViews(tester);
    expect(find.text('Request not sent'), findsOneWidget);

    await tester.tap(find.text('Proxy settings'));
    await settleRealApp(tester);
    await tester.tap(find.text('Network'));
    await settleRealApp(tester);
    await tester.tap(find.byType(ProxyChoiceDropdown));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TOR').last);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await settleRealApp(tester);
    await tester.tap(find.text('Save Settings'));
    await settleRealApp(tester);

    expect(find.byType(TorBootstrapPlaceholder), findsOneWidget);
    expect(webView, findsNothing);
    runtime.bootstrapTo(9050);
    await settleRealApp(tester);
    await attachWebViews(tester);

    expect(find.text('Request not sent'), findsNothing);
    final params = tester.widget<inapp.InAppWebView>(webView).platform.params;
    expect(params.initialUrlRequest?.url?.toString(), url);
    expect(
      params.initialSettings?.proxySettings?.proxyRules.single.url,
      contains('127.0.0.1:9050'),
    );
  });
}
