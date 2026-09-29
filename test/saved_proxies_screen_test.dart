import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/saved_proxies.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/saved_proxies.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/site_info_sheet.dart';

class _MemoryStore extends SavedProxyStore {
  _MemoryStore(this.proxies);

  List<SavedProxy> proxies;
  int saves = 0;

  @override
  List<SavedProxy> load() => proxies;

  @override
  Future<void> save(List<SavedProxy> next) async {
    saves++;
    proxies = [for (final p in next) p.copy()];
  }
}

SavedProxy _vpn() => SavedProxy(
      id: 'vpn',
      name: 'Work VPN',
      settings:
          UserProxySettings(type: ProxyType.SOCKS5, address: '10.8.0.1:1080'),
    );

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ));
  await tester.pumpAndSettle();
}

void main() {
  late AppLocalizations loc;
  late ProxyHealthService previous;

  setUpAll(() async {
    loc = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    previous = ProxyHealthService.instance;
    ProxyHealthService.instance = ProxyHealthService(
      probe: (s) async => ProxyTestResult(s.address == '10.8.0.1:1080'
          ? ProxyTestOutcome.reachable
          : ProxyTestOutcome.unreachable),
    );
    SavedProxies.setInMemory([_vpn()]);
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(() {
    ProxyHealthService.instance = previous;
    SavedProxies.resetForTest();
  });

  group('Saved proxies screen', () {
    testWidgets('lists each proxy with its route, use and status',
        (tester) async {
      await _pump(
        tester,
        SavedProxiesScreen(
          usageCount: (_) => 3,
          usedByAppWide: (_) => false,
          onChanged: () {},
          store: _MemoryStore([_vpn()]),
        ),
      );
      expect(find.text('Work VPN'), findsOneWidget);
      expect(find.text('SOCKS5 10.8.0.1:1080'), findsOneWidget);
      expect(find.text(loc.savedProxyUsage(3)), findsOneWidget);
      expect(find.text(loc.proxyTestOk), findsOneWidget);
    });

    testWidgets('an empty list says so', (tester) async {
      await _pump(
        tester,
        SavedProxiesScreen(
          usageCount: (_) => 0,
          usedByAppWide: (_) => false,
          onChanged: () {},
          store: _MemoryStore([]),
        ),
      );
      expect(find.text(loc.savedProxiesEmpty), findsOneWidget);
    });

    testWidgets('adding one persists it and reports the change',
        (tester) async {
      final store = _MemoryStore([]);
      var changed = 0;
      await _pump(
        tester,
        SavedProxiesScreen(
          usageCount: (_) => 0,
          usedByAppWide: (_) => false,
          onChanged: () => changed++,
          store: store,
        ),
      );
      await tester.tap(find.text(loc.savedProxiesAdd));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.savedProxyName), 'Home');
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          '192.0.2.1:1080');
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();

      expect(store.proxies.single.name, 'Home');
      expect(store.proxies.single.settings.type, ProxyType.SOCKS5);
      expect(store.proxies.single.settings.address, '192.0.2.1:1080');
      expect(changed, 1);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('a proxy without a name or a valid address is not saved',
        (tester) async {
      final store = _MemoryStore([]);
      await _pump(
        tester,
        SavedProxiesScreen(
          usageCount: (_) => 0,
          usedByAppWide: (_) => false,
          onChanged: () {},
          store: store,
        ),
      );
      await tester.tap(find.text(loc.savedProxiesAdd));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          'no-port');
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();

      expect(find.text(loc.savedProxyNameRequired), findsOneWidget);
      expect(find.text(loc.siteSettingsProxyAddressFormatError),
          findsOneWidget);
      expect(store.saves, 0);
    });

    testWidgets('deleting one warns how many sites it blocks',
        (tester) async {
      final store = _MemoryStore([_vpn()]);
      await _pump(
        tester,
        SavedProxiesScreen(
          usageCount: (_) => 2,
          usedByAppWide: (_) => true,
          onChanged: () {},
          store: store,
        ),
      );
      await tester.tap(find.text('Work VPN'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(loc.commonDelete));
      await tester.pumpAndSettle();

      expect(find.text(loc.savedProxyDeleteTitle('Work VPN')), findsOneWidget);
      expect(find.text(loc.savedProxyDeleteBody(2)), findsOneWidget);
      expect(find.text(loc.savedProxyDeleteAppWide), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, loc.commonDelete));
      await tester.pumpAndSettle();
      expect(store.proxies, isEmpty);
      expect(find.text(loc.savedProxiesEmpty), findsOneWidget);
    });
  });

  group('Proxy picker', () {
    Future<List<ProxyChoice>> pick(
      WidgetTester tester, {
      ProxyType type = ProxyType.DEFAULT,
      String? savedProxyId,
      required String label,
    }) async {
      final picked = <ProxyChoice>[];
      await _pump(
        tester,
        Scaffold(
          body: Center(
            child: ProxyChoiceDropdown(
              type: type,
              savedProxyId: savedProxyId,
              savedProxies: [_vpn()],
              torAvailable: false,
              onChanged: picked.add,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(ProxyChoiceDropdown));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('offers a saved proxy by name and reports its id',
        (tester) async {
      final picked = await pick(tester, label: 'Work VPN');
      expect(picked.single.type, ProxyType.SAVED);
      expect(picked.single.savedProxyId, 'vpn');
    });

    testWidgets('offers the plain types beside it', (tester) async {
      final picked = await pick(tester, label: 'HTTPS');
      expect(picked.single.type, ProxyType.HTTPS);
      expect(picked.single.savedProxyId, isNull);
    });

    testWidgets('a deleted saved proxy reads as missing', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: Center(
            child: ProxyChoiceDropdown(
              type: ProxyType.SAVED,
              savedProxyId: 'gone',
              savedProxies: [_vpn()],
              torAvailable: false,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text(loc.savedProxyMissing), findsOneWidget);
    });
  });

  group('Network screen on a saved proxy', () {
    testWidgets('shows the route and whether it answers, not the fields',
        (tester) async {
      await _pump(
        tester,
        SiteNetworkScreen(
          host: 'example.com',
          siteId: 'site-1',
          values: const SiteNetworkValues(
            proxyType: ProxyType.SAVED,
            savedProxyId: 'vpn',
            webRtcPolicy: WebRtcPolicy.defaultPolicy,
          ),
          onChanged: (_) {},
          proxyAddressController: TextEditingController(),
          proxyUsernameController: TextEditingController(),
          proxyPasswordController: TextEditingController(),
          proxySupported: true,
          showSavedSignIns: false,
          savedProxies: [_vpn()],
        ),
      );
      expect(find.text('SOCKS5 10.8.0.1:1080'), findsOneWidget);
      expect(find.text(loc.proxyTestOk), findsOneWidget);
      expect(find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          findsNothing);
    });

    testWidgets('a pick reports the saved proxy with the rest of the value',
        (tester) async {
      SiteNetworkValues? reported;
      await _pump(
        tester,
        SiteNetworkScreen(
          host: 'example.com',
          siteId: 'site-1',
          values: const SiteNetworkValues(
            proxyType: ProxyType.DEFAULT,
            webRtcPolicy: WebRtcPolicy.relayOnly,
          ),
          onChanged: (v) => reported = v,
          proxyAddressController: TextEditingController(),
          proxyUsernameController: TextEditingController(),
          proxyPasswordController: TextEditingController(),
          proxySupported: true,
          showSavedSignIns: false,
          savedProxies: [_vpn()],
        ),
      );
      await tester.tap(find.byType(ProxyChoiceDropdown));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work VPN').last);
      await tester.pumpAndSettle();
      expect(reported!.proxyType, ProxyType.SAVED);
      expect(reported!.savedProxyId, 'vpn');
      expect(reported!.webRtcPolicy, WebRtcPolicy.relayOnly);
    });
  });

  group('Network screen overrides', () {
    Future<List<SiteNetworkValues>> pumpSaved(
      WidgetTester tester, {
      bool ownAddress = false,
      bool ownCredentials = false,
      TextEditingController? address,
    }) async {
      final reported = <SiteNetworkValues>[];
      await _pump(
        tester,
        SiteNetworkScreen(
          host: 'example.com',
          siteId: 'site-1',
          values: SiteNetworkValues(
            proxyType: ProxyType.SAVED,
            savedProxyId: 'vpn',
            ownAddress: ownAddress,
            ownCredentials: ownCredentials,
            webRtcPolicy: WebRtcPolicy.defaultPolicy,
          ),
          onChanged: reported.add,
          proxyAddressController: address ?? TextEditingController(),
          proxyUsernameController: TextEditingController(),
          proxyPasswordController: TextEditingController(),
          proxySupported: true,
          showSavedSignIns: false,
          savedProxies: [_vpn()],
        ),
      );
      return reported;
    }

    testWidgets('both switches start off with no fields', (tester) async {
      await pumpSaved(tester);
      expect(find.text(loc.savedProxyOwnAddress), findsOneWidget);
      expect(find.text(loc.savedProxyOwnCredentials), findsOneWidget);
      expect(find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          findsNothing);
    });

    testWidgets('turning on an own address reports it and shows the field',
        (tester) async {
      final reported = await pumpSaved(tester);
      await tester.tap(find.text(loc.savedProxyOwnAddress));
      await tester.pumpAndSettle();
      expect(reported.last.ownAddress, isTrue);
      expect(reported.last.ownCredentials, isFalse);
      expect(reported.last.savedProxyId, 'vpn');
      expect(find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          findsOneWidget);
    });

    testWidgets('the route follows the own address as it is typed',
        (tester) async {
      final address = TextEditingController();
      await pumpSaved(tester, ownAddress: true, address: address);
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          'de.gw.example:1080');
      await tester.pump();
      expect(find.text('SOCKS5 de.gw.example:1080'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a malformed own address is flagged', (tester) async {
      await pumpSaved(tester, ownAddress: true);
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          'no-port');
      await tester.pump();
      expect(find.text(loc.siteSettingsProxyAddressFormatError),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('Connection indicator', () {
    testWidgets('a proxy being typed is probed once it settles',
        (tester) async {
      final probed = <String?>[];
      final service = ProxyHealthService(probe: (s) async {
        probed.add(s.address);
        return const ProxyTestResult(ProxyTestOutcome.reachable);
      });
      Widget at(String address) => MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ProxyStatusIndicator(
                service: service,
                proxy: UserProxySettings(
                    type: ProxyType.SOCKS5, address: address),
              ),
            ),
          );
      await tester.pumpWidget(at('10.0.0.1:1'));
      await tester.pump();
      expect(probed, ['10.0.0.1:1']);
      await tester.pumpWidget(at('10.0.0.1:10'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(at('10.0.0.1:1080'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(probed, ['10.0.0.1:1']);
      await tester.pump(const Duration(seconds: 2));
      expect(probed, ['10.0.0.1:1', '10.0.0.1:1080']);
    });
  });

  group('Site info sheet connection row', () {
    SiteInfo info(UserProxySettings? proxy) => SiteInfo(
          siteName: 'Mail',
          pageUrl: 'https://mail.example.com/',
          containerId: 'ws-1',
          incognito: false,
          proxy: proxy,
          siteId: 'site-1',
        );

    testWidgets('names a saved proxy and shows whether it answers',
        (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(
                type: ProxyType.SAVED, savedProxyId: 'vpn')),
          ),
        ),
      );
      expect(find.text(loc.siteInfoConnection), findsOneWidget);
      expect(find.text('Work VPN'), findsOneWidget);
      expect(find.text('SOCKS5 10.8.0.1:1080'), findsOneWidget);
      expect(find.text(loc.proxyTestOk), findsOneWidget);
    });

    testWidgets('a site with no proxy reads as direct', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(type: ProxyType.DEFAULT)),
          ),
        ),
      );
      expect(find.text(loc.siteInfoConnectionDirect), findsOneWidget);
    });

    testWidgets('a missing saved proxy says so', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(
                type: ProxyType.SAVED, savedProxyId: 'gone')),
          ),
        ),
      );
      expect(find.text(loc.savedProxyMissing), findsWidgets);
    });

    testWidgets('no row where the platform binds no proxy', (tester) async {
      await _pump(tester, Scaffold(body: SiteInfoSheet(info: info(null))));
      expect(find.text(loc.siteInfoConnection), findsNothing);
    });
  });
}
