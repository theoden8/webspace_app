import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

void main() {
  setUp(GlobalOutboundProxy.resetForTest);
  tearDown(GlobalOutboundProxy.resetForTest);

  group('waitsForTor (TOR-008 over the effective proxy)', () {
    final defaultSite = UserProxySettings(type: ProxyType.DEFAULT);
    final torSite = UserProxySettings(type: ProxyType.TOR);

    test('explicit Tor site waits while Tor is down', () {
      expect(waitsForTor(torSite, siteId: 's', torUp: false), isTrue);
      expect(waitsForTor(torSite, siteId: 's', torUp: true), isFalse);
    });

    test('DEFAULT site under a global Tor waits exactly like an explicit one', () {
      GlobalOutboundProxy.setForTest(UserProxySettings(type: ProxyType.TOR));
      expect(waitsForTor(defaultSite, siteId: 's', torUp: false), isTrue);
      expect(waitsForTor(defaultSite, siteId: 's', torUp: true), isFalse);
    });

    test('DEFAULT site with no global Tor never waits', () {
      expect(waitsForTor(defaultSite, siteId: 's', torUp: false), isFalse);
      GlobalOutboundProxy.setForTest(UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'p:1080',
      ));
      expect(waitsForTor(defaultSite, siteId: 's', torUp: false), isFalse);
    });
  });

  group('deferInitialLoadForProxy (LEAK-003 first request)', () {
    test('global-override platforms defer a proxied site', () {
      expect(
        deferInitialLoadForProxy(
          proxyIsGlobal: true,
          effectiveNonDefault: true,
          overrideActive: false,
        ),
        isTrue,
      );
    });

    test('a DEFAULT site defers while another site\'s override is active', () {
      expect(
        deferInitialLoadForProxy(
          proxyIsGlobal: true,
          effectiveNonDefault: false,
          overrideActive: true,
        ),
        isTrue,
      );
    });

    test('a DEFAULT site with no override loads immediately', () {
      expect(
        deferInitialLoadForProxy(
          proxyIsGlobal: true,
          effectiveNonDefault: false,
          overrideActive: false,
        ),
        isFalse,
      );
    });

    test('per-session platforms (iOS/macOS) never defer', () {
      expect(
        deferInitialLoadForProxy(
          proxyIsGlobal: false,
          effectiveNonDefault: true,
          overrideActive: true,
        ),
        isFalse,
      );
    });
  });
}
