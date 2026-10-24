import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

/// The process-wide rule the proxy manager writes where one rule covers every
/// webview (Android), read off the plugin's channel: it takes the address the
/// settings screens take (PROXY-017), and writes nothing for one they refuse.
/// Where each store takes its own proxy at construction (iOS, macOS and
/// Linux, PROXY-027) the manager writes no rule at all. Each binding is
/// pinned, so both run on whichever host CI runs this on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_proxycontroller');
  final site = SiteId('a');
  final occupant = (use: RouteUse.webview, site: site);
  late List<MethodCall> calls;

  setUp(() async {
    AndroidInAppWebViewPlatform.registerWith();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    GlobalOutboundProxy.setInMemory(UserProxySettings(type: ProxyType.DEFAULT));
    await PlatformInfo.initialize();
    ProxyManager.pinBindingForTest(ProxyBinding.processWide);
  });

  tearDown(() {
    ProxyManager.pinBindingForTest(null);
    ProcessRoute.instance.release(occupant);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<Object?> rules() => [
        for (final c in calls)
          if (c.method == 'setProxyOverride')
            for (final r in ((c.arguments as Map)['settings'] as Map)['proxyRules']
                as List)
              (r as Map)['url'],
      ];

  Future<void> apply(String address) => ProxyManager().setProxySettings(
        UserProxySettings(type: ProxyType.HTTP, address: address),
        siteId: site,
        occupant: occupant,
      );

  test('a bracketed IPv6 proxy is written as one (PROXY-017)', () async {
    await apply('[::1]:8080');
    expect(rules(), ['http://[::1]:8080']);
  });

  test('an address the screens refuse writes no rule (PROXY-017)', () async {
    for (final address in ['::1:8080', 'proxy.example:0', 'proxy.example']) {
      calls.clear();
      await expectLater(apply(address), throwsException, reason: address);
      expect(rules(), isEmpty, reason: address);
    }
  });

  test('where each store binds its proxy, no rule is written (PROXY-027)',
      () async {
    ProxyManager.pinBindingForTest(ProxyBinding.perSite);
    await apply('127.0.0.1:8080');
    expect(calls, isEmpty);
  });
}
