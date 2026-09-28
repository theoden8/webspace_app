import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';

import 'helpers/mock_secure_storage.dart';

SiteNetworkValues _values({
  ProxyType proxyType = ProxyType.DEFAULT,
  String? torExitCountry,
  WebRtcPolicy webRtcPolicy = WebRtcPolicy.defaultPolicy,
}) =>
    SiteNetworkValues(
      proxyType: proxyType,
      torExitCountry: torExitCountry,
      webRtcPolicy: webRtcPolicy,
    );

class _Form {
  final address = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
}

Future<_Form> _pump(
  WidgetTester tester, {
  required SiteNetworkValues values,
  ValueChanged<SiteNetworkValues>? onChanged,
  bool proxySupported = true,
  Widget? proxyTest,
  String address = '',
}) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final form = _Form()..address.text = address;
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SiteNetworkScreen(
      host: 'example.com',
      siteId: 'site-1',
      values: values,
      onChanged: onChanged ?? (_) {},
      proxyAddressController: form.address,
      proxyUsernameController: form.username,
      proxyPasswordController: form.password,
      proxySupported: proxySupported,
      proxyTest: proxyTest,
      // Secure storage has no platform side here; the row is covered on its
      // own below with an in-memory store.
      showSavedSignIns: false,
    ),
  ));
  await tester.pumpAndSettle();
  return form;
}

Finder get _proxyDropdown => find.byType(DropdownButton<ProxyType>);
Finder get _webRtcDropdown => find.byType(DropdownButton<WebRtcPolicy>);
Finder get _addressField =>
    find.widgetWithText(TextFormField, 'Proxy Address');

Future<void> _pick(WidgetTester tester, Finder dropdown, String label) async {
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  late AppLocalizations loc;

  setUpAll(() async {
    loc = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('SiteNetworkValues', () {
    test('an explicit null unpins the exit country, an omitted one keeps it',
        () {
      final pinned = _values(proxyType: ProxyType.TOR, torExitCountry: 'de');
      expect(pinned.copyWith(webRtcPolicy: WebRtcPolicy.disabled)
          .torExitCountry, 'de');
      expect(pinned.copyWith(torExitCountry: null).torExitCountry, isNull);
    });
  });

  group('validateProxyAddress', () {
    test('DEFAULT and TOR carry no address to check', () {
      expect(validateProxyAddress(loc, ProxyType.DEFAULT, ''), isNull);
      expect(validateProxyAddress(loc, ProxyType.TOR, ''), isNull);
    });

    test('a manual proxy needs host:port with a real port', () {
      expect(validateProxyAddress(loc, ProxyType.SOCKS5, ''),
          loc.siteSettingsProxyAddressRequired);
      expect(validateProxyAddress(loc, ProxyType.HTTP, 'proxy.example.com'),
          loc.siteSettingsProxyAddressFormatError);
      expect(validateProxyAddress(loc, ProxyType.HTTPS, 'proxy:70000'),
          loc.siteSettingsProxyInvalidPort);
      expect(validateProxyAddress(loc, ProxyType.SOCKS5, '127.0.0.1:1080'),
          isNull);
    });
  });

  testWidgets('proxy and WebRTC both live on this screen', (tester) async {
    await _pump(tester, values: _values());
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Proxy'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(_proxyDropdown, findsOneWidget);
    expect(_webRtcDropdown, findsOneWidget);
    // DEFAULT has nothing to type in.
    expect(_addressField, findsNothing);
  });

  testWidgets('no proxy group where the platform cannot bind one',
      (tester) async {
    await _pump(tester, values: _values(), proxySupported: false);
    expect(find.text('Proxy'), findsNothing);
    expect(_proxyDropdown, findsNothing);
    expect(_webRtcDropdown, findsOneWidget);
  });

  testWidgets('picking a proxy reports the whole value and opens its fields',
      (tester) async {
    SiteNetworkValues? reported;
    await _pump(
      tester,
      values: _values(webRtcPolicy: WebRtcPolicy.relayOnly),
      onChanged: (v) => reported = v,
    );
    await _pick(tester, _proxyDropdown, 'SOCKS5');
    expect(reported?.proxyType, ProxyType.SOCKS5);
    expect(reported?.webRtcPolicy, WebRtcPolicy.relayOnly);
    expect(_addressField, findsOneWidget);
    expect(find.text('Proxy authentication'), findsOneWidget);
  });

  testWidgets('the address is typed into the caller\'s controller',
      (tester) async {
    final form = await _pump(tester, values: _values(proxyType: ProxyType.HTTP));
    await tester.enterText(_addressField, 'proxy.example.com:8080');
    expect(form.address.text, 'proxy.example.com:8080');
  });

  testWidgets('a malformed address is flagged on the screen that holds it',
      (tester) async {
    await _pump(tester, values: _values(proxyType: ProxyType.SOCKS5));
    await tester.enterText(_addressField, 'proxy.example.com');
    await tester.pump();
    expect(find.text(loc.siteSettingsProxyAddressFormatError), findsOneWidget);
    await tester.enterText(_addressField, 'proxy.example.com:1080');
    await tester.pump();
    expect(find.text(loc.siteSettingsProxyAddressFormatError), findsNothing);
  });

  testWidgets('TOR hides the manual fields and offers an exit country',
      (tester) async {
    SiteNetworkValues? reported;
    await _pump(
      tester,
      values: _values(proxyType: ProxyType.TOR, torExitCountry: 'zz'),
      onChanged: (v) => reported = v,
    );
    expect(_addressField, findsNothing);
    expect(find.text('Exit country'), findsOneWidget);
    // An unlisted pin is still a pin (TOR-014).
    expect(find.text('ZZ'), findsOneWidget);

    await tester.tap(find.text('Exit country'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any country'));
    await tester.pumpAndSettle();
    expect(reported?.proxyType, ProxyType.TOR);
    expect(reported?.torExitCountry, isNull);
    expect(find.text('Any country'), findsOneWidget);
  });

  testWidgets('WebRTC policy reports the whole value', (tester) async {
    SiteNetworkValues? reported;
    await _pump(
      tester,
      values: _values(proxyType: ProxyType.SOCKS5),
      onChanged: (v) => reported = v,
    );
    await _pick(tester, _webRtcDropdown, 'Disabled');
    expect(reported?.webRtcPolicy, WebRtcPolicy.disabled);
    expect(reported?.proxyType, ProxyType.SOCKS5);
  });

  testWidgets('the connection test shows only while a proxy is chosen',
      (tester) async {
    const probe = Text('probe', key: Key('probe'));
    await _pump(tester, values: _values(), proxyTest: probe);
    expect(find.byKey(const Key('probe')), findsNothing);
    await _pick(tester, _proxyDropdown, 'HTTP');
    expect(find.byKey(const Key('probe')), findsOneWidget);
  });

  group('SavedSignInsTile', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('shows the count and forgets on confirm', (tester) async {
      final store =
          HttpAuthSecureStorage(secureStorage: MockFlutterSecureStorage());
      const c = HttpAuthCredential(username: 'alice', password: 's3cret');
      await tester.runAsync(() async {
        await store.save('site-1', 'nas.example.com', 'Files', c);
        await store.save('site-1', 'nas.example.com', 'Admin', c);
      });

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SavedSignInsTile(siteId: 'site-1', storage: store),
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('2 saved'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Clear').last);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('None'), findsOneWidget);
      expect(await tester.runAsync(() => store.countForSite('site-1')), 0);
    });
  });
}
