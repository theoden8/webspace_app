import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/saved_proxies.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/widgets/proxy_status_indicator.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'helpers/localized.dart';

class _MemoryStore extends ProxyLibraryStore {
  _MemoryStore(this.data);

  ProxyLibraryData data;
  int saves = 0;

  @override
  ProxyLibraryData load() => data.copy();

  @override
  Future<void> save(ProxyLibraryData next) async {
    saves++;
    data = next.copy();
  }
}

ProxyLibraryData _library() => ProxyLibraryData(
      gateways: [
        SavedGateway(
            id: 'us', name: 'VPN US', type: ProxyType.SOCKS5, address: 'us.gw:1080'),
        SavedGateway(
            id: 'de', name: 'VPN DE', type: ProxyType.SOCKS5, address: 'de.gw:1080'),
      ],
      credentials: [
        SavedCredentials(
            id: 'alice',
            name: 'Alice',
            username: 'alice',
            password: 'p',
            gatewayIds: {'us', 'de'}),
        SavedCredentials(
            id: 'mail',
            name: 'Mail session',
            username: 'alice-session-mail',
            password: 'p',
            gatewayIds: {'de'}),
      ],
      proxies: [
        SavedProxy(
          id: 'work',
          name: 'Work VPN',
          settings: UserProxySettings(
              type: ProxyType.GATEWAY, gatewayId: 'us', credentialsId: 'alice'),
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, {required Widget home}) async {
  await pumpLocalized(tester, home: home, size: const Size(1000, 2400));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester,
    {required Finder dropdown, required String label}) async {
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
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
      probe: (s) async => ProxyTestResult(s.address == 'us.gw:1080'
          ? ProxyTestOutcome.reachable
          : ProxyTestOutcome.unreachable),
    );
    ProxyLibrary.setInMemory(_library());
    GlobalOutboundProxy.resetForTest();
  });

  tearDown(() {
    ProxyHealthService.instance = previous;
    ProxyLibrary.resetForTest();
  });

  ProxyLibraryScreen screen(_MemoryStore store,
          {List<UserProxySettings> sites = const [], VoidCallback? onChanged}) =>
      ProxyLibraryScreen(
        siteProxies: () => sites,
        appWideProxy: () => UserProxySettings(type: ProxyType.DEFAULT),
        onChanged: onChanged ?? () {},
        store: store,
      );

  group('Saved proxies screen', () {
    testWidgets('lists proxies, gateways and credentials with their use',
        (tester) async {
      await _pump(
        tester,
        home: screen(_MemoryStore(_library()), sites: [
          UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'work'),
          UserProxySettings(
              type: ProxyType.GATEWAY, gatewayId: 'de', credentialsId: 'mail'),
        ]),
      );
      expect(find.text('Work VPN'), findsOneWidget);
      expect(find.text('VPN US · Alice'), findsOneWidget);
      expect(find.text(loc.proxyTestOk), findsOneWidget);
      expect(find.text('VPN DE'), findsWidgets);
      expect(find.text('SOCKS5 de.gw:1080'), findsOneWidget);
      expect(find.text('Mail session'), findsOneWidget);
      expect(find.text(loc.proxyLibraryWorksOnList('VPN DE')), findsOneWidget);
      // Alice is used by the site on Work VPN; Mail session by the other.
      expect(find.text(loc.savedProxyUsage(1)), findsWidgets);
    });

    testWidgets('an empty library says so under each heading',
        (tester) async {
      await _pump(tester, home: screen(_MemoryStore(ProxyLibraryData())));
      expect(find.text(loc.proxyLibraryNone), findsNWidgets(3));
    });

    testWidgets('a plain proxy is typed in one form (the 1-1 case)',
        (tester) async {
      final store = _MemoryStore(ProxyLibraryData());
      var changed = 0;
      await _pump(tester, home: screen(store, onChanged: () => changed++));
      await tester.tap(find.text(loc.savedProxiesAdd));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.savedProxyName), 'Home');
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          '192.0.2.1:1080');
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();

      final saved = store.data.proxies.single;
      expect(saved.name, 'Home');
      expect(saved.settings.type, ProxyType.SOCKS5);
      expect(saved.settings.address, '192.0.2.1:1080');
      expect(store.data.gateways, isEmpty);
      expect(changed, 1);
    });

    testWidgets('a gateway is saved on its own', (tester) async {
      final store = _MemoryStore(ProxyLibraryData());
      await _pump(tester, home: screen(store));
      await tester.tap(find.text(loc.proxyLibraryAddGateway));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.savedProxyName), 'VPN FR');
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          'fr.gw:1080');
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();
      expect(store.data.gateways.single.address, 'fr.gw:1080');
    });

    testWidgets('credentials must name a gateway they work on',
        (tester) async {
      final store = _MemoryStore(_library());
      await _pump(tester, home: screen(store));
      await tester.tap(find.text(loc.proxyLibraryAddCredentials));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.savedProxyName), 'Bob');
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();
      expect(find.text(loc.proxyLibraryWorksOnRequired), findsOneWidget);
      expect(store.saves, 0);

      await tester.tap(find.widgetWithText(CheckboxListTile, 'VPN DE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();
      final bob = store.data.credentials.last;
      expect(bob.name, 'Bob');
      expect(bob.gatewayIds, {'de'});
    });

    testWidgets('a saved proxy pairs a gateway with credentials that fit',
        (tester) async {
      final store = _MemoryStore(_library());
      await _pump(tester, home: screen(store));
      await tester.tap(find.text(loc.savedProxiesAdd));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, loc.savedProxyName), 'Mail DE');
      await _pick(tester,
          dropdown: find.byType(ProxyChoiceDropdown), label: 'VPN DE');
      // Both credentials fit DE; only Alice fits US, so Mail session is
      // offered here and nowhere else.
      await _pick(tester,
          dropdown: find.byType(ProxyCredentialsDropdown),
          label: 'Mail session');
      await tester.tap(find.text(loc.commonSave));
      await tester.pumpAndSettle();
      final p = store.data.proxies.last.settings;
      expect(p.type, ProxyType.GATEWAY);
      expect(p.gatewayId, 'de');
      expect(p.credentialsId, 'mail');
    });

    testWidgets('deleting a gateway warns and unlists it from credentials',
        (tester) async {
      final store = _MemoryStore(_library());
      await _pump(
        tester,
        home: screen(store, sites: [
          UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'work'),
          UserProxySettings(type: ProxyType.GATEWAY, gatewayId: 'us'),
        ]),
      );
      await tester.tap(find.text('VPN US').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(loc.commonDelete));
      await tester.pumpAndSettle();
      expect(find.text(loc.savedProxyDeleteBody(2)), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, loc.commonDelete));
      await tester.pumpAndSettle();
      expect(store.data.gateway('us'), isNull);
      expect(store.data.credentialsById('alice')!.gatewayIds, {'de'});
      // Work VPN now names a gateway that is gone, and says so.
      expect(find.text(loc.proxyLibraryGatewayMissing), findsOneWidget);
    });
  });

  group('Proxy picker', () {
Future<List<ProxyChoice>> pick(WidgetTester tester,
    {required String label}) async {
  final picked = <ProxyChoice>[];
  await _pump(
    tester,
    home: Scaffold(
      body: Center(
        child: ProxyChoiceDropdown(
          type: ProxyType.DEFAULT,
          savedProxyId: null,
          gatewayId: null,
          library: _library(),
          torAvailable: false,
          onChanged: picked.add,
        ),
      ),
    ),
  );
  await _pick(tester, dropdown: find.byType(ProxyChoiceDropdown), label: label);
  return picked;
}

    testWidgets('offers a saved proxy by name', (tester) async {
      final picked = await pick(tester, label: 'Work VPN');
      expect(picked.single.type, ProxyType.SAVED);
      expect(picked.single.savedProxyId, 'work');
    });

    testWidgets('offers a saved gateway by name', (tester) async {
      final picked = await pick(tester, label: 'VPN DE');
      expect(picked.single.type, ProxyType.GATEWAY);
      expect(picked.single.gatewayId, 'de');
    });

    testWidgets('offers the plain types beside them', (tester) async {
      final picked = await pick(tester, label: 'HTTPS');
      expect(picked.single.type, ProxyType.HTTPS);
    });

    testWidgets('credentials are offered only where they fit',
        (tester) async {
      await _pump(
        tester,
        home: Scaffold(
          body: Center(
            child: ProxyCredentialsDropdown(
              gatewayId: 'us',
              credentialsId: null,
              library: _library(),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byType(ProxyCredentialsDropdown));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsWidgets);
      expect(find.text('Mail session'), findsNothing);
    });

    testWidgets('a pairing that no longer fits says so', (tester) async {
      await _pump(
        tester,
        home: Scaffold(
          body: Center(
            child: ProxyCredentialsDropdown(
              gatewayId: 'us',
              credentialsId: 'mail',
              library: _library(),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text(loc.proxyLibraryCredentialsMismatch), findsOneWidget);
    });
  });

  group('Network screen', () {
    Future<List<SiteNetworkValues>> pumpNetwork(
      WidgetTester tester, {
      required SiteNetworkValues values,
      TextEditingController? username,
    }) async {
      final reported = <SiteNetworkValues>[];
      await _pump(
        tester,
        home: SiteNetworkScreen(
          host: 'example.com',
          siteId: 'site-1',
          values: values,
          onChanged: reported.add,
          proxyAddressController: TextEditingController(),
          proxyUsernameController: username ?? TextEditingController(),
          proxyPasswordController: TextEditingController(),
          proxySupported: true,
          showSavedSignIns: false,
          library: _library(),
        ),
      );
      return reported;
    }

    testWidgets('a saved proxy shows its route and status, no fields',
        (tester) async {
      await pumpNetwork(
        tester,
        values: const SiteNetworkValues(
          proxyType: ProxyType.SAVED,
          savedProxyId: 'work',
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        ),
      );
      expect(find.text('SOCKS5 us.gw:1080'), findsOneWidget);
      expect(find.text(loc.proxyTestOk), findsOneWidget);
      expect(find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          findsNothing);
      expect(find.byType(ProxyCredentialsDropdown), findsNothing);
    });

    testWidgets('a saved gateway takes saved credentials, no address',
        (tester) async {
      final reported = await pumpNetwork(
        tester,
        values: const SiteNetworkValues(
          proxyType: ProxyType.GATEWAY,
          gatewayId: 'de',
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        ),
      );
      expect(find.widgetWithText(TextFormField, loc.siteSettingsProxyAddress),
          findsNothing);
      await _pick(tester,
          dropdown: find.byType(ProxyCredentialsDropdown),
          label: 'Mail session');
      expect(reported.last.credentialsId, 'mail');
      expect(reported.last.gatewayId, 'de');
    });

    testWidgets('moving to a gateway the credentials do not list drops them',
        (tester) async {
      final reported = await pumpNetwork(
        tester,
        values: const SiteNetworkValues(
          proxyType: ProxyType.GATEWAY,
          gatewayId: 'de',
          credentialsId: 'mail',
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        ),
      );
      await _pick(tester,
          dropdown: find.byType(ProxyChoiceDropdown), label: 'VPN US');
      expect(reported.last.gatewayId, 'us');
      expect(reported.last.credentialsId, isNull);
    });

    testWidgets('credentials that list the new gateway are kept',
        (tester) async {
      final reported = await pumpNetwork(
        tester,
        values: const SiteNetworkValues(
          proxyType: ProxyType.GATEWAY,
          gatewayId: 'de',
          credentialsId: 'alice',
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        ),
      );
      await _pick(tester,
          dropdown: find.byType(ProxyChoiceDropdown), label: 'VPN US');
      expect(reported.last.credentialsId, 'alice');
    });

    testWidgets('typed credentials on a saved gateway reach the status row',
        (tester) async {
      final username = TextEditingController();
      await pumpNetwork(
        tester,
        values: const SiteNetworkValues(
          proxyType: ProxyType.GATEWAY,
          gatewayId: 'de',
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        ),
        username: username,
      );
      expect(find.text('SOCKS5 de.gw:1080'), findsOneWidget);
      username.text = 'typed-user';
      await tester.pump();
      expect(find.text('SOCKS5 de.gw:1080'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('the Network screen offers the library with developer mode off',
      (tester) async {
    DeveloperModeService.instance.debugSet(on: false);
    await _pump(
      tester,
      home: SiteNetworkScreen(
        host: 'example.com',
        siteId: 'site-1',
        values: const SiteNetworkValues(
          proxyType: ProxyType.DEFAULT,
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        ),
        onChanged: (_) {},
        proxyAddressController: TextEditingController(),
        proxyUsernameController: TextEditingController(),
        proxyPasswordController: TextEditingController(),
        proxySupported: true,
        showSavedSignIns: false,
        library: _library(),
      ),
    );
    await tester.tap(find.byType(ProxyChoiceDropdown));
    await tester.pumpAndSettle();
    expect(find.text('Work VPN'), findsWidgets);
    expect(find.text('VPN DE'), findsWidgets);
  });

  group('Connection indicator', () {
    testWidgets('a proxy being typed is probed once it settles',
        (tester) async {
      final probed = <String?>[];
      final service = ProxyHealthService(probe: (s) async {
        probed.add(s.address);
        return const ProxyTestResult(ProxyTestOutcome.reachable);
      });
      Widget at(String address) => localizedApp(Scaffold(
        body: ProxyStatusIndicator(
          service: service,
          proxy:
              UserProxySettings(type: ProxyType.SOCKS5, address: address),
        ),
      ));
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
        home: Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(
                type: ProxyType.SAVED, savedProxyId: 'work')),
          ),
        ),
      );
      expect(find.text(loc.siteInfoConnection), findsOneWidget);
      expect(find.text('Work VPN'), findsOneWidget);
      expect(find.text('SOCKS5 us.gw:1080'), findsOneWidget);
      expect(find.text(loc.proxyTestOk), findsOneWidget);
    });

    testWidgets('names a saved gateway', (tester) async {
      await _pump(
        tester,
        home: Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(
                type: ProxyType.GATEWAY, gatewayId: 'de', credentialsId: 'mail')),
          ),
        ),
      );
      expect(find.text('VPN DE'), findsOneWidget);
      expect(find.text('SOCKS5 de.gw:1080'), findsOneWidget);
    });

    testWidgets('a site with no proxy reads as direct', (tester) async {
      await _pump(
        tester,
        home: Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(type: ProxyType.DEFAULT)),
          ),
        ),
      );
      expect(find.text(loc.siteInfoConnectionDirect), findsOneWidget);
    });

    testWidgets('a pairing that does not fit says why', (tester) async {
      await _pump(
        tester,
        home: Scaffold(
          body: SiteInfoSheet(
            info: info(UserProxySettings(
                type: ProxyType.GATEWAY, gatewayId: 'us', credentialsId: 'mail')),
          ),
        ),
      );
      expect(find.text(loc.proxyLibraryCredentialsMismatch), findsWidgets);
    });

    testWidgets('no row where the platform binds no proxy', (tester) async {
      await _pump(tester,
          home: Scaffold(body: SiteInfoSheet(info: info(null))));
      expect(find.text(loc.siteInfoConnection), findsNothing);
    });
  });
}
