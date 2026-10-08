import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'package:webspace/services/webview_proxy.dart';

/// Pushes site settings over a plain home route, so a back press is a real
/// pop that the unsaved-changes guard can intercept.
Future<void> _pump(WidgetTester tester, {required WebViewModel model}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreen(webViewModel: model),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

String _summary(WidgetTester tester) {
  final row = find.ancestor(
    of: find.text('Network'),
    matching: find.byType(ListTile),
  );
  final tile = tester.widget<ListTile>(row);
  return (tile.subtitle! as Text).data!;
}

Future<void> _openNetwork(WidgetTester tester) async {
  await tester.tap(find.text('Network'));
  await tester.pumpAndSettle();
  expect(find.byType(SiteNetworkScreen), findsOneWidget);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // The Linux host reports per-site proxy support without a plugin call.
    await PlatformInfo.initialize();
  });

  tearDown(GlobalOutboundProxy.resetForTest);

  testWidgets('the Network row sits between Behaviour and Privacy',
      (tester) async {
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Site'), lessThan(y('Behaviour')));
    expect(y('Behaviour'), lessThan(y('Network')));
    expect(y('Network'), lessThan(y('Privacy')));
    expect(y('Privacy'), lessThan(y('Permissions')));
  });

  testWidgets('no network control is left on the settings screen',
      (tester) async {
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    expect(find.byType(DropdownButton<ProxyType>), findsNothing);
    expect(find.byType(ProxyChoiceDropdown), findsNothing);
    expect(find.byType(DropdownButton<WebRtcPolicy>), findsNothing);
    expect(find.text('Saved sign-ins'), findsNothing);
  });

  testWidgets('a site with nothing set reads as the default connection',
      (tester) async {
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    expect(_summary(tester), 'Default connection');
  });

  testWidgets('a site without its own proxy names the app-wide one',
      (tester) async {
    GlobalOutboundProxy.setForTest(
      UserProxySettings(type: ProxyType.SOCKS5, address: '10.0.0.1:1080'),
    );
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        trackingProtectionEnabled: false,
      ),
    );
    expect(_summary(tester), 'App-wide proxy');
  });

  testWidgets('a Default that Tracking Protection raises reads as Relay only',
      (tester) async {
    GlobalOutboundProxy.setForTest(
      UserProxySettings(type: ProxyType.SOCKS5, address: '10.0.0.1:1080'),
    );
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    expect(_summary(tester), 'App-wide proxy · WebRTC: Relay only');
  });

  testWidgets('the row names the proxy and a non-default WebRTC policy',
      (tester) async {
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings:
            UserProxySettings(type: ProxyType.SOCKS5, address: '127.0.0.1:1080'),
        webRtcPolicy: WebRtcPolicy.relayOnly,
      ),
    );
    expect(_summary(tester), 'SOCKS5 127.0.0.1:1080 · WebRTC: Relay only');
  });

  testWidgets('a saved proxy goes by its name (NET-002, PROXY-030)',
      (tester) async {
    ProxyLibrary.setInMemory(ProxyLibraryData(
      gateways: [
        SavedGateway(
            id: 'de', name: 'VPN DE', type: ProxyType.SOCKS5, address: 'de.gw:1'),
      ],
      proxies: [
        SavedProxy(
          id: 'vpn',
          name: 'Work VPN',
          settings: UserProxySettings(
              type: ProxyType.SOCKS5, address: '10.8.0.1:1080'),
        ),
      ],
    ));
    addTearDown(ProxyLibrary.resetForTest);
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings:
            UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'vpn'),
        // The entry's name is the point here; ETP-031's WebRTC entry has
        // its own test.
        trackingProtectionEnabled: false,
      ),
    );
    expect(_summary(tester), 'Work VPN');
  });

  testWidgets('a saved gateway goes by its name', (tester) async {
    ProxyLibrary.setInMemory(ProxyLibraryData(gateways: [
      SavedGateway(
          id: 'de', name: 'VPN DE', type: ProxyType.SOCKS5, address: 'de.gw:1'),
    ]));
    addTearDown(ProxyLibrary.resetForTest);
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings:
            UserProxySettings(type: ProxyType.GATEWAY, gatewayId: 'de'),
        // The entry's name is the point here; ETP-031's WebRTC entry has
        // its own test.
        trackingProtectionEnabled: false,
      ),
    );
    expect(_summary(tester), 'VPN DE');
  });

  testWidgets('a deleted saved proxy reads as missing', (tester) async {
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings:
            UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'gone'),
        // The entry's name is the point here; ETP-031's WebRTC entry has
        // its own test.
        trackingProtectionEnabled: false,
      ),
    );
    expect(_summary(tester), 'Missing saved proxy');
  });

  testWidgets('a pinned Tor exit counts, and more than two overflow',
      (tester) async {
    final country = kTorExitCountries.first;
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings:
            UserProxySettings(type: ProxyType.TOR, torExitCountry: country.code),
        webRtcPolicy: WebRtcPolicy.disabled,
      ),
    );
    expect(_summary(tester), 'TOR · ${country.label} · 1 more');
  });

  testWidgets('a WebRTC edit comes back to the row and guards the leave',
      (tester) async {
    await _pump(tester, model: WebViewModel(initUrl: 'https://example.com/'));
    await _openNetwork(tester);
    await tester.tap(find.byType(DropdownButton<WebRtcPolicy>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disabled').last);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(_summary(tester), 'WebRTC: Disabled');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
  });

  // BUG-006: the exit country was the one proxy field the dirty snapshot did
  // not read, so pinning one and backing out dropped it without a prompt.
  testWidgets('pinning a Tor exit country guards the leave', (tester) async {
    final country = kTorExitCountries.first;
    await _pump(
      tester,
      model: WebViewModel(
        initUrl: 'https://example.com/',
        proxySettings: UserProxySettings(type: ProxyType.TOR),
      ),
    );
    await _openNetwork(tester);
    await tester.tap(find.text('Exit country'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(country.label));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
  });

  testWidgets('an archived site lists no grant the archive holds off',
      (tester) async {
    final model = WebViewModel(initUrl: 'https://example.com/')
      ..isArchiveTier = true
      ..captures = CaptureGrants.none.copyWith(
        camera: (mode: CameraAccessMode.real, source: null),
        microphone: (mode: MicrophoneAccessMode.real, source: null),
      );
    await _pump(tester, model: model);
    final row = find.ancestor(
      of: find.text('Permissions'),
      matching: find.byType(ListTile),
    );
    final summary = (tester.widget<ListTile>(row).subtitle! as Text).data!;
    expect(summary, isNot(contains('Camera access')),
        reason: 'the drawer shows no camera badge for it either');
    expect(summary, isNot(contains('Microphone access')));
    expect(model.captures.camera.mode, CameraAccessMode.real,
        reason: 'the stored grant survives for when it leaves the archive');
  });
}
