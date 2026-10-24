import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart'
    show PlatformInfo, ProxyManager;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

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
    await site.updateProxySettings(proxy('127.0.0.1:18082'));
    expect(site.controller, isNull, reason: 'the webview goes to be rebuilt');
    expect(ruleCalls, isEmpty);
  });
}
