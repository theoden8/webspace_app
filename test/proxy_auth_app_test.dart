import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart'
    show PlatformInfo, ProxyManager;
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// A site's proxy password is kept in secure storage, never in its JSON
/// (PWD-005), and a cold start puts it back into the proxy rule the site's
/// webview is built with (PROXY-001).
void main() {
  setUp(PlatformInfo.initialize);

  testWidgets('a proxy password from secure storage reaches the rule the '
      "site's webview is built with (PROXY-001, PWD-005)", (tester) async {
    final site = WebViewModel(
      siteId: SiteId('proxy-1'),
      initUrl: 'http://192.0.2.1/',
      name: 'Proxy Site',
      proxySettings: UserProxySettings(
        type: ProxyType.HTTP,
        address: '198.51.100.1:8080',
        username: 'puser',
      ),
    );
    await pumpRealApp(
      tester,
      sites: [site],
      secureStorage: {
        'proxy_passwords': jsonEncode({'proxy-1': 'sekret-pass'}),
      },
    );
    expect(ProxyManager.binding, ProxyBinding.perSite,
        reason: 'Linux and Apple hosts bind a proxy per store');
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Proxy Site');

    final rules = tester
        .widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView).first)
        .platform
        .params
        .initialSettings
        ?.proxySettings
        ?.proxyRules;
    final url = rules?.single.url;
    expect(url, startsWith('http://'));
    expect(url, contains('198.51.100.1:8080'));
    expect(url, contains('puser'));
    expect(url, contains('sekret-pass'));
  });
}
