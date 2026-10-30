import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/services/egress_relay.dart';
import 'package:webspace/services/egress_route_engine.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/network_interface.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

const _secret = '00112233445566778899aabbccddeeff';
const _up = EgressUp(host: '127.44.5.6', port: 41000, secret: _secret);
final _wg0 = NamedInterface(InterfaceName.parse('wg0')!);

UserProxySettings _route(ProxyType type,
        {String? address, String? username, String? password}) =>
    UserProxySettings(
        type: type, address: address, username: username, password: password);

/// The vectors both sides of the credential are held to.
List<Map<String, String?>> _vectors() {
  const columns = [
    'name', 'secret', 'link', 'kind', 'host', 'port', 'user',
    'upstream_password', 'username', 'password',
  ];
  return [
    for (final line
        in File('test/fixtures/egress_credentials.tsv').readAsLinesSync())
      if (line.isNotEmpty && !line.startsWith('#'))
        {
          for (final (i, value) in line.split('\t').indexed)
            columns[i]: value == '-' ? null : value,
        },
  ];
}

void main() {
  tearDown(() => EgressRelay.instance.setInMemory(state: null));

  group('InterfaceChoice (NETIF-001)', () {
    test('NETIF-001: absent reads as system routing and writes nothing', () {
      final settings = UserProxySettings.fromJson({'type': 0});
      expect(settings.leavesBy, const SystemRouting());
      expect(settings.toJson().containsKey('networkInterface'), isFalse);
    });

    test('NETIF-001: a named interface round-trips through the settings', () {
      final stored = UserProxySettings(type: ProxyType.DEFAULT, leavesBy: _wg0);
      final back = UserProxySettings.fromJson(stored.toJson());
      expect(back.leavesBy, _wg0);
    });

    test('NETIF-001: a choice this build cannot read refuses and survives', () {
      final raw = {'transport': 'vpn'};
      final settings =
          UserProxySettings.fromJson({'type': 0, 'networkInterface': raw});
      expect(settings.leavesBy, isA<UnreadableInterface>());
      expect(settings.toJson()['networkInterface'], same(raw));
      expect(
          egressRoute(
                  route: _route(ProxyType.DEFAULT),
                  leavesBy: settings.leavesBy,
                  relay: _up)
              .type,
          ProxyType.SAVED);
    });

    test('NETIF-001: a name the kernel cannot hold does not parse', () {
      for (final bad in ['', '../wg0', 'a b', 'sixteen-chars-xx', 'wg0&t=1']) {
        expect(InterfaceName.parse(bad), isNull, reason: bad);
        expect(InterfaceChoice.fromJson({'name': bad}),
            isA<UnreadableInterface>());
      }
    });
  });

  group('egressRoute', () {
    test('NETIF-013: with the experiment off a stored interface is kept '
        'and not applied', () {
      final route = _route(ProxyType.SOCKS5, address: '10.0.0.1:1080');
      expect(
          identical(
              egressRoute(
                  route: route, leavesBy: _wg0, relay: const EgressOff()),
              route),
          isTrue);
    });

    test('NETIF-002: no relay running is no route, never the default one', () {
      final route = egressRoute(
          route: _route(ProxyType.DEFAULT),
          leavesBy: _wg0,
          relay: const EgressDown());
      expect(route.type, ProxyType.SAVED);
      expect(route.address, isNull);
    });

    test('NETIF-004: a bound site rides the relay with its route in the '
        'credential', () {
      final route = egressRoute(
          route: _route(ProxyType.DEFAULT), leavesBy: _wg0, relay: _up);
      expect(route.type, ProxyType.SOCKS5);
      expect(route.address, '127.44.5.6:41000');
      expect(route.username, 'ws-egress-1?if=wg0');
      expect(route.password, _secret);
    });

    test('NETIF-006: Tor and an HTTPS proxy have no route over an interface',
        () {
      for (final type in [ProxyType.TOR, ProxyType.HTTPS, ProxyType.SAVED]) {
        expect(
            egressRoute(
                    route: _route(type, address: '127.0.0.1:9050'),
                    leavesBy: _wg0,
                    relay: _up)
                .type,
            ProxyType.SAVED,
            reason: '$type');
      }
    });

    test('NETIF-004: a credential RFC 1929 cannot carry is no route', () {
      final route = egressRoute(
          route: _route(ProxyType.SOCKS5,
              address: '10.0.0.1:1080', username: 'u' * 250),
          leavesBy: _wg0,
          relay: _up);
      expect(route.type, ProxyType.SAVED);
    });

    for (final v in _vectors()) {
      test('NETIF-005: writes the ${v['name']} vector the relay reads', () {
        final kind = v['kind'];
        final upstream = kind == null
            ? _route(ProxyType.DEFAULT)
            : _route(kind == 'socks5' ? ProxyType.SOCKS5 : ProxyType.HTTP,
                address: '${v['host']}:${v['port']}',
                username: v['user'],
                password: v['upstream_password']);
        final route = egressRoute(
          route: upstream,
          leavesBy: NamedInterface(InterfaceName.parse(v['link'])!),
          relay: EgressUp(host: '127.0.0.9', port: 1, secret: v['secret']!),
        );
        expect(route.username, v['username']);
        expect(route.password, v['password']);
      });
    }
  });

  group('OutboundProxy', () {
    setUp(() => GlobalOutboundProxy.setInMemory(
        UserProxySettings(type: ProxyType.DEFAULT)));

    test('NETIF-006: a Tor site that names an interface stays bound, '
        'never on Tor', () {
      EgressRelay.instance.setInMemory(state: _up);
      final stored = UserProxySettings(type: ProxyType.TOR, leavesBy: _wg0);
      final route =
          OutboundProxy.ofSite(stored, site: SiteId('site-1')).resolved;
      expect(route.type, ProxyType.SAVED);
    });

    test('NETIF-008: a bound site with no proxy counts as routed for the '
        'WebRTC floor', () {
      EgressRelay.instance.setInMemory(state: _up);
      final route = resolveEffectiveProxy(
          UserProxySettings(type: ProxyType.DEFAULT, leavesBy: _wg0),
          siteId: SiteId('site-1'));
      expect(
          resolveWebRtcPolicy(
            stored: WebRtcPolicy.defaultPolicy,
            trackingProtectionEnabled: true,
            proxied: route.type != ProxyType.DEFAULT,
          ),
          WebRtcPolicy.relayOnly);
    });

    test('NETIF-011: two sites on two interfaces are two routes', () {
      EgressRelay.instance.setInMemory(state: _up);
      final tun = NamedInterface(InterfaceName.parse('tun0')!);
      final a = resolveEffectiveProxy(
          UserProxySettings(type: ProxyType.DEFAULT, leavesBy: _wg0),
          siteId: SiteId('a'));
      final b = resolveEffectiveProxy(
          UserProxySettings(type: ProxyType.DEFAULT, leavesBy: tun),
          siteId: SiteId('b'));
      final none = resolveEffectiveProxy(
          UserProxySettings(type: ProxyType.DEFAULT),
          siteId: SiteId('c'));
      expect(a.routeKey, isNot(b.routeKey));
      expect(a.routeKey, isNot(none.routeKey));
    });
  });

  group('QR share (NETIF-012)', () {
    test('NETIF-012: a QR share carries no interface', () {
      final site = WebViewModel(
        initUrl: 'https://example.com',
        proxySettings: UserProxySettings(
            type: ProxyType.SOCKS5, address: '10.0.0.1:1080', leavesBy: _wg0),
      );
      final shared = SiteSettingsQrCodec.decode(SiteSettingsQrCodec.encode(
          SiteSettingsQrCodec.shareableSubset(site.toJson())))!;
      final proxy = shared['proxySettings'] as Map<String, dynamic>;
      expect(proxy['address'], '10.0.0.1:1080');
      expect(proxy.containsKey('networkInterface'), isFalse);
    });

    test('NETIF-012: a QR that names an interface binds no site', () {
      final hostile = {
        'initUrl': 'https://example.com',
        'proxySettings': {
          'type': ProxyType.DEFAULT.index,
          'networkInterface': {'name': 'wg0'},
        },
      };
      final payload = base64Url
          .encode(gzip.encode(utf8.encode(jsonEncode(hostile))))
          .replaceAll('=', '');
      final decoded =
          SiteSettingsQrCodec.decode('webspace://qr/site/v1/$payload')!;
      final proxy = decoded['proxySettings'] as Map<String, dynamic>;
      expect(proxy.containsKey('networkInterface'), isFalse);
    });
  });

  group('Network interface row (NETIF-010)', () {
    const channel =
        MethodChannel('org.codeberg.theoden8.webspace/egress_relay');

    setUp(() {
      GlobalOutboundProxy.setInMemory(
          UserProxySettings(type: ProxyType.DEFAULT));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'links') return null;
        return [
          {'name': 'lo', 'up': true, 'addresses': ['127.0.0.1']},
          {'name': 'wg0', 'up': true, 'addresses': ['10.64.0.2']},
          {'name': 'eth0', 'up': true, 'addresses': ['192.168.1.5']},
        ];
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    Future<void> pump(WidgetTester tester,
        {required SiteNetworkValues values,
        ValueChanged<SiteNetworkValues>? onChanged}) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SiteNetworkScreen(
          host: 'example.com',
          siteId: SiteId('site-1'),
          values: values,
          onChanged: onChanged ?? (_) {},
          proxyAddressController: TextEditingController(),
          proxyUsernameController: TextEditingController(),
          proxyPasswordController: TextEditingController(),
          proxySupported: true,
          showSavedSignIns: false,
        ),
      ));
      await tester.pumpAndSettle();
    }

    SiteNetworkValues values({
      ProxyType proxyType = ProxyType.DEFAULT,
      InterfaceChoice leavesBy = const SystemRouting(),
    }) =>
        SiteNetworkValues(
          proxyType: proxyType,
          leavesBy: leavesBy,
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        );

    final dropdown = find.byType(DropdownButton<InterfaceChoice>);

    testWidgets('NETIF-013: absent while the experiment is off',
        (tester) async {
      await pump(tester, values: values());
      expect(find.text('Network interface'), findsNothing);
    });

    testWidgets('NETIF-010: lists the interfaces present and reports a pick',
        (tester) async {
      EgressRelay.instance.setInMemory(state: _up);
      SiteNetworkValues? changed;
      await pump(tester, values: values(), onChanged: (v) => changed = v);
      expect(find.text('Network interface'), findsOneWidget);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('lo'), findsNothing);
      expect(find.text('eth0'), findsWidgets);
      await tester.tap(find.text('wg0').last);
      await tester.pumpAndSettle();
      expect(changed?.leavesBy, _wg0);
    });

    testWidgets('NETIF-010: a stored interface that is gone stays chosen',
        (tester) async {
      EgressRelay.instance.setInMemory(state: _up);
      final gone = NamedInterface(InterfaceName.parse('tun9')!);
      await pump(tester, values: values(leavesBy: gone));
      expect(find.text('tun9, not connected'), findsWidgets);
    });

    testWidgets('NETIF-006: locked for a Tor site with nothing chosen',
        (tester) async {
      EgressRelay.instance.setInMemory(state: _up);
      await pump(tester, values: values(proxyType: ProxyType.TOR));
      expect(find.text('Tor makes its own connections'), findsOneWidget);
      final guard = tester.widget<IgnorePointer>(find
          .ancestor(of: dropdown, matching: find.byType(IgnorePointer))
          .first);
      expect(guard.ignoring, isTrue);
    });
  });
}
