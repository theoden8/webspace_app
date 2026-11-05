import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_proxy_relay.dart';

/// The process-wide rule the proxy manager writes where one rule covers every
/// webview (Android), read off the plugin's channel: it takes the address the
/// settings screens take (PROXY-017), and writes nothing for one they refuse.
/// Where each store takes its own proxy at construction (iOS, macOS and
/// Linux, PROXY-027) the manager writes no rule at all. Each binding is
/// pinned, so both run on whichever host CI runs this on. A credentialed
/// proxy reaches the rule only as the relay that injects its credentials,
/// and a relay that cannot start writes nothing (LEAK-012).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_proxycontroller');
  final site = SiteId('a');
  final occupant = (use: RouteUse.webview, site: site);
  late List<MethodCall> calls;
  late FakeRelay relay;

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
    relay = FakeRelay();
    ProxyRouterService.instance.setRelayForTest(relay);
    LogService.instance.resetForTest();
  });

  tearDown(() {
    ProxyRouterService.instance.resetForTest();
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

  test('LEAK-012: a credentialed proxy is written as the relay that injects '
      'its credentials, with none in the rule', () async {
    await ProxyManager().setProxySettings(
      UserProxySettings(
        type: ProxyType.HTTP,
        address: 'proxy.example:3128',
        username: 'alice',
        password: 's3cret',
      ),
      siteId: site,
      occupant: occupant,
    );
    expect(rules(), ['http://${FakeRelay.boundHost}:${relay.nextPort}'],
        reason: 'Chromium refuses a rule with userinfo and goes direct');
    for (final rule in rules()) {
      expect('$rule', isNot(contains('@')));
      expect('$rule', isNot(contains('s3cret')));
    }
    expect(relay.startedUpstream?.address, 'proxy.example:3128');
    expect(relay.startedUpstream?.password, 's3cret',
        reason: 'the credentials travel to the relay alone');
  });

  test('LEAK-012: a relay that cannot start leaves no rule to go direct on',
      () async {
    relay.canBind = false;
    await expectLater(
      ProxyManager().setProxySettings(
        UserProxySettings(
          type: ProxyType.SOCKS5,
          address: 'proxy.example:1080',
          username: 'alice',
          password: 's3cret',
        ),
        siteId: site,
        occupant: occupant,
      ),
      throwsA(isA<ProxyRefused>()),
    );
    expect(calls, isEmpty,
        reason: 'neither a rule written nor the override cleared: the site '
            'is refused, not sent out direct');
    expect(
      LogService.instance
          .recent({LogTag.proxy})
          .where((e) => e.level == LogLevel.error),
      isNotEmpty,
      reason: 'the refusal is logged at error level',
    );
  });

  test('where each store binds its proxy, no rule is written (PROXY-027)',
      () async {
    ProxyManager.pinBindingForTest(ProxyBinding.perSite);
    await apply('127.0.0.1:8080');
    expect(calls, isEmpty);
  });
}
