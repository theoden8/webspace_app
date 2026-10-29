import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/webview_config.dart';

void main() {
  setUp(GlobalOutboundProxy.resetForTest);
  tearDown(GlobalOutboundProxy.resetForTest);

  group('waitsForTor (TOR-008 over the effective proxy)', () {
    final defaultSite = UserProxySettings(type: ProxyType.DEFAULT);
    final torSite = UserProxySettings(type: ProxyType.TOR);

    test('explicit Tor site waits while Tor is down', () {
      expect(waitsForTor(OutboundProxy.ofSite(torSite, site: SiteId('s')), torUp: false), isTrue);
      expect(waitsForTor(OutboundProxy.ofSite(torSite, site: SiteId('s')), torUp: true), isFalse);
    });

    test('DEFAULT site under a global Tor waits exactly like an explicit one', () {
      GlobalOutboundProxy.setInMemory(UserProxySettings(type: ProxyType.TOR));
      expect(waitsForTor(OutboundProxy.ofSite(defaultSite, site: SiteId('s')), torUp: false), isTrue);
      expect(waitsForTor(OutboundProxy.ofSite(defaultSite, site: SiteId('s')), torUp: true), isFalse);
    });

    test('DEFAULT site with no global Tor never waits', () {
      expect(waitsForTor(OutboundProxy.ofSite(defaultSite, site: SiteId('s')), torUp: false), isFalse);
      GlobalOutboundProxy.setInMemory(UserProxySettings(
        type: ProxyType.SOCKS5,
        address: 'p:1080',
      ));
      expect(waitsForTor(OutboundProxy.ofSite(defaultSite, site: SiteId('s')), torUp: false), isFalse);
    });
  });

  group('deferInitialLoadForProxy (LEAK-003 first request)', () {
    test('global-override platforms defer a proxied site', () {
      expect(
        deferInitialLoadForProxy(
          proxyIsGlobal: true,
          effectiveNonDefault: true,
          overrideActive: false,
          releasesContainerProxy: false,
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
          releasesContainerProxy: false,
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
          releasesContainerProxy: false,
        ),
        isFalse,
      );
    });

    test('per-session platforms (iOS/macOS) do not defer for an override', () {
      expect(
        deferInitialLoadForProxy(
          proxyIsGlobal: false,
          effectiveNonDefault: true,
          overrideActive: true,
          releasesContainerProxy: false,
        ),
        isFalse,
      );
    });

    test('a container that keeps a proxy its site dropped defers (PROXY-029)',
        () {
      for (final proxyIsGlobal in [true, false]) {
        expect(
          deferInitialLoadForProxy(
            proxyIsGlobal: proxyIsGlobal,
            effectiveNonDefault: false,
            overrideActive: false,
            releasesContainerProxy: true,
          ),
          isTrue,
          reason: 'the clear goes out from setController, so the first load '
              'has to wait for it (proxyIsGlobal: $proxyIsGlobal)',
        );
      }
    });
  });
}
