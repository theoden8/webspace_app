import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/headless_site_check.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/view_blockers.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_headless.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/host_hooks.dart';

class _Controller implements inapp.InAppWebViewController {
  @override
  Future<void> setSettings({
    required inapp.InAppWebViewSettings settings,
  }) async {}

  @override
  Future<void> stopLoading() async {}

  @override
  dynamic getViewId() => 'check-1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headless implements inapp.HeadlessInAppWebView {
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A wake's headless check runs the page while the user may download a DNS
/// level, and Android's interceptor keeps the level it was attached at: the
/// check is one of the views the DNS lists tell as they move, from its
/// attach to its dispose, as a site's webview is (DNS-022, NOTIF-016).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DnsBlockService dns;
  late List<ViewAttach> sent;
  final site = WebViewModel(initUrl: 'https://example.com/');
  const view = OnHeadless('check-1');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WebInterceptNative.debugAssumeAndroid = true;
    dns = DnsBlockService.instance
      ..resetForTest()
      ..store = MemoryFileStore();
    sent = [];
    dns.views = ViewBlockers(send: sent.add, resolve: dns.effectiveLevelFor);
    final list = [for (var i = 0; i < 1200; i++) 'filler-$i.example'].join('\n');
    outboundHttp = FakeOutbound(responder: (_) => http.Response(list, 200));
  });

  tearDown(() {
    WebInterceptNative.debugAssumeAndroid = false;
    resetOutboundHttp();
    dns.resetForTest();
  });

  HeadlessSiteCheck check() => HeadlessSiteCheck.over(
    _Headless(),
    controller: _Controller(),
    settings: inapp.InAppWebViewSettings(),
  );

  test('a check is told its level as the lists move, until it is disposed '
      '(DNS-022)', () async {
    final c = check();
    await c.follow(site.headlessCheckConfig(inertHostHooks()), headlessId: 'check-1');
    expect(dns.views.told, {site.siteId: 0}, reason: 'attached at its level');

    expect(await dns.downloadList(1), isTrue);
    expect(dns.views.told, {site.siteId: 1});
    expect([for (final a in sent) (a.view, a.blockers.dnsLevel)], [(view, 1)]);

    await c.dispose();
    sent.clear();
    expect(await dns.downloadList(2), isTrue);
    expect(dns.views.told, isEmpty, reason: 'a disposed check is no view');
    expect(sent, isEmpty);
  });
}
